"""Capacités explicites par fournisseur/modèle.

Principe : une capacité n'est vraie que si elle est DÉCLARÉE (table ci-dessous ou
variable LLM_CAPABILITIES). En particulier, vision=False par défaut : une requête
portant des images n'est jamais routée vers un modèle dont la vision n'est pas déclarée.

Surcharge sans code : LLM_CAPABILITIES (JSON), clés "fournisseur" ou
"fournisseur:modèle" (la plus précise gagne), ex. :
  {"local": {"vision": true}, "openai:gpt-4o-mini": {"vision": true}}
"""
from __future__ import annotations

import json
import logging
import os
import re
from dataclasses import replace

from ..parsing import parse_bool
from .base import ModelCapabilities

logger = logging.getLogger("python-ia.llm")

# Modèles Claude dont la réflexion adaptative est ACTIVE PAR DÉFAUT (paramètre
# `thinking` omis) : les jetons de réflexion consomment max_tokens.
_CLAUDE_ALWAYS_THINKING = re.compile(r"^claude-(opus-5|sonnet-5|fable|mythos)")
# Modèles Claude acceptant output_config.effort.
_CLAUDE_EFFORT = re.compile(r"^claude-(opus-5|opus-4-[5-9]|sonnet-5|sonnet-4-6|fable|mythos)")
# Sortie 128K (sinon 64K pour les Claude 4.x récents, 8K par prudence au-delà).
_CLAUDE_128K = re.compile(r"^claude-(opus-5|opus-4-[6-9]|sonnet-5|sonnet-4-6|fable|mythos)")
_CLAUDE_64K = re.compile(r"^claude-(haiku-4-5|sonnet-4-5|opus-4-5|sonnet-4|opus-4)")

# Modèles OpenAI-compatibles dont la vision est connue.
_OPENAI_COMPAT_VISION = re.compile(
    r"^(gpt-4o|gpt-4\.1|gpt-5|o3|o4|chatgpt-4o|gemini-|pixtral|grok-4|grok-2-vision|"
    r"qwen-vl|qwen2\.5-vl|qwen-omni|llava|llama3\.2-vision|.*-vl-|.*-vision)",
)


def _builtin(family: str, model: str) -> ModelCapabilities:
    m = (model or "").lower()
    if family == "anthropic":
        if not m.startswith("claude-"):
            return ModelCapabilities()
        if _CLAUDE_128K.match(m):
            max_out = 128_000
        elif _CLAUDE_64K.match(m):
            max_out = 64_000
        else:
            max_out = 8_192
        return ModelCapabilities(
            vision=True,
            json_schema=True,
            thinking=bool(_CLAUDE_ALWAYS_THINKING.match(m)),
            effort=bool(_CLAUDE_EFFORT.match(m)),
            max_output_tokens=max_out,
        )
    # openai-compat / local : rien n'est supposé hors des modèles connus.
    return ModelCapabilities(
        vision=bool(_OPENAI_COMPAT_VISION.match(m)),
        json_schema=False,  # json_object + consigne, pas de schéma natif garanti
        thinking=False,
        effort=False,
        max_output_tokens=16_384,
    )


def _overrides() -> dict[str, dict]:
    raw = os.getenv("LLM_CAPABILITIES", "")
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        logger.warning("LLM_CAPABILITIES n'est pas un JSON valide : ignoré")
        return {}
    return {str(k): v for k, v in data.items() if isinstance(v, dict)} if isinstance(data, dict) else {}


_ALLOWED_FIELDS = {"vision", "json_schema", "thinking", "effort", "max_output_tokens"}


def capabilities_for(provider_id: str, family: str, model: str) -> ModelCapabilities:
    caps = _builtin(family, model)
    ov = _overrides()
    for key in (provider_id, f"{provider_id}:{model}"):  # le plus précis en dernier
        patch = ov.get(key)
        if not patch:
            continue
        clean = {}
        for k, v in patch.items():
            if k not in _ALLOWED_FIELDS:
                continue
            clean[k] = int(v) if k == "max_output_tokens" else parse_bool(v, False)
        caps = replace(caps, **clean)
    return caps
