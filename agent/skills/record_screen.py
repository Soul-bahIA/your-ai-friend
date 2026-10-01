"""Skill : enregistrer l'écran pendant N secondes (sensible, chemin whitelisté).

Auto-suffisant (mss + OpenCV) — ne dépend pas d'un logiciel tiers particulier,
conformément à la spec (« s'adapter à différents logiciels compatibles »).
Cadence constante calée sur le temps réel (durée vidéo ≈ durée demandée), codec
H.264 si disponible (sinon mp4v + avertissement) : voir skills/recording.py.

Exemple : {"type": "record_screen", "path": "C:/videos/demo.mp4", "duration": 8, "fps": 10, "monitor": 1}
"""
from __future__ import annotations

from skills.base import PathCheck, Skill, SkillResult, current_token
from skills.recording import (
    output_dir_error,
    record_to_file,
    validate_monitor,
    validate_video_path,
)

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
        return validate_video_path(step.get("path")) or validate_monitor(step.get("monitor"))

    def run(self, step: dict) -> SkillResult:
        path = step.get("path")
        err = validate_video_path(path) or validate_monitor(step.get("monitor")) or output_dir_error(path)
        if err:
            return SkillResult(ok=False, detail=err)

        try:
            import cv2  # noqa: F401
            import mss  # noqa: F401
            import numpy  # noqa: F401
        except ImportError as e:
            return SkillResult(ok=False, detail=f"dépendance manquante : {e.name}")

        try:
            duration = max(_MIN_DURATION, min(float(step.get("duration", 5)), _MAX_DURATION))
            fps = max(1, min(int(step.get("fps", _DEFAULT_FPS)), 30))
        except (TypeError, ValueError):
            return SkillResult(ok=False, detail="champs 'duration'/'fps' invalides")
        monitor = 1 if step.get("monitor") is None else int(step["monitor"])

        token = current_token()
        try:
            # Arrêt demandé (stop utilisateur, délai dépassé, Ctrl+C) : on finalise le fichier.
            stats = record_to_file(path, fps, token.is_cancelled, duration, monitor=monitor, wait=token.wait)
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec enregistrement : {e}")

        data = {"path": path, **stats}
        if token.is_cancelled():
            return SkillResult(ok=False, detail=f"enregistrement interrompu ({stats['frames']} images) → {path}",
                               data=data)
        detail = (f"{stats['frames']} images ({stats['duration_s']} s réelles @ {fps} fps, "
                  f"capture {stats['capture_fps']} fps, codec {stats.get('codec')}) → {path}")
        if stats.get("warning"):
            detail += f" — avertissement : {stats['warning']}"
        return SkillResult(ok=True, detail=detail, data=data)
