"""Fournisseur générique compatible API OpenAI (/chat/completions).

Un seul code couvre OpenAI, Google Gemini (endpoint OpenAI-compat), Mistral,
DeepSeek, xAI (Grok), Qwen (DashScope) et les modèles locaux (Ollama / LM Studio),
qui exposent tous la même forme d'API. On diffère seulement par l'URL de base, la
clé et le modèle.
"""
from __future__ import annotations

import json
from typing import Any

import httpx

from .base import LLMError, LLMProvider


class OpenAICompatProvider(LLMProvider):
    def __init__(
        self,
        provider_id: str,
        base_url: str,
        api_key: str,
        model: str,
        family: str = "openai-compat",
        supports_vision: bool = True,
    ):
        self.id = provider_id
        self.family = family
        self.model = model
        self.supports_vision = supports_vision
        self.supports_json_schema = False  # via response_format json_object + consigne
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key

    async def complete(
        self,
        system: str,
        messages: list[dict[str, Any]],
        max_tokens: int,
        json_schema: dict | None = None,
        images: list[str] | None = None,
    ) -> str:
        sys_text = system
        if json_schema is not None:
            # Pas de json_schema natif garanti partout : on impose le schéma en consigne
            # et on active response_format json_object (respecté par la plupart).
            sys_text = (
                f"{system}\n\nRéponds UNIQUEMENT avec un objet JSON valide conforme à ce schéma "
                f"(sans texte ni balises autour) :\n{json.dumps(json_schema, ensure_ascii=False)}"
            )

        chat_messages: list[dict[str, Any]] = [{"role": "system", "content": sys_text}]
        msgs = [dict(m) for m in messages]

        if images:
            last = msgs[-1] if msgs else {"role": "user", "content": ""}
            text = last.get("content", "") if isinstance(last.get("content"), str) else ""
            content: list[dict[str, Any]] = [
                {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b}"}}
                for b in images
            ]
            content.append({"type": "text", "text": text})
            last["content"] = content
            if msgs:
                msgs[-1] = last
            else:
                msgs = [{"role": "user", "content": content}]

        chat_messages.extend(msgs)

        payload: dict[str, Any] = {
            "model": self.model,
            "messages": chat_messages,
            "max_tokens": max_tokens,
        }
        if json_schema is not None:
            payload["response_format"] = {"type": "json_object"}

        headers = {"Content-Type": "application/json"}
        if self._api_key:
            headers["Authorization"] = f"Bearer {self._api_key}"

        try:
            async with httpx.AsyncClient(timeout=180) as client:
                r = await client.post(
                    f"{self._base_url}/chat/completions", headers=headers, json=payload
                )
        except httpx.HTTPError as e:
            raise LLMError(502, f"Service IA ({self.id}) injoignable : {e}")

        if r.status_code == 401:
            raise LLMError(401, f"Clé API invalide pour {self.id}.")
        if r.status_code == 429:
            raise LLMError(429, f"Trop de requêtes ({self.id}). Réessayez.")
        if r.status_code == 402:
            raise LLMError(402, f"Crédits épuisés pour {self.id}.")
        if r.status_code >= 400:
            raise LLMError(502, f"Erreur {self.id} ({r.status_code}) : {r.text[:200]}")

        try:
            data = r.json()
            return data["choices"][0]["message"]["content"] or ""
        except (KeyError, IndexError, ValueError) as e:
            raise LLMError(502, f"Réponse {self.id} inattendue : {e}")
