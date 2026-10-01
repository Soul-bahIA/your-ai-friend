"""Accès LLM de SoulBah AI — délègue à l'orchestrateur multi-fournisseurs.

Les fonctions publiques (structured_generate / text_generate_json /
vision_generate_json) gardent leur signature : generation.py et reasoning.py sont
inchangés. Elles acceptent désormais un `task` (pour le routage par type de tâche)
et un `provider` optionnel (pour imposer un fournisseur).
"""
from __future__ import annotations

import json
import re

# LLMError reste importable depuis ce module (main.py, video.py en dépendent).
from .providers import LLMError, orchestrator

__all__ = [
    "LLMError",
    "structured_generate",
    "text_generate_json",
    "vision_generate_json",
]


def _parse_json(text: str) -> dict:
    raw = text.strip()
    # Retire d'éventuelles balises markdown ```json ... ```
    if raw.startswith("```"):
        raw = re.sub(r"^```[a-zA-Z]*\n?", "", raw)
        raw = re.sub(r"\n?```\s*$", "", raw).strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", raw, re.S)  # premier objet {...}
        if m:
            try:
                return json.loads(m.group(0))
            except json.JSONDecodeError:
                pass
        raise LLMError(502, "Réponse IA non parsable")


async def structured_generate(
    system: str,
    messages: list[dict],
    schema: dict,
    max_tokens: int = 8192,
    task: str = "general",
    provider: str | None = None,
) -> dict:
    """Sortie JSON conforme au schéma (nativement si le fournisseur le supporte)."""
    text = await orchestrator.complete(
        task, system, messages, max_tokens, json_schema=schema, provider=provider
    )
    if not text.strip():
        raise LLMError(502, "Réponse IA vide")
    return _parse_json(text)


async def text_generate_json(
    system: str,
    messages: list[dict],
    max_tokens: int = 4096,
    task: str = "reasoning",
    provider: str | None = None,
) -> dict:
    """Génération JSON simple (forme décrite dans le prompt), parsée puis réparée."""
    text = await orchestrator.complete(task, system, messages, max_tokens, provider=provider)
    if not text.strip():
        raise LLMError(502, "Réponse IA vide")
    return _parse_json(text)


async def vision_generate_json(
    system: str,
    text: str,
    images_b64: list[str],
    max_tokens: int = 4096,
    task: str = "vision",
    provider: str | None = None,
) -> dict:
    """Génération JSON avec analyse d'image(s) — le modèle « voit » les captures."""
    out = await orchestrator.complete(
        task,
        system,
        [{"role": "user", "content": text}],
        max_tokens,
        images=images_b64,
        provider=provider,
    )
    if not out.strip():
        raise LLMError(502, "Réponse IA vide")
    return _parse_json(out)
