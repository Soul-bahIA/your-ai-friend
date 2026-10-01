"""Tests LOT 5 — Model Router v2 (audit §13 ligne 5 : ≥ 25 tests sans appel payant ;
la vision n'est jamais routée vers un modèle non-vision ; un override inconnu → 400).

Tout passe par FakeProvider (app/providers/fake.py) : aucun réseau, aucune clé, aucun coût.
"""
from __future__ import annotations

import asyncio
import json
import logging

import pytest
from fastapi.testclient import TestClient

from app import main, providers
from app.providers import circuit, usage
from app.providers.base import CompletionResult, LLMError
from app.providers.circuit import CircuitBreaker
from app.providers.router import OUTPUT_TOKEN_CAPS, Orchestrator, orchestrator
from app.providers import router as router_module

from .fakes import FakeProvider, rate_limited

MSG = [{"role": "user", "content": "u"}]
# FakeProvider répond toujours 11 jetons d'entrée / 7 de sortie :
# claude-opus-5-5 (4 $ / 20 $ par million) → (11×4 + 7×20) / 1e6.
OPUS_CALL_COST = 0.000184
OPUS = "claude-opus-5-5"


def run(coro):
    return asyncio.run(coro)


def opus(pid: str = "anthropic", **kw) -> FakeProvider:
    return FakeProvider(pid, model=OPUS, **kw)


@pytest.fixture(autouse=True)
def _reset_global_meter():
    """L'orchestrateur global est partagé entre les tests d'endpoint : compteur remis à zéro."""
    orchestrator.meter.reset()
    yield
    orchestrator.meter.reset()


# ===========================================================================
# Tarification (shared/models/pricing.json ↔ usage.py)
# ===========================================================================
class TestPricing:
    def test_known_models(self):
        assert usage.estimate_cost("anthropic", OPUS, 1_000_000, 1_000_000) == 24.0
        assert usage.estimate_cost("anthropic", "claude-sonnet-5-5", 1_000_000, 1_000_000) == 12.0
        assert usage.estimate_cost("openai", "gpt-4o", 1_000_000, 0) == 2.5
        assert usage.estimate_cost("gemini", "gemini-2.0-flash", 0, 1_000_000) == 0.4
        assert usage.estimate_cost("deepseek", "deepseek-chat", 1_000_000, 1_000_000) == pytest.approx(1.37)

    def test_prefix_match_longest_wins(self):
        # Identifiant daté → préfixe « claude-haiku-4-5 » ; suffixe -latest → « mistral-large ».
        assert usage.estimate_cost("anthropic", "claude-haiku-4-5-20251001", 1_000_000, 0) == 1.0
        assert usage.estimate_cost("mistral", "mistral-large-latest", 1_000_000, 0) == 2.0
        # gpt-4o-mini-2024-07-18 doit prendre le tarif mini (0,15), pas celui de gpt-4o (2,5).
        assert usage.estimate_cost("openai", "gpt-4o-mini-2024-07-18", 1_000_000, 0) == 0.15
        assert usage.estimate_cost("xai", "grok-2-latest", 1_000_000, 0) == 2.0

    def test_unknown_is_none_never_zero(self):
        assert usage.estimate_cost("fake", "fake-model", 11, 7) is None
        assert usage.estimate_cost("anthropic", "claude-mystere-9", 11, 7) is None
        assert usage.estimate_cost("inconnu", OPUS, 11, 7) is None
        assert usage.estimate_cost("openai", "", 11, 7) is None

    def test_local_is_zero(self):
        assert usage.estimate_cost("local", "llama3.1", 1_000_000, 1_000_000) == 0.0
        assert usage.estimate_cost("local", "n-importe-quoi", 5, 5) == 0.0

    def test_missing_tokens_count_as_zero(self):
        assert usage.estimate_cost("anthropic", OPUS, None, None) == 0.0

    def test_env_override_adds_or_fixes_pricing(self, monkeypatch):
        monkeypatch.setenv("LLM_PRICING", json.dumps({"fake": {"fake-model": {"input": 1, "output": 2}},
                                                      "anthropic": {OPUS: {"input": 8, "output": 40}}}))
        assert usage.estimate_cost("fake", "fake-model", 11, 7) == pytest.approx((11 * 1 + 7 * 2) / 1e6)
        assert usage.estimate_cost("anthropic", OPUS, 1_000_000, 0) == 8.0
        monkeypatch.setenv("LLM_PRICING", "{pas du json")
        assert usage.estimate_cost("fake", "fake-model", 11, 7) is None
        monkeypatch.setenv("LLM_PRICING", json.dumps({"fake": {"fake-model": {"input": -1, "output": "x"}}}))
        assert usage.estimate_cost("fake", "fake-model", 11, 7) is None

    def test_builtin_matches_shared_json(self):
        """Non-dérive : la copie intégrée est identique à shared/models/pricing.json."""
        shared = usage.load_shared_pricing(usage.SHARED_PRICING_PATH)
        assert shared is not None, "shared/models/pricing.json introuvable"
        assert shared == usage._BUILTIN_PRICING

    def test_pricing_file_env_merges(self, tmp_path, monkeypatch):
        f = tmp_path / "p.json"
        f.write_text(json.dumps({"providers": {"fake": {"*": {"input": 0.5, "output": 0.5}}}}), encoding="utf-8")
        monkeypatch.setenv("LLM_PRICING_FILE", str(f))
        assert usage.estimate_cost("fake", "quelconque", 1_000_000, 1_000_000) == 1.0
        assert usage.estimate_cost("anthropic", OPUS, 1_000_000, 0) == 4.0  # copie intégrée conservée
        monkeypatch.setenv("LLM_PRICING_FILE", str(tmp_path / "absent.json"))
        assert usage.estimate_cost("fake", "quelconque", 1, 1) is None


