"""Registre `local_models` (V3 LOT 2, mission §6) : un fichier JSON local, écrit atomiquement.

Forme : {"version": 1, "models": {id: entrée}, "engines": {id: entrée}}.
Entrée de modèle : id, name, family, version, roles, path, size_bytes, sha256, quantization,
context_max, ram_estimate_gb, vram_estimate_gb, runtime, capabilities, license, source,
benchmark, installed_at, status (installed | verified | failed).
"""
from __future__ import annotations

import datetime as _dt
import json
import os
import re
import tempfile
import threading
from typing import Any

REGISTRY_VERSION = 1
MODEL_STATUSES = ("installed", "verified", "failed")
ROLES = ("reasoning", "planning", "chat", "code", "vision", "embedding", "rerank", "stt", "tts", "fast")
_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,99}$")
_lock = threading.Lock()


def base_dir() -> str:
    return os.environ.get("SOULBAH_MODELS_DIR") or os.path.join(
        os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "Soulbah", "models")


def engines_dir() -> str:
    return os.environ.get("SOULBAH_ENGINES_DIR") or os.path.join(
        os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "Soulbah", "engines")


def registry_path() -> str:
    return os.path.join(base_dir(), "registry.json")


def now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")


def valid_id(model_id: str) -> bool:
    return bool(_ID_RE.match(model_id or ""))


def ram_estimate_gb(size_bytes: int, context: int = 4096, parallel: int = 1) -> float:
    """Estimation : poids + cache KV (≈ 0,25 Go par tranche de 4 096 jetons et par contexte
    pour un modèle de 1 à 4 milliards de paramètres) + 0,3 Go de surcoût du serveur."""
    return round(size_bytes / 1024 ** 3 + 0.25 * (context / 4096) * max(1, parallel) + 0.3, 2)


def load() -> dict[str, Any]:
    path = registry_path()
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return {"version": REGISTRY_VERSION, "models": {}, "engines": {}}
    if not isinstance(data, dict) or data.get("version") != REGISTRY_VERSION:
        raise ValueError(f"registre des modèles illisible ou de version inconnue : {path}")
    data.setdefault("models", {})
    data.setdefault("engines", {})
    return data


def save(data: dict[str, Any]) -> None:
    path = registry_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".registry-", suffix=".json", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def upsert(kind: str, entry: dict[str, Any]) -> dict[str, Any]:
    if kind not in ("models", "engines"):
        raise ValueError("kind : models | engines")
    if not valid_id(str(entry.get("id"))):
        raise ValueError(f"identifiant invalide : {entry.get('id')!r}")
    with _lock:
        data = load()
        current = data[kind].get(entry["id"], {})
        merged = {**current, **entry, "updated_at": now_iso()}
        data[kind][entry["id"]] = merged
        save(data)
        return merged


def remove(kind: str, entry_id: str) -> bool:
    with _lock:
        data = load()
        existed = data[kind].pop(entry_id, None) is not None
        if existed:
            save(data)
        return existed


def models_for_role(role: str) -> list[dict[str, Any]]:
    """Modèles installés et sains pour un rôle, du plus grand au plus petit (repli Large → Small)."""
    data = load()
    out = [m for m in data["models"].values()
           if role in (m.get("roles") or []) and m.get("status") in ("installed", "verified")
           and m.get("path") and os.path.isfile(m["path"])]
    return sorted(out, key=lambda m: -(m.get("size_bytes") or 0))
