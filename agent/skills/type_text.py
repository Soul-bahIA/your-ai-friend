"""Skill : saisir du texte au clavier (sensible).

Frappe FIABLE quel que soit l'agencement clavier (AZERTY, QWERTZ, accents,
symboles) : `pyautogui.typewrite` raisonne en QWERTY US (« ! » tapé « § »,
accents perdus). Méthodes :

  - "clipboard" (défaut) : le texte est collé via Ctrl+V. Le contenu précédent du
    presse-papier est SAUVEGARDÉ puis RESTAURÉ juste après (S8) ; le texte collé
    est marqué « hors historique / hors cloud » (Win+V). Si le presse-papier
    contient autre chose que du texte (image, fichiers, HTML…), impossible de le
    restaurer fidèlement : on ne le touche pas et on bascule sur "unicode".
  - "unicode" (Windows) : SendInput KEYEVENTF_UNICODE, caractère par caractère,
    indépendant de l'agencement, sans presse-papier.
  - "typewrite" : frappe touche par touche pyautogui (ASCII).

Sécurité :
  - le texte n'apparaît jamais dans les journaux, évènements ni résultats
    (« [texte masqué : N car.] ») ; il est affiché EN ENTIER sur la console locale
    au moment de la confirmation (S7) ;
  - S3 : même avec le contrôle d'entrée pré-autorisé, une saisie dans une fenêtre
    inconnue (terminal, boîte « Exécuter », Explorateur, appli hors allowlist…) ou
    qui ne correspond pas à `window_title` reste confirmée.

Exemple : {"type": "type_text", "text": "Bonjour !", "window_title": "Bloc-notes"}
"""
from __future__ import annotations

import hashlib
import logging
import sys
import time

from skills import desktop
from skills.base import PathCheck, Skill, SkillResult, is_number, mask_text
from skills.open_app import _BLOCKED_APPS, _allowed_apps

log = logging.getLogger("soulbah.type_text")

_MAX_TEXT = 20000
_METHODS = ("clipboard", "unicode", "typewrite")
_PASTE_SETTLE_SECONDS = 0.5  # laisse l'application lire le presse-papier avant restauration

# Hôtes de commandes / terminaux : y taper du texte revient à exécuter des commandes.
_TERMINAL_HOSTS = frozenset(_BLOCKED_APPS) | {
    "windowsterminal", "openconsole", "mintty", "putty", "kitty", "alacritty", "wezterm-gui",
    "conemu", "conemu64", "cmder", "git-bash", "hyper", "tabby", "warp", "terminal",
}

CF_TEXT = 1
CF_OEMTEXT = 7
CF_UNICODETEXT = 13
CF_LOCALE = 16
_PRIVATE_FORMAT_NAMES = (
    "ExcludeClipboardContentFromMonitorProcessing",
    "CanIncludeInClipboardHistory",
    "CanUploadToCloudClipboard",
)