# ===========================================================================
# cost_usd dans CompletionResult.usage() et dans l'en-tête x-llm-usage
# ===========================================================================
class TestCostInUsage:
    def test_cost_in_result_and_usage(self, caplog):
        a = opus(script=["ok"])
        with caplog.at_level(logging.INFO, logger="python-ia.llm"):
            res = run(Orchestrator({"anthropic": a}).generate("general", "s", MSG, 100))
        assert res.cost_usd == pytest.approx(OPUS_CALL_COST)
        assert res.usage()["cost_usd"] == pytest.approx(OPUS_CALL_COST)
        assert any("llm_call" in r.getMessage() and '"cost_usd": 0.000184' in r.getMessage() for r in caplog.records)

    def test_unknown_cost_is_none(self):
        a = FakeProvider("fake", script=["ok"])
        orch = Orchestrator({"fake": a})
        res = run(orch.generate("general", "s", MSG, 100))
        assert res.cost_usd is None and res.usage()["cost_usd"] is None
        assert orch.meter.snapshot()["total"]["unknown_cost_calls"] == 1

    def test_provider_supplied_cost_is_kept(self):
        pre = CompletionResult(text="ok", provider="anthropic", model=OPUS, input_tokens=11, output_tokens=7,
                               stop_reason="end_turn", cost_usd=0.5)
        res = run(Orchestrator({"anthropic": opus(script=[pre])}).generate("general", "s", MSG, 100))
        assert res.cost_usd == 0.5

    def test_endpoint_header_includes_cost(self, client, use_providers):
        plan = json.dumps({"understanding": "u", "feasible": True, "steps": [{"type": "wait", "seconds": 1}]})
        use_providers({"anthropic": opus(script=[plan])})
        r = client.post("/agent/plan", json={"goal": "attends"})
        assert r.status_code == 200, r.text
        hdr = json.loads(r.headers["x-llm-usage"])
        assert hdr["calls"] == 1 and hdr["cost_usd"] == pytest.approx(OPUS_CALL_COST)

    def test_endpoint_header_cost_null_when_unknown(self, client, use_providers):
        plan = json.dumps({"understanding": "u", "feasible": True, "steps": [{"type": "wait", "seconds": 1}]})
        use_providers({"fake": FakeProvider("fake", script=[plan])})
        r = client.post("/agent/plan", json={"goal": "attends"})
        assert r.status_code == 200, r.text
        assert json.loads(r.headers["x-llm-usage"])["cost_usd"] is None


