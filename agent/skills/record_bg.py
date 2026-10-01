"""Skills : enregistrement d'écran EN ARRIÈRE-PLAN (démos synchronisées).

Contrairement à record_screen (bloquant, durée fixe), ceux-ci démarrent la capture
dans un thread et rendent la main : l'agent peut alors ouvrir des logiciels,
cliquer, taper… PENDANT que l'écran est filmé, puis arrêter la capture.

  start_recording_bg : {"type": "start_recording_bg", "path": "C:/.../demo.mp4", "fps": 10, "monitor": 1}
  stop_recording_bg  : {"type": "stop_recording_bg", "path": "C:/.../demo.mp4"}

Le chemin de sortie est validé par le gate contre la liste blanche (catégorie video).

- Le démarrage n'est annoncé qu'une fois le fichier vidéo réellement ouvert : un
  chemin invalide (dossier absent, codec impossible…) fait ÉCHOUER l'étape (C18).
- Cadence constante calée sur le temps réel : durée vidéo ≈ durée réelle (T24).
- Un enregistrement oublié (tâche en échec, arrêt de l'agent…) est stoppé et son
  fichier finalisé (writer.release) par `stop_all()`, appelé par l'executor en
  fin de tâche et enregistré via atexit — sinon le MP4 serait corrompu.
"""
from __future__ import annotations

import atexit
import logging
import os
import threading

from skills.base import PathCheck, Skill, SkillResult
from skills.recording import (
    VIDEO_EXTENSIONS,  # noqa: F401 - réexporté
    output_dir_error,
    record_to_file,
    recording_key,
    validate_monitor,
    validate_video_path,
)

log = logging.getLogger("soulbah.record_bg")

# Enregistrements actifs : clé normalisée du chemin de sortie -> état du thread.
_ACTIVE: dict[str, dict] = {}
_LOCK = threading.Lock()
_MAX_SECONDS = 600  # borne de sécurité : un enregistrement oublié s'arrête seul
_START_TIMEOUT = 15.0  # délai max pour que le fichier vidéo soit ouvert


def _record_loop(path: str, fps: int, monitor: int, state: dict) -> None:
    def on_ready(error: str | None) -> None:
        if error and not state["error"]:
            state["error"] = error
        state["ready"].set()

    try:
        stats = record_to_file(
            path, fps, state["stop"].is_set, _MAX_SECONDS, monitor=monitor,
            wait=state["stop"].wait, on_ready=on_ready,
        )
        state["stats"] = stats
    except Exception as e:  # noqa: BLE001
        if not state["error"]:
            state["error"] = str(e)
    finally:
        state["stopped"] = True
        state["ready"].set()


def _stop_one(state: dict, join_timeout: float = 15.0) -> None:
    state["stop"].set()
    thread = state.get("thread")
    if thread and thread.is_alive():
        thread.join(timeout=join_timeout)


def stop_all(reason: str = "fin de tâche") -> int:
    """Stoppe et finalise tous les enregistrements encore actifs. Retourne leur nombre."""
    with _LOCK:
        items = list(_ACTIVE.values())
        _ACTIVE.clear()
    for state in items:
        if not state.get("stopped"):
            log.warning("Enregistrement en arrière-plan arrêté automatiquement (%s) : %s", reason, state.get("path"))
        _stop_one(state)
    return len(items)


atexit.register(stop_all, "arrêt de l'agent")


def _fps(step: dict) -> int:
    try:
        return max(1, min(int(step.get("fps", 10)), 30))
    except (TypeError, ValueError):
        return 10


class StartRecordingBgSkill(Skill):
    name = "start_recording_bg"
    step_types = ("start_recording_bg",)
    category = "video"
    sensitive = True

    def describe(self, step: dict) -> str:
        return f"démarrer l'enregistrement d'écran (arrière-plan) → {step.get('path', '?')}"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        return validate_video_path(step.get("path")) or validate_monitor(step.get("monitor"))

    def run(self, step: dict) -> SkillResult:
        path = step.get("path")
        err = validate_video_path(path) or validate_monitor(step.get("monitor"))
        if err:
            return SkillResult(ok=False, detail=err)
        err = output_dir_error(path)
        if err:
            return SkillResult(ok=False, detail=err)
        key = recording_key(path)
        with _LOCK:
            if key in _ACTIVE and not _ACTIVE[key].get("stopped"):
                return SkillResult(ok=False, detail="un enregistrement est déjà en cours pour ce chemin")
        try:
            import cv2  # noqa: F401
            import mss  # noqa: F401
        except ImportError as e:
            return SkillResult(ok=False, detail=f"dépendance manquante : {e.name}")

        fps = _fps(step)
        monitor = 1 if step.get("monitor") is None else int(step["monitor"])
        state = {"stop": threading.Event(), "ready": threading.Event(), "stopped": False,
                 "error": None, "stats": None, "path": path}
        thread = threading.Thread(target=_record_loop, args=(path, fps, monitor, state), daemon=True,
                                  name="record-bg")
        state["thread"] = thread
        with _LOCK:
            _ACTIVE[key] = state
        thread.start()

        # C18 : n'annoncer le démarrage qu'une fois le fichier vidéo ouvert.
        if not state["ready"].wait(_START_TIMEOUT) or state["error"] or state["stopped"]:
            with _LOCK:
                _ACTIVE.pop(key, None)
            _stop_one(state)
            reason = state["error"] or "l'enregistrement n'a pas démarré à temps"
            return SkillResult(ok=False, detail=f"échec du démarrage de l'enregistrement : {reason}")
        return SkillResult(ok=True, detail=f"enregistrement démarré (arrière-plan, {fps} fps) → {path}",
                           data={"path": path, "fps": fps})


class StopRecordingBgSkill(Skill):
    name = "stop_recording_bg"
    step_types = ("stop_recording_bg",)
    category = "video"
    sensitive = True

    def describe(self, step: dict) -> str:
        return f"arrêter l'enregistrement d'écran → {step.get('path', '?')}"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        return validate_video_path(step.get("path"))

    def run(self, step: dict) -> SkillResult:
        path = step.get("path")
        state = None
        if isinstance(path, str) and path.strip():
            with _LOCK:
                state = _ACTIVE.pop(recording_key(path), None)
        if state is None:
            return SkillResult(ok=False, detail="aucun enregistrement en cours pour ce chemin")
        _stop_one(state)
        if state.get("error"):
            return SkillResult(ok=False, detail=f"échec enregistrement : {state['error']}")
        stats = dict(state.get("stats") or {})
        real_path = state.get("path") or path
        if not os.path.isfile(real_path) or os.path.getsize(real_path) <= 0:
            return SkillResult(ok=False, detail=f"fichier vidéo absent ou vide : {real_path}")
        detail = (f"{stats.get('frames', 0)} images ({stats.get('duration_s', 0)} s réelles, "
                  f"capture {stats.get('capture_fps', 0)} fps, codec {stats.get('codec', '?')}) → {real_path}")
        if stats.get("warning"):
            detail += f" — avertissement : {stats['warning']}"
        return SkillResult(ok=True, detail=detail, data={"path": real_path, **stats})
