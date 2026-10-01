"""Sonde vidéo : un export n'est un succès que si le fichier existe, n'est pas vide
et se décode réellement (T7 : plus de faux succès)."""
from __future__ import annotations

import os
from typing import Any


def probe_video(path: str) -> tuple[bool, dict[str, Any] | str]:
    """Retourne (True, infos) si `path` est une vidéo lisible, sinon (False, raison)."""
    if not isinstance(path, str) or not os.path.isfile(path):
        return False, f"fichier absent : {path}"
    size = os.path.getsize(path)
    if size <= 0:
        return False, f"fichier vide : {path}"
    try:
        import cv2
    except ImportError:
        return False, "sonde vidéo indisponible (opencv non installé) — export non vérifié"
    cap = cv2.VideoCapture(path)
    try:
        if not cap.isOpened():
            return False, f"fichier vidéo illisible : {path}"
        ok, frame = cap.read()
        if not ok or frame is None:
            return False, f"aucune image décodable : {path}"
        fps = float(cap.get(cv2.CAP_PROP_FPS) or 0.0)
        frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        info: dict[str, Any] = {
            "size_bytes": size,
            "fps": round(fps, 3),
            "frames": frames,
            "width": int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0),
            "height": int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0),
        }
        if fps > 0 and frames > 0:
            info["duration_s"] = round(frames / fps, 3)
        return True, info
    finally:
        cap.release()
