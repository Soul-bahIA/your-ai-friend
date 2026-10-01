"""Skill : capturer l'écran (lecture seule, peu sensible).

En plus d'enregistrer le fichier, la capture est encodée en base64 (redimensionnée,
JPEG) et jointe au résultat sous data.image_b64 — c'est ce qui permet à Claude de
« voir » l'écran pendant la phase Observer du moteur de raisonnement.
"""
from __future__ import annotations

import base64
import io
import os
import tempfile

from skills.base import Skill, SkillResult

_MAX_SIDE = 1280  # borne la taille (coût des tokens vision + payload réseau)


def _encode_for_vision(path: str) -> tuple[str, str]:
    from PIL import Image

    with Image.open(path) as img:
        img = img.convert("RGB")
        w, h = img.size
        scale = min(1.0, _MAX_SIDE / max(w, h))
        if scale < 1.0:
            img = img.resize((max(1, int(w * scale)), max(1, int(h * scale))))
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=80)
        return base64.b64encode(buf.getvalue()).decode("ascii"), "image/jpeg"


class ScreenshotSkill(Skill):
    name = "screenshot"
    step_types = ("screenshot", "capture")
    category = "screen"
    sensitive = False  # lecture seule

    def describe(self, step: dict) -> str:
        return f"capture d'écran → {step.get('path', '(fichier temporaire)')}"

    def run(self, step: dict) -> SkillResult:
        try:
            import mss  # import tardif : évite d'exiger la lib si le skill n'est pas utilisé
        except ImportError:
            return SkillResult(ok=False, detail="dépendance 'mss' non installée")

        path = step.get("path")
        if not path:
            path = os.path.join(tempfile.gettempdir(), "soulbah_screenshot.png")

        try:
            with mss.mss() as sct:
                sct.shot(output=path)
        except Exception as e:  # noqa: BLE001 - on remonte l'erreur telle quelle
            return SkillResult(ok=False, detail=f"échec capture : {e}")

        data: dict = {"path": path}
        try:
            image_b64, media_type = _encode_for_vision(path)
            data["image_b64"] = image_b64
            data["media_type"] = media_type
        except Exception:  # noqa: BLE001 - l'encodage vision est un bonus, pas bloquant
            pass

        return SkillResult(ok=True, detail=f"capture enregistrée : {path}", data=data)
