"""Skill : montage vidéo basique — concaténation de clips + titre (sensible).

Portée volontairement limitée à ce qui est fiable sans dépendance externe fragile
(pas d'ImageMagick) : concaténation ("coupes") + un titre rendu en image (PIL).
Pas de transitions animées dans cette v1.

Exemple : {"type": "edit_video", "clips": ["a.mp4", "b.mp4"], "title": "Ma démo", "output": "final.mp4"}
"""
from __future__ import annotations

import os

from skills.base import PathCheck, Skill, SkillResult


def _make_title_clip(title: str, size: tuple[int, int], duration: float = 2.0):
    """Rend un titre en image (PIL) puis l'enveloppe en clip — évite ImageMagick."""
    import numpy as np
    from moviepy.editor import ImageClip
    from PIL import Image, ImageDraw, ImageFont

    img = Image.new("RGB", size, color=(12, 12, 16))
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("arial.ttf", max(24, size[1] // 12))
    except Exception:  # noqa: BLE001
        font = ImageFont.load_default()

    bbox = draw.textbbox((0, 0), title, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text(((size[0] - tw) / 2, (size[1] - th) / 2), title, fill=(240, 240, 240), font=font)

    return ImageClip(np.array(img)).set_duration(duration)


class EditVideoSkill(Skill):
    name = "edit_video"
    step_types = ("edit_video", "montage")
    category = "video"
    sensitive = True
    timeout_s = 1800.0  # un rendu peut être long

    def describe(self, step: dict) -> str:
        n = len(step.get("clips") or [])
        return f"montage de {n} clip(s) → {step.get('output', '?')}"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        output = step.get("output")
        if not isinstance(output, str) or not output.lower().endswith(".mp4"):
            return "champ 'output' invalide (fichier .mp4 attendu)"
        return None

    def run(self, step: dict) -> SkillResult:
        clips_paths = step.get("clips") or []
        output = step.get("output")
        title = step.get("title")

        if not isinstance(clips_paths, list) or not clips_paths:
            return SkillResult(ok=False, detail="champ 'clips' (liste de chemins) requis")
        if not isinstance(output, str) or not output.lower().endswith(".mp4"):
            return SkillResult(ok=False, detail="champ 'output' invalide (fichier .mp4 attendu)")
        for p in clips_paths:
            if not isinstance(p, str) or not os.path.isfile(p):
                return SkillResult(ok=False, detail=f"clip introuvable : {p}")

        try:
            from moviepy.editor import VideoFileClip, concatenate_videoclips
        except ImportError:
            return SkillResult(ok=False, detail="dépendance 'moviepy' non installée")

        video_clips = []
        try:
            video_clips = [VideoFileClip(p) for p in clips_paths]
            size = video_clips[0].size
            sequence = []
            if title:
                sequence.append(_make_title_clip(str(title), size))
            sequence.extend(video_clips)

            final = concatenate_videoclips(sequence, method="compose")
            final.write_videofile(output, codec="libx264", audio=False, logger=None)
            final.close()
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec montage : {e}")
        finally:
            for c in video_clips:
                try:
                    c.close()
                except Exception:  # noqa: BLE001
                    pass

        return SkillResult(ok=True, detail=f"vidéo montée : {output}", data={"path": output})
