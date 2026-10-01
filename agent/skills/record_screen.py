"""Skill : enregistrer l'écran pendant N secondes (sensible, chemin whitelisté).

Auto-suffisant (mss + OpenCV) — ne dépend pas d'un logiciel tiers particulier,
conformément à la spec (« s'adapter à différents logiciels compatibles »).

Exemple : {"type": "record_screen", "path": "C:/videos/demo.mp4", "duration": 8, "fps": 10}
"""
from __future__ import annotations

import time

from skills.base import Skill, SkillResult

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

    def run(self, step: dict) -> SkillResult:
        path = step.get("path")
        if not path:
            return SkillResult(ok=False, detail="champ 'path' manquant (chemin de sortie .mp4)")

        try:
            import cv2
            import mss
            import numpy as np
        except ImportError as e:
            return SkillResult(ok=False, detail=f"dépendance manquante : {e.name}")

        duration = max(_MIN_DURATION, min(float(step.get("duration", 5)), _MAX_DURATION))
        fps = max(1, min(int(step.get("fps", _DEFAULT_FPS)), 30))
        interval = 1.0 / fps

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
                frames = 0
                while time.monotonic() - start < duration:
                    t0 = time.monotonic()
                    frame = np.array(sct.grab(monitor))
                    frame = cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)
                    writer.write(frame)
                    frames += 1
                    elapsed = time.monotonic() - t0
                    if elapsed < interval:
                        time.sleep(interval - elapsed)
                writer.release()
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec enregistrement : {e}")

        return SkillResult(
            ok=True,
            detail=f"{frames} images enregistrées ({duration}s @ {fps}fps) → {path}",
            data={"path": path, "duration_s": duration, "frames": frames},
        )
