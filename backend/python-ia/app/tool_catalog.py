"""Catalogue d'outils de l'agent (LOT 2 : contrat d'outils unique).

app/generated/tool_catalog.json est une copie GÉNÉRÉE de shared/tools/catalog.json :
agent/skills/manifests.py → scripts/gen_catalog.py (`--check` en CI échoue à la moindre
dérive). Ne jamais la modifier à la main : voir docs/CATALOGUE_OUTILS.md. La copie vit
dans app/ parce que l'image Docker est construite depuis backend/python-ia (shared/ est
hors du contexte de build).
"""
from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

CATALOG_PATH = Path(__file__).resolve().parent / "generated" / "tool_catalog.json"


def _check(catalog: Any) -> dict[str, Any]:
    """Contrôle de forme (le schéma complet est vérifié par gen_catalog.py) : une copie
    corrompue doit faire échouer le démarrage, pas produire un prompt incomplet."""
    if not isinstance(catalog, dict) or not isinstance(catalog.get("tools"), list) or not catalog["tools"]:
        raise ValueError(f"catalogue d'outils invalide : {CATALOG_PATH}")
    seen: set[str] = set()
    for tool in catalog["tools"]:
        if not isinstance(tool, dict) or not isinstance(tool.get("name"), str) \
                or not isinstance(tool.get("params"), list) or not isinstance(tool.get("aliases"), list):
            raise ValueError(f"catalogue d'outils invalide (outil) : {CATALOG_PATH}")
        for step_type in (tool["name"], *tool["aliases"]):
            if step_type in seen:
                raise ValueError(f"catalogue d'outils invalide (type en double « {step_type} »)")
            seen.add(step_type)
    return catalog


@lru_cache(maxsize=1)
def load_catalog() -> dict[str, Any]:
    with open(CATALOG_PATH, encoding="utf-8") as f:
        return _check(json.load(f))


def tool_names(catalog: dict[str, Any] | None = None) -> frozenset[str]:
    """Noms CANONIQUES des outils (les alias historiques restent réservés aux plans
    écrits à la main : le planificateur n'utilise que les noms du prompt)."""
    return frozenset(t["name"] for t in (catalog or load_catalog())["tools"])


def path_params(catalog: dict[str, Any] | None = None) -> list[str]:
    """Paramètres de chemin (texte ou liste), triés : confinés aux dossiers autorisés."""
    return sorted({p["name"] for t in (catalog or load_catalog())["tools"] for p in t["params"] if p["is_path"]})


def secret_params(catalog: dict[str, Any] | None = None) -> frozenset[str]:
    """Paramètres de texte libre (texte saisi, contenu écrit) à masquer."""
    return frozenset(p["name"] for t in (catalog or load_catalog())["tools"] for p in t["params"]
                     if p["is_secret_text"])
