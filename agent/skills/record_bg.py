"""Skills : enregistrement d'écran EN ARRIÈRE-PLAN (démos synchronisées).

Contrairement à record_screen (bloquant, durée fixe), ceux-ci démarrent la capture
dans un thread et rendent la main immédiatement : l'agent peut alors ouvrir des
logiciels, cliquer, taper… PENDANT que l'écran est filmé, puis arrêter la capture.

  start_recording_bg : {"type": "start_recording_bg", "path": "C:/.../demo.mp4", "fps": 10}
  stop_recording_bg  : {"type": "stop_recording_bg", "path": "C:/.../demo.mp4"}

Le chemin de sortie est validé par le gate contre la liste blanche (catégorie video).

Robustesse : un enregistrement oublié (tâche en échec, arrêt de l'agent…) est
stoppé et son fichier finalisé (writer.release) par `stop_all()`, appelé par
l'executor en fin de tâche et enregistré via atexit — sinon le MP4 serait corrompu.
"""
from __future__ import annotations

import atexit
import logging
import threading
import time

from skills.base import PathCheck, Skill, SkillResult

log = logging.getLogger("soulbah.record_bg")

# Enregistrements actifs : chemin de sortie -> état du thread.
_ACTIVE: dict[str, dict] = {}
_LOCK = threading.Lock()
_MAX_SECONDS = 600  # borne de sécurité : un enregistrement oublié s'arrête seul
VIDEO_EXTENSIONS = (".mp4", ".avi")


def validate_video_path(path: object, label: str = "path") -> str | None:
    if not isinstance(path, str) or not path.strip():
        return f"champ '{label}' manquant (.mp4)"
    if not path.lower().endswith(VIDEO_EXTENSIONS):
        return f"le fichier vidéo doit finir par {' / '.join(VIDEO_EXTENSIONS)} : {path}"
    return None


def _record_loop(path: str, fps: int, state: dict) -> None:
    import cv2
    import mss
    import numpy as np

    interval = 1.0 / fps
    writer = None
    start = time.monotonic()
    frames = 0
    try:
        with mss.mss() as sct:
            monitor = sct.monitors[1]
            first = np.array(sct.grab(monitor))
            h, w = first.shape[0], first.shape[1]
            fourcc = cv2.VideoWriter_fourcc(*"mp4v")
            writer = cv2.VideoWriter(path, fourcc, fps, (w, h))
            if not writer.isOpened():
                state["error"] = f"impossible de créer le fichier vidéo : {path}"
                return
            while not state["stop"].is_set() and (time.monotonic() - start) < _MAX_SECONDS:
                t0 = time.monotonic()
                frame = cv2.cvtColor(np.array(sct.grab(monitor)), cv2.COLOR_BGRA2BGR)
                writer.write(frame)
                frames += 1
                elapsed = time.monotonic() - t0
                if elapsed < interval:
                    state["stop"].wait(interval - elapsed)
    except Exception as e:  # noqa: BLE001
        state["error"] = str(e)
    finally:
        # Toujours finaliser le fichier, même en cas d'erreur en cours de capture.
        if writer is not None:
            try:
                writer.release()
            except Exception:  # noqa: BLE001
                pass
        state["frames"] = frames
        state["duration_s"] = round(time.monotonic() - start, 1)
        state["stopped"] = True


def _stop_one(path: str, state: dict, join_timeout: float = 15.0) -> None:
    state["stop"].set()
    thread = state.get("thread")
    if thread and thread.is_alive():
        thread.join(timeout=join_timeout)


def stop_all(reason: str = "fin de tâche") -> int:
    """Stoppe et finalise tous les enregistrements encore actifs. Retourne leur nombre."""
    with _LOCK:
        items = list(_ACTIVE.items())
        _ACTIVE.clear()
    for path, state in items:
        if not state.get("stopped"):
            log.warning("Enregistrement en arrière-plan arrêté automatiquement (%s) : %s", reason, path)
        _stop_one(path, state)
    return len(items)


atexit.register(stop_all, "arrêt de l'agent")


class StartRecordingBgSkill(Skill):
    name = "start_recording_bg"
    step_types = ("start_recording_bg",)
    category = "video"
    sensitive = True

    def describe(self, step: dict) -> str:
        return f"démarrer l'enregistrement d'écran (arrière-plan) → {step.get('path', '?')}"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        return validate_video_path(step.get("path"))

    def run(self, step: dict) -> SkillResult:
        path = step.get("path")
        err = validate_video_path(path)
        if err:
            return SkillResult(ok=False, detail=err)
        with _LOCK:
            if path in _ACTIVE and not _ACTIVE[path].get("stopped"):
                return SkillResult(ok=False, detail="un enregistrement est déjà en cours pour ce chemin")
        try:
            import cv2  # noqa: F401
            import mss  # noqa: F401
        except ImportError as e:
            return SkillResult(ok=False, detail=f"dépendance manquante : {e.name}")

        try:
            fps = max(1, min(int(step.get("fps", 10)), 30))
        except (TypeError, ValueError):
            fps = 10
        state = {"stop": threading.Event(), "stopped": False, "frames": 0, "error": None}
        thread = threading.Thread(target=_record_loop, args=(path, fps, state), daemon=True, name="record-bg")
        state["thread"] = thread
        with _LOCK:
            _ACTIVE[path] = state
        thread.start()
        return SkillResult(ok=True, detail=f"enregistrement démarré (arrière-plan) → {path}", data={"path": path})


class StopRecordingBgSkill(Skill):
    name = "stop_recording_bg"
    step_types = ("stop_recording_bg",)
    category = "video"
    sensitive = True

    def describe(self, step: dict) -> str:
        return f"arrêter l'enregistrement d'écran → {step.get('path', '?')}"

    def run(self, step: dict) -> SkillResult:
        path = step.get("path")
        with _LOCK:
            state = _ACTIVE.pop(path, None) if isinstance(path, str) else None
        if state is None:
            return SkillResult(ok=False, detail="aucun enregistrement en cours pour ce chemin")
        _stop_one(path, state)
        if state.get("error"):
            return SkillResult(ok=False, detail=f"échec enregistrement : {state['error']}")
        return SkillResult(
            ok=True,
            detail=f"{state.get('frames', 0)} images ({state.get('duration_s', 0)}s) → {path}",
            data={"path": path, "frames": state.get("frames", 0), "duration_s": state.get("duration_s", 0)},
        )
