"""Fournisseur Anthropic (Claude) — SDK natif, sortie structurée + vision."""
from __future__ import annotations

from typing import Any

import anthropic
from anthropic import AsyncAnthropic

from .base import LLMError, LLMProvider, upstream_error


class AnthropicProvider(LLMProvider):
    family = "anthropic"
    supports_vision = True
    supports_json_schema = True

    def __init__(self, provider_id: str, model: str, api_key: str):
        self.id = provider_id
        self.model = model
        self._client = AsyncAnthropic(api_key=api_key)

    async def complete(
        self,
        system: str,
        messages: list[dict[str, Any]],
        max_tokens: int,
        json_schema: dict | None = None,
        images: list[str] | None = None,
    ) -> str:
        msgs: list[dict[str, Any]] = [dict(m) for m in messages]

        # Vision : attacher les images au dernier message utilisateur.
        if images:
            last = msgs[-1] if msgs else {"role": "user", "content": ""}
            text = last.get("content", "") if isinstance(last.get("content"), str) else ""
            blocks: list[dict[str, Any]] = [
                {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": b}}
                for b in images
            ]
            blocks.append({"type": "text", "text": text})
            last["content"] = blocks
            if msgs:
                msgs[-1] = last
            else:
                msgs = [{"role": "user", "content": blocks}]

        kwargs: dict[str, Any] = dict(
            model=self.model, max_tokens=max_tokens, system=system, messages=msgs
        )
        if json_schema is not None:
            kwargs["output_config"] = {"format": {"type": "json_schema", "schema": json_schema}}

        try:
            resp = await self._client.messages.create(**kwargs)
        except anthropic.APIConnectionError:
            raise LLMError(502, "Service IA (Anthropic) injoignable")
        except anthropic.BadRequestError as e:
            msg = str(e)
            if "credit balance" in msg.lower():
                raise LLMError(402, "Crédits Anthropic épuisés. Ajoutez des crédits sur console.anthropic.com.")
            # Requête rejetée par le fournisseur : c'est NOTRE appel amont qui est en
            # cause, pas la requête du client -> 502.
            raise LLMError(502, f"Requête IA rejetée par Anthropic : {msg[:200]}")
        except anthropic.APIStatusError as e:
            # 401/403 (clé invalide) -> 502 ; 429 -> 429 ; reste -> 502.
            raise upstream_error(self.id, e.status_code)

        if getattr(resp, "stop_reason", None) == "refusal":
            raise LLMError(400, "Requête refusée par le modèle IA")

        for block in resp.content:
            if getattr(block, "type", None) == "text":
                return block.text
        return ""
