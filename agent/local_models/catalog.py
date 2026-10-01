"""Candidats de modèles et de moteurs locaux (V3 LOT 2) — PROPOSITIONS, jamais téléchargées seules.

Chaque entrée nomme une source officielle (dépôt Hugging Face, publication GitHub). `resolve()`
lit en ligne les métadonnées EXACTES avant toute proposition : taille, empreinte sha256, licence
déclarée, révision figée. La licence « attendue » ici n'est qu'un indice : seule la licence lue au
moment de la résolution est présentée, et l'utilisateur doit l'accepter (mission V3 §81).

Tailles indicatives : modèles de 1,5 à 4 milliards de paramètres quantifiés en 4 bits, adaptés à
une machine de 8 Go sans GPU dédié (rapport LOT 0 §E). Rien n'est supposé « le meilleur » : le
banc d'essai (bench.py) départage sur la machine réelle (mission §46).
"""
from __future__ import annotations

import re
from typing import Any

HF_API = "https://huggingface.co/api/models"
HF_RESOLVE = "https://huggingface.co/{repo}/resolve/{revision}/{file}"
GITHUB_API = "https://api.github.com/repos"
TIMEOUT = 30

MODELS: dict[str, dict[str, Any]] = {
    "qwen2.5-1.5b-instruct-q4_k_m": {
        "name": "Qwen2.5 1.5B Instruct (Q4_K_M)", "family": "qwen2.5", "version": "2.5", "quantization": "Q4_K_M",
        "repo": "Qwen/Qwen2.5-1.5B-Instruct-GGUF", "file": "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        "roles": ["chat", "planning", "reasoning", "fast"], "context_max": 32768, "expected_license": "apache-2.0",
        "capabilities": {"json_schema": True, "vision": False},
    },
    "qwen2.5-3b-instruct-q4_k_m": {
        "name": "Qwen2.5 3B Instruct (Q4_K_M)", "family": "qwen2.5", "version": "2.5", "quantization": "Q4_K_M",
        "repo": "Qwen/Qwen2.5-3B-Instruct-GGUF", "file": "qwen2.5-3b-instruct-q4_k_m.gguf",
        "roles": ["chat", "planning", "reasoning"], "context_max": 32768, "expected_license": "à vérifier",
        "capabilities": {"json_schema": True, "vision": False},
    },
    "phi-3.5-mini-instruct-q4_k_m": {
        "name": "Phi-3.5 mini Instruct (Q4_K_M)", "family": "phi-3.5", "version": "3.5", "quantization": "Q4_K_M",
        "repo": "bartowski/Phi-3.5-mini-instruct-GGUF", "file": "Phi-3.5-mini-instruct-Q4_K_M.gguf",
        "roles": ["chat", "planning", "reasoning"], "context_max": 131072, "expected_license": "mit",
        "capabilities": {"json_schema": True, "vision": False},
    },
    "llama-3.2-3b-instruct-q4_k_m": {
        "name": "Llama 3.2 3B Instruct (Q4_K_M)", "family": "llama-3.2", "version": "3.2", "quantization": "Q4_K_M",
        "repo": "bartowski/Llama-3.2-3B-Instruct-GGUF", "file": "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
        "roles": ["chat", "planning", "reasoning"], "context_max": 131072, "expected_license": "llama3.2",
        "capabilities": {"json_schema": True, "vision": False},
    },
    "qwen2.5-coder-1.5b-instruct-q4_k_m": {
        "name": "Qwen2.5 Coder 1.5B Instruct (Q4_K_M)", "family": "qwen2.5-coder", "version": "2.5",
        "quantization": "Q4_K_M", "repo": "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF",
        "file": "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf", "roles": ["code"], "context_max": 32768,
        "expected_license": "apache-2.0", "capabilities": {"json_schema": True, "vision": False},
    },
    "nomic-embed-text-v1.5-q8_0": {
        "name": "nomic-embed-text v1.5 (Q8_0)", "family": "nomic-embed", "version": "1.5", "quantization": "Q8_0",
        "repo": "nomic-ai/nomic-embed-text-v1.5-GGUF", "file": "nomic-embed-text-v1.5.Q8_0.gguf",
        "roles": ["embedding"], "context_max": 8192, "expected_license": "apache-2.0",
        "capabilities": {"embedding_dim": 768},
    },
}

