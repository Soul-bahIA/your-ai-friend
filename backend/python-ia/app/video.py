"""Production vidéo d'une formation : narration (OpenAI TTS) + diapos + montage MP4.

Produit un VRAI fichier .mp4 (diapositives rendues en images, avec piste audio de
narration synthétisée) — remplace l'ancien diaporama navigateur + voix Chrome.

T27 (partiel) :
- la narration TTS des diapos est synthétisée EN PARALLÈLE dans un pool borné
  (VIDEO_TTS_CONCURRENCY, défaut 3, max 8) ;
- annulation coopérative : `should_cancel()` (client déconnecté ou échéance
  x-deadline-ms dépassée, cf. main.py) est consulté par le thread appelant avant
  chaque phase et toutes les secondes pendant les TTS ; les TTS non démarrées sont
  abandonnées (aucun nouvel appel payant).
- échéance propagée aux TTS : chaque requête TTS a un délai TOTAL (garde
  asyncio.wait_for, pas seulement les délais par phase d'httpx) de
  min(120 s, temps restant avant x-deadline-ms − marge) ; une TTS qui ne peut plus
  aboutir avant l'échéance n'est pas lancée (504). Les TTS en vol se terminent donc
  avant l'échéance et le 504 n'arrive pas après elle.
Limite documentée : l'encodage MP4 (moviepy/ffmpeg) n'est pas interruptible une fois
lancé. Une vraie file de jobs annulables relève du LOT 14.
"""
from __future__ import annotations

import asyncio
import concurrent.futures as cf
import logging
import os
import shutil
import tempfile
import textwrap
import threading
import time
import uuid
from typing import Callable

import httpx

from . import request_context
from .llm import LLMError
from .providers.base import upstream_error

logger = logging.getLogger("python-ia")

OPENAI_TTS_URL = os.getenv("OPENAI_TTS_URL", "https://api.openai.com/v1/audio/speech")
TTS_MODEL = os.getenv("TTS_MODEL", "tts-1")
TTS_VOICE = os.getenv("TTS_VOICE", "alloy")

_W, _H = 1280, 720
_BG = (15, 17, 26)
_ACCENT = (99, 102, 241)
_TEXT = (235, 236, 240)
_MUTED = (150, 155, 170)
_MAX_TTS_CHARS = 3500  # limite par requête TTS
_ASSETS_FONTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets", "fonts")
_CANCEL_POLL_S = 1.0
_TTS_TIMEOUT_S = 120.0       # délai TOTAL maximal d'une requête TTS
_TTS_MIN_BUDGET_S = 1.0      # en dessous, on ne lance pas une TTS (elle ne peut aboutir)
_TTS_DEADLINE_MARGIN_S = 0.5  # temps laissé pour répondre à l'appelant


class VideoCancelled(Exception):
    """Production abandonnée (client déconnecté ou échéance dépassée)."""


def _tts_concurrency() -> int:
    try:
        return max(1, min(8, int(os.getenv("VIDEO_TTS_CONCURRENCY", "3"))))
    except ValueError:
        return 3


