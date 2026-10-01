"""Instantané d'interface d'une fenêtre (LOT 12, audit §9.7 : « UIA + DPI-aware »).

`ui_snapshot` lit, SANS rien modifier, l'état d'une fenêtre : titre, classe, processus, position,
DPI et facteur d'échelle, état (premier plan, réduite, agrandie) et ses contrôles enfants (classe,
libellé court, position, visible, actif). Implémenté en ctypes (API Win32) : aucune dépendance,
et assez rapide pour une boucle observer → agir (< 2 s par itération, mesuré dans `elapsed_ms`).

Confidentialité : le texte d'un champ de saisie (Edit, RichEdit) n'est JAMAIS renvoyé ; seuls sa
longueur et son empreinte sha256 (UTF-8) le sont, ce qui suffit à prouver qu'un texte attendu a
été saisi (critère `artifact_hash`). Les champs mot de passe sont ignorés.
"""
from __future__ import annotations

import hashlib
import sys
import time
from typing import Any

from skills.base import PathCheck, Skill, SkillResult
from skills.manifests import declared_param_error
from skills.desktop import ensure_dpi_awareness

MAX_CONTROLS_DEFAULT = 200
MAX_CONTROLS_LIMIT = 1000
LABEL_CHARS = 100
EDIT_CLASSES = ("edit", "richedit", "richedit20w", "richedit50w", "richeditd2dpt", "scintilla")
_ES_PASSWORD = 0x0020
_WM_GETTEXT = 0x000D
_WM_GETTEXTLENGTH = 0x000E
_SMTO_ABORTIFHUNG = 0x0002
_GWL_STYLE = -16
_MAX_EDIT_CHARS = 2_000_000

if sys.platform == "win32":
    import ctypes
    from ctypes import wintypes

    _user32 = ctypes.WinDLL("user32", use_last_error=True)
    _k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _ENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    _user32.EnumWindows.argtypes = [_ENUMPROC, wintypes.LPARAM]
    _user32.EnumChildWindows.argtypes = [wintypes.HWND, _ENUMPROC, wintypes.LPARAM]
    _user32.GetForegroundWindow.restype = wintypes.HWND
    _user32.IsWindowVisible.argtypes = [wintypes.HWND]
    _user32.IsWindowEnabled.argtypes = [wintypes.HWND]
    _user32.IsIconic.argtypes = [wintypes.HWND]
    _user32.IsZoomed.argtypes = [wintypes.HWND]
    _user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
    _user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    _user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    _user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
    _user32.GetDlgCtrlID.argtypes = [wintypes.HWND]
    _user32.GetParent.argtypes = [wintypes.HWND]
    _user32.GetParent.restype = wintypes.HWND
    _user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    _user32.GetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int]
    _user32.GetWindowLongW.restype = ctypes.c_long
    _user32.SendMessageTimeoutW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM,
                                            wintypes.UINT, wintypes.UINT, ctypes.POINTER(ctypes.c_size_t)]
    _user32.SendMessageTimeoutW.restype = ctypes.c_ssize_t
    try:
        _user32.GetDpiForWindow.argtypes = [wintypes.HWND]
        _user32.GetDpiForWindow.restype = wintypes.UINT
        _HAS_DPI_FOR_WINDOW = True
    except AttributeError:  # Windows < 10 1607
        _HAS_DPI_FOR_WINDOW = False
    _k32.OpenProcess.restype = wintypes.HANDLE
    _k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    _k32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
                                                ctypes.POINTER(wintypes.DWORD)]
    _k32.CloseHandle.argtypes = [wintypes.HANDLE]


def _text(hwnd: Any) -> str:
    n = _user32.GetWindowTextLengthW(hwnd)
    if n <= 0:
        return ""
    buf = ctypes.create_unicode_buffer(n + 1)
    _user32.GetWindowTextW(hwnd, buf, n + 1)
    return buf.value


def _class(hwnd: Any) -> str:
    buf = ctypes.create_unicode_buffer(256)
    _user32.GetClassNameW(hwnd, buf, 256)
    return buf.value


