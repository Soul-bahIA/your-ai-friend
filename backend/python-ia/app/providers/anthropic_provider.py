"""Fournisseur Anthropic (Claude) — SDK natif, sortie structurée + vision.

- Délai par appel (`timeout_s`, aligné sur l'échéance de la requête) et peu de
  tentatives SDK (LLM_MAX_RETRIES, défaut 1) : le repli entre fournisseurs est
  géré par le routeur, pas par des minutes de tentatives internes.
- Les modèles qui réfléchissent par défaut (Opus 5.x…) consomment max_tokens en
  jetons de réflexion : plancher LLM_THINKING_MIN_MAX_TOKENS (défaut 16000).
- Troncature (stop_reason max_tokens) signalée dans CompletionResult.truncated.
"""
from __future__ import annotations

import logging
import os
import time
from typing import Any

import anthropic
from anthropic import AsyncAnthropic

from .base import CompletionResult, LLMError, LLMProvider, ModelCapabilities, attach_images_last_user, upstream_error
from .capabilities import capabilities_for

logger = logging.getLogger("python-ia.llm")

DEFAULT_TIMEOUT_S = float(os.getenv("LLM_TIMEOUT_S", "100"))
MAX_RETRIES = int(os.getenv("LLM_MAX_RETRIES", "1"))
THINKING_MIN_MAX_TOKENS = int(os.getenv("LLM_THINKING_MIN_MAX_TOKENS", "16000"))

_TRUNCATION_STOPS = {"max_tokens", "model_context_window_exceeded"}
_VALID_EFFORTS = {"low", "medium", "high", "xhigh", "max"}


class AnthropicProvider(LLMProvider):
    family = "anthropic"

    def __init__(self, provider_id: str, model: str, api_key: str):
        self.id = provider_id
        self.model = model
        self._client = AsyncAnthropic(
            api_key=api_key, max_retries=MAX_RETRIES, timeout=DEFAULT_TIMEOUT_S
        )

    def capabilities(self, model: str | None = None) -> ModelCapabilities:
        return capabilities_for(self.id, self.family, model or self.model)

    def effective_max_tokens(self, requested: int, model: str | None = None) -> int:
        caps = self.capabilities(model)
        value = requested
        if caps.thinking:
            value = max(value, THINKING_MIN_MAX_TOKENS)
        return max(1, min(value, caps.max_output_tokens))

    async def generate(
        self,
        system: str,
        messages: list[dict[str, Any]],
        max_tokens: int,
        json_schema: dict | None = None,
        images: list[str] | None = None,
        *,
        model: str | None = None,
        timeout_s: float | None = None,
        effort: str | None = None,
    ) -> CompletionResult:
        use_model = model or self.model
        caps = self.capabilities(use_model)
        if images and not caps.vision:
            raise LLMError(400, f"Le modèle {use_model} ne prend pas en charge les images.", kind="no_vision")

        msgs: list[dict[str, Any]] = [dict(m) for m in messages]
        if images:
            msgs = attach_images_last_user(
                messages,
                images,
                lambda b: {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": b}},
            )

        kwargs: dict[str, Any] = dict(
            model=use_model,
            max_tokens=self.effective_max_tokens(max_tokens, use_model),
            system=system,
            messages=msgs,
            timeout=timeout_s if timeout_s is not None else DEFAULT_TIMEOUT_S,
        )
        output_config: dict[str, Any] = {}
        if json_schema is not None and caps.json_schema:
            output_config["format"] = {"type": "json_schema", "schema": json_schema}
        if effort and caps.effort and effort in _VALID_EFFORTS:
            output_config["effort"] = effort
        if output_config:
            kwargs["output_config"] = output_config

        t0 = time.monotonic()
        try:
            resp = await self._client.messages.create(**kwargs)
        except anthropic.APITimeoutError:
            raise LLMError(504, "Service IA (Anthropic) : délai dépassé", fallback=True, kind="timeout")
        except anthropic.APIConnectionError as e:
            logger.warning("Anthropic injoignable : %s", e)
            raise LLMError(502, "Service IA (Anthropic) injoignable", fallback=True, kind="connection")
        except anthropic.BadRequestError as e:
            msg = str(e)
            if "credit balance" in msg.lower():
                raise LLMError(402, "Crédits Anthropic épuisés. Ajoutez des crédits sur console.anthropic.com.",
                               fallback=True, kind="credits")
            # Requête rejetée par le fournisseur : c'est NOTRE appel amont qui est en
            # cause, pas la requête du client -> 502. Détail amont : logs seulement.
            logger.warning("Requête rejetée par Anthropic (%s) : %s", use_model, msg[:500])
            raise LLMError(502, "Requête IA rejetée par le fournisseur (Anthropic).", kind="bad_request")
        except anthropic.APIStatusError as e:
            # 401/403 (clé invalide) -> 502 ; 429 -> 429 ; 5xx/529 -> 502 (repli possible).
            raise upstream_error(self.id, e.status_code, str(e))
        latency_ms = int((time.monotonic() - t0) * 1000)

        stop_reason = getattr(resp, "stop_reason", None)
        if stop_reason == "refusal":
            raise LLMError(400, "Requête refusée par le modèle IA", kind="refusal")

        text = "".join(
            getattr(block, "text", "") or ""
            for block in (getattr(resp, "content", None) or [])
            if getattr(block, "type", None) == "text"
        )
        usage = getattr(resp, "usage", None)
        return CompletionResult(
            text=text,
            provider=self.id,
            model=str(getattr(resp, "model", None) or use_model),
            input_tokens=getattr(usage, "input_tokens", None),
            output_tokens=getattr(usage, "output_tokens", None),
            stop_reason=stop_reason,
            truncated=stop_reason in _TRUNCATION_STOPS,
            latency_ms=latency_ms,
        )