if sys.platform == "win32":
    import ctypes
    from ctypes import wintypes

    _user32 = ctypes.WinDLL("user32", use_last_error=True)
    _k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _GMEM_MOVEABLE = 0x0002

    _k32.GlobalAlloc.restype = wintypes.HGLOBAL
    _k32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
    _k32.GlobalLock.restype = wintypes.LPVOID
    _k32.GlobalLock.argtypes = [wintypes.HGLOBAL]
    _k32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
    _k32.GlobalFree.argtypes = [wintypes.HGLOBAL]
    _user32.OpenClipboard.argtypes = [wintypes.HWND]
    _user32.SetClipboardData.restype = wintypes.HANDLE
    _user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
    _user32.GetClipboardData.restype = wintypes.HANDLE
    _user32.GetClipboardData.argtypes = [wintypes.UINT]
    _user32.EnumClipboardFormats.restype = wintypes.UINT
    _user32.EnumClipboardFormats.argtypes = [wintypes.UINT]
    _user32.RegisterClipboardFormatW.restype = wintypes.UINT
    _user32.RegisterClipboardFormatW.argtypes = [wintypes.LPCWSTR]

    _ULONG_PTR = ctypes.c_size_t
    _INPUT_KEYBOARD = 1
    _KEYEVENTF_KEYUP = 0x0002
    _KEYEVENTF_UNICODE = 0x0004
    _VK_RETURN = 0x0D
    _VK_TAB = 0x09

    class _MOUSEINPUT(ctypes.Structure):
        _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                    ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", _ULONG_PTR)]

    class _KEYBDINPUT(ctypes.Structure):
        _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                    ("time", wintypes.DWORD), ("dwExtraInfo", _ULONG_PTR)]

    class _HARDWAREINPUT(ctypes.Structure):
        _fields_ = [("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD), ("wParamH", wintypes.WORD)]

    class _INPUTUNION(ctypes.Union):
        _fields_ = [("mi", _MOUSEINPUT), ("ki", _KEYBDINPUT), ("hi", _HARDWAREINPUT)]

    class INPUT(ctypes.Structure):
        _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]

    _user32.SendInput.restype = wintypes.UINT
    _user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]


# --- presse-papier Windows -----------------------------------------------------
def _open_clipboard(retries: int = 10) -> bool:
    for _ in range(retries):
        if _user32.OpenClipboard(None):
            return True
        time.sleep(0.02)
    return False


def _private_formats() -> set[int]:
    return {f for f in (_user32.RegisterClipboardFormatW(n) for n in _PRIVATE_FORMAT_NAMES) if f}


def _put_data(fmt: int, raw: bytes) -> bool:
    handle = _k32.GlobalAlloc(_GMEM_MOVEABLE, max(1, len(raw)))
    if not handle:
        return False
    ptr = _k32.GlobalLock(handle)
    if not ptr:
        _k32.GlobalFree(handle)
        return False
    ctypes.memmove(ptr, raw, len(raw))
    _k32.GlobalUnlock(handle)
    # Une fois SetClipboardData réussi, le système possède la mémoire (ne pas libérer).
    if not _user32.SetClipboardData(fmt, handle):
        _k32.GlobalFree(handle)
        return False
    return True


def _set_clipboard_windows(text: str, private: bool = True) -> bool:
    """Place `text` (Unicode) dans le presse-papier ; `private` l'exclut de
    l'historique Win+V et de la synchronisation cloud."""
    if not _open_clipboard():
        return False
    try:
        _user32.EmptyClipboard()
        if not _put_data(CF_UNICODETEXT, (text + "\0").encode("utf-16-le")):
            return False
        if private:
            for fmt in _private_formats():
                _put_data(fmt, (0).to_bytes(4, "little"))
        return True
    finally:
        _user32.CloseClipboard()


def _snapshot_clipboard_windows() -> tuple[str, str | None]:
    """("empty", None) | ("text", texte) | ("other", None) | ("error", None)."""
    if not _open_clipboard():
        return "error", None
    try:
        formats: set[int] = set()
        fmt = 0
        while True:
            fmt = _user32.EnumClipboardFormats(fmt)
            if not fmt:
                break
            formats.add(fmt)
        if not formats:
            return "empty", None
        if not formats <= ({CF_TEXT, CF_OEMTEXT, CF_UNICODETEXT, CF_LOCALE} | _private_formats()):
            return "other", None
        handle = _user32.GetClipboardData(CF_UNICODETEXT)
        if not handle:
            return "other", None
        ptr = _k32.GlobalLock(handle)
        if not ptr:
            return "other", None
        try:
            return "text", ctypes.wstring_at(ptr)
        finally:
            _k32.GlobalUnlock(handle)
    finally:
        _user32.CloseClipboard()


def _clear_clipboard_windows() -> bool:
    if not _open_clipboard():
        return False
    try:
        return bool(_user32.EmptyClipboard())
    finally:
        _user32.CloseClipboard()


