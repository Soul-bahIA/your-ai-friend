"""FakeProvider : fournisseur LLM scriptable et déterministe, sans AUCUN accès réseau (LOT 3).

Deux usages :
  - tests (tests/fakes.py le réexporte) : `script` dicte les réponses successives ;
  - pile de développement locale : LLM_FAKE_PROVIDER=1 (SOULBAH_ENV=dev|test uniquement,
    cf. config.check_startup_config) → le registre ne contient QUE ce fournisseur. Sans
    script, il répond un objet conforme au `json_schema` demandé (squelette : champs
    requis avec une valeur neutre) ou le texte '{"ok": true}'. Il valide la plomberie
    (auth inter-services, routage, délais, usage, en-têtes), jamais la qualité d'un plan.

Aucune clé, aucun coût, aucune donnée ne quitte le PC.
"""
from __future__ import annotations

import asyncio
import json
from typing import Any

from .base import CompletionResult, LLMProvider, ModelCapabilities

DEFAULT_TEXT_REPLY = '{"ok": true}'


def skeleton_from_schema(schema: Any) -> Any:
    """Valeur neutre conforme à un JSON Schema simple (sous-ensemble : type, const, enum,
    default, properties/required, items/minItems, anyOf/oneOf, type liste)."""
    if not isinstance(schema, dict):
        return None
    if "const" in schema:
        return schema["const"]
    if "default" in schema:
        return schema["default"]
    enum = schema.get("enum")
    if isinstance(enum, list) and enum:
        return enum[0]
    for key in ("anyOf", "oneOf"):
        variants = schema.get(key)
        if isinstance(variants, list) and variants:
            return skeleton_from_schema(variants[0])
    type_ = schema.get("type")
    if isinstance(type_, list):
        type_ = next((t for t in type_ if t != "null"), None)
    if type_ == "object" or (type_ is None and "properties" in schema):
        props = schema.get("properties") or {}
        required = schema.get("required")
        keys = [k for k in required if k in props] if isinstance(required, list) and required else list(props)
        return {k: skeleton_from_schema(props[k]) for k in keys}
    if type_ == "array":
        n = schema.get("minItems") or 0
        return [skeleton_from_schema(schema.get("items") or {}) for _ in range(int(n))]
    if type_ == "string":
        return "fake"
    if type_ == "integer":
        return 0
    if type_ == "number":
        return 0.0
    if type_ == "boolean":
        return True
    return None


class FakeProvider(LLMProvider):
    """Chaque appel consomme le prochain élément de `script` :
    - str              -> réponse texte (usage 11 / 7 jetons, stop_reason end_turn) ;
    - CompletionResult -> renvoyé tel quel ;
    - Exception        -> levée.
    Script épuisé -> squelette du `json_schema` demandé, sinon DEFAULT_TEXT_REPLY.
    `delay` simule une latence (ignore timeout_s, pour vérifier que le routeur impose
    lui-même le délai)."""

    def __init__(self, pid: str = "fake", model: str = "fake-model", *, vision: bool = False,
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
                           "images": images, "max_tokens": max_tokens, "messages": messages,
                           "json_schema": json_schema})
        if self.delay:
            await asyncio.sleep(self.delay)
        if self.script:
            item = self.script.pop(0)
        elif json_schema is not None:
            item = json.dumps(skeleton_from_schema(json_schema), ensure_ascii=False)
        else:
            item = DEFAULT_TEXT_REPLY
        if isinstance(item, BaseException):
            raise item
        if isinstance(item, CompletionResult):
            return item
        return CompletionResult(text=item, provider=self.id, model=model or self.model,
                                input_tokens=11, output_tokens=7, stop_reason="end_turn")
