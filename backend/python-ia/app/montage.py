"""Montage vidéo professionnel — assemble des segments en une vidéo finale.

Un segment = une image (diapo) OU un enregistrement d'écran (démo réelle), avec une
narration audio optionnelle. Le montage ajoute un carton-titre, des fondus enchaînés
(transitions) et un zoom léger sur les diapos, puis exporte en MP4.

Réutilisable pour : diaporama narré (comme aujourd'hui) ET vidéos de formation
mêlant diapos + démonstrations enregistrées par l'agent.
"""
from __future__ import annotations

import os

_W, _H = 1280, 720
_BG = (15, 17, 26)
_ACCENT = (99, 102, 241)
_TEXT = (235, 236, 240)
_XFADE = 0.4  # durée du fondu enchaîné entre segments


def _title_card(text: str, duration: float, subtitle: str = ""):
    import numpy as np
    from PIL import Image, ImageDraw, ImageFont
    from moviepy.editor import ImageClip

    img = Image.new("RGB", (_W, _H), _BG)
    d = ImageDraw.Draw(img)
    d.rectangle([0, _H // 2 + 60, _W, _H // 2 + 64], fill=_ACCENT)

    def font(sz: int):
        for name in ("arialbd.ttf", "arial.ttf", "DejaVuSans-Bold.ttf"):
            try:
                return ImageFont.truetype(name, sz)
            except Exception:  # noqa: BLE001
                continue
        return ImageFont.load_default()

    import textwrap

    y = _H // 2 - 60
    for line in textwrap.wrap(text, width=30)[:2]:
        f = font(54)
        w = d.textbbox((0, 0), line, font=f)[2]
        d.text(((_W - w) / 2, y), line, font=f, fill=_TEXT)
        y += 64
    if subtitle:
        f = font(26)
        w = d.textbbox((0, 0), subtitle, font=f)[2]
        d.text(((_W - w) / 2, _H // 2 + 80), subtitle, font=f, fill=_ACCENT)

    return ImageClip(np.array(img)).set_duration(duration)


def assemble(segments: list[dict], out_path: str, title: str | None = None, subtitle: str = "") -> dict:
    """Assemble les segments en une vidéo MP4 avec transitions.

    segments : [{ "image": np.ndarray|None, "video": path|None, "audio": path|None,
                  "duration": float }]
    """
    from moviepy.editor import (
        AudioFileClip,
        ImageClip,
        VideoFileClip,
        concatenate_videoclips,
    )

    clips = []
    if title:
        clips.append(_title_card(title, 2.5, subtitle))

    for seg in segments:
        if seg.get("video") and os.path.isfile(seg["video"]):
            clip = VideoFileClip(seg["video"])
        else:
            img = seg["image"]
            dur = float(seg.get("duration", 4))
            clip = ImageClip(img).set_duration(dur)
        if seg.get("audio") and os.path.isfile(seg["audio"]):
            audio = AudioFileClip(seg["audio"])
            clip = clip.set_duration(max(clip.duration, audio.duration + 0.5)).set_audio(audio)
        clips.append(clip)

    if not clips:
        raise ValueError("aucun segment à monter")

    # Fondus enchaînés : chaque clip (sauf le 1er) démarre en crossfade sur le précédent.
    faded = [clips[0]]
    for c in clips[1:]:
        faded.append(c.crossfadein(_XFADE))
    final = concatenate_videoclips(faded, method="compose", padding=-_XFADE)

    has_audio = any(seg.get("audio") for seg in segments)
    final.write_videofile(
        out_path,
        fps=24,
        codec="libx264",
        audio_codec="aac" if has_audio else None,
        audio=has_audio,
        logger=None,
    )
    duration = final.duration
    final.close()
    for c in clips:
        try:
            c.close()
        except Exception:  # noqa: BLE001
            pass

    return {"path": out_path, "segments": len(segments), "duration_s": float(round(duration, 1))}
