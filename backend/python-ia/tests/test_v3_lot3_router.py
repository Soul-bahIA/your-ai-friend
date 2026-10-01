"""V3 LOT 3 — routeur de modèles local : chaîne locale par rôle (spécialisé → général → petit),
local prioritaire en HYBRID, model_policy (auto, local-only, cloud-first, fournisseur[:modèle]),
jamais de cloud en OFFLINE, capacités des serveurs locaux (vision déclarée, JSON contraint)."""
from __future__ import annotations

import pytest

from app import config
from app.providers import orchestrator, registry


@pytest.fixture()
def env(monkeypatch):
    def _apply(**values: str) -> None:
        for k, v in values.items():
            monkeypatch.setenv(k, v)
        config.settings_resolution.cache_clear()
        orchestrator.set_providers(None)

    yield _apply
    config.settings_resolution.cache_clear()
    orchestrator.set_providers(None)


LOCALS = {
    "LOCAL_LLM_URL": "http://127.0.0.1:8091/v1",
    "LOCAL_LLM_MODEL": "qwen2.5-1.5b-instruct-q4_k_m",
    "LOCAL_LLM_URL_CODE": "http://127.0.0.1:8092/v1",
    "LOCAL_LLM_MODEL_CODE": "qwen2.5-coder-1.5b-instruct-q4_k_m",
    "LOCAL_LLM_URL_SMALL": "http://127.0.0.1:8093/v1",
    "LOCAL_LLM_URL_VISION": "http://127.0.0.1:8094/v1",
}


def hops(task: str, vision: bool = False) -> list[tuple[str, str]]:
    return [(h.provider.id, h.model) for h in orchestrator.plan_hops(task, None, vision)]


def test_role_chain_specialised_then_general_then_small(env):
    env(**LOCALS)
    assert [p for p, _ in hops("code")] == ["local_code", "local", "local_small"]
    assert hops("code")[0] == ("local_code", "qwen2.5-coder-1.5b-instruct-q4_k_m")
    assert [p for p, _ in hops("automation")] == ["local", "local_small"]  # pas de serveur « planner »
    assert orchestrator.status()["local_chains"]["code"] == ["local_code", "local", "local_small"]


def test_hybrid_auto_puts_local_first_then_cloud(env):
    env(ANTHROPIC_API_KEY="sk-test", **LOCALS)
    assert [p for p, _ in hops("automation")] == ["local", "local_small", "anthropic"]


def test_policy_cloud_first_keeps_v2_order(env):
    env(ANTHROPIC_API_KEY="sk-test", SOULBAH_MODEL_POLICY="cloud-first", **LOCALS)
    assert [p for p, _ in hops("automation")] == ["anthropic", "local", "local_small"]


def test_policy_local_only_never_uses_cloud_even_in_hybrid(env):
    env(ANTHROPIC_API_KEY="sk-test", SOULBAH_MODEL_POLICY="local-only", **LOCALS)
    assert all(p.startswith("local") for p, _ in hops("automation"))


def test_policy_pins_provider_and_model(env):
    env(ANTHROPIC_API_KEY="sk-test", SOULBAH_MODEL_POLICY="local_small:phi-3.5-mini-instruct-q4_k_m", **LOCALS)
    first = hops("automation")[0]
    assert first == ("local_small", "phi-3.5-mini-instruct-q4_k_m")


def test_offline_never_reaches_cloud_and_falls_back_locally(env):
    env(SOULBAH_MODE="OFFLINE", ANTHROPIC_API_KEY="sk-test", SOULBAH_MODEL_POLICY="anthropic:claude-opus-5-5", **LOCALS)
    order = [p for p, _ in hops("automation")]
    assert "anthropic" not in order and order == ["local", "local_small"]


def test_local_vision_server_is_vision_capable_and_others_skipped(env):
    env(SOULBAH_MODE="OFFLINE", **LOCALS)
    assert [p for p, _ in hops("vision", vision=True)] == ["local_vision"]
    caps = registry.build_providers()["local"].capabilities()
    assert caps.json_schema is True and caps.vision is False


def test_role_server_on_internet_refused_outside_hybrid(env):
    env(SOULBAH_MODE="LOCAL_INTERNET", LOCAL_LLM_URL="http://127.0.0.1:8091/v1",
        LOCAL_LLM_URL_CODE="https://code.exemple.com/v1")
    provs = registry.build_providers()
    assert "local_code" not in provs and "local_code" in registry.BLOCKED_BY_MODE
    assert [p for p, _ in hops("code")] == ["local"]
