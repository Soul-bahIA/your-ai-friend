"""Skill : enregistrer l'écran pendant N secondes (sensible, chemin whitelisté).

Auto-suffisant (mss + OpenCV) — ne dépend pas d'un logiciel tiers particulier,
conformément à la spec (« s'adapter à différents logiciels compatibles »).

Exemple : {"type": "record_screen", "path": "C:/videos/demo.mp4", "duration": 8, "fps": 10}
"""
from __future__ import annotations

import time

from skills.base import PathCheck, Skill, SkillResult, cancel_event
from skills.record_bg import validate_video_path

_MIN_DURATION = 1
_MAX_DURATION = 120  # borne de sécurité
_DEFAULT_FPS = 10


class RecordScreenSkill(Skill):
    name = "record_screen"
    step_types = ("record_screen", "start_recording")
    category = "video"
    sensitive = True

    def describe(self, step: dict) -> str:
        return f"enregistrer l'écran {step.get('duration', 5)}s → {step.get('path', '?')}"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        return validate_video_path(step.get("path"))

    def run(self, step: dict) -> SkillResult:
        path = step.get("path")
        err = validate_video_path(path)
        if err:
            return SkillResult(ok=False, detail=err)

        try:
            import cv2
            import mss
            import numpy as np
        except ImportError as e:
            return SkillResult(ok=False, detail=f"dépendance manquante : {e.name}")

        try:
            duration = max(_MIN_DURATION, min(float(step.get("duration", 5)), _MAX_DURATION))
            fps = max(1, min(int(step.get("fps", _DEFAULT_FPS)), 30))
        except (TypeError, ValueError):
            return SkillResult(ok=False, detail="champs 'duration'/'fps' invalides")
        interval = 1.0 / fps

        writer = None
        frames = 0
        cancelled = False
        try:
            with mss.mss() as sct:
                monitor = sct.monitors[1]
                first = np.array(sct.grab(monitor))
                h, w = first.shape[0], first.shape[1]
                fourcc = cv2.VideoWriter_fourcc(*"mp4v")
                writer = cv2.VideoWriter(path, fourcc, fps, (w, h))
                if not writer.isOpened():
                    return SkillResult(ok=False, detail=f"impossible de créer le fichier vidéo : {path}")

                start = time.monotonic()
                while time.monotonic() - start < duration:
                    # Arrêt demandé (stop utilisateur, délai dépassé…) : on finalise le fichier.
                    if cancel_event.is_set():
                        cancelled = True
                        break
                    t0 = time.monotonic()
                    frame = np.array(sct.grab(monitor))
                    frame = cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)
                    writer.write(frame)
                    frames += 1
                    elapsed = time.monotonic() - t0
                    if elapsed < interval:
                        time.sleep(interval - elapsed)
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec enregistrement : {e}")
        finally:
            if writer is not None:
                try:
                    writer.release()
                except Exception:  # noqa: BLE001
                    pass

        if cancelled:
            return SkillResult(ok=False, detail=f"enregistrement interrompu ({frames} images) → {path}",
                               data={"path": path, "frames": frames})
        return SkillResult(
            ok=True,
            detail=f"{frames} images enregistrées ({duration}s @ {fps}fps) → {path}",
            data={"path": path, "duration_s": duration, "frames": frames},
        )