def _rect(hwnd: Any) -> list[int]:
    r = wintypes.RECT()
    if not _user32.GetWindowRect(hwnd, ctypes.byref(r)):
        return [0, 0, 0, 0]
    return [r.left, r.top, r.right - r.left, r.bottom - r.top]


def _exe(hwnd: Any) -> tuple[str, int]:
    pid = wintypes.DWORD()
    _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    exe = ""
    handle = _k32.OpenProcess(0x1000, False, pid.value)
    if handle:
        try:
            size = wintypes.DWORD(1024)
            buf = ctypes.create_unicode_buffer(size.value)
            if _k32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                exe = buf.value
        finally:
            _k32.CloseHandle(handle)
    return exe, int(pid.value)


def _dpi(hwnd: Any) -> int:
    if _HAS_DPI_FOR_WINDOW:
        try:
            v = int(_user32.GetDpiForWindow(hwnd))
            if v > 0:
                return v
        except OSError:
            pass
    return 96


def _edit_text(hwnd: Any, timeout_ms: int = 500) -> str | None:
    """Texte d'un champ d'une AUTRE application (WM_GETTEXT avec délai : une fenêtre figée ne
    bloque pas l'agent). None si illisible."""
    result = ctypes.c_size_t(0)
    if not _user32.SendMessageTimeoutW(hwnd, _WM_GETTEXTLENGTH, 0, 0, _SMTO_ABORTIFHUNG, timeout_ms,
                                       ctypes.byref(result)):
        return None
    n = min(int(result.value), _MAX_EDIT_CHARS)
    buf = ctypes.create_unicode_buffer(n + 1)
    copied = ctypes.c_size_t(0)
    if not _user32.SendMessageTimeoutW(hwnd, _WM_GETTEXT, n + 1, ctypes.addressof(buf), _SMTO_ABORTIFHUNG,
                                       timeout_ms, ctypes.byref(copied)):
        return None
    return buf.value


def text_digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def top_windows() -> list[Any]:
    """Fenêtres de premier niveau visibles et titrées, dans l'ordre z (du dessus vers le dessous)."""
    out: list[Any] = []

    def _cb(hwnd: Any, _lp: Any) -> bool:
        if _user32.IsWindowVisible(hwnd) and _user32.GetWindowTextLengthW(hwnd) > 0:
            out.append(hwnd)
        return True

    _user32.EnumWindows(_ENUMPROC(_cb), 0)
    return out


def find_window(title: str | None) -> tuple[Any | None, str | None]:
    """Fenêtre cible : celle au premier plan sans titre ; sinon le titre exact, puis la première
    (ordre z) dont le titre CONTIENT le texte (insensible à la casse)."""
    if not title:
        hwnd = _user32.GetForegroundWindow()
        return (hwnd, None) if hwnd else (None, "aucune fenêtre au premier plan")
    needle = title.casefold()
    windows = top_windows()
    for hwnd in windows:
        if _text(hwnd).casefold() == needle:
            return hwnd, None
    for hwnd in windows:
        if needle in _text(hwnd).casefold():
            return hwnd, None
    return None, f"aucune fenêtre visible dont le titre contient « {title} »"