# ===========================================================================
# Plafond de jetons de sortie par profil : LLM_MAX_OUTPUT_TOKENS_<RÔLE>
# ===========================================================================
class TestOutputTokenCaps:
    def test_caps_table_covers_every_profile(self):
        assert set(OUTPUT_TOKEN_CAPS) == set(router_module.PROFILES)

    def test_cap_applied_to_profile_task(self, monkeypatch):
        monkeypatch.setenv("LLM_MAX_OUTPUT_TOKENS_PLANNER", "50")
        a = opus(script=["p"])
        run(Orchestrator({"anthropic": a}).generate("automation", "s", MSG, 1000))
        assert a.calls[0]["max_tokens"] == 50

    def test_default_is_requested_value(self):
        a = opus(script=["p", "e"])
        orch = Orchestrator({"anthropic": a})
        run(orch.generate("automation", "s", MSG, 1000))
        run(orch.generate("evaluation", "s", MSG, 20))
        assert [c["max_tokens"] for c in a.calls] == [1000, 20]

    def test_requested_below_cap_unchanged(self, monkeypatch):
        monkeypatch.setenv("LLM_MAX_OUTPUT_TOKENS_EVALUATOR", "500")
        a = opus(script=["e"])
        run(Orchestrator({"anthropic": a}).generate("evaluation", "s", MSG, 20))
        assert a.calls[0]["max_tokens"] == 20

    def test_cap_does_not_touch_tasks_without_profile(self, monkeypatch):
        for role in OUTPUT_TOKEN_CAPS.values():
            monkeypatch.setenv(role, "1")
        a = opus(script=["g"])
        run(Orchestrator({"anthropic": a}).generate("general", "s", MSG, 1000))
        assert a.calls[0]["max_tokens"] == 1000

    @pytest.mark.parametrize("bad", ["abc", "0", "-5", " "])
    def test_invalid_cap_ignored(self, monkeypatch, bad):
        monkeypatch.setenv("LLM_MAX_OUTPUT_TOKENS_CHEAP", bad)
        a = opus(script=["r"])
        run(Orchestrator({"anthropic": a}).generate("routing", "s", MSG, 300))
        assert a.calls[0]["max_tokens"] == 300

    def test_status_exposes_caps(self, monkeypatch):
        monkeypatch.setenv("LLM_MAX_OUTPUT_TOKENS_VISION", "2048")
        st = Orchestrator({"anthropic": opus()}).status()
        assert st["profiles"]["vision"]["max_output_tokens_cap"] == 2048
        assert st["profiles"]["planner"]["max_output_tokens_cap"] is None