# --- presse-papier multiplateforme -------------------------------------------
def _snapshot_clipboard() -> tuple[str, str | None]:
    if sys.platform == "win32":
        try:
            return _snapshot_clipboard_windows()
        except Exception:  # noqa: BLE001
            return "error", None
    try:
        import pyperclip

        return "text", pyperclip.paste()
    except Exception:  # noqa: BLE001
        return "error", None


def _set_clipboard(text: str) -> bool:
    """Copie `text` dans le presse-papier (natif sous Windows, sinon pyperclip)."""
    if sys.platform == "win32":
        try:
            return _set_clipboard_windows(text)
        except Exception:  # noqa: BLE001
            return False
    try:
        import pyperclip

        pyperclip.copy(text)
        return True
    except Exception:  # noqa: BLE001
        return False


def _restore_clipboard(snapshot: tuple[str, str | None]) -> bool:
    kind, previous = snapshot
    try:
        if sys.platform == "win32":
            if kind == "text":
                return _set_clipboard_windows(previous or "")
            if kind == "empty":
                return _clear_clipboard_windows()
            return False
        if kind == "text":
            import pyperclip

            pyperclip.copy(previous or "")
            return True
    except Exception:  # noqa: BLE001
        return False
    return False


# --- frappe Unicode (Windows) -------------------------------------------------
def build_unicode_inputs(text: str) -> list:
    """Évènements SendInput (appui + relâchement) pour `text` ; \\n → Entrée, \\t → Tab."""
    events = []

    def key(vk: int = 0, scan: int = 0, flags: int = 0) -> None:
        inp = INPUT()
        inp.type = _INPUT_KEYBOARD
        inp.u.ki = _KEYBDINPUT(wVk=vk, wScan=scan, dwFlags=flags, time=0, dwExtraInfo=0)
        events.append(inp)

    for ch in text.replace("\r\n", "\n").replace("\r", "\n"):
        if ch == "\n":
            key(vk=_VK_RETURN)
            key(vk=_VK_RETURN, flags=_KEYEVENTF_KEYUP)
        elif ch == "\t":
            key(vk=_VK_TAB)
            key(vk=_VK_TAB, flags=_KEYEVENTF_KEYUP)
        else:
            raw = ch.encode("utf-16-le")
            for i in range(0, len(raw), 2):
                unit = int.from_bytes(raw[i:i + 2], "little")
                key(scan=unit, flags=_KEYEVENTF_UNICODE)
                key(scan=unit, flags=_KEYEVENTF_UNICODE | _KEYEVENTF_KEYUP)
    return events


def _send_unicode_windows(text: str, interval: float = 0.0) -> None:
    events = build_unicode_inputs(text)
    chunk = 64
    for i in range(0, len(events), chunk):
        part = events[i:i + chunk]
        arr = (INPUT * len(part))(*part)
        sent = _user32.SendInput(len(part), arr, ctypes.sizeof(INPUT))
        if sent != len(part):
            raise OSError(f"SendInput a échoué (erreur {ctypes.get_last_error()}) — "
                          f"fenêtre protégée (lancée en administrateur) ?")
        time.sleep(max(0.005, interval))


def _check_text_step(step: dict) -> str | None:
    text = step.get("text")
    if not isinstance(text, str) or not text:
        return "champ 'text' manquant (texte attendu)"
    if len(text) > _MAX_TEXT:
        return f"texte trop long (max {_MAX_TEXT} caractères)"
    method = step.get("method")
    if method is not None and method not in _METHODS:
        return f"champ 'method' invalide ({' | '.join(_METHODS)})"
    interval = step.get("interval")
    if interval is not None and (not is_number(interval) or not 0 <= interval <= 1):
        return "champ 'interval' invalide (nombre de 0 à 1 s)"
    title = step.get("window_title")
    if title is not None and (not isinstance(title, str) or not title.strip() or len(title) > 200):
        return "champ 'window_title' invalide (texte ≤ 200 caractères)"
    return None