def snapshot(hwnd: Any, max_controls: int = MAX_CONTROLS_DEFAULT, hash_text: bool = True) -> dict[str, Any]:
    exe, pid = _exe(hwnd)
    dpi = _dpi(hwnd)
    fg = _user32.GetForegroundWindow()
    state = "minimized" if _user32.IsIconic(hwnd) else ("foreground" if fg and int(fg) == int(hwnd) else "background")
    controls: list[dict[str, Any]] = []
    total = {"n": 0}
    edits: list[tuple[int, Any]] = []

    def _cb(child: Any, _lp: Any) -> bool:
        total["n"] += 1
        if len(controls) >= max_controls:
            return True
        cls = _class(child)
        style = int(_user32.GetWindowLongW(child, _GWL_STYLE)) & 0xFFFFFFFF
        is_edit = cls.casefold() in EDIT_CLASSES
        r = _rect(child)
        entry: dict[str, Any] = {
            "class": cls,
            "id": int(_user32.GetDlgCtrlID(child)),
            "rect": r,
            "visible": bool(_user32.IsWindowVisible(child)),
            "enabled": bool(_user32.IsWindowEnabled(child)),
        }
        if is_edit:
            entry["role"] = "edit"
            if style & _ES_PASSWORD:
                entry["password"] = True
            elif entry["visible"]:
                edits.append((r[2] * r[3], child))
        else:
            label = _text(child)
            if label:
                entry["label"] = label[:LABEL_CHARS]
        controls.append(entry)
        return True

    _user32.EnumChildWindows(hwnd, _ENUMPROC(_cb), 0)
    main_edit: dict[str, Any] | None = None
    if hash_text and edits:
        edits.sort(key=lambda e: e[0], reverse=True)  # le plus grand champ = la zone de texte principale
        value = _edit_text(edits[0][1])
        if value is not None:
            main_edit = {"length": len(value), "sha256": text_digest(value)}
            # Le contrôle Edit de Windows stocke les fins de ligne en CRLF ; l'empreinte LF est
            # aussi fournie pour comparer avec un texte attendu écrit en LF.
            if "\r\n" in value:
                main_edit["sha256_lf"] = text_digest(value.replace("\r\n", "\n"))
    title = _text(hwnd)
    return {
        "hwnd": int(hwnd),
        "title": title,
        "class": _class(hwnd),
        "exe": exe,
        "pid": pid,
        "rect": _rect(hwnd),
        "dpi": dpi,
        "scale": round(dpi / 96.0, 3),
        "state": state,
        "maximized": bool(_user32.IsZoomed(hwnd)),
        "controls": controls,
        "controls_total": total["n"],
        "edit": main_edit,
    }


class UiSnapshotSkill(Skill):
    name = "ui_snapshot"
    step_types = ("ui_snapshot",)
    category = "screen"
    sensitive = False
    timeout_s = 30.0

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        declared = declared_param_error(step)
        if declared:
            return declared
        title = step.get("window_title")
        if title is not None and (not isinstance(title, str) or len(title) > 200):
            return "champ 'window_title' : texte de 200 caractères au plus"
        mc = step.get("max_controls", MAX_CONTROLS_DEFAULT)
        if isinstance(mc, bool) or not isinstance(mc, int) or not 0 <= mc <= MAX_CONTROLS_LIMIT:
            return f"champ 'max_controls' : entier de 0 à {MAX_CONTROLS_LIMIT}"
        if not isinstance(step.get("hash_text", True), bool):
            return "champ 'hash_text' : booléen"
        return None

    def run(self, step: dict) -> SkillResult:
        if sys.platform != "win32":
            return SkillResult(ok=False, detail="ui_snapshot n'est disponible que sous Windows")
        ensure_dpi_awareness()
        started = time.perf_counter()
        hwnd, err = find_window(step.get("window_title") or None)
        if hwnd is None:
            return SkillResult(ok=False, detail=err or "fenêtre introuvable")
        snap = snapshot(hwnd, int(step.get("max_controls", MAX_CONTROLS_DEFAULT)), bool(step.get("hash_text", True)))
        elapsed_ms = int((time.perf_counter() - started) * 1000)
        edit = snap.get("edit")
        ui_state = {"name": snap["title"], "state": snap["state"], "class": snap["class"],
                    "controls": snap["controls_total"], "dpi": snap["dpi"]}
        if edit:
            ui_state["text_length"] = edit["length"]
        data = {**snap, "ui_state": ui_state, "elapsed_ms": elapsed_ms}
        if edit:
            data["text_sha256"] = edit["sha256"]
        detail = (f"« {snap['title'][:80]} » ({snap['class']}) · {snap['state']} · {snap['controls_total']} contrôle(s)"
                  f" · {snap['dpi']} dpi · {elapsed_ms} ms")
        if edit:
            detail += f" · texte {edit['length']} car."
        return SkillResult(ok=True, detail=detail, data=data)
