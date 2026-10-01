"""Génération de formations et d'applications par Claude (Anthropic).

Utilise les sorties structurées (JSON Schema) : le modèle renvoie directement un
JSON conforme au schéma, ce qui remplace l'ancien parsing/réparation manuel.
"""
from __future__ import annotations

import json

from .llm import structured_generate

_MAX_HISTORY_CHARS = 20_000  # par message d'historique

# --- Schémas de sortie (additionalProperties=false requis par les sorties structurées) ---

FORMATION_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "title": {"type": "string"},
        "description": {"type": "string"},
        "duration": {"type": "string"},
        "lessons": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "title": {"type": "string"},
                    "objectives": {"type": "array", "items": {"type": "string"}},
                    "content": {"type": "string"},
                    "examples": {"type": "array", "items": {"type": "string"}},
                    "exercises": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["title", "objectives", "content", "examples", "exercises"],
            },
        },
    },
    "required": ["title", "description", "duration", "lessons"],
}

APPLICATION_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "title": {"type": "string"},
        "description": {"type": "string"},
        "app_type": {"type": "string"},
        "tech_stack": {"type": "string"},
        "architecture": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "frontend": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "framework": {"type": "string"},
                        "components": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "additionalProperties": False,
                                "properties": {
                                    "name": {"type": "string"},
                                    "description": {"type": "string"},
                                    "code": {"type": "string"},
                                },
                                "required": ["name", "description", "code"],
                            },
                        },
                    },
                    "required": ["framework", "components"],
                },
                "backend": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "endpoints": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "additionalProperties": False,
                                "properties": {
                                    "method": {"type": "string"},
                                    "path": {"type": "string"},
                                    "description": {"type": "string"},
                                },
                                "required": ["method", "path", "description"],
                            },
                        },
                    },
                    "required": ["endpoints"],
                },
                "database": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "tables": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "additionalProperties": False,
                                "properties": {
                                    "name": {"type": "string"},
                                    "columns": {"type": "array", "items": {"type": "string"}},
                                    "description": {"type": "string"},
                                },
                                "required": ["name", "columns", "description"],
                            },
                        },
                    },
                    "required": ["tables"],
                },
            },
            "required": ["frontend", "backend", "database"],
        },
    },
    "required": ["title", "description", "app_type", "tech_stack", "architecture"],
}


# ---------------------------------------------------------------------------
# Formations
# ---------------------------------------------------------------------------

_FORMATION_SYSTEM = (
    "Tu es un expert en création de formations pédagogiques. Tu génères des "
    "formations structurées et complètes en français, avec des exemples concrets "
    "et des exercices pratiques."
)


async def generate_formation(topic: str, details: str | None, provider: str | None = None) -> dict:
    user = (
        f'Crée une formation complète sur : "{topic}".'
        + (f"\nDétails supplémentaires : {details}" if details else "")
        + "\nGénère entre 5 et 8 leçons structurées."
    )
    content = await structured_generate(
        _FORMATION_SYSTEM, [{"role": "user", "content": user}], FORMATION_SCHEMA,
        max_tokens=8192, task="formation", provider=provider,
    )
    content.setdefault("title", topic)
    content.setdefault("lessons", [])
    return content


# ---------------------------------------------------------------------------
# Applications
# ---------------------------------------------------------------------------


async def generate_application(
    app_name: str,
    app_desc: str | None,
    conversation_history: list[dict] | None,
    existing_architecture: dict | None,
    provider: str | None = None,
) -> dict:
    is_improvement = bool(conversation_history) and bool(existing_architecture)

    if is_improvement:
        arch_str = json.dumps(existing_architecture, ensure_ascii=False)
        system = (
            "Tu es un architecte logiciel qui modifie des applications.\n\n"
            "INSTRUCTIONS CRITIQUES:\n"
            "1. Applique l'instruction de modification demandée par l'utilisateur.\n"
            "2. SUPPRIMER → retire l'élément du JSON. MODIFIER → change-le. AJOUTER → ajoute-le.\n"
            "3. Retourne l'architecture COMPLÈTE avec la modification appliquée.\n"
            "4. Ne retourne jamais l'architecture identique sans modification.\n\n"
            f"Architecture JSON actuelle à modifier:\n{arch_str}"
        )
        # Historique fourni par le client : on ne garde que des messages bien formés
        # (rôle user/assistant, contenu texte borné) au lieu d'un KeyError -> 500.
        messages = [
            {"role": m["role"], "content": m["content"][:_MAX_HISTORY_CHARS]}
            for m in (conversation_history or [])
            if isinstance(m, dict)
            and m.get("role") in ("user", "assistant")
            and isinstance(m.get("content"), str)
            and m["content"].strip()
        ]
        if not messages or messages[-1]["role"] != "user":
            messages.append({
                "role": "user",
                "content": f"Améliore l'application « {app_name} »." + (f" {app_desc}" if app_desc else ""),
            })
    else:
        system = "Tu es un architecte logiciel expert. Tu conçois des applications complètes."
        messages = [
            {
                "role": "user",
                "content": (
                    f'Conçois l\'architecture complète de l\'application : "{app_name}".'
                    + (f"\nDescription : {app_desc}" if app_desc else "")
                    + "\nInclus : composants frontend avec code, API backend, schéma de base de données."
                ),
            }
        ]

    content = await structured_generate(
        system, messages, APPLICATION_SCHEMA, max_tokens=8192,
        task="application", provider=provider,
    )

    # Filet de sécurité (les sorties structurées garantissent déjà ces champs)
    content.setdefault("title", app_name)
    content.setdefault("description", "")
    content.setdefault("app_type", "Web App")
    content.setdefault("tech_stack", "React + TypeScript")
    if not isinstance(content.get("architecture"), dict):
        content["architecture"] = {}
    _clean_architecture(content["architecture"])
    return content


def _clean_architecture(arch: dict) -> None:
    """Dédoublonne les listes de l'architecture (le modèle émet parfois un doublon,
    p. ex. une table vide + la même table complète). On garde la version la plus riche."""

    def dedupe(items: list, key: str, richness) -> list:
        best: dict = {}
        order: list = []
        for it in items:
            if not isinstance(it, dict):
                continue
            name = str(it.get(key) or "").strip().lower()
            if not name:
                continue
            if name not in best:
                best[name] = it
                order.append(name)
            elif richness(it) > richness(best[name]):
                best[name] = it
        return [best[n] for n in order]

    db = arch.get("database")
    if isinstance(db, dict) and isinstance(db.get("tables"), list):
        db["tables"] = dedupe(db["tables"], "name", lambda t: len(t.get("columns") or []))

    fe = arch.get("frontend")
    if isinstance(fe, dict) and isinstance(fe.get("components"), list):
        fe["components"] = dedupe(fe["components"], "name", lambda c: len(c.get("code") or ""))

    be = arch.get("backend")
    if isinstance(be, dict) and isinstance(be.get("endpoints"), list):
        seen = set()
        out = []
        for e in be["endpoints"]:
            if not isinstance(e, dict):
                continue
            sig = (str(e.get("method") or "").upper().strip(), str(e.get("path") or "").strip())
            if sig not in seen and sig[1]:
                seen.add(sig)
                out.append(e)
        be["endpoints"] = out
