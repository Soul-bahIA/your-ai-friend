"""Routeur de modèles — API V2 (LOT 5).

  GET  /v2/models           état complet du routeur : fournisseurs et capacités, profils
                            par rôle, tarifs connus, disjoncteurs, totaux de consommation,
                            budget quotidien.
  POST /v2/models/complete  relais générique pour le plan de contrôle (node-api) :
                            {task, system, messages, json_schema?, images?, max_tokens?,
                            provider?, effort?} → {text, json?, usage}. `json` est l'objet
                            parsé quand `json_schema` est fourni (502 « réponse IA non
                            parsable » sinon). Les erreurs du routeur (400 override,
                            402 budget, 502/503/504…) remontent telles quelles (LLMError).

Le middleware de main.py s'applique : x-ia-token obligatoire quand IA_SERVICE_TOKEN est
défini, x-deadline-ms borne les délais, x-llm-usage renvoie le métrage (dont cost_usd).
Les bornes pydantic reprennent celles de main.py (importer main créerait un cycle).
"""
from __future__ import annotations

from typing import Annotated, Any, Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field, StringConstraints

from ..llm import LLMError, _parse_json
from ..providers import orchestrator

router = APIRouter(prefix="/models", tags=["models"])

# Mêmes bornes que main.py.
TaskStr = Annotated[str, StringConstraints(max_length=50, pattern=r"^[a-z][a-z0-9_]*$")]
TextStr = Annotated[str, StringConstraints(max_length=20_000)]
LongStr = Annotated[str, StringConstraints(max_length=100_000)]
ProviderId = Annotated[str, StringConstraints(max_length=50)]
ScreenshotB64 = Annotated[str, StringConstraints(max_length=6 * 1024 * 1024)]

DEFAULT_MAX_TOKENS = 4096
MAX_MAX_TOKENS = 128_000


class Message(BaseModel):
    role: Literal["user", "assistant"]
    content: LongStr


class CompleteRequest(BaseModel):
    task: TaskStr = "general"
    system: TextStr = ""
    messages: list[Message] = Field(min_length=1, max_length=200)
    json_schema: dict[str, Any] | None = None
    images: list[ScreenshotB64] | None = Field(default=None, max_length=10)
    max_tokens: int = Field(default=DEFAULT_MAX_TOKENS, ge=1, le=MAX_MAX_TOKENS)
    # Accepté UNIQUEMENT s'il figure dans LLM_ALLOWED_OVERRIDES ; sinon 400 (S32).
    provider: ProviderId | None = None
    effort: Literal["low", "medium", "high", "xhigh", "max"] | None = None


@router.get("")
async def models_status():
    """État du routeur de modèles (sans secret : aucune clé n'y figure)."""
    return orchestrator.status()


@router.post("/complete")
async def models_complete(req: CompleteRequest):
    if req.messages[-1].role != "user":
        raise HTTPException(status_code=400, detail="Le dernier message doit être de rôle user.")
    if not any(m.content.strip() for m in req.messages) and not req.images:
        raise HTTPException(status_code=400, detail="messages vides")
    images = [i for i in (req.images or []) if i.strip()] or None
    result = await orchestrator.generate(
        req.task,
        req.system,
        [m.model_dump() for m in req.messages],
        req.max_tokens,
        json_schema=req.json_schema,
        images=images,
        provider=req.provider,
        effort=req.effort,
    )
    if not result.text.strip():
        raise LLMError(502, "Réponse IA vide")
    body: dict[str, Any] = {"text": result.text, "usage": result.usage()}
    if req.json_schema is not None:
        body["json"] = _parse_json(result.text)  # LLMError 502 « Réponse IA non parsable »
    return body