def _font(size: int):
    from PIL import ImageFont

    for name in (os.path.join(_ASSETS_FONTS, "DejaVuSans-Bold.ttf"), "arialbd.ttf", "arial.ttf",
                 "DejaVuSans-Bold.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except Exception:  # noqa: BLE001
            continue
    return ImageFont.load_default()


def _tts_timeout(deadline_at: float | None) -> float:
    """Délai total d'une TTS lancée MAINTENANT : min(120 s, temps restant avant
    l'échéance − marge). LLMError 504 si ce budget ne permet plus d'aboutir."""
    if deadline_at is None:
        return _TTS_TIMEOUT_S
    budget = deadline_at - time.monotonic() - _TTS_DEADLINE_MARGIN_S
    if budget < _TTS_MIN_BUDGET_S:
        raise LLMError(504, "Délai de la requête dépassé avant la fin de la narration audio.",
                       kind="deadline")
    return min(_TTS_TIMEOUT_S, budget)


async def _post_tts(key: str, payload: dict, total_s: float) -> httpx.Response:
    # httpx.Timeout borne chaque phase (connexion, écriture, lecture…) ; wait_for borne
    # la DURÉE TOTALE (un serveur qui distille la réponse octet par octet est coupé).
    async with httpx.AsyncClient(timeout=httpx.Timeout(total_s)) as client:
        return await asyncio.wait_for(
            client.post(OPENAI_TTS_URL, headers={"Authorization": f"Bearer {key}"}, json=payload),
            timeout=total_s,
        )


def _synthesize(text: str, out_path: str, timeout_s: float | None = None) -> None:
    """Narration -> fichier MP3 via OpenAI TTS (appel bloquant, depuis un thread du pool).

    `timeout_s` : délai TOTAL de la requête (défaut et plafond : 120 s)."""
    key = os.getenv("OPENAI_API_KEY")
    if not key:
        raise LLMError(500, "OPENAI_API_KEY non configurée (narration audio)")
    total = _TTS_TIMEOUT_S if timeout_s is None else max(0.1, min(_TTS_TIMEOUT_S, float(timeout_s)))
    payload = {"model": TTS_MODEL, "voice": TTS_VOICE, "input": text[:_MAX_TTS_CHARS]}
    try:
        r = asyncio.run(_post_tts(key, payload, total))
    except (TimeoutError, httpx.TimeoutException):
        logger.warning("Service TTS : délai dépassé (%.1f s)", total)
        raise LLMError(504, "Service TTS : délai dépassé", fallback=True, kind="timeout")
    except httpx.HTTPError as e:
        logger.warning("Service TTS injoignable : %s", e)
        raise LLMError(502, "Service TTS injoignable", fallback=True, kind="connection")
    if r.status_code != 200:
        # Ne jamais propager tel quel le code amont (un 401 OpenAI ferait croire au
        # client que SA session est invalide) ni un corps amont (journalisé seulement).
        raise upstream_error("TTS OpenAI", r.status_code, r.text[:500])
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


def _synthesize_all(slides: list[dict], tmpdir: str, should_cancel: Callable[[], bool]) -> list[str]:
    """Synthétise la narration de chaque diapo dans un pool borné ; renvoie les
    chemins MP3 dans l'ordre des diapos. Annulation : voir docstring du module."""
    paths = [os.path.join(tmpdir, f"n{idx}.mp3") for idx in range(len(slides))]
    stop = threading.Event()
    # Échéance de la requête, lue ICI (thread appelant : les ContextVar de la requête
    # n'existent pas dans les threads du pool) puis figée en instant absolu.
    remaining = request_context.remaining_s()
    deadline_at = time.monotonic() + remaining if remaining is not None else None

    def job(idx: int) -> None:
        if stop.is_set():
            raise VideoCancelled()
        _synthesize(slides[idx]["narration"], paths[idx], timeout_s=_tts_timeout(deadline_at))

    pool = cf.ThreadPoolExecutor(max_workers=_tts_concurrency(), thread_name_prefix="soulbah-tts")
    futures = [pool.submit(job, i) for i in range(len(slides))]
    try:
        pending = set(futures)
        while pending:
            if should_cancel():
                raise VideoCancelled()
            done, pending = cf.wait(pending, timeout=_CANCEL_POLL_S, return_when=cf.FIRST_EXCEPTION)
            for f in done:
                exc = f.exception()
                if exc is not None:
                    raise exc
        return paths
    finally:
        stop.set()
        # Les TTS non démarrées sont annulées ; celles déjà en vol (délai total borné par
        # l'échéance, cf. _tts_timeout) sont attendues pour qu'aucun thread n'écrive
        # encore dans tmpdir après le retour.
        pool.shutdown(wait=True, cancel_futures=True)


def build_formation_video(
    title: str,
    lessons: list[dict],
    out_path: str,
    max_slides: int | None = None,
    should_cancel: Callable[[], bool] | None = None,
) -> dict:
    """Assemble la vidéo MP4. Retourne {path, slides, duration_s}.

    `should_cancel` (optionnel) est appelé UNIQUEMENT depuis le thread appelant ;
    s'il renvoie True, la production s'arrête (VideoCancelled) sans fichier final.
    """
    from moviepy.editor import AudioFileClip, ImageClip, concatenate_videoclips

    cancelled = should_cancel or (lambda: False)
    slides = _slides_from_formation(title, lessons)
    if max_slides:
        slides = slides[:max_slides]

    tmpdir = tempfile.mkdtemp(prefix="soulbah_video_")
    clips = []
    audios = []
    final = None
    # Écriture dans un fichier temporaire du MÊME dossier, puis os.replace atomique :
    # un lecteur (Node /media) ne voit jamais un MP4 à moitié écrit.
    out_dir = os.path.dirname(os.path.abspath(out_path))
    partial = os.path.join(out_dir, f".{os.path.basename(out_path)}.{uuid.uuid4().hex}.part.mp4")
    try:
        if cancelled():
            raise VideoCancelled()
        mp3s = _synthesize_all(slides, tmpdir, cancelled)
        for s, mp3 in zip(slides, mp3s):
            frame = _render_slide(s["kind"], s["heading"], s["title"], s["bullets"])
            audio = AudioFileClip(mp3)
            audios.append(audio)
            # Un court battement après la narration
            dur = audio.duration + 0.8
            clip = ImageClip(frame).set_duration(dur).set_audio(audio)
            clips.append(clip)

        if cancelled():
            raise VideoCancelled()
        final = concatenate_videoclips(clips, method="compose")
        final.write_videofile(
            partial, fps=24, codec="libx264", audio_codec="aac", logger=None,
            temp_audiofile=os.path.join(tmpdir, "final_audio.m4a"),
        )
        duration = final.duration
        os.replace(partial, out_path)
    finally:
        for c in [final, *clips, *audios]:
            if c is None:
                continue
            try:
                c.close()
            except Exception:  # noqa: BLE001
                pass
        if os.path.exists(partial):
            try:
                os.remove(partial)
            except OSError:
                pass
        shutil.rmtree(tmpdir, ignore_errors=True)

    return {"path": out_path, "slides": len(slides), "duration_s": float(round(duration, 1))}
