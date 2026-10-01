"""Briques communes de l'enregistrement d'écran (record_screen / record_bg), T24.

- Cadence CONSTANTE calée sur l'horloge réelle : l'image n°i correspond à
  t = i / fps. Si la capture est plus lente que le fps demandé (grand écran,
  machine chargée), la dernière image est dupliquée pour combler : la durée de la
  vidéo reste égale au temps réel (±1 image), au lieu d'une vidéo accélérée.
- fps réellement capturé mesuré et renvoyé (`capture_fps`).
- Codec : H.264 (`avc1`) si OpenCV le fournit, sinon `mp4v` avec un avertissement.
"""
from __future__ import annotations

import logging
import os
import time
from typing import Any, Callable

log = logging.getLogger("soulbah.recording")

VIDEO_EXTENSIONS = (".mp4", ".avi")
_CODECS = {
    ".mp4": ("avc1", "H264", "mp4v"),
    ".avi": ("MJPG", "XVID"),
}
_PREFERRED = {".mp4": ("avc1", "H264"), ".avi": ("MJPG", "XVID")}


def validate_video_path(path: object, label: str = "path") -> str | None:
    if not isinstance(path, str) or not path.strip():
        return f"champ '{label}' manquant (.mp4)"
    if not path.lower().endswith(VIDEO_EXTENSIONS):
        return f"le fichier vidéo doit finir par {' / '.join(VIDEO_EXTENSIONS)} : {path}"
    return None


def validate_monitor(value: object) -> str | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 16:
        return "champ 'monitor' invalide (entier : 1 = écran principal, 0 = tous les écrans)"
    return None


def recording_key(path: str) -> str:
    """Clé normalisée d'un enregistrement : « C:/x/Demo.mp4 » et « c:\\x\\demo.mp4 »
    désignent le même fichier sous Windows."""
    return os.path.normcase(os.path.realpath(os.path.abspath(path)))


def output_dir_error(path: str) -> str | None:
    directory = os.path.dirname(os.path.abspath(path))
    if not os.path.isdir(directory):
        return f"dossier de sortie introuvable : {directory}"
    return None


def open_writer(cv2: Any, path: str, fps: int, size: tuple[int, int]) -> tuple[Any, str | None, str | None]:
    """Ouvre un VideoWriter avec le meilleur codec disponible.

    Retourne (writer, codec, avertissement) ; writer None si aucun codec ne marche."""
    ext = os.path.splitext(path)[1].lower()
    candidates = _CODECS.get(ext, ("mp4v",))
    for codec in candidates:
        try:
            writer = cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*codec), fps, size)
        except Exception:  # noqa: BLE001 - codec absent de cette build d'OpenCV
            writer = None
        if writer is not None and writer.isOpened():
            warning = None
            if codec not in _PREFERRED.get(ext, ()):
                warning = (f"codec H.264 indisponible dans OpenCV — repli « {codec} » "
                           f"(lecture possible limitée dans certains navigateurs/éditeurs)")
                log.warning("%s : %s", path, warning)
            return writer, codec, warning
        if writer is not None:
            try:
                writer.release()
            except Exception:  # noqa: BLE001
                pass
        try:  # un essai raté peut laisser un fichier vide
            if os.path.isfile(path) and os.path.getsize(path) == 0:
                os.remove(path)
        except OSError:
            pass
    return None, None, None


def capture_loop(
    grab: Callable[[], Any],
    write: Callable[[Any], None],
    fps: int,
    should_stop: Callable[[], bool],
    max_seconds: float,
    clock: Callable[[], float] = time.monotonic,
    wait: Callable[[float], Any] = time.sleep,
    on_first: Callable[[], None] | None = None,
) -> dict[str, Any]:
    """Capture à cadence constante calée sur l'horloge réelle (voir module)."""
    start = clock()
    written = 0
    unique = 0
    last = None
    while True:
        if should_stop() or clock() - start >= max_seconds:
            break
        frame = grab()
        unique += 1
        last = frame
        # Nombre d'images qui devraient exister à cet instant (t = i / fps).
        target = int((clock() - start) * fps) + 1
        for _ in range(max(1, target - written)):
            write(frame)
            written += 1
        if unique == 1 and on_first is not None:
            on_first()
        delay = start + written / fps - clock()
        if delay > 0:
            wait(delay)
    elapsed = max(0.0, clock() - start)
    expected = int(round(elapsed * fps))
    if last is not None:
        while written < expected:  # complète jusqu'à l'instant de l'arrêt
            write(last)
            written += 1
    return {
        "frames": written,
        "unique_frames": unique,
        "duration_s": round(elapsed, 3),
        "video_duration_s": round(written / fps, 3) if fps else 0.0,
        "capture_fps": round(unique / elapsed, 2) if elapsed > 0 else 0.0,
        "fps": fps,
    }


def record_to_file(
    path: str,
    fps: int,
    should_stop: Callable[[], bool],
    max_seconds: float,
    monitor: int = 1,
    wait: Callable[[float], Any] = time.sleep,
    on_ready: Callable[[str | None], None] | None = None,
) -> dict[str, Any]:
    """Enregistre l'écran dans `path` (mss + OpenCV). `on_ready(erreur|None)` est
    appelé dès que le fichier est ouvert (ou a échoué). Lève RuntimeError en cas
    d'échec d'ouverture ; le fichier est toujours finalisé."""
    import cv2
    import mss
    import numpy as np

    writer = None
    try:
        with mss.mss() as sct:
            if monitor >= len(sct.monitors):
                raise RuntimeError(f"écran {monitor} introuvable ({len(sct.monitors) - 1} écran(s))")
            area = sct.monitors[monitor]
            first = np.array(sct.grab(area))
            h, w = first.shape[0], first.shape[1]
            writer, codec, warning = open_writer(cv2, path, fps, (w, h))
            if writer is None:
                raise RuntimeError(f"impossible de créer le fichier vidéo : {path}")
            if on_ready is not None:
                on_ready(None)

            def grab() -> Any:
                return cv2.cvtColor(np.array(sct.grab(area)), cv2.COLOR_BGRA2BGR)

            stats = capture_loop(grab, writer.write, fps, should_stop, max_seconds, wait=wait)
            stats.update({"codec": codec, "width": w, "height": h, "monitor": monitor})
            if warning:
                stats["warning"] = warning
            return stats
    except Exception as e:
        if on_ready is not None:
            on_ready(str(e))
        raise
    finally:
        # Toujours finaliser le fichier, même en cas d'erreur en cours de capture.
        if writer is not None:
            try:
                writer.release()
            except Exception:  # noqa: BLE001
                pass