# ===========================================================================
# Budget quotidien : LLM_DAILY_BUDGET_USD
# ===========================================================================
class TestDailyBudget:
    def test_exhausted_budget_is_402_without_call_nor_fallback(self, monkeypatch):
        monkeypatch.setenv("LLM_DAILY_BUDGET_USD", "0.0001")  # < coût d'un appel (0,000184)
        a = opus(script=["ok", "jamais"])
        b = FakeProvider("openai", model="gpt-4o", script=["jamais non plus"])
        orch = Orchestrator({"anthropic": a, "openai": b})
        assert run(orch.generate("general", "s", MSG, 100)).text == "ok"
        with pytest.raises(LLMError) as ei:
            run(orch.generate("general", "s", MSG, 100))
        assert ei.value.status == 402 and ei.value.kind == "budget" and not ei.value.fallback
        assert len(a.calls) == 1 and not b.calls
        assert orch.meter.snapshot()["budget_exhausted"] is True

    def test_empty_budget_is_unlimited(self, monkeypatch):
        monkeypatch.delenv("LLM_DAILY_BUDGET_USD", raising=False)
        a = opus(script=["1", "2", "3"])
        orch = Orchestrator({"anthropic": a})
        for _ in range(3):
            run(orch.generate("general", "s", MSG, 100))
        snap = orch.meter.snapshot()
        assert snap["daily_budget_usd"] is None and snap["budget_remaining_usd"] is None and len(a.calls) == 3

    @pytest.mark.parametrize("bad", ["abc", "0", "-1"])
    def test_invalid_or_non_positive_budget_is_unlimited(self, monkeypatch, bad):
        monkeypatch.setenv("LLM_DAILY_BUDGET_USD", bad)
        assert usage.daily_budget_usd() is None

    def test_warning_at_80_percent_then_exhausted(self, monkeypatch, caplog):
        # 1 appel = 0,000184 : 1er appel = 92 % de 0,0002 (avertissement 80 %), 2e = ATTEINT.
        monkeypatch.setenv("LLM_DAILY_BUDGET_USD", "0.0002")
        a = opus(script=["1", "2"])
        orch = Orchestrator({"anthropic": a})
        with caplog.at_level(logging.WARNING, logger="python-ia.llm"):
            run(orch.generate("general", "s", MSG, 100))
            msgs = [r.getMessage() for r in caplog.records]
            assert any("Budget quotidien LLM à 92 %" in m for m in msgs)
            assert not any("ATTEINT" in m for m in msgs)
            run(orch.generate("general", "s", MSG, 100))
        msgs = [r.getMessage() for r in caplog.records]
        assert sum("Budget quotidien LLM à" in m for m in msgs) == 1  # une seule fois par jour
        assert any("ATTEINT" in m for m in msgs)

    def test_budget_resets_on_new_utc_day(self, monkeypatch):
        monkeypatch.setenv("LLM_DAILY_BUDGET_USD", "0.5")
        now = [1_800_000_000.0]
        meter = usage.UsageMeter(clock=lambda: now[0])
        meter.record("anthropic", OPUS, "planner", 1, 1, 1.0)
        with pytest.raises(LLMError) as ei:
            meter.check_budget()
        assert ei.value.status == 402
        now[0] += 86_400  # lendemain UTC
        meter.check_budget()  # ne lève plus
        snap = meter.snapshot()
        assert snap["today"]["cost_usd"] == 0.0 and snap["today"]["calls"] == 0
        assert snap["total"]["cost_usd"] == 1.0  # le cumul global, lui, n'est pas remis à zéro
        assert snap["budget_remaining_usd"] == 0.5

    def test_unknown_cost_does_not_consume_budget(self, monkeypatch):
        monkeypatch.setenv("LLM_DAILY_BUDGET_USD", "0.0000001")
        a = FakeProvider("fake", script=["1", "2"])
        orch = Orchestrator({"fake": a})
        run(orch.generate("general", "s", MSG, 100))
        run(orch.generate("general", "s", MSG, 100))
        snap = orch.meter.snapshot()
        assert len(a.calls) == 2 and snap["today"]["unknown_cost_calls"] == 2 and snap["today"]["cost_usd"] == 0.0

    def test_endpoint_returns_402_before_any_call(self, client, use_providers, monkeypatch):
        monkeypatch.setenv("LLM_DAILY_BUDGET_USD", "0.001")
        a = opus(script=["jamais"])
        use_providers({"anthropic": a})
        orchestrator.meter.record("anthropic", OPUS, "planner", 100, 100, 0.001)
        r = client.post("/agent/plan", json={"goal": "x"})
        assert r.status_code == 402 and "Budget" in r.json()["detail"] and not a.calls
        r = client.post("/v2/models/complete", json={"messages": MSG})
        assert r.status_code == 402 and not a.calls


# ===========================================================================
# Disjoncteur : module circuit.py, réexports
# ===========================================================================
class TestCircuitModule:
    def test_importable_and_reexported(self):
        assert CircuitBreaker is circuit.CircuitBreaker
        assert router_module.CircuitBreaker is circuit.CircuitBreaker
        assert providers.CircuitBreaker is circuit.CircuitBreaker
        assert CircuitBreaker.__module__ == "app.providers.circuit"
        assert isinstance(Orchestrator({"anthropic": opus()}).breaker, CircuitBreaker)

    def test_cycle_closed_open_half_open_closed(self):
        now = [0.0]
        br = CircuitBreaker(threshold=2, cooldown_s=10, clock=lambda: now[0])
        assert br.state("p") == "closed"
        br.failure("p")
        assert br.state("p") == "closed"
        br.failure("p")
        assert br.state("p") == "open" and br.acquire("p") is None
        now[0] += 10
        assert br.state("p") == "half_open"
        token = br.acquire("p")
        assert token is not None and br.acquire("p") is None  # une seule sonde
        br.success("p")
        assert br.state("p") == "closed" and br.snapshot() == {}


