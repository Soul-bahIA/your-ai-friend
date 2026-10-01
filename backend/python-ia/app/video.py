"""Production vidéo d'une formation : narration (OpenAI TTS) + diapos + montage MP4.

Produit un VRAI fichier .mp4 (diapositives rendues en images, avec piste audio de
narration synthétisée) — remplace l'ancien diaporama navigateur + voix Chrome.
"""
from __future__ import annotations

import os
import tempfile
import textwrap

import httpx

from .llm import LLMError

OPENAI_TTS_URL = os.getenv("OPENAI_TTS_URL", "https://api.openai.com/v1/audio/speech")
TTS_MODEL = os.getenv("TTS_MODEL", "tts-1")
TTS_VOICE = os.getenv("TTS_VOICE", "alloy")

_W, _H = 1280, 720
_BG = (15, 17, 26)
_ACCENT = (99, 102, 241)
_TEXT = (235, 236, 240)
_MUTED = (150, 155, 170)
_MAX_TTS_CHARS = 3500  # limite par requête TTS


def _font(size: int):
    from PIL import ImageFont

    for name in ("arialbd.ttf", "arial.ttf", "DejaVuSans-Bold.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except Exception:  # noqa: BLE001
            continue
    return ImageFont.load_default()


def _synthesize(text: str, out_path: str) -> None:
    """Narration -> fichier MP3 via OpenAI TTS."""
    key = os.getenv("OPENAI_API_KEY")
    if not key:
        raise LLMError(500, "OPENAI_API_KEY non configurée (narration audio)")
    try:
        r = httpx.post(
            OPENAI_TTS_URL,
            headers={"Authorization": f"Bearer {key}"},
            json={"model": TTS_MODEL, "voice": TTS_VOICE, "input": text[:_MAX_TTS_CHARS]},
            timeout=120,
        )
    except httpx.HTTPError as e:
        raise LLMError(502, f"Service TTS injoignable : {e}")
    if r.status_code != 200:
        raise LLMError(r.status_code, f"Erreur TTS ({r.status_code}) : {r.text[:200]}")
    with open(out_path, "wb") as f:
        f.write(r.content)


def _render_slide(kind: str, heading: str, title: str, bullets: list[str]):
    """Rend une diapo en image numpy (RGB)."""
    import numpy as np
    from PIL import Image, ImageDraw

    img = Image.new("RGB", (_W, _H), _BG)
    d = ImageDraw.Draw(img)

    # Bandeau accent en haut
    d.rectangle([0, 0, _W, 8], fill=_ACCENT)

    # Sur-titre (ex. "Leçon 2", "Objectifs")
    d.text((80, 70), heading.upper(), font=_font(30), fill=_ACCENT)

    # Titre principal (wrap)
    y = 130
    for line in textwrap.wrap(title, width=34)[:3]:
        d.text((80, y), line, font=_font(52), fill=_TEXT)
        y += 66

    # Puces
    y += 30
    for b in bullets[:6]:
        wrapped = textwrap.wrap(b, width=64)
        if not wrapped:
            continue
        d.ellipse([80, y + 12, 92, y + 24], fill=_ACCENT)
        for i, line in enumerate(wrapped[:3]):
            d.text((110, y), line, font=_font(28), fill=_TEXT if i == 0 else _MUTED)
            y += 40
        y += 12

    # Pied de page
    d.text((80, _H - 50), "SoulBah AI — Formation", font=_font(22), fill=_MUTED)
    return np.array(img)


def _slides_from_formation(title: str, lessons: list[dict]) -> list[dict]:
    """Construit la liste des diapos {image_args, narration}."""
    slides: list[dict] = []

    slides.append({
        "kind": "intro", "heading": "Formation", "title": title,
        "bullets": [f"{len(lessons)} leçons", "Produit par SoulBah AI"],
        "narration": f"Bienvenue dans la formation : {title}. Cette formation comporte {len(lessons)} leçons.",
    })

    for i, lesson in enumerate(lessons, 1):
        lt = str(lesson.get("title", f"Leçon {i}"))
        objectives = [str(o) for o in (lesson.get("objectives") or [])][:5]
        content = str(lesson.get("content", "")).strip()

        # Diapo titre + objectifs
        slides.append({
            "kind": f"Leçon {i}", "heading": f"Leçon {i}", "title": lt,
            "bullets": objectives or ["—"],
            "narration": (
                f"Leçon {i} : {lt}. "
                + ("Objectifs : " + ". ".join(objectives) + "." if objectives else "")
            ),
        })

        # Diapo contenu (narration = le contenu, tronqué pour le rythme)
        if content:
            summary = content[:700]
            slides.append({
                "kind": f"Leçon {i}", "heading": "Contenu", "title": lt,
                "bullets": textwrap.wrap(content, width=64)[:6],
                "narration": summary,
            })

    slides.append({
        "kind": "conclusion", "heading": "Conclusion", "title": "Merci d'avoir suivi cette formation",
        "bullets": ["Révisez les exercices", "Mettez en pratique"],
        "narration": "Merci d'avoir suivi cette formation. Pensez à réaliser les exercices pour ancrer vos acquis.",
    })
    return slides


def build_formation_video(title: str, lessons: list[dict], out_path: str, max_slides: int | None = None) -> dict:
    """Assemble la vidéo MP4. Retourne {path, slides, duration_s}."""
    from moviepy.editor import AudioFileClip, ImageClip, concatenate_videoclips

    slides = _slides_from_formation(title, lessons)
    if max_slides:
        slides = slides[:max_slides]

    tmpdir = tempfile.mkdtemp(prefix="soulbah_video_")
    clips = []
    audio_files = []
    try:
        for idx, s in enumerate(slides):
            frame = _render_slide(s["kind"], s["heading"], s["title"], s["bullets"])
            mp3 = os.path.join(tmpdir, f"n{idx}.mp3")
            _synthesize(s["narration"], mp3)
            audio_files.append(mp3)
            audio = AudioFileClip(mp3)
            # Un court battement après la narration
            dur = audio.duration + 0.8
            clip = ImageClip(frame).set_duration(dur).set_audio(audio)
            clips.append(clip)

        final = concatenate_videoclips(clips, method="compose")
        final.write_videofile(
            out_path, fps=24, codec="libx264", audio_codec="aac", logger=None,
            temp_audiofile=os.path.join(tmpdir, "final_audio.m4a"),
        )
        duration = final.duration
        final.close()
    finally:
        for c in clips:
            try:
                c.close()
            except Exception:  # noqa: BLE001
                pass

    return {"path": out_path, "slides": len(slides), "duration_s": float(round(duration, 1))}
