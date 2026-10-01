"""V3 — test EN DIRECT avec un vrai modèle local (lancé seulement si LIVE_LOCAL_LLM_URL est
défini, ex. http://127.0.0.1:8091/v1 après `python agent/soulbah_models.py serve <modèle>`).

Prouve que python-ia raisonne sans aucune API cloud : mode OFFLINE, NetworkGuard actif (toute
connexion vers Internet refusée), clé cloud présente mais ignorée, plan JSON contraint par schéma
produit par le modèle local et relu par le routeur.
"""
from __future__ import annotations

import asyncio
import json
import os
import socket

import pytest

from app import config, network_guard, soulbah_settings
from app.providers import orchestrator

LIVE_URL = os.environ.get("LIVE_LOCAL_LLM_URL", "").strip()
pytestmark = pytest.mark.skipif(not LIVE_URL, reason="LIVE_LOCAL_LLM_URL non défini (test en direct)")

PLAN_SCHEMA = {
    "type": "object",
    "required": ["understanding", "steps"],
    "properties": {
        "understanding": {"type": "string"},
        "steps": {
            "type": "array", "minItems": 1, "maxItems": 6,
            "items": {"type": "object", "required": ["type"],
                      "properties": {"type": {"type": "string", "enum": ["write_file", "read_file", "run_command", "wait"]},
                                     "path": {"type": "string"}, "content": {"type": "string"},
                                     "program": {"type": "string"}, "args": {"type": "array", "items": {"type": "string"}},
                                     "cwd": {"type": "string"}}},
        },
    },
}


@pytest.fixture()
def offline_local(monkeypatch):
    monkeypatch.setenv("SOULBAH_MODE", "OFFLINE")
    monkeypatch.setenv("LOCAL_LLM_URL", LIVE_URL)
    monkeypatch.setenv("LOCAL_LLM_MODEL", os.environ.get("LIVE_LOCAL_LLM_NAME", "local"))
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ne-doit-jamais-servir")
    config.settings_resolution.cache_clear()
    orchestrator.set_providers(None)
    network_guard.install(config.soulbah_settings_now())
    yield
    network_guard.install(soulbah_settings.resolve({})["settings"])
    monkeypatch.delenv("SOULBAH_MODE")
    config.settings_resolution.cache_clear()
    orchestrator.set_providers(None)


def test_offline_planning_with_local_model_only(offline_local):
    status = orchestrator.status()
    assert status["mode"] == "OFFLINE" and status["configured"] == ["local"] and "anthropic" in status["blocked_by_mode"]
    with pytest.raises(network_guard.NetworkGuardError):
        socket.getaddrinfo("api.anthropic.com", 443)  # Internet réellement refusé pendant le test
    system = ("Tu es le planificateur de Soulbah. Réponds par un plan JSON d'étapes d'outils. "
              "Dossier autorisé : C:\\w. Outils : write_file(path, content), read_file(path), "
              "run_command(program, args, cwd), wait.")
    messages = [{"role": "user", "content": "Écris « bonjour hors ligne » dans le fichier C:\\w\\note.txt puis relis-le."}]
    result = asyncio.run(orchestrator.generate("automation", system, messages, 400, json_schema=PLAN_SCHEMA))
    assert result.provider == "local"
    plan = json.loads(result.text)
    tools = [s.get("type") for s in plan["steps"]]
    assert "write_file" in tools, plan
    write = next(s for s in plan["steps"] if s.get("type") == "write_file")
    assert "note.txt" in str(write.get("path")), plan
    print(f"\nPlan local ({result.model}) : {json.dumps(plan, ensure_ascii=False)}")
    print(f"Jetons : entrée {result.input_tokens}, sortie {result.output_tokens}")
