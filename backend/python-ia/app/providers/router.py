"""Orchestrateur : choisit le fournisseur d'IA le plus adapté à chaque tâche.

Priorité de sélection :
  1. override explicite (l'utilisateur impose un fournisseur) s'il est disponible ;
  2. mapping tâche → fournisseur (défauts ci-dessous, surchargés par LLM_ROUTING) ;
  3. fournisseur par défaut disponible (LLM_DEFAULT_PROVIDER, sinon 1er configuré).

En cas d'échec réseau/5xx du fournisseur choisi, repli automatique sur le défaut.
"""
from __future__ import annotations

import json
import os
from typing import Any

from .base import LLMError, LLMProvider
from .registry import build_providers

# Type de tâche -> fournisseur préféré. Ajustable sans code via LLM_ROUTING (JSON).
# Tant qu'un seul fournisseur est configuré, tout retombe dessus (voir _select).
_DEFAULT_ROUTING: dict[str, str] = {
    "code": "deepseek",        # génération de code
    "reasoning": "anthropic",  # raisonnement complexe
    "writing": "openai",       # rédaction
    "doc_analysis": "anthropic",
    "translation": "openai",
    "formation": "anthropic",
    "application": "anthropic",
    "vision": "anthropic",
    "automation": "anthropic",
    "optimization": "anthropic",
    "chat": "openai",
    "general": "anthropic",
}

_PREFERRED_DEFAULTS = ["anthropic", "openai", "gemini", "mistral", "deepseek", "xai", "qwen", "local"]


class Orchestrator:
    def __init__(self) -> None:
        self._providers: dict[str, LLMProvider] | None = None
        self._routing: dict[str, str] = dict(_DEFAULT_ROUTING)
        try:
            override = json.loads(os.getenv("LLM_ROUTING", "") or "{}")
            if isinstance(override, dict):
                self._routing.update({str(k): str(v) for k, v in override.items()})
        except json.JSONDecodeError:
            pass

    def _providers_map(self) -> dict[str, LLMProvider]:
        if self._providers is None:
            self._providers = build_providers()
        return self._providers

    def _default_provider_id(self) -> str | None:
        provs = self._providers_map()
        wanted = os.getenv("LLM_DEFAULT_PROVIDER", "")
        if wanted and wanted in provs:
            return wanted
        for pid in _PREFERRED_DEFAULTS:
            if pid in provs:
                return pid
        return next(iter(provs), None)

    def _select(self, task: str, override: str | None) -> LLMProvider:
        provs = self._providers_map()
        if not provs:
            raise LLMError(
                500,
                "Aucun fournisseur d'IA configuré. Renseignez au moins une clé "
                "(ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, …).",
            )
        # 1. override explicite
        if override and override in provs:
            return provs[override]
        # 2. routage par tâche
        pid = self._routing.get(task)
        if pid and pid in provs:
            return provs[pid]
        # 3. défaut disponible
        default_id = self._default_provider_id()
        return provs[default_id]  # type: ignore[index]

    async def complete(
        self,
        task: str,
        system: str,
        messages: list[dict[str, Any]],
        max_tokens: int,
        json_schema: dict | None = None,
        images: list[str] | None = None,
        provider: str | None = None,
    ) -> str:
        chosen = self._select(task, provider)
        try:
            return await chosen.complete(system, messages, max_tokens, json_schema, images)
        except LLMError as e:
            # Repli automatique sur le défaut pour les pannes transitoires (réseau/5xx).
            default_id = self._default_provider_id()
            if e.status in (429, 502, 503) and default_id and default_id != chosen.id:
                fallback = self._providers_map()[default_id]
                # La vision peut ne pas être supportée par le repli : on n'insiste pas.
                if not images or fallback.supports_vision:
                    return await fallback.complete(system, messages, max_tokens, json_schema, images)
            raise

    def status(self) -> dict[str, Any]:
        provs = self._providers_map()
        return {
            "providers": [p.describe() for p in provs.values()],
            "configured": list(provs.keys()),
            "default": self._default_provider_id(),
            "routing": self._routing,
        }


orchestrator = Orchestrator()
