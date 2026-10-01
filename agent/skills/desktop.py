"""Informations sur la fenêtre au premier plan (Windows, via ctypes).

Sert au contrôle S3 : une saisie clavier dans une fenêtre inconnue (boîte
« Exécuter », terminal…) équivaut à exécuter du code et doit être confirmée."""
from __future__ import annotations

import os
import sys
from typing import Any

if sys.platform == "win32":
    import ctypes
    from ctypes import wintypes

    _user32 = ctypes.WinDLL("user32", use_last_error=True)
    _k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

    _user32.GetForegroundWindow.restype = wintypes.HWND
    _user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
    _user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    _user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    _user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    _k32.OpenProcess.restype = wintypes.HANDLE
    _k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    _k32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
                                                ctypes.POINTER(wintypes.DWORD)]
    _k32.CloseHandle.argtypes = [wintypes.HANDLE]


def foreground_window() -> dict[str, Any] | None:
    """{"title", "class", "exe", "pid"} de la fenêtre active, ou None (inconnue)."""
    if sys.platform != "win32":
        return None
    try:
        hwnd = _user32.GetForegroundWindow()
        if not hwnd:
            return None
        n = _user32.GetWindowTextLengthW(hwnd)
        title = ctypes.create_unicode_buffer(n + 1)
        _user32.GetWindowTextW(hwnd, title, n + 1)
        cls = ctypes.create_unicode_buffer(256)
        _user32.GetClassNameW(hwnd, cls, 256)
        pid = wintypes.DWORD()
        _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        exe = ""
        handle = _k32.OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
        if handle:
            try:
                size = wintypes.DWORD(1024)
                buf = ctypes.create_unicode_buffer(size.value)
                if _k32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                    exe = buf.value
            finally:
                _k32.CloseHandle(handle)
        return {"title": title.value, "class": cls.value, "exe": exe, "pid": pid.value}
    except Exception:  # noqa: BLE001 - inconnu = traité comme risqué par l'appelant
        return None


def exe_stem(info: dict[str, Any] | None) -> str:
    """Nom d'exécutable sans extension, en minuscules ('' si inconnu)."""
    exe = (info or {}).get("exe") or ""
    return os.path.splitext(os.path.basename(exe))[0].lower()


_DPI_DONE: dict[str, str] = {}


def ensure_dpi_awareness() -> str:
    """Rend le processus sensible au DPI (LOT 12, audit §9.7), une seule fois.

    Sans cela, sur un écran mis à l'échelle (125 %, 150 %…), Windows « virtualise » les
    coordonnées : les clics (pyautogui) et les positions de fenêtres seraient en pixels
    logiques alors que les captures (mss) sont en pixels physiques. Ordre d'essai : par
    moniteur v2 (Windows 10 1703+), par moniteur (8.1+), système (Vista+). Doit être appelé
    tôt, avant la création de toute fenêtre ; sans effet hors Windows. Retourne le mode obtenu."""
    if "mode" in _DPI_DONE:
        return _DPI_DONE["mode"]
    mode = "unsupported"
    if sys.platform == "win32":
        try:
            if ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4)):
                mode = "per_monitor_v2"
        except (AttributeError, OSError):
            pass
        if mode == "unsupported":
            try:
                hr = ctypes.windll.shcore.SetProcessDpiAwareness(2)
                # E_ACCESSDENIED (0x80070005) : déjà défini pour ce processus — on garde le réglage existant.
                mode = "per_monitor" if hr == 0 else "already_set"
            except (AttributeError, OSError):
                try:
                    mode = "system" if ctypes.windll.user32.SetProcessDPIAware() else "already_set"
                except (AttributeError, OSError):
                    mode = "unsupported"
    _DPI_DONE["mode"] = mode
    return mode
