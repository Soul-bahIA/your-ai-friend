"""V3 LOT 1 — configuration centrale et modes côté python-ia.

  - module partagé identique à la source (shared/config/soulbah_settings.py) ;
  - cas de résolution communs (shared/config/resolution_cases.json) ;
  - OFFLINE / LOCAL_INTERNET : aucun fournisseur cloud construit même avec une clé ; erreur
    503 explicite sans modèle local ; LOCAL_LLM_URL accepté seulement vers une machine locale ;
  - narration vidéo (TTS cloud) refusée hors HYBRID ; démarrage refusé si SOULBAH_MODE invalide.
"""
from __future__ import annotations

import json
import pathlib

import pytest

from app import config, soulbah_settings
from app.llm import LLMError
from app.providers import orchestrator, registry

ROOT = pathlib.Path(__file__).resolve().parents[3]
CASES = json.loads((ROOT / "shared" / "config" / "resolution_cases.json").read_text(encoding="utf-8"))["cases"]


@pytest.fixture()
def mode(monkeypatch):
    """Applique un mode (et d'autres variables), reconstruit configuration et fournisseurs."""

    def _apply(value: str | None, **env: str) -> None:
        if value is None:
            monkeypatch.delenv("SOULBAH_MODE", raising=False)
        else:
            monkeypatch.setenv("SOULBAH_MODE", value)
        for k, v in env.items():
            monkeypatch.setenv(k, v)
        config.settings_resolution.cache_clear()
        orchestrator.set_providers(None)

    yield _apply
    monkeypatch.delenv("SOULBAH_MODE", raising=False)
    config.settings_resolution.cache_clear()
    orchestrator.set_providers(None)


def test_shared_module_is_identical_to_source():
    src = (ROOT / "shared" / "config" / "soulbah_settings.py").read_bytes()
    assert (ROOT / "backend" / "python-ia" / "app" / "soulbah_settings.py").read_bytes() == src, \
        "copie modifiée : python scripts/sync_shared.py"


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_resolution_cases(case):
    r = soulbah_settings.resolve(case["env"], case["file"])
    if "errors" in case:
        joined = " | ".join(r["errors"])
        for fragment in case["errors"]:
            assert fragment in joined
        return
    assert r["errors"] == []
    for k, v in case.get("expect", {}).items():
        assert r["settings"][k] == v, k
    view = soulbah_settings.public_view(r["settings"])
    for k, v in case.get("derived", {}).items():
        assert view[k] == v, k
    for host, allowed in case.get("hosts", {}).items():
        assert soulbah_settings.host_allowed(r["settings"], host) is allowed, host


def test_example_config_is_valid():
    r = soulbah_settings.load(None, {"SOULBAH_CONFIG": str(ROOT / "shared" / "config" / "soulbah.config.example.json")})
    assert r["errors"] == [] and r["settings"]["mode"] == "HYBRID"


@pytest.mark.parametrize("value", ["OFFLINE", "LOCAL_INTERNET"])
def test_cloud_providers_never_built_outside_hybrid(mode, value):
    mode(value, ANTHROPIC_API_KEY="sk-test", OPENAI_API_KEY="sk-test")
    provs = registry.build_providers()
    assert provs == {}
    assert set(registry.BLOCKED_BY_MODE) >= {"anthropic", "openai"}
    with pytest.raises(LLMError) as e:
        orchestrator.plan_hops("planning", None, False)
    assert e.value.status == 503 and "LOCAL_LLM_URL" in e.value.message
    status = orchestrator.status()
    assert status["mode"] == value and status["reasoning_available"] is False
    assert status["cloud_models_allowed"] is False and "anthropic" in status["blocked_by_mode"]


def test_local_model_allowed_offline_only_on_a_local_machine(mode):
    mode("OFFLINE", LOCAL_LLM_URL="http://127.0.0.1:8080/v1", ANTHROPIC_API_KEY="sk-test")
    assert list(registry.build_providers()) == ["local"]
    hops = orchestrator.plan_hops("planning", None, False)
    assert [h.provider.id for h in hops] == ["local"]

    mode("LOCAL_INTERNET", LOCAL_LLM_URL="https://modeles.exemple.com/v1")
    assert registry.build_providers() == {} and "local" in registry.BLOCKED_BY_MODE

    mode("OFFLINE", LOCAL_LLM_URL="http://192.168.1.20:8080/v1", SOULBAH_NETWORK_ALLOW_HOSTS="192.168.1.20")
    assert list(registry.build_providers()) == ["local"]


def test_hybrid_keeps_v2_behaviour(mode):
    mode(None, ANTHROPIC_API_KEY="sk-test", LOCAL_LLM_URL="https://modeles.exemple.com/v1")
    provs = registry.build_providers()
    assert "anthropic" in provs and "local" in provs and registry.BLOCKED_BY_MODE == {}
    assert orchestrator.status()["mode"] == "HYBRID"


def test_models_route_exposes_mode(mode, client):
    mode("OFFLINE")
    body = client.get("/v2/models").json()
    assert body["mode"] == "OFFLINE" and body["mode_label"] == "OFFLINE — 100% LOCAL"


def test_formation_narration_refused_outside_hybrid(mode, tmp_path):
    from app import video

    mode("OFFLINE", OPENAI_API_KEY="sk-test")
    with pytest.raises(LLMError) as e:
        video._synthesize("Bonjour", str(tmp_path / "a.mp3"))
    assert e.value.status == 503 and "OFFLINE" in e.value.message


def test_startup_refused_on_invalid_mode(mode):
    mode("OFLINE")
    with pytest.raises(RuntimeError, match="mode inconnu"):
        config.check_startup_config()
