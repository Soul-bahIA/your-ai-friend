"""FakeProvider : fournisseur LLM scriptable, sans aucun accès réseau."""
from __future__ import annotations

import asyncio
from typing import Any

from app.providers.base import CompletionResult, LLMError, LLMProvider, ModelCapabilities


class FakeProvider(LLMProvider):
    """Chaque appel consomme le prochain élément de `script` :
    - str              -> réponse texte (usage 11 / 7 jetons, stop_reason end_turn) ;
    - CompletionResult -> renvoyé tel quel ;
    - Exception        -> levée.
    Script épuisé -> '{"ok": true}'. `delay` simule une latence (ignore timeout_s,
    pour vérifier que le routeur impose lui-même le délai)."""

    def __init__(self, pid: str, model: str = "fake-model", *, vision: bool = False,
                 script: list | None = None, delay: float = 0.0, family: str = "fake"):
        self.id = pid
        self.model = model
        self.family = family
        self._vision = vision
        self.script = list(script or [])
        self.delay = delay
        self.calls: list[dict[str, Any]] = []

    def capabilities(self, model: str | None = None) -> ModelCapabilities:
        return ModelCapabilities(vision=self._vision, json_schema=True)

    async def generate(self, system, messages, max_tokens, json_schema=None, images=None, *,
                       model=None, timeout_s=None, effort=None) -> CompletionResult:
        self.calls.append({"model": model, "timeout_s": timeout_s, "effort": effort,
                           "images": images, "max_tokens": max_tokens, "messages": messages})
        if self.delay:
            await asyncio.sleep(self.delay)
        item = self.script.pop(0) if self.script else '{"ok": true}'
        if isinstance(item, BaseException):
            raise item
        if isinstance(item, CompletionResult):
            return item
        return CompletionResult(text=item, provider=self.id, model=model or self.model,
                                input_tokens=11, output_tokens=7, stop_reason="end_turn")


def rate_limited(pid: str = "x") -> LLMError:
    return LLMError(429, f"Trop de requêtes ({pid}).", fallback=True, kind="rate_limit")


def server_error(pid: str = "x") -> LLMError:
    return LLMError(502, f"Erreur du fournisseur {pid} (503)", fallback=True, kind="server")
