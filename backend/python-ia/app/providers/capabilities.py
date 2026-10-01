"""Capacités explicites par fournisseur/modèle.

Principe : une capacité n'est vraie que si elle est DÉCLARÉE (table ci-dessous ou
variable LLM_CAPABILITIES). En particulier, vision=False par défaut : une requête
portant des images n'est jamais routée vers un modèle dont la vision n'est pas déclarée.

Surcharge sans code : LLM_CAPABILITIES (JSON), clés "fournisseur" ou
"fournisseur:modèle" (la plus précise gagne), ex. :
  {"local": {"vision": true}, "openai:gpt-4o-mini": {"vision": true}}
Une valeur invalide (ex. max_output_tokens non entier) est ignorée avec un
avertissement : une surcharge mal saisie ne doit jamais faire échouer tous les appels.
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
# Claude 1 / 2 / Instant (retirés) : ni entrée image, ni sortie structurée.
_CLAUDE_LEGACY = re.compile(r"^claude-(instant|[12](\.|-|$))")

# Modèles OpenAI-compatibles dont la vision est connue (familles, par préfixe)...
_OPENAI_COMPAT_VISION = re.compile(
    r"^(gpt-4o|gpt-4\.1|gpt-5|o3|o4|chatgpt-4o|gemini-|pixtral|grok-4|grok-2-vision|"
    r"qwen-vl|qwen2\.5-vl|qwen-omni|llava|llama3\.2-vision|.*-vl-|.*-vision)",
)
# ... SAUF les variantes de ces familles qui n'acceptent PAS d'image : o1-mini /
# o3-mini (texte seul), modèles audio, temps réel, synthèse ou transcription vocale,
# recherche, embeddings. Mieux vaut une vision non déclarée (réactivable via
# LLM_CAPABILITIES) qu'une image envoyée à un modèle qui répond 400 (502 sans repli).
_OPENAI_COMPAT_NO_VISION = re.compile(
    r"^(o1-mini|o1-preview|o3-mini)|-(audio|realtime|tts|transcribe|search)(-|$)|embedding",
)
# Modèles de raisonnement OpenAI (o1, o3, o4-mini, gpt-5…) : `max_tokens` y est refusé
# (400 -> 502 sans repli) au profit de `max_completion_tokens`, et les jetons de
# raisonnement consomment cette limite (plancher appliqué par le fournisseur).
_OPENAI_REASONING = re.compile(r"^(o\d|gpt-5)")

TOKEN_PARAMS = ("max_tokens", "max_completion_tokens")


def _builtin(family: str, model: str) -> ModelCapabilities:
    m = (model or "").lower()
    if family == "anthropic":
        if not m.startswith("claude-"):
            return ModelCapabilities()
        if _CLAUDE_LEGACY.match(m):
            return ModelCapabilities(max_output_tokens=4_096)
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
    reasoning = bool(_OPENAI_REASONING.match(m))
    return ModelCapabilities(
        vision=bool(_OPENAI_COMPAT_VISION.match(m)) and not _OPENAI_COMPAT_NO_VISION.search(m),
        json_schema=False,  # json_object + consigne, pas de schéma natif garanti
        thinking=reasoning,
        effort=False,
        max_output_tokens=16_384,
        max_tokens_param="max_completion_tokens" if reasoning else "max_tokens",
    )


def _overrides() -> dict[str, dict]:
    raw = os.getenv("LLM_CAPABILITIES", "")
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        _warn_once("LLM_CAPABILITIES n'est pas un JSON valide : ignoré")
        return {}
    return {str(k): v for k, v in data.items() if isinstance(v, dict)} if isinstance(data, dict) else {}


_ALLOWED_FIELDS = {"vision", "json_schema", "thinking", "effort", "max_output_tokens", "max_tokens_param"}
_warned: set[str] = set()


def _warn_once(message: str) -> None:
    # capabilities_for est appelé à chaque requête : un seul avertissement par message.
    if message not in _warned:
        _warned.add(message)
        logger.warning(message)


def _positive_int(value) -> int | None:
    """Entier strictement positif (int, float entier ou chaîne de chiffres), sinon None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        n = value
    elif isinstance(value, float) and value.is_integer():
        n = int(value)
    elif isinstance(value, str) and value.strip().isdigit():
        n = int(value.strip())
    else:
        return None
    return n if n >= 1 else None


def _clean_patch(key: str, patch: dict) -> dict:
    """Champs valides d'une surcharge ; une valeur invalide est ignorée (avertissement)."""
    clean: dict = {}
    for k, v in patch.items():
        if k not in _ALLOWED_FIELDS:
            continue
        if k == "max_output_tokens":
            n = _positive_int(v)
            if n is None:
                _warn_once(f"LLM_CAPABILITIES[{key[:60]!r}].max_output_tokens invalide "
                           f"({str(v)[:40]!r}, entier > 0 attendu) : ignoré")
                continue
            clean[k] = n
        elif k == "max_tokens_param":
            if v not in TOKEN_PARAMS:
                _warn_once(f"LLM_CAPABILITIES[{key[:60]!r}].max_tokens_param invalide "
                           f"({str(v)[:40]!r}, attendu : {' | '.join(TOKEN_PARAMS)}) : ignoré")
                continue
            clean[k] = v
        else:
            clean[k] = parse_bool(v, False)
    return clean


def capabilities_for(provider_id: str, family: str, model: str) -> ModelCapabilities:
    caps = _builtin(family, model)
    ov = _overrides()
    for key in (provider_id, f"{provider_id}:{model}"):  # le plus précis en dernier
        patch = ov.get(key)
        if not patch:
            continue
        clean = _clean_patch(key, patch)
        if clean:
            caps = replace(caps, **clean)
    return caps