ENGINES: dict[str, dict[str, Any]] = {
    "llama.cpp-win-cpu-x64": {
        "name": "llama.cpp (Windows, CPU x64)", "repo": "ggml-org/llama.cpp",
        "asset_pattern": r"^llama-b\d+-bin-win-cpu-x64\.zip$", "binary": "llama-server.exe",
        "expected_license": "MIT",
    },
    "llama.cpp-win-vulkan-x64": {
        "name": "llama.cpp (Windows, Vulkan x64)", "repo": "ggml-org/llama.cpp",
        "asset_pattern": r"^llama-b\d+-bin-win-vulkan-x64\.zip$", "binary": "llama-server.exe",
        "expected_license": "MIT",
    },
}


class ResolveError(RuntimeError):
    pass


def _get_json(session: Any, url: str) -> Any:
    r = session.get(url, timeout=TIMEOUT, headers={"Accept": "application/json", "User-Agent": "SoulBahAgent/2"})
    if r.status_code != 200:
        raise ResolveError(f"{url} : HTTP {r.status_code}")
    return r.json()


def _hf_license(info: dict[str, Any]) -> str | None:
    card = info.get("cardData") or {}
    if isinstance(card, dict) and card.get("license"):
        lic = card["license"]
        name = card.get("license_name")
        return f"{lic} ({name})" if name and lic == "other" else str(lic)
    for tag in info.get("tags") or []:
        if isinstance(tag, str) and tag.startswith("license:"):
            return tag.split(":", 1)[1]
    return None


def resolve_model(model_id: str, session: Any = None) -> dict[str, Any]:
    """Métadonnées EXACTES d'un modèle du catalogue (lecture seule, quelques Ko)."""
    spec = MODELS.get(model_id)
    if spec is None:
        raise ResolveError(f"modèle inconnu du catalogue : {model_id}")
    if session is None:
        import requests

        session = requests.Session()
    info = _get_json(session, f"{HF_API}/{spec['repo']}")
    revision = info.get("sha")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ResolveError(f"révision introuvable pour {spec['repo']}")
    tree = _get_json(session, f"{HF_API}/{spec['repo']}/tree/{revision}")
    entry = next((e for e in tree if isinstance(e, dict) and e.get("path") == spec["file"]), None)
    if entry is None:
        raise ResolveError(f"fichier {spec['file']} absent de {spec['repo']}")
    lfs = entry.get("lfs") or {}
    sha = lfs.get("oid") or lfs.get("sha256")
    size = lfs.get("size") or entry.get("size")
    if not (isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{64}", sha)) or not isinstance(size, int):
        raise ResolveError(f"empreinte sha256 ou taille non publiée pour {spec['file']}")
    return {
        "kind": "model", "id": model_id, **{k: v for k, v in spec.items() if k != "expected_license"},
        "license": _hf_license(info), "expected_license": spec["expected_license"], "revision": revision,
        "size_bytes": size, "sha256": sha,
        "url": HF_RESOLVE.format(repo=spec["repo"], revision=revision, file=spec["file"]),
        "source_page": f"https://huggingface.co/{spec['repo']}",
        "gated": bool(info.get("gated")),
    }


def resolve_engine(engine_id: str, session: Any = None) -> dict[str, Any]:
    spec = ENGINES.get(engine_id)
    if spec is None:
        raise ResolveError(f"moteur inconnu du catalogue : {engine_id}")
    if session is None:
        import requests

        session = requests.Session()
    # llama.cpp publie ses binaires dans des versions « bNNNNN » marquées prerelease ; la « latest »
    # officielle peut ne pas en contenir : on prend la plus récente qui contient le fichier attendu.
    pattern = re.compile(spec["asset_pattern"])
    rel: dict[str, Any] = {}
    asset = None
    for candidate in _get_json(session, f"{GITHUB_API}/{spec['repo']}/releases?per_page=15"):
        asset = next((a for a in candidate.get("assets") or [] if pattern.match(str(a.get("name")))), None)
        if asset is not None:
            rel = candidate
            break
    if asset is None:
        raise ResolveError(f"aucun fichier « {spec['asset_pattern']} » dans les publications récentes de {spec['repo']}")
    digest = str(asset.get("digest") or "")
    sha = digest.split(":", 1)[1] if digest.startswith("sha256:") else None
    repo = _get_json(session, f"{GITHUB_API}/{spec['repo']}")
    lic = (repo.get("license") or {}).get("spdx_id")
    return {
        "kind": "engine", "id": engine_id, "name": spec["name"], "repo": spec["repo"], "binary": spec["binary"],
        "release": rel.get("tag_name"), "file": asset.get("name"), "size_bytes": asset.get("size"), "sha256": sha,
        "url": asset.get("browser_download_url"), "license": lic, "expected_license": spec["expected_license"],
        "source_page": rel.get("html_url"),
    }