# ===========================================================================
# Overrides : inconnu → 400, non autorisé → 400 (S32), via /v2/models/complete
# ===========================================================================
class TestOverridesV2:
    def test_unknown_provider_400_without_call(self, client, use_providers):
        a = opus(script=["jamais"])
        use_providers({"anthropic": a})
        r = client.post("/v2/models/complete", json={"messages": MSG, "provider": "inconnu"})
        assert r.status_code == 400 and "non autorisé" in r.json()["detail"] and not a.calls

    def test_allowed_but_not_configured_400(self, client, use_providers, monkeypatch):
        monkeypatch.setenv("LLM_ALLOWED_OVERRIDES", "inconnu")
        a = opus(script=["jamais"])
        use_providers({"anthropic": a})
        r = client.post("/v2/models/complete", json={"messages": MSG, "provider": "inconnu"})
        assert r.status_code == 400 and "non configuré" in r.json()["detail"] and not a.calls

    def test_configured_but_not_allowed_400(self, client, use_providers, monkeypatch):
        monkeypatch.setenv("LLM_ALLOWED_OVERRIDES", "anthropic")
        a, b = opus(script=["jamais"]), FakeProvider("openai", script=["jamais"])
        use_providers({"anthropic": a, "openai": b})
        r = client.post("/v2/models/complete", json={"messages": MSG, "provider": "openai"})
        assert r.status_code == 400 and not a.calls and not b.calls

    def test_allowed_override_used_without_fallback(self, client, use_providers, monkeypatch):
        monkeypatch.setenv("LLM_ALLOWED_OVERRIDES", "openai")
        a = opus(script=["jamais"])
        b = FakeProvider("openai", model="gpt-4o", script=[rate_limited("openai")])
        use_providers({"anthropic": a, "openai": b})
        r = client.post("/v2/models/complete", json={"messages": MSG, "provider": "OpenAI"})
        assert r.status_code == 429 and len(b.calls) == 1 and not a.calls


# ===========================================================================
# Vision : jamais vers un modèle non-vision
# ===========================================================================
class TestVisionNeverNonVision:
    def test_only_vision_provider_failing_never_falls_back_to_non_vision(self):
        a = FakeProvider("anthropic", vision=True, script=[rate_limited("anthropic")])
        b = FakeProvider("openai", vision=False, script=["jamais"])
        c = FakeProvider("gemini", vision=False, script=["jamais"])
        with pytest.raises(LLMError) as ei:
            run(Orchestrator({"anthropic": a, "openai": b, "gemini": c})
                .generate("vision", "s", MSG, 100, images=["aGk="]))
        assert ei.value.status == 429 and len(a.calls) == 1 and not b.calls and not c.calls

    def test_vision_provider_circuit_open_does_not_route_to_non_vision(self):
        a = FakeProvider("anthropic", vision=True, script=["jamais"])
        b = FakeProvider("openai", vision=False, script=["jamais"])
        orch = Orchestrator({"anthropic": a, "openai": b})
        orch.breaker = CircuitBreaker(threshold=1, cooldown_s=60)
        orch.breaker.failure("anthropic")
        with pytest.raises(LLMError) as ei:
            run(orch.generate("vision", "s", MSG, 100, images=["aGk="]))
        assert ei.value.status == 503 and ei.value.kind == "circuit_open" and not a.calls and not b.calls

    def test_non_vision_task_still_uses_any_provider(self):
        # Sans image, la vision n'est pas requise : le fournisseur non-vision est utilisable.
        b = FakeProvider("openai", vision=False, script=["texte"])
        assert run(Orchestrator({"openai": b}).generate("vision", "s", MSG, 100)).text == "texte"

    def test_v2_images_routed_to_vision_provider_only(self, client, use_providers):
        a = FakeProvider("anthropic", vision=False, script=["jamais"])
        b = FakeProvider("openai", vision=True, script=["VU"])
        use_providers({"anthropic": a, "openai": b})
        r = client.post("/v2/models/complete", json={"task": "vision", "messages": MSG, "images": ["aGk="]})
        assert r.status_code == 200 and r.json()["text"] == "VU"
        assert not a.calls and b.calls[0]["images"] == ["aGk="]

    def test_v2_override_to_non_vision_400(self, client, use_providers, monkeypatch):
        monkeypatch.setenv("LLM_ALLOWED_OVERRIDES", "openai")
        a = FakeProvider("anthropic", vision=True, script=["jamais"])
        b = FakeProvider("openai", vision=False, script=["jamais"])
        use_providers({"anthropic": a, "openai": b})
        r = client.post("/v2/models/complete",
                        json={"task": "vision", "messages": MSG, "images": ["aGk="], "provider": "openai"})
        assert r.status_code == 400 and "images" in r.json()["detail"] and not a.calls and not b.calls

    def test_v2_no_vision_model_503(self, client, use_providers):
        a = FakeProvider("anthropic", vision=False, script=["jamais"])
        use_providers({"anthropic": a})
        r = client.post("/v2/models/complete", json={"messages": MSG, "images": ["aGk="]})
        assert r.status_code == 503 and not a.calls


