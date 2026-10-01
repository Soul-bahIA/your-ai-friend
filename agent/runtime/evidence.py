"""Preuves typées d'une étape (LOT 9, audit §9.8) construites à partir du résultat d'un
skill et des déclarations `evidence` de son manifeste (shared/tools/catalog.json).

Forme : shared/schemas/evidence.schema.json — `{kind, confidence, description?, value?,
artifact_id?, sha256?, step_index?, at?}`, rien d'autre. Règles :

  - jamais de contenu binaire : une capture (`image_b64`) devient un ARTEFACT téléversé
    (`PUT /api/v2/artifacts/<sha256>`) et la preuve ne porte que son empreinte / son id ;
    si le téléversement échoue, l'empreinte seule est envoyée (preuve toujours valide) ;
  - jamais de contenu lu : `read_file` produit l'empreinte du texte, pas le texte (il peut
    contenir un secret) ;
  - un fichier produit (`path`) est accompagné de son sha256 (preuve « high ») quand il
    existe et reste raisonnable (≤ 256 Mo) ;
  - toute valeur est rédigée (LOT 6) et bornée à 3 000 caractères ; une valeur qui
    ressemble à un blob base64 est omise.
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import re
from typing import Any, Callable

from redaction import redact_obj, redact_text
from skills.manifests import get_manifest

log = logging.getLogger("soulbah.runtime.evidence")

MAX_VALUE_CHARS = 3000
MAX_DESCRIPTION_CHARS = 2000
MAX_HASH_BYTES = 256 * 1024 * 1024
# Même seuil que backend/node-api/src/v2/evidence.ts (containsBinaryBlob).
_BASE64_BLOB = re.compile(r"^[A-Za-z0-9+/=\r\n]{256,}$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

# Téléverse (contenu, mime, kind) → (artifact_id | None, sha256) ; None si indisponible.
Uploader = Callable[[bytes, str, str], "tuple[str | None, str] | None"]


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: str, limit: int = MAX_HASH_BYTES) -> str | None:
    """Empreinte d'un fichier existant (None s'il est absent, illisible ou trop gros)."""
    try:
        if not os.path.isfile(path) or os.path.getsize(path) > limit:
            return None
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def looks_binary(value: Any) -> bool:
    if isinstance(value, str):
        return bool(_BASE64_BLOB.match(value)) or value.startswith(("data:image/", "data:video/"))
    if isinstance(value, dict):
        return any(k in ("image_b64", "b64", "base64") or looks_binary(v) for k, v in value.items())
    if isinstance(value, (list, tuple)):
        return any(looks_binary(v) for v in value)
    return False


def bounded_value(value: Any) -> Any:
    """Valeur rédigée, sans blob, sérialisée en ≤ MAX_VALUE_CHARS (sinon tronquée en texte)."""
    if value is None or looks_binary(value):
        return None
    value = redact_obj(value) if isinstance(value, (dict, list)) else (
        redact_text(value) if isinstance(value, str) else value)
    if isinstance(value, (int, float, bool)):
        return value
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, default=str)
    if len(text) <= MAX_VALUE_CHARS:
        return value
    return text[:MAX_VALUE_CHARS] + f"… [{len(text) - MAX_VALUE_CHARS} car. tronqués]"


def _description(text: Any) -> str | None:
    if not text:
        return None
    return redact_text(str(text))[:MAX_DESCRIPTION_CHARS]


def _entry(kind: str, confidence: str, description: Any = None, value: Any = None,
           sha256: str | None = None, artifact_id: str | None = None, step_index: int | None = None
           ) -> dict[str, Any]:
    e: dict[str, Any] = {"kind": kind, "confidence": confidence}
    desc = _description(description)
    if desc:
        e["description"] = desc
    v = bounded_value(value)
    if v is not None:
        e["value"] = v
    if sha256:
        e["sha256"] = sha256
    if artifact_id:
        e["artifact_id"] = artifact_id
    if step_index is not None:
        e["step_index"] = int(step_index)
    return e


def _image_bytes(data: dict[str, Any]) -> tuple[bytes, str] | None:
    """Contenu de la capture : le fichier sur disque s'il existe, sinon l'image encodée."""
    path = data.get("path")
    if isinstance(path, str) and os.path.isfile(path):
        try:
            with open(path, "rb") as f:
                content = f.read()
            ext = os.path.splitext(path)[1].lower()
            mime = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}.get(
                ext, "application/octet-stream")
            return content, mime
        except OSError:
            pass
    b64 = data.get("image_b64")
    if isinstance(b64, str) and b64:
        try:
            return base64.b64decode(b64, validate=False), str(data.get("media_type") or "image/jpeg")
        except (ValueError, TypeError):
            return None
    return None


def build_evidence(step_type: str, ok: bool, detail: str, data: dict[str, Any] | None,
                   step_index: int | None = None, upload: Uploader | None = None) -> list[dict[str, Any]]:
    """Preuves d'une étape exécutée (vide pour un outil sans preuve déclarée, ex. wait)."""
    data = data if isinstance(data, dict) else {}
    manifest = get_manifest(step_type)
    declared = list(manifest.get("evidence") or []) if manifest else []
    out: list[dict[str, Any]] = []
    seen_paths: set[str] = set()

    for spec in declared:
        kind = str(spec.get("kind"))
        conf = str(spec.get("confidence") or "none")
        field = spec.get("field")
        if not field:
            # Preuve sans champ : le compte rendu de l'agent (ou le titre pour `window`).
            out.append(_entry(kind, conf, description=detail, step_index=step_index))
            continue
        if field == "image_b64":
            img = _image_bytes(data)
            if img is None:
                continue
            content, mime = img
            digest = sha256_bytes(content)
            artifact_id = None
            if upload is not None:
                try:
                    uploaded = upload(content, mime, "screenshot")
                    if uploaded:
                        artifact_id, digest = uploaded[0], uploaded[1] or digest
                except Exception:  # noqa: BLE001 - un artefact manquant ne casse pas la preuve
                    log.warning("Téléversement de la capture impossible (étape %s)", step_index, exc_info=True)
            out.append(_entry(kind, conf, description="capture d'écran (artefact)", sha256=digest,
                              artifact_id=artifact_id, step_index=step_index))
            continue
        if field not in data:
            continue
        value = data.get(field)
        if kind == "sha256":
            # Empreinte calculée par le skill (page web, texte d'un champ…) : portée par `sha256`.
            if isinstance(value, str) and _SHA256_RE.match(value):
                out.append(_entry(kind, conf, description=spec.get("description") or detail, sha256=value,
                                  step_index=step_index))
            continue
        if field == "content":
            text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, default=str)
            out.append(_entry(kind, conf, description=f"{len(text)} caractères lus (contenu non transmis)",
                              sha256=sha256_bytes(text.encode("utf-8")), step_index=step_index))
            continue
        if field == "entries" and isinstance(value, list):
            names = [str(e.get("name") if isinstance(e, dict) else e) for e in value[:20]]
            out.append(_entry(kind, conf, description=f"{len(value)} entrée(s)",
                              value={"count": len(value), "sample": names}, step_index=step_index))
            continue
        if field in ("stdout", "stderr"):
            if not value:
                continue
            out.append(_entry(kind, conf, description=field, value=str(value), step_index=step_index))
            continue
        if field == "path" and isinstance(value, str):
            seen_paths.add(value)
            out.append(_entry(kind, conf, description=detail, value=value, step_index=step_index))
            digest = sha256_file(value)
            if digest:
                out.append(_entry("sha256", "high", description=f"empreinte de {os.path.basename(value)}",
                                  sha256=digest, step_index=step_index))
            continue
        if field == "frames":
            # Statistiques numériques de l'enregistrement (frames, fps, durée…).
            stats = {k: v for k, v in data.items() if isinstance(v, (int, float)) and not isinstance(v, bool)}
            out.append(_entry(kind, conf, description=detail, value=stats, step_index=step_index))
            continue
        out.append(_entry(kind, conf, description=detail, value=value, step_index=step_index))

    # Fichier produit sans déclaration `path` (ex. edit_video) : son empreinte reste utile.
    path = data.get("path")
    if isinstance(path, str) and path not in seen_paths and ok:
        digest = sha256_file(path)
        if digest:
            out.append(_entry("sha256", "high", description=f"empreinte de {os.path.basename(path)}",
                              sha256=digest, step_index=step_index))
    return out


def self_report(detail: str, step_index: int | None = None) -> list[dict[str, Any]]:
    """Preuve minimale (compte rendu, confiance nulle) : dry-run, reprise."""
    return [_entry("self_report", "none", description=detail or "—", step_index=step_index)]
