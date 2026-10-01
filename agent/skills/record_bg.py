"""Skills : enregistrement d'écran EN ARRIÈRE-PLAN (démos synchronisées).

Contrairement à record_screen (bloquant, durée fixe), ceux-ci démarrent la capture
dans un thread et rendent la main immédiatement : l'agent peut alors ouvrir des
logiciels, cliquer, taper… PENDANT que l'écran est filmé, puis arrêter la capture.

  start_recording_bg : {"type": "start_recording_bg", "path": "C:/.../demo.mp4", "fps": 10}
  stop_recording_bg  : {"type": "stop_recording_bg", "path": "C:/.../demo.mp4"}

Le chemin de sortie est validé par le gate contre la liste blanche (catégorie video).
"""
from __future__ import annotations

import threading
import time

from skills.base import Skill, SkillResult

# Enregistrements actifs : chemin de sortie -> état du thread.
_ACTIVE: dict[str, dict] = {}
_MAX_SECONDS = 600  # borne de sécurité : un enregistrement oublié s'arrête seul


def _record_loop(path: str, fps: int, state: dict) -> None:
    import cv2
    import mss
    import numpy as np

    interval = 1.0 / fps
    try:
        with mss.mss() as sct:
            monitor = sct.monitors[1]
            first = np.array(sct.grab(monitor))
            h, w = first.shape[0], first.shape[1]
            fourcc = cv2.VideoWriter_fourcc(*"mp4v")
            writer = cv2.VideoWriter(path, fourcc, fps, (w, h))
            if not writer.isOpened():
                state["error"] = f"impossible de créer le fichier vidéo : {path}"
                state["stopped"] = True
                return
            start = time.monotonic()
            frames = 0
            while not state["stop"] and (time.monotonic() - start) < _MAX_SECONDS:
                t0 = time.monotonic()
                frame = cv2.cvtColor(np.array(sct.grab(monitor)), cv2.COLOR_BGRA2BGR)
                writer.write(frame)
                frames += 1
                elapsed = time.monotonic() - t0
                if elapsed < interval:
                    time.sleep(interval - elapsed)
            writer.release()
            state["frames"] = frames
            state["duration_s"] = round(time.monotonic() - start, 1)
    except Exception as e:  # noqa: BLE001
        state["error"] = str(e)
    finally:
        state["stopped"] = True


class StartRecordingBgSkill(Skill):
    name = "start_recording_bg"
    step_types = ("start_recording_bg",)
    category = "video"
    sensitive = True

    def describe(self, step: dict) -> str:
        return f"démarrer l'enregistrement d'écran (arrière-plan) → {step.get('path', '?')}"

    def run(self, step: dict) -> SkillResult:
        path = step.get("path")
        if not path:
            return SkillResult(ok=False, detail="champ 'path' manquant (.mp4)")
        if path in _ACTIVE and not _ACTIVE[path].get("stopped"):
            return SkillResult(ok=False, detail="un enregistrement est déjà en cours pour ce chemin")
        try:
            import cv2  # noqa: F401
            import mss  # noqa: F401
        except ImportError as e:
            return SkillResult(ok=False, detail=f"dépendance manquante : {e.name}")

        fps = max(1, min(int(step.get("fps", 10)), 30))
        state = {"stop": False, "stopped": False, "frames": 0, "error": None}
        thread = threading.Thread(target=_record_loop, args=(path, fps, state), daemon=True)
        state["thread"] = thread
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
        if not path or path not in _ACTIVE:
            return SkillResult(ok=False, detail="aucun enregistrement en cours pour ce chemin")
        state = _ACTIVE[path]
        state["stop"] = True
        thread = state.get("thread")
        if thread:
            thread.join(timeout=15)
        _ACTIVE.pop(path, None)
        if state.get("error"):
            return SkillResult(ok=False, detail=f"échec enregistrement : {state['error']}")
        return SkillResult(
            ok=True,
            detail=f"{state.get('frames', 0)} images ({state.get('duration_s', 0)}s) → {path}",
            data={"path": path, "frames": state.get("frames", 0), "duration_s": state.get("duration_s", 0)},
        )