# ===========================================================================
# GET /v2/models et POST /v2/models/complete
# ===========================================================================
class TestV2ModelsEndpoints:
    def test_status_shape(self, client, use_providers):
        use_providers({"anthropic": opus(), "local": FakeProvider("local", model="llama3.1", family="local")})
        r = client.get("/v2/models")
        assert r.status_code == 200, r.text
        st = r.json()
        for key in ("providers", "configured", "profiles", "allowed_overrides", "circuit_breakers", "pricing", "usage"):
            assert key in st, key
        assert st["pricing"][f"anthropic:{OPUS}"] == {"input": 4.0, "output": 20.0}
        assert st["pricing"]["local:llama3.1"] == {"input": 0.0, "output": 0.0}
        assert st["pricing"]["anthropic:claude-haiku-4-5-20251001"] == {"input": 1.0, "output": 5.0}
        assert st["profiles"]["cheap"]["pricing_usd_per_mtok"] == {"input": 1.0, "output": 5.0}
        assert st["providers"][0]["capabilities"]["vision"] is False
        assert st["usage"]["total"]["calls"] == 0
        assert json.dumps(st).count("sk-") == 0  # aucun secret

    def test_status_matches_legacy_providers_route(self, client, use_providers):
        use_providers({"anthropic": opus()})
        assert client.get("/v2/models").json() == client.get("/providers").json()

    def test_complete_text(self, client, use_providers):
        a = opus(script=["Bonjour"])
        use_providers({"anthropic": a})
        r = client.post("/v2/models/complete", json={"task": "chat", "system": "sys", "messages": MSG})
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["text"] == "Bonjour" and "json" not in body
        assert body["usage"]["provider"] == "anthropic" and body["usage"]["model"] == OPUS
        assert body["usage"]["input_tokens"] == 11 and body["usage"]["cost_usd"] == pytest.approx(OPUS_CALL_COST)
        assert a.calls[0]["messages"] == MSG and a.calls[0]["max_tokens"] == 4096
        assert json.loads(r.headers["x-llm-usage"])["cost_usd"] == pytest.approx(OPUS_CALL_COST)

    def test_complete_json_schema_parsed(self, client, use_providers):
        a = opus(script=['```json\n{"a": 1, "b": [2]}\n```'])
        use_providers({"anthropic": a})
        schema = {"type": "object", "properties": {"a": {"type": "integer"}}, "required": ["a"]}
        r = client.post("/v2/models/complete", json={"messages": MSG, "json_schema": schema, "max_tokens": 64})
        assert r.status_code == 200, r.text
        assert r.json()["json"] == {"a": 1, "b": [2]}
        assert a.calls[0]["json_schema"] == schema and a.calls[0]["max_tokens"] == 64

    def test_complete_json_schema_default_skeleton(self, client, use_providers):
        use_providers({"anthropic": opus()})  # sans script : squelette du schéma
        schema = {"type": "object", "properties": {"ok": {"type": "boolean"}, "n": {"type": "integer"}},
                  "required": ["ok", "n"]}
        r = client.post("/v2/models/complete", json={"messages": MSG, "json_schema": schema})
        assert r.status_code == 200 and r.json()["json"] == {"ok": True, "n": 0}

    def test_complete_unparsable_json_502(self, client, use_providers):
        use_providers({"anthropic": opus(script=["ceci n'est pas du JSON"])})
        r = client.post("/v2/models/complete", json={"messages": MSG, "json_schema": {"type": "object"}})
        assert r.status_code == 502 and "non parsable" in r.json()["detail"]

    def test_complete_empty_reply_502(self, client, use_providers):
        use_providers({"anthropic": opus(script=["   "])})
        r = client.post("/v2/models/complete", json={"messages": MSG})
        assert r.status_code == 502 and "vide" in r.json()["detail"]

    def test_complete_effort_overrides_profile(self, client, use_providers):
        a = opus(script=["p", "q"])
        use_providers({"anthropic": a})
        assert client.post("/v2/models/complete", json={"task": "automation", "messages": MSG}).status_code == 200
        assert client.post("/v2/models/complete",
                           json={"task": "automation", "messages": MSG, "effort": "low"}).status_code == 200
        assert [c["effort"] for c in a.calls] == ["high", "low"]
        assert [c["model"] for c in a.calls] == [OPUS, OPUS]

    @pytest.mark.parametrize("body", [
        {"messages": []},                                             # aucun message
        {"messages": MSG, "max_tokens": 0},                           # max_tokens < 1
        {"messages": MSG, "max_tokens": 1_000_000},                   # au-delà de la borne
        {"messages": MSG, "task": "Pas Valide"},                      # tâche hors motif
        {"messages": MSG, "effort": "ultra"},                         # effort inconnu
        {"messages": [{"role": "system", "content": "x"}]},           # rôle interdit
        {"messages": MSG, "images": ["x"] * 11},                      # trop d'images
    ])
    def test_complete_validation_422(self, client, use_providers, body):
        a = opus(script=["jamais"])
        use_providers({"anthropic": a})
        assert client.post("/v2/models/complete", json=body).status_code == 422 and not a.calls

    def test_complete_last_message_must_be_user(self, client, use_providers):
        a = opus(script=["jamais"])
        use_providers({"anthropic": a})
        r = client.post("/v2/models/complete", json={"messages": MSG + [{"role": "assistant", "content": "a"}]})
        assert r.status_code == 400 and not a.calls
        r = client.post("/v2/models/complete", json={"messages": [{"role": "user", "content": "  "}]})
        assert r.status_code == 400 and not a.calls

    def test_401_without_service_token(self, use_providers, monkeypatch):
        monkeypatch.setenv("IA_SERVICE_TOKEN", "secret-de-test")
        a = opus(script=["ok"])
        use_providers({"anthropic": a})
        with TestClient(main.app) as c:
            assert c.get("/v2/models").status_code == 401
            r = c.post("/v2/models/complete", json={"messages": MSG})
            assert r.status_code == 401 and not a.calls
            r = c.post("/v2/models/complete", json={"messages": MSG}, headers={"x-ia-token": "mauvais"})
            assert r.status_code == 401 and not a.calls
            r = c.post("/v2/models/complete", json={"messages": MSG}, headers={"x-ia-token": "secret-de-test"})
            assert r.status_code == 200 and r.json()["text"] == "ok"
            assert c.get("/v2/models", headers={"x-ia-token": "secret-de-test"}).status_code == 200

    def test_deadline_header_bounds_provider_timeout(self, client, use_providers):
        a = opus(script=["ok"])
        use_providers({"anthropic": a})
        r = client.post("/v2/models/complete", json={"messages": MSG}, headers={"x-deadline-ms": "5000"})
        assert r.status_code == 200 and 0 < a.calls[0]["timeout_s"] <= 5.0

    def test_expired_deadline_is_504_without_call(self, client, use_providers):
        a = opus(script=["jamais"])
        use_providers({"anthropic": a})
        r = client.post("/v2/models/complete", json={"messages": MSG}, headers={"x-deadline-ms": "1"})
        assert r.status_code == 504 and not a.calls

    def test_slow_provider_cut_by_deadline(self, client, use_providers):
        a = opus(script=["trop tard"], delay=5.0)
        use_providers({"anthropic": a})
        r = client.post("/v2/models/complete", json={"messages": MSG}, headers={"x-deadline-ms": "1600"})
        assert r.status_code == 504 and len(a.calls) == 1

    def test_invalid_deadline_header_400(self, client, use_providers):
        use_providers({"anthropic": opus()})
        r = client.post("/v2/models/complete", json={"messages": MSG}, headers={"x-deadline-ms": "abc"})
        assert r.status_code == 400


