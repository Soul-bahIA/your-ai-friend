"""Skill : saisir du texte au clavier (sensible).

Frappe FIABLE quel que soit l'agencement clavier (AZERTY, QWERTZ, accents,
symboles) : le texte est placé dans le presse-papier puis collé via Ctrl+V.
On évite ainsi le mauvais mappage des caractères par pyautogui.typewrite, qui
raisonne en QWERTY US (ex. « ! » tapé « § », accents perdus) sur un clavier FR.

Le repli touche-à-touche (typewrite) reste disponible via {"method": "typewrite"}.
"""
from __future__ import annotations

import sys
import time

from skills.base import Skill, SkillResult


def _set_clipboard_windows(text: str) -> bool:
    """Place `text` (Unicode) dans le presse-papier Windows via l'API native (ctypes)."""
    import ctypes
    from ctypes import wintypes

    CF_UNICODETEXT = 13
    GMEM_MOVEABLE = 0x0002

    kernel32 = ctypes.windll.kernel32
    user32 = ctypes.windll.user32

    kernel32.GlobalAlloc.restype = wintypes.HGLOBAL
    kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
    kernel32.GlobalLock.restype = wintypes.LPVOID
    kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
    kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
    user32.OpenClipboard.argtypes = [wintypes.HWND]
    user32.SetClipboardData.restype = wintypes.HANDLE
    user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]

    if not user32.OpenClipboard(None):
        return False
    try:
        user32.EmptyClipboard()
        # Buffer UTF-16 terminé par un nul (requis par CF_UNICODETEXT).
        buf = ctypes.create_unicode_buffer(text)
        size = ctypes.sizeof(buf)
        handle = kernel32.GlobalAlloc(GMEM_MOVEABLE, size)
        if not handle:
            return False
        ptr = kernel32.GlobalLock(handle)
        if not ptr:
            return False
        ctypes.memmove(ptr, buf, size)
        kernel32.GlobalUnlock(handle)
        # Une fois SetClipboardData réussi, le système possède la mémoire (ne pas libérer).
        return bool(user32.SetClipboardData(CF_UNICODETEXT, handle))
    finally:
        user32.CloseClipboard()


def _set_clipboard(text: str) -> bool:
    """Copie `text` dans le presse-papier. Natif sous Windows, sinon pyperclip."""
    if sys.platform == "win32":
        try:
            if _set_clipboard_windows(text):
                return True
        except Exception:  # noqa: BLE001 - on tentera pyperclip en repli
            pass
    try:
        import pyperclip

        pyperclip.copy(text)
        return True
    except Exception:  # noqa: BLE001
        return False


class TypeTextSkill(Skill):
    name = "type_text"
    step_types = ("type_text", "type", "keyboard")
    category = "keyboard"
    sensitive = True

    def describe(self, step: dict) -> str:
        text = str(step.get("text", ""))
        preview = text if len(text) <= 40 else text[:40] + "…"
        return f"taper le texte : « {preview} »"

    def run(self, step: dict) -> SkillResult:
        text = step.get("text")
        if not text:
            return SkillResult(ok=False, detail="champ 'text' manquant")
        text = str(text)

        try:
            import pyautogui
        except ImportError:
            return SkillResult(ok=False, detail="dépendance 'pyautogui' non installée")

        # Méthode par défaut : presse-papier + Ctrl+V (indépendant de l'agencement).
        method = str(step.get("method", "clipboard")).lower()
        if method != "typewrite" and _set_clipboard(text):
            try:
                time.sleep(0.05)  # laisse le presse-papier se stabiliser
                pyautogui.hotkey("ctrl", "v")
                return SkillResult(ok=True, detail=f"{len(text)} caractères collés (presse-papier)")
            except Exception as e:  # noqa: BLE001
                return SkillResult(ok=False, detail=f"échec collage : {e}")

        # Repli : frappe touche-à-touche (ASCII fiable ; symboles selon l'agencement).
        interval = float(step.get("interval", 0.02))
        try:
            pyautogui.typewrite(text, interval=interval)
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec saisie : {e}")
        return SkillResult(ok=True, detail=f"{len(text)} caractères saisis (frappe directe)")
