"""Fournisseur générique compatible API OpenAI (/chat/completions).

Un seul code couvre OpenAI, Google Gemini (endpoint OpenAI-compat), Mistral,
DeepSeek, xAI (Grok), Qwen (DashScope) et les modèles locaux (Ollama / LM Studio),
qui exposent tous la même forme d'API. On diffère seulement par l'URL de base, la
clé et le modèle. Les capacités (vision…) sont EXPLICITES : voir capabilities.py.
"""
from __future__ import annotations

import json
import logging
import os
import time
import dataclasses
from typing import Any

import httpx

from .base import CompletionResult, LLMError, LLMProvider, ModelCapabilities, attach_images_last_user, upstream_error
from .capabilities import capabilities_for

logger = logging.getLogger("python-ia.llm")

DEFAULT_TIMEOUT_S = float(os.getenv("LLM_TIMEOUT_S", "100"))
# Même plancher que pour Claude : un modèle de raisonnement (o-series, gpt-5) consomme
# sa limite de sortie en jetons de raisonnement avant de répondre.
THINKING_MIN_MAX_TOKENS = int(os.getenv("LLM_THINKING_MIN_MAX_TOKENS", "16000"))


class OpenAICompatProvider(LLMProvider):
    def __init__(
        self,
        provider_id: str,
        base_url: str,
        api_key: str,
        model: str,
        family: str = "openai-compat",
    ):
        self.id = provider_id
        self.family = family
        self.model = model
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key

    @property
    def base_url(self) -> str:
        """URL de base (V3 LOT 6 : clé de la file d'inférence d'un serveur local)."""
        return self._base_url

    def capabilities(self, model: str | None = None) -> ModelCapabilities:
        caps = capabilities_for(self.id, self.family, model or self.model)
        if self.id == "local_vision" and not caps.vision:
            # V3 LOT 3 : serveur local déclaré pour le rôle vision (LOCAL_LLM_URL_VISION).
            caps = dataclasses.replace(caps, vision=True)
        if self.family == "local" and not caps.json_schema:
            # llama-server contraint la sortie par grammaire (response_format.schema).
            caps = dataclasses.replace(caps, json_schema=True)
        return caps

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
        effort: str | None = None,  # non supporté : ignoré
    ) -> CompletionResult:
        use_model = model or self.model
        caps = self.capabilities(use_model)
        if images and not caps.vision:
            raise LLMError(400, f"Le modèle {use_model} ne prend pas en charge les images.", kind="no_vision")

        sys_text = system
        if json_schema is not None and self.family == "local":
            # V3 : llama-server impose le schéma par grammaire (response_format.schema) — inutile de
            # le recopier dans le prompt (des centaines de jetons de moins pour un petit contexte).
            sys_text = f"{system}\n\nRéponds UNIQUEMENT avec un objet JSON valide (sans texte ni balises autour)."
        elif json_schema is not None:
            # Pas de json_schema natif garanti partout : on impose le schéma en consigne
            # et on active response_format json_object (respecté par la plupart).
            sys_text = (
                f"{system}\n\nRéponds UNIQUEMENT avec un objet JSON valide conforme à ce schéma "
                f"(sans texte ni balises autour) :\n{json.dumps(json_schema, ensure_ascii=False)}"
            )

        chat_messages: list[dict[str, Any]] = [{"role": "system", "content": sys_text}]
        msgs = [dict(m) for m in messages]
        if images:
            msgs = attach_images_last_user(
                messages, images, lambda b: {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b}"}}
            )
        chat_messages.extend(msgs)

        limit = max(max_tokens, THINKING_MIN_MAX_TOKENS) if caps.thinking else max_tokens
        payload: dict[str, Any] = {
            "model": use_model,
            "messages": chat_messages,
            # `max_tokens` ou `max_completion_tokens` (modèles de raisonnement OpenAI).
            caps.max_tokens_param: max(1, min(limit, caps.max_output_tokens)),
        }
        if json_schema is not None:
            payload["response_format"] = {"type": "json_object"}
            if self.family == "local":
                # V3 LOT 2 : llama-server contraint la génération par grammaire à partir du schéma
                # (sortie JSON valide garantie) — décisif pour la fiabilité des petits modèles locaux.
                payload["response_format"]["schema"] = json_schema

        headers = {"Content-Type": "application/json"}
        if self._api_key:
            headers["Authorization"] = f"Bearer {self._api_key}"

        timeout = timeout_s if timeout_s is not None else DEFAULT_TIMEOUT_S
        t0 = time.monotonic()
        try:
            async with httpx.AsyncClient(timeout=timeout) as client:
                r = await client.post(
                    f"{self._base_url}/chat/completions", headers=headers, json=payload
                )
        except httpx.TimeoutException:
            raise LLMError(504, f"Service IA ({self.id}) : délai dépassé", fallback=True, kind="timeout")
        except httpx.HTTPError as e:
            logger.warning("Fournisseur %s injoignable : %s", self.id, e)
            raise LLMError(502, f"Service IA ({self.id}) injoignable", fallback=True, kind="connection")
        latency_ms = int((time.monotonic() - t0) * 1000)

        if r.status_code >= 400:
            # Le corps amont n'est JAMAIS renvoyé au client (il peut contenir un
            # extrait de clé) : upstream_error le journalise seulement (hors 401/403).
            raise upstream_error(self.id, r.status_code, r.text[:500])

        try:
            data = r.json()
            choice = data["choices"][0]
            text = choice["message"]["content"] or ""
        except (KeyError, IndexError, TypeError, ValueError) as e:
            logger.warning("Réponse %s inattendue : %s", self.id, e)
            raise LLMError(502, f"Réponse du fournisseur {self.id} inattendue", fallback=True, kind="bad_response")

        finish = choice.get("finish_reason") if isinstance(choice, dict) else None
        if finish == "content_filter":
            raise LLMError(400, "Requête refusée par le modèle IA", kind="refusal")
        usage = data.get("usage") if isinstance(data, dict) else None
        usage = usage if isinstance(usage, dict) else {}
        return CompletionResult(
            text=text,
            provider=self.id,
            model=str(data.get("model") or use_model),
            input_tokens=usage.get("prompt_tokens"),
            output_tokens=usage.get("completion_tokens"),
            stop_reason=finish,
            truncated=finish == "length",
            latency_ms=latency_ms,
        )