# ===========================================================================
# Totaux de consommation (par fournisseur, par rôle, jour UTC)
# ===========================================================================
class TestConsumptionTotals:
    def test_totals_by_provider_and_role(self):
        a = opus(script=["p", "g", "r"])
        b = FakeProvider("openai", model="gpt-4o", script=["c"])
        orch = Orchestrator({"anthropic": a, "openai": b})
        run(orch.generate("automation", "s", MSG, 100))   # rôle planner
        run(orch.generate("general", "s", MSG, 100))      # pas de profil → rôle = tâche
        run(orch.generate("routing", "s", MSG, 100))      # rôle cheap (haiku)
        run(orch.generate("chat", "s", MSG, 100))         # openai (routage par tâche)
        snap = orch.meter.snapshot()
        assert snap["total"]["calls"] == 4
        assert snap["total"]["input_tokens"] == 44 and snap["total"]["output_tokens"] == 28
        assert snap["by_provider"]["anthropic"]["calls"] == 3 and snap["by_provider"]["openai"]["calls"] == 1
        haiku_cost = (11 * 1 + 7 * 5) / 1e6
        gpt4o_cost = (11 * 2.5 + 7 * 10) / 1e6
        assert snap["by_role"]["planner"]["cost_usd"] == pytest.approx(OPUS_CALL_COST)
        assert snap["by_role"]["general"]["cost_usd"] == pytest.approx(OPUS_CALL_COST)
        assert snap["by_role"]["cheap"]["cost_usd"] == pytest.approx(haiku_cost)
        assert snap["by_role"]["chat"]["cost_usd"] == pytest.approx(gpt4o_cost)
        assert snap["today"]["cost_usd"] == pytest.approx(2 * OPUS_CALL_COST + haiku_cost + gpt4o_cost)
        assert snap["total"]["unknown_cost_calls"] == 0

    def test_failed_hops_not_counted_but_fallback_is(self):
        a = opus(script=[rate_limited("anthropic")])
        b = FakeProvider("openai", model="gpt-4o", script=["ok"])
        orch = Orchestrator({"anthropic": a, "openai": b})
        res = run(orch.generate("general", "s", MSG, 100))
        snap = orch.meter.snapshot()
        assert res.fallback_from == ["anthropic"]
        assert "anthropic" not in snap["by_provider"] and snap["by_provider"]["openai"]["calls"] == 1

    def test_truncated_reply_is_still_counted(self):
        trunc = CompletionResult(text="{", provider="anthropic", model=OPUS, input_tokens=11, output_tokens=7,
                                 stop_reason="max_tokens", truncated=True)
        orch = Orchestrator({"anthropic": opus(script=[trunc])})
        with pytest.raises(LLMError):
            run(orch.generate("general", "s", MSG, 100))
        assert orch.meter.snapshot()["total"]["cost_usd"] == pytest.approx(OPUS_CALL_COST)

    def test_totals_survive_set_providers(self):
        orch = Orchestrator({"anthropic": opus(script=["1"])})
        run(orch.generate("general", "s", MSG, 100))
        orch.set_providers({"anthropic": opus(script=["2"])})
        run(orch.generate("general", "s", MSG, 100))
        assert orch.meter.snapshot()["total"]["calls"] == 2

    def test_endpoint_status_exposes_totals(self, client, use_providers):
        use_providers({"anthropic": opus(script=["ok"])})
        assert client.post("/v2/models/complete", json={"task": "automation", "messages": MSG}).status_code == 200
        st = client.get("/v2/models").json()["usage"]
        assert st["total"]["calls"] == 1 and st["by_role"]["planner"]["calls"] == 1
        assert st["by_provider"]["anthropic"]["cost_usd"] == pytest.approx(OPUS_CALL_COST)
        assert st["today"]["day"] and st["daily_budget_usd"] is None
