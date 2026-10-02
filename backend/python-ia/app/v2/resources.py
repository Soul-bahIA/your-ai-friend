"""Ressources de la machine du modèle — Resource Manager V3 (LOT 6).

  GET /v2/resources  → {memory: {total_mb, free_mb, load_percent, pressure, policy},
                        inference: [{key, url, capacity, server_slots, active, waiting, queue,
                                     served, rejected_busy, max_active, max_waiting, wait_s}]}

Une file par serveur local configuré (voir app/inference_gate.py), même avant le premier
appel. Lecture seule, sans secret.
"""
from __future__ import annotations

import asyncio
from typing import Any

from fastapi import APIRouter

from .. import inference_gate, soulbah_resources
from ..providers import orchestrator

router = APIRouter(prefix="/resources", tags=["resources"])


def _snapshot() -> dict[str, Any]:
    for provider in orchestrator._providers_map().values():  # noqa: SLF001 — lecture des fournisseurs construits
        inference_gate.gates.gate_for(provider)
    return {
        "memory": soulbah_resources.snapshot(),
        "inference": inference_gate.gates.snapshot(),
        "queue_max_s": inference_gate.gates.queue_max_s(),
    }


@router.get("")
async def resources_status():
    return await asyncio.to_thread(_snapshot)


__all__ = ["router"]
