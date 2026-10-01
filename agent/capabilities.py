"""Capacités locales de l'agent (V3 LOT 1, mission V3 §84-86).

`local_capabilities(settings, profile)` dit honnêtement ce que CE PC peut faire maintenant, selon
la configuration centrale (mode, computer_control, recording) et ce qui est installé :
  available   l'outil existe, ses dépendances sont présentes et le mode le permet ;
  unavailable il manque un composant (la raison le nomme) ;
  disabled    refusé par le mode ou la configuration.

Le résultat est envoyé au plan de contrôle à l'enregistrement du runtime (capabilities.local)
et affiché par `python doctor.py`.
"""
from __future__ import annotations

import sys
from typing import Any, Mapping

import soulbah_settings as S

IS_WIN = sys.platform == "win32"


def _ok(via: str) -> dict[str, str]:
    return {"status": "available", "via": via}


def _no(reason: str) -> dict[str, str]:
    return {"status": "unavailable", "reason": reason}


def _off(reason: str) -> dict[str, str]:
    return {"status": "disabled", "reason": reason}


def local_capabilities(settings: Mapping[str, Any], profile: Mapping[str, Any]) -> dict[str, dict[str, str]]:
    tools = profile.get("tools") or {}
    pkgs = profile.get("python_packages") or {}
    mode = settings.get("mode")
    caps: dict[str, dict[str, str]] = {}

    if not settings.get("computer_control", True):
        caps["computer.input"] = _off("contrôle de l'ordinateur désactivé (computer_control=false)")
    elif not IS_WIN:
        caps["computer.input"] = _no("pilotage souris / clavier / fenêtres : Windows uniquement")
    elif not pkgs.get("pyautogui"):
        caps["computer.input"] = _no("dépendance pyautogui absente")
    else:
        caps["computer.input"] = _ok("pyautogui + Win32")

    caps["screen.capture"] = _ok("mss") if pkgs.get("mss") else _no("dépendance mss absente")
    caps["screen.inspect"] = _ok("Win32 (ui_snapshot)") if IS_WIN else _no("inspection d'interface : Windows uniquement")
    caps["screen.ocr"] = _ok("tesseract") if tools.get("tesseract") else _no("aucun moteur OCR local (LOT 9 V3)")
    caps["vision.local"] = _no("aucun modèle de vision local (LOT 9 V3)")

    caps["files"] = _ok("local")
    caps["terminal.execute"] = _ok("run_command (sans shell, allowlist)")
    caps["git.local"] = _ok("git") if tools.get("git") else _no("git absent du PATH")
    if not tools.get("git"):
        caps["git.remote"] = _no("git absent du PATH")
    elif not S.internet_allowed(settings):
        caps["git.remote"] = _off(f"dépôt distant (push) refusé en mode {mode}")
    else:
        caps["git.remote"] = _ok("git (push L3)")
    caps["editor.vscode"] = _ok("Code.exe") if tools.get("vscode") else _no("VS Code introuvable")

    if not S.internet_allowed(settings):
        caps["web.read"] = _off(f"lecture web refusée en mode {mode} (hôtes déclarés seulement)")
    else:
        caps["web.read"] = _ok("http" + (" + navigateur (Playwright)" if pkgs.get("playwright") else ""))

    if not settings.get("recording", True):
        caps["video.record"] = _off("enregistrement de l'écran désactivé (recording=false)")
    elif pkgs.get("mss") and pkgs.get("cv2"):
        caps["video.record"] = _ok("mss + OpenCV")
    else:
        caps["video.record"] = _no("dépendances mss / opencv absentes")
    caps["video.edit"] = _ok("moviepy + FFmpeg") if (pkgs.get("moviepy") and tools.get("ffmpeg")) else \
        _no("moviepy ou FFmpeg absent")

    sapi5 = profile.get("sapi5_voices") or []
    if IS_WIN and sapi5:
        caps["voice.tts"] = _ok(f"voix Windows (speak_text) : {', '.join(sapi5[:6])}")
    else:
        caps["voice.tts"] = _no("aucune voix de synthèse locale installée")
    caps["voice.stt"] = _no("aucun moteur de reconnaissance vocale local (LOT 11 V3)")

    if not settings.get("computer_control", True):
        caps["phone.android"] = _off("contrôle des appareils désactivé (computer_control=false)")
    else:
        caps["phone.android"] = _ok("adb") if tools.get("adb") else _no("adb absent (Android Platform Tools)")

    engines = [e for e in ("ollama", "llama-server", "llama-cli") if tools.get(e)]
    caps["llm.engine"] = _ok(", ".join(engines)) if engines else _no("aucun moteur de modèle local installé (LOT 2 V3)")
    return caps


def registration_payload(settings: Mapping[str, Any], profile: Mapping[str, Any]) -> dict[str, Any]:
    """Champs ajoutés à `capabilities` lors de l'enregistrement du runtime (POST /register)."""
    import hardware

    import network_guard

    guard = {k: v for k, v in network_guard.status().items() if k != "recent"}
    return {"mode": settings.get("mode"), "hardware": hardware.summary(dict(profile)),
            "local": local_capabilities(settings, profile), "network_guard": guard}