def text_details(text: str) -> str:
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return f"Texte à taper ({len(text)} caractères, sha256 {digest[:16]}…) :\n{text}"


class TypeTextSkill(Skill):
    name = "type_text"
    step_types = ("type_text", "type", "keyboard")
    category = "keyboard"
    sensitive = True

    def describe(self, step: dict) -> str:
        where = step.get("window_title")
        suffix = f" dans « {where} »" if isinstance(where, str) and where else ""
        return f"taper le texte : {mask_text(step.get('text', ''))}{suffix}"

    def confirm_details(self, step: dict) -> str | None:
        text = step.get("text")
        return text_details(text) if isinstance(text, str) else None

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        return _check_text_step(step)

    def input_risk(self, step: dict) -> str | None:
        info = desktop.foreground_window()
        if info is None:
            return "fenêtre cible inconnue (fenêtre au premier plan non identifiable)"
        stem = desktop.exe_stem(info)
        title = str(info.get("title") or "")
        if stem in _TERMINAL_HOSTS:
            return f"saisie dans un terminal / hôte de commandes ({stem})"
        if stem == "explorer" or info.get("class") == "#32770" and not stem:
            return "saisie dans l'Explorateur ou une boîte « Exécuter » (exécution de commandes possible)"
        known = _allowed_apps() - {"explorer"}
        if stem not in known:
            return f"fenêtre cible inconnue ({stem or '?'} — « {title[:60]} »)"
        expected = step.get("window_title")
        if isinstance(expected, str) and expected.strip() and expected.strip().lower() not in title.lower():
            return f"la fenêtre au premier plan (« {title[:60]} ») ne correspond pas à « {expected} »"
        return None

    def _unicode(self, text: str, interval: float) -> SkillResult:
        try:
            _send_unicode_windows(text, interval)
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec saisie Unicode : {e}")
        return SkillResult(ok=True, detail=f"{len(text)} caractères saisis (Unicode, sans presse-papier)")

    def run(self, step: dict) -> SkillResult:
        err = _check_text_step(step)
        if err:
            return SkillResult(ok=False, detail=err)
        text = step["text"]
        method = step.get("method") or "clipboard"
        interval = float(step.get("interval") or 0.0)

        if method == "unicode":
            if sys.platform != "win32":
                return SkillResult(ok=False, detail="méthode 'unicode' disponible sous Windows uniquement")
            return self._unicode(text, interval)

        try:
            import pyautogui
        except ImportError:
            return SkillResult(ok=False, detail="dépendance 'pyautogui' non installée")

        if method == "clipboard":
            snapshot = _snapshot_clipboard()
            if snapshot[0] in ("text", "empty"):
                if not _set_clipboard(text):
                    _restore_clipboard(snapshot)
                    return SkillResult(ok=False, detail="presse-papier indisponible")
                try:
                    time.sleep(0.05)  # laisse le presse-papier se stabiliser
                    pyautogui.hotkey("ctrl", "v")
                    time.sleep(_PASTE_SETTLE_SECONDS)
                except Exception as e:  # noqa: BLE001
                    return SkillResult(ok=False, detail=f"échec collage : {e}")
                finally:
                    restored = _restore_clipboard(snapshot)
                if not restored:
                    log.warning("Presse-papier non restauré après collage")
                    return SkillResult(ok=True, detail=(f"{len(text)} caractères collés — ATTENTION : "
                                                        f"presse-papier précédent non restauré"))
                return SkillResult(ok=True, detail=f"{len(text)} caractères collés (presse-papier restauré)")
            # Contenu non textuel (image, fichiers…) : non restaurable → on n'y touche pas.
            if sys.platform == "win32":
                return self._unicode(text, interval)

        # Frappe touche-à-touche (ASCII fiable ; symboles selon l'agencement).
        try:
            pyautogui.typewrite(text, interval=interval or 0.02)
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec saisie : {e}")
        return SkillResult(ok=True, detail=f"{len(text)} caractères saisis (frappe directe)")
