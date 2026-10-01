"""Tests LOT 1 de python-ia (T6, T10, T26, T27, T43, T50, S14, S23, S29, S32, §12).

Aucun appel réseau ni LLM payant : FakeProvider, MockTransport et SDK patché.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import threading
import time
from types import SimpleNamespace

import anthropic
import httpx
import pytest
from fastapi.testclient import TestClient

from app import agents, config, main, pdf, reasoning, request_context, rust_client, video
from app.llm import LLMError
from app.parsing import parse_bool
from app.providers.anthropic_provider import AnthropicProvider
from app.providers.base import CompletionResult
from app.providers.openai_compat import OpenAICompatProvider
from app.providers.registry import SPECS
from app.providers.router import CircuitBreaker, Orchestrator

from .fakes import FakeProvider, rate_limited, server_error

VALID_ID = "123e4567-e89b-12d3-a456-426614174000"
MSG = [{"role": "user", "content": "u"}]


def run(coro):
    return asyncio.run(coro)


def patch_tts_transport(monkeypatch, handler):
    """Toute requête TTS (httpx.AsyncClient de video.py) passe par `handler`
    (MockTransport) : aucun accès réseau réel."""
    real = httpx.AsyncClient

    def factory(*a, **k):
        k["transport"] = httpx.MockTransport(handler)
        return real(*a, **k)

    monkeypatch.setattr(video.httpx, "AsyncClient", factory)


# ===========================================================================
# T26 — Routeur : repli multi-sauts, disjoncteur, vision, usage, délais
# ===========================================================================
class TestRouterFallback:
    def test_fallback_on_429(self):
        a = FakeProvider("anthropic", script=[rate_limited("anthropic")])
        b = FakeProvider("openai", script=["OK-B"])
        orch = Orchestrator({"anthropic": a, "openai": b})
        res = run(orch.generate("general", "s", MSG, 100))
        assert res.text == "OK-B" and res.provider == "openai"
        assert res.fallback_from == ["anthropic"]
        assert len(a.calls) == 1 and len(b.calls) == 1

    def test_fallback_on_5xx(self):
        a = FakeProvider("anthropic", script=[server_error("anthropic")])
        b = FakeProvider("openai", script=["OK-B"])
        res = run(Orchestrator({"anthropic": a, "openai": b}).generate("general", "s", MSG, 100))
        assert res.text == "OK-B"

    def test_fallback_on_connection_error(self):
        a = FakeProvider("anthropic", script=[LLMError(502, "injoignable", fallback=True, kind="connection")])
        b = FakeProvider("openai", script=["OK-B"])
        assert run(Orchestrator({"anthropic": a, "openai": b}).generate("general", "s", MSG, 100)).text == "OK-B"

    def test_fallback_on_real_timeout(self, monkeypatch):
        # Le fournisseur ignore son délai : le routeur l'impose (wait_for) puis passe au suivant.
        monkeypatch.setenv("LLM_TIMEOUT_S", "0.2")
        a = FakeProvider("anthropic", delay=3.0)
        b = FakeProvider("openai", script=["OK-B"])
        t0 = time.monotonic()
        res = run(Orchestrator({"anthropic": a, "openai": b}).generate("general", "s", MSG, 100))
        assert res.text == "OK-B" and res.fallback_from == ["anthropic"]
        assert time.monotonic() - t0 < 2.5
        assert a.calls[0]["timeout_s"] == pytest.approx(0.2)

    def test_multi_hop(self):
        a = FakeProvider("anthropic", script=[rate_limited()])
        b = FakeProvider("openai", script=[server_error()])
        c = FakeProvider("gemini", script=["OK-C"])
        res = run(Orchestrator({"anthropic": a, "openai": b, "gemini": c}).generate("general", "s", MSG, 100))
        assert res.text == "OK-C" and res.fallback_from == ["anthropic", "openai"]

    def test_no_fallback_on_bad_request(self):
        a = FakeProvider("anthropic", script=[LLMError(502, "rejetée", kind="bad_request")])
        b = FakeProvider("openai", script=["OK-B"])
        with pytest.raises(LLMError) as ei:
            run(Orchestrator({"anthropic": a, "openai": b}).generate("general", "s", MSG, 100))
        assert ei.value.kind == "bad_request" and not b.calls

    def test_all_fail_raises_primary_error(self):
        a = FakeProvider("anthropic", script=[rate_limited()])
        b = FakeProvider("openai", script=[server_error()])
        with pytest.raises(LLMError) as ei:
            run(Orchestrator({"anthropic": a, "openai": b}).generate("general", "s", MSG, 100))
        assert ei.value.status == 429

    def test_max_hops_one_disables_fallback(self, monkeypatch):
        monkeypatch.setenv("LLM_MAX_HOPS", "1")
        a = FakeProvider("anthropic", script=[rate_limited()])
        b = FakeProvider("openai", script=["OK-B"])
        with pytest.raises(LLMError):
            run(Orchestrator({"anthropic": a, "openai": b}).generate("general", "s", MSG, 100))
        assert not b.calls


class TestCircuitBreaker:
    def test_opens_after_threshold_and_skips_provider(self, monkeypatch):
        monkeypatch.setenv("LLM_CB_THRESHOLD", "2")
        a = FakeProvider("anthropic", script=[rate_limited(), rate_limited(), "jamais"])
        b = FakeProvider("openai", script=["B1", "B2", "B3"])
        orch = Orchestrator({"anthropic": a, "openai": b})
        for _ in range(3):
            assert run(orch.generate("general", "s", MSG, 100)).provider == "openai"
        assert len(a.calls) == 2  # 3e requête : disjoncteur ouvert, fournisseur sauté
        assert orch.breaker.state("anthropic") == "open"
        assert orch.status()["circuit_breakers"]["anthropic"]["state"] == "open"

    def test_half_open_then_closes_on_success(self):
        now = [0.0]
        br = CircuitBreaker(threshold=2, cooldown_s=30, clock=lambda: now[0])
        br.failure("p"); br.failure("p")
        assert not br.allow("p")
        now[0] = 31.0
        assert br.state("p") == "half_open" and br.allow("p")
        br.success("p")
        assert br.state("p") == "closed"

    def test_half_open_failure_reopens(self):
        now = [0.0]
        br = CircuitBreaker(threshold=1, cooldown_s=10, clock=lambda: now[0])
        br.failure("p")
        now[0] = 11.0
        assert br.allow("p")
        br.failure("p")
        assert br.state("p") == "open"

    def test_all_open_gives_503(self, monkeypatch):
        monkeypatch.setenv("LLM_CB_THRESHOLD", "1")
        a = FakeProvider("anthropic", script=[rate_limited()])
        orch = Orchestrator({"anthropic": a})
        with pytest.raises(LLMError):
            run(orch.generate("general", "s", MSG, 100))
        with pytest.raises(LLMError) as ei:
            run(orch.generate("general", "s", MSG, 100))
        assert ei.value.status == 503 and len(a.calls) == 1


class TestVisionRouting:
    def test_image_request_skips_non_vision_model(self):
        a = FakeProvider("anthropic", vision=False)
        b = FakeProvider("openai", vision=True, script=["VU"])
        res = run(Orchestrator({"anthropic": a, "openai": b}).generate("vision", "s", MSG, 100, images=["aGk="]))
        assert res.text == "VU" and not a.calls
        assert b.calls[0]["images"] == ["aGk="]

    def test_no_vision_model_configured_refuses(self):
        a = FakeProvider("anthropic", vision=False)
        with pytest.raises(LLMError) as ei:
            run(Orchestrator({"anthropic": a}).generate("vision", "s", MSG, 100, images=["aGk="]))
        assert ei.value.status == 503 and not a.calls

    def test_fallback_never_goes_to_non_vision(self):
        a = FakeProvider("anthropic", vision=True, script=[rate_limited()])
        b = FakeProvider("openai", vision=False)
        with pytest.raises(LLMError):
            run(Orchestrator({"anthropic": a, "openai": b}).generate("vision", "s", MSG, 100, images=["aGk="]))
        assert not b.calls

    def test_override_to_non_vision_is_400(self, monkeypatch):
        monkeypatch.setenv("LLM_ALLOWED_OVERRIDES", "openai")
        a = FakeProvider("anthropic", vision=True)
        b = FakeProvider("openai", vision=False)
        with pytest.raises(LLMError) as ei:
            run(Orchestrator({"anthropic": a, "openai": b}).generate("vision", "s", MSG, 100,
                                                                      images=["aGk="], provider="openai"))
        assert ei.value.status == 400 and not b.calls

    def test_provider_level_refusal_for_non_vision_model(self, monkeypatch):
        p = AnthropicProvider("anthropic", "pas-un-claude", "sk-ant-test")
        called = []

        async def create(**kw):
            called.append(kw)

        monkeypatch.setattr(p._client.messages, "create", create)
        with pytest.raises(LLMError) as ei:
            run(p.generate("s", MSG, 10, images=["aGk="]))
        assert ei.value.status == 400 and not called

    def test_capabilities_explicit(self, monkeypatch):
        assert not OpenAICompatProvider("deepseek", "http://x", "k", "deepseek-chat").capabilities().vision
        assert not OpenAICompatProvider("local", "http://x", "", "llama3.1", family="local").capabilities().vision
        assert OpenAICompatProvider("openai", "http://x", "k", "gpt-4o").capabilities().vision
        claude = AnthropicProvider("anthropic", "claude-opus-5-5", "k").capabilities()
        assert claude.vision and claude.thinking and claude.effort and claude.max_output_tokens == 128_000
        haiku = AnthropicProvider("anthropic", "claude-haiku-4-5-20251001", "k").capabilities()
        assert haiku.vision and not haiku.thinking and not haiku.effort
        monkeypatch.setenv("LLM_CAPABILITIES", json.dumps({"deepseek": {"vision": "true"}}))
        assert OpenAICompatProvider("deepseek", "http://x", "k", "deepseek-chat").capabilities().vision


class TestUsageAndTruncation:
    def test_usage_returned_and_logged(self, caplog):
        a = FakeProvider("anthropic", script=["OK"])
        with caplog.at_level(logging.INFO, logger="python-ia.llm"):
            res = run(Orchestrator({"anthropic": a}).generate("general", "s", MSG, 100))
        assert (res.input_tokens, res.output_tokens, res.stop_reason) == (11, 7, "end_turn")
        assert res.usage()["truncated"] is False
        assert any("llm_call" in r.getMessage() and '"input_tokens": 11' in r.getMessage() for r in caplog.records)

    def test_truncation_becomes_502(self):
        trunc = CompletionResult(text='{"a": ', provider="anthropic", model="m",
                                 input_tokens=5, output_tokens=100, stop_reason="max_tokens", truncated=True)
        a = FakeProvider("anthropic", script=[trunc])
        b = FakeProvider("openai", script=["jamais"])
        with pytest.raises(LLMError) as ei:
            run(Orchestrator({"anthropic": a, "openai": b}).generate("general", "s", MSG, 100))
        assert ei.value.status == 502 and "tronquée" in ei.value.message and not b.calls

    def test_endpoint_exposes_usage_header(self, client, use_providers):
        plan = json.dumps({"understanding": "u", "feasible": True, "steps": [{"type": "wait", "seconds": 1}]})
        use_providers({"anthropic": FakeProvider("anthropic", script=[plan])})
        r = client.post("/agent/plan", json={"goal": "attends"})
        assert r.status_code == 200, r.text
        usage = json.loads(r.headers["x-llm-usage"])
        assert usage["calls"] == 1 and usage["input_tokens"] == 11 and usage["output_tokens"] == 7

    def test_endpoint_truncated_is_502(self, client, use_providers):
        trunc = CompletionResult(text="{", provider="anthropic", model="m", stop_reason="max_tokens", truncated=True)
        use_providers({"anthropic": FakeProvider("anthropic", script=[trunc])})
        r = client.post("/agent/plan", json={"goal": "x"})
        assert r.status_code == 502 and "tronquée" in r.json()["detail"]


class TestDeadline:
    def test_expired_deadline_no_call(self):
        a = FakeProvider("anthropic")
        token = request_context.set_deadline_in(0.3)
        try:
            with pytest.raises(LLMError) as ei:
                run(Orchestrator({"anthropic": a}).generate("general", "s", MSG, 100))
        finally:
            request_context.reset_deadline(token)
        assert ei.value.status == 504 and not a.calls

    def test_timeout_bounded_by_deadline(self):
        a = FakeProvider("anthropic", script=["OK"])
        token = request_context.set_deadline_in(5.0)
        try:
            run(Orchestrator({"anthropic": a}).generate("general", "s", MSG, 100))
        finally:
            request_context.reset_deadline(token)
        assert 0 < a.calls[0]["timeout_s"] <= 5.0

    def test_header_deadline_passed_to_provider(self, client, use_providers):
        a = FakeProvider("anthropic", script=['{"verdict": "success", "reason": "ok"}'])
        use_providers({"anthropic": a})
        r = client.post("/agent/evaluate", headers={"x-deadline-ms": "3000"}, json={
            "goal": "g", "steps": [{"type": "wait"}],
            "result": {"steps": [{"index": 0, "type": "wait", "ok": True, "detail": "ok"}]},
        })
        assert r.status_code == 200, r.text
        assert a.calls[0]["timeout_s"] <= 3.0

    @pytest.mark.parametrize("bad", ["abc", "-5", "0", "1.5"])
    def test_invalid_deadline_header_400(self, client, bad):
        r = client.get("/agents", headers={"x-deadline-ms": bad})
        assert r.status_code == 400

    def test_task_timeouts_aligned_with_node(self, monkeypatch):
        # Sans en-tête : court (<= 110 s < 120 s node), long (<= 840 s < 900 s node).
        assert Orchestrator._task_budget_s("automation") < 120
        assert Orchestrator._task_budget_s("formation") < 900
        assert Orchestrator._task_timeout_s("automation") <= Orchestrator._task_budget_s("automation")


class TestAnthropicProvider:
    @staticmethod
    def _resp(stop="end_turn", text="ok"):
        return SimpleNamespace(
            stop_reason=stop, model="claude-opus-5-5",
            content=[SimpleNamespace(type="thinking", thinking=""), SimpleNamespace(type="text", text=text)],
            usage=SimpleNamespace(input_tokens=5, output_tokens=9),
        )

    def test_thinking_model_floor_timeout_and_effort(self, monkeypatch):
        p = AnthropicProvider("anthropic", "claude-opus-5-5", "sk-ant-test")
        seen = {}

        async def create(**kw):
            seen.update(kw)
            return self._resp()

        monkeypatch.setattr(p._client.messages, "create", create)
        res = run(p.generate("s", MSG, 1200, json_schema={"type": "object"}, timeout_s=7.5, effort="high"))
        assert seen["max_tokens"] >= 16000  # la réflexion ne doit pas tout consommer
        assert seen["timeout"] == 7.5
        assert seen["output_config"]["effort"] == "high"
        assert seen["output_config"]["format"]["type"] == "json_schema"
        assert (res.text, res.input_tokens, res.output_tokens, res.truncated) == ("ok", 5, 9, False)

    def test_cheap_model_no_effort_no_floor(self, monkeypatch):
        p = AnthropicProvider("anthropic", "claude-opus-5-5", "sk-ant-test")
        seen = {}

        async def create(**kw):
            seen.update(kw)
            return self._resp()

        monkeypatch.setattr(p._client.messages, "create", create)
        run(p.generate("s", MSG, 1200, model="claude-haiku-4-5-20251001", effort="low"))
        assert seen["model"] == "claude-haiku-4-5-20251001"
        assert seen["max_tokens"] == 1200 and "output_config" not in seen

    def test_max_tokens_stop_reason_is_truncated(self, monkeypatch):
        p = AnthropicProvider("anthropic", "claude-opus-5-5", "sk-ant-test")

        async def create(**kw):
            return self._resp(stop="max_tokens", text='{"a":')

        monkeypatch.setattr(p._client.messages, "create", create)
        res = run(p.generate("s", MSG, 100))
        assert res.truncated and res.stop_reason == "max_tokens"

    def test_sdk_timeout_is_504_with_fallback(self, monkeypatch):
        p = AnthropicProvider("anthropic", "claude-opus-5-5", "sk-ant-test")

        async def create(**kw):
            raise anthropic.APITimeoutError(request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"))

        monkeypatch.setattr(p._client.messages, "create", create)
        with pytest.raises(LLMError) as ei:
            run(p.generate("s", MSG, 100))
        assert ei.value.status == 504 and ei.value.fallback

    def test_overloaded_529_allows_fallback(self, monkeypatch):
        p = AnthropicProvider("anthropic", "claude-opus-5-5", "sk-ant-test")
        resp = httpx.Response(529, request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"))

        async def create(**kw):
            raise anthropic.APIStatusError("overloaded", response=resp, body=None)

        monkeypatch.setattr(p._client.messages, "create", create)
        with pytest.raises(LLMError) as ei:
            run(p.generate("s", MSG, 100))
        assert ei.value.status == 502 and ei.value.fallback

    def test_small_sdk_retries(self):
        p = AnthropicProvider("anthropic", "claude-opus-5-5", "sk-ant-test")
        assert p._client.max_retries <= 2

    def test_bad_request_text_not_leaked(self, monkeypatch):
        p = AnthropicProvider("anthropic", "claude-opus-5-5", "sk-ant-test")
        resp = httpx.Response(400, request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"))

        async def create(**kw):
            raise anthropic.BadRequestError("SECRET-internal-detail sk-ant-123", response=resp, body=None)

        monkeypatch.setattr(p._client.messages, "create", create)
        with pytest.raises(LLMError) as ei:
            run(p.generate("s", MSG, 100))
        assert "SECRET" not in ei.value.message and "sk-ant" not in ei.value.message


class TestOpenAICompat:
    @staticmethod
    def _patch(monkeypatch, status, body):
        real = httpx.AsyncClient

        def factory(*a, **k):
            k["transport"] = httpx.MockTransport(lambda req: httpx.Response(status, text=body))
            return real(*a, **k)

        from app.providers import openai_compat
        monkeypatch.setattr(openai_compat.httpx, "AsyncClient", factory)

    def test_usage_and_length_truncation(self, monkeypatch):
        self._patch(monkeypatch, 200, json.dumps({
            "model": "gpt-4o", "choices": [{"message": {"content": "{"}, "finish_reason": "length"}],
            "usage": {"prompt_tokens": 12, "completion_tokens": 34},
        }))
        res = run(OpenAICompatProvider("openai", "https://api.example", "k", "gpt-4o").generate("s", MSG, 10))
        assert res.truncated and (res.input_tokens, res.output_tokens) == (12, 34)

    def test_upstream_body_never_in_message(self, monkeypatch):
        self._patch(monkeypatch, 500, '{"error": "SECRET stack trace at /srv/app.py"}')
        with pytest.raises(LLMError) as ei:
            run(OpenAICompatProvider("openai", "https://api.example", "k", "m").generate("s", MSG, 10))
        assert "SECRET" not in ei.value.message and ei.value.fallback


class TestProfilesAndModels:
    def test_default_anthropic_model_is_opus_5_5(self):
        assert SPECS["anthropic"]["default_model"] == "claude-opus-5-5"

    def test_task_profiles_defaults(self):
        a = FakeProvider("anthropic", script=["p", "e", "r"])
        orch = Orchestrator({"anthropic": a})
        run(orch.generate("automation", "s", MSG, 100))
        run(orch.generate("evaluation", "s", MSG, 100))
        run(orch.generate("routing", "s", MSG, 100))
        assert [c["model"] for c in a.calls] == ["claude-opus-5-5", "claude-opus-5-5", "claude-haiku-4-5-20251001"]
        assert [c["effort"] for c in a.calls] == ["high", "high", "low"]

    def test_profile_env_override_with_provider_prefix(self, monkeypatch):
        monkeypatch.setenv("LLM_MODEL_PLANNER", "openai:gpt-4.1")
        monkeypatch.setenv("LLM_ROUTING", json.dumps({"automation": "openai"}))
        a = FakeProvider("anthropic")
        b = FakeProvider("openai", model="gpt-4o", script=["ok"])
        run(Orchestrator({"anthropic": a, "openai": b}).generate("automation", "s", MSG, 100))
        assert b.calls[0]["model"] == "gpt-4.1"

    def test_profile_ignored_for_other_provider(self):
        b = FakeProvider("openai", model="gpt-4o", script=["ok"])
        run(Orchestrator({"openai": b}).generate("automation", "s", MSG, 100))
        assert b.calls[0]["model"] == "gpt-4o"


# ===========================================================================
# S32 — override de fournisseur : liste blanche
# ===========================================================================
class TestOverrideAllowlist:
    def test_unknown_override_400_without_call(self, client, use_providers):
        a = FakeProvider("anthropic")
        use_providers({"anthropic": a})
        r = client.post("/orchestrator/route", json={"request": "bonjour", "provider": "openai"})
        assert r.status_code == 400 and not a.calls

    def test_default_allowlist_empty_refuses_even_configured(self, client, use_providers):
        a = FakeProvider("anthropic")
        use_providers({"anthropic": a})
        r = client.post("/synthesize", json={"query": "q", "provider": "anthropic"})
        assert r.status_code == 400 and not a.calls

    def test_allowed_but_not_configured_400(self, client, use_providers, monkeypatch):
        monkeypatch.setenv("LLM_ALLOWED_OVERRIDES", "openai,mistral")
        use_providers({"anthropic": FakeProvider("anthropic")})
        r = client.post("/formation/analyze", json={"topic": "t", "provider": "mistral"})
        assert r.status_code == 400

    def test_allowed_override_is_used_without_fallback(self, monkeypatch):
        monkeypatch.setenv("LLM_ALLOWED_OVERRIDES", "openai")
        a = FakeProvider("anthropic", script=["A"])
        b = FakeProvider("openai", script=[rate_limited()])
        with pytest.raises(LLMError) as ei:
            run(Orchestrator({"anthropic": a, "openai": b}).generate("general", "s", MSG, 100, provider="openai"))
        assert ei.value.status == 429 and not a.calls  # choix explicite respecté

    def test_empty_override_is_ignored(self):
        a = FakeProvider("anthropic", script=["A"])
        assert run(Orchestrator({"anthropic": a}).generate("general", "s", MSG, 100, provider="  ")).text == "A"


# ===========================================================================
# T10 / §12 — évaluation : jamais de succès pour un run simulé/vide ; masquage
# ===========================================================================
class TestEvaluateNotEvaluable:
    @pytest.mark.parametrize("steps,result", [
        ([{"type": "wait"}], {"simulated": True, "steps": [{"ok": True, "detail": "ok"}]}),
        ([], {"empty_plan": True, "steps": []}),
        ([], {}),
        ([{"type": "wait"}], {"steps": []}),
        ([{"type": "wait"}], {"steps": [{"ok": True, "detail": "[dry-run] attendre 1 s"}]}),
        ([{"type": "wait"}], {"status": "cancelled", "steps": [{"ok": True, "detail": "x"}]}),
        ([{"type": "wait"}], {"simulated": "true", "steps": [{"ok": True, "detail": "x"}]}),
    ])
    def test_not_evaluable_without_llm(self, client, fake_llm, steps, result):
        fake_llm.reply = '{"verdict": "success", "reason": "ok"}'
        r = client.post("/agent/evaluate", json={"goal": "g", "steps": steps, "result": result})
        assert r.status_code == 200, r.text
        ev = r.json()["evaluation"]
        assert ev["verdict"] == "not_evaluable" and ev["evaluable"] is False
        assert ev["corrective_steps"] == [] and not fake_llm.calls

    def test_real_run_still_evaluated(self, client, fake_llm):
        fake_llm.reply = '{"verdict": "success", "reason": "ok"}'
        r = client.post("/agent/evaluate", json={"goal": "g", "steps": [{"type": "wait"}],
                                                 "result": {"steps": [{"ok": True, "detail": "attendu"}]}})
        ev = r.json()["evaluation"]
        assert ev["verdict"] == "success" and ev["evaluable"] is True
        assert fake_llm.calls[0]["task"] == "evaluation"

    def test_no_dry_run_success_rule_in_prompt(self):
        assert "considere ces etapes reussies" not in reasoning._EVAL_SYSTEM
        assert "ne prouve rien" in reasoning._EVAL_SYSTEM


class TestMasking:
    def test_text_and_content_masked_in_prompt(self, client, fake_llm):
        fake_llm.reply = '{"verdict": "success", "reason": "ok"}'
        secret = "mot-de-passe-TRES-secret"
        r = client.post("/agent/evaluate", json={
            "goal": "g",
            "steps": [{"type": "type_text", "text": secret},
                      {"type": "write_file", "path": "C:/w/a.txt", "content": secret + "-fichier"}],
            "result": {"steps": [
                {"index": 0, "type": "type_text", "ok": True, "detail": "tapé", "data": {"text": secret}},
                {"index": 1, "type": "write_file", "ok": True, "detail": "[texte masqué : 31 car.]"},
            ]},
        })
        assert r.status_code == 200, r.text
        prompt = fake_llm.calls[0]["messages"][0]["content"]
        assert secret not in prompt
        assert f"[texte masqué : {len(secret)} car.]" in prompt
        assert "C:/w/a.txt" in prompt  # le chemin reste visible

    def test_already_masked_kept(self):
        out = reasoning._scrub({"text": "[texte masqué : 12 car.]"}, mask=True)
        assert out["text"] == "[texte masqué : 12 car.]"

    def test_scrub_without_mask_unchanged(self):
        assert reasoning._scrub({"text": "abc"}) == {"text": "abc"}


# ===========================================================================
# T43 — booléens stricts
# ===========================================================================
class TestBoolParsing:
    @pytest.mark.parametrize("value,expected", [
        (True, True), (False, False), ("true", True), ("false", False), ("False", False),
        ("oui", True), ("non", False), ("0", False), ("1", True), (0, False), (1, True),
        ("peut-être", False), (None, False), ([], False),
    ])
    def test_parse_bool(self, value, expected):
        assert parse_bool(value, default=False) is expected

    @pytest.mark.parametrize("feasible,expected", [("false", False), ("true", True), (None, False), ("non", False)])
    def test_plan_feasible_string(self, client, fake_llm, feasible, expected):
        fake_llm.reply = json.dumps({"understanding": "u", "feasible": feasible,
                                     "steps": [{"type": "wait", "seconds": 1}]})
        r = client.post("/agent/plan", json={"goal": "x"})
        assert r.status_code == 200 and r.json()["plan"]["feasible"] is expected

    def test_plan_feasible_missing_defaults_true(self, client, fake_llm):
        fake_llm.reply = json.dumps({"understanding": "u", "steps": [{"type": "wait", "seconds": 1}]})
        assert client.post("/agent/plan", json={"goal": "x"}).json()["plan"]["feasible"] is True

    def test_route_needs_memory_check_string(self, fake_llm):
        fake_llm.reply = json.dumps({"agent": "chat", "task_type": "chat", "reason": "r",
                                     "complexity": "simple", "subtasks": [], "needs_memory_check": "false"})
        decision = run(agents.route_request("bonjour"))
        assert decision["needs_memory_check"] is False
        assert fake_llm.calls[0]["task"] == "routing"


# ===========================================================================
# T50 — rust-compute indisponible -> 503
# ===========================================================================
class TestRustCompute:
    @staticmethod
    def _patch(monkeypatch, handler):
        real = httpx.AsyncClient

        def factory(*a, **k):
            k["transport"] = httpx.MockTransport(handler)
            return real(*a, **k)

        monkeypatch.setattr(rust_client.httpx, "AsyncClient", factory)

    def test_unreachable_is_503(self, client, monkeypatch):
        def handler(req):
            raise httpx.ConnectError("Connection refused 10.0.0.5:8080", request=req)

        self._patch(monkeypatch, handler)
        r = client.post("/infer", json={"text": "super"})
        assert r.status_code == 503
        assert r.json()["detail"] == "Service de calcul indisponible"
        assert "10.0.0.5" not in r.text

    def test_upstream_500_is_503(self, client, monkeypatch):
        self._patch(monkeypatch, lambda req: httpx.Response(500, text="panic at src/main.rs"))
        r = client.post("/infer", json={"text": "super"})
        assert r.status_code == 503 and "panic" not in r.text

    def test_ok(self, client, monkeypatch):
        self._patch(monkeypatch, lambda req: httpx.Response(200, json={"sum": 1.0}))
        r = client.post("/infer", json={"text": "super"})
        assert r.status_code == 200 and r.json()["compute"] == {"sum": 1.0}

    def test_rust_dockerfile_non_root(self):
        path = os.path.join(os.path.dirname(__file__), "..", "..", "rust-compute", "Dockerfile")
        with open(path, encoding="utf-8") as f:
            content = f.read()
        final_stage = content.split("FROM debian")[-1]
        assert "\nUSER " in final_stage and "USER root" not in final_stage


# ===========================================================================
# S14 / contrat §1 — token obligatoire hors dev/test
# ===========================================================================
class TestStartupToken:
    @pytest.mark.parametrize("env", ["production", "staging"])
    def test_refuses_without_token(self, monkeypatch, env):
        monkeypatch.setenv("SOULBAH_ENV", env)
        monkeypatch.delenv("IA_SERVICE_TOKEN", raising=False)
        with pytest.raises(RuntimeError, match="IA_SERVICE_TOKEN"):
            config.check_startup_config()

    def test_lifespan_refuses_start_in_production(self, monkeypatch):
        monkeypatch.setenv("SOULBAH_ENV", "production")
        monkeypatch.delenv("IA_SERVICE_TOKEN", raising=False)
        with pytest.raises(RuntimeError):
            with TestClient(main.app):
                pass

    def test_production_with_token_starts(self, monkeypatch):
        monkeypatch.setenv("SOULBAH_ENV", "production")
        monkeypatch.setenv("IA_SERVICE_TOKEN", "tok")
        with TestClient(main.app) as c:
            assert c.get("/health").status_code == 200
            assert c.get("/agents").status_code == 401

    @pytest.mark.parametrize("env", ["dev", "test", ""])
    def test_dev_test_allow_missing_token(self, monkeypatch, env):
        monkeypatch.setenv("SOULBAH_ENV", env)
        monkeypatch.delenv("IA_SERVICE_TOKEN", raising=False)
        warnings = config.check_startup_config()
        assert any("IA_SERVICE_TOKEN" in w for w in warnings)


# ===========================================================================
# S29 — corps chunked sans Content-Length
# ===========================================================================
class TestChunkedBody:
    def test_chunked_body_over_limit_413(self, client, fake_llm, monkeypatch):
        monkeypatch.setattr(main, "MAX_BODY_BYTES", 100)

        def gen():
            yield b'{"goal": "'
            yield b"x" * 500
            yield b'"}'

        r = client.post("/agent/plan", content=gen(), headers={"content-type": "application/json"})
        assert r.status_code == 413
        assert not fake_llm.calls

    def test_chunked_body_under_limit_ok(self, client, fake_llm):
        fake_llm.reply = json.dumps({"understanding": "u", "feasible": True, "steps": [{"type": "wait"}]})

        def gen():
            yield b'{"goal": "ouvre notepad"}'

        r = client.post("/agent/plan", content=gen(), headers={"content-type": "application/json"})
        assert r.status_code == 200, r.text


# ===========================================================================
# S23 — aucune fuite de texte d'exception
# ===========================================================================
class TestNoInternalLeak:
    def test_pdf_failure_generic(self, client, monkeypatch):
        def boom(*a, **k):
            raise RuntimeError("SECRET /srv/internal/path")

        monkeypatch.setattr(main, "build_formation_pdf", boom)
        r = client.post("/formation/pdf", json={"formationId": VALID_ID, "curriculum": {}})
        assert r.status_code == 500 and "SECRET" not in r.text and "réf." in r.json()["detail"]

    def test_video_failure_generic(self, client, monkeypatch):
        def boom(*a, **k):
            raise RuntimeError("SECRET ffmpeg /usr/bin")

        monkeypatch.setattr(main, "build_formation_video", boom)
        r = client.post("/generate/formation-video", json={"formationId": VALID_ID, "title": "t",
                                                           "lessons": [{"title": "a"}]})
        assert r.status_code == 500 and "SECRET" not in r.text

    def test_unhandled_exception_generic(self, monkeypatch):
        async def boom(*a, **k):
            raise RuntimeError("SECRET-unhandled")

        monkeypatch.setattr(main, "plan_goal", boom)
        with TestClient(main.app, raise_server_exceptions=False) as c:
            r = c.post("/agent/plan", json={"goal": "x"})
        assert r.status_code == 500 and "SECRET" not in r.text

    def test_tts_connection_error_generic(self, monkeypatch):
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test")

        def handler(req):
            raise httpx.ConnectError("SECRET-host:443 refused", request=req)

        patch_tts_transport(monkeypatch, handler)
        with pytest.raises(LLMError) as ei:
            video._synthesize("bonjour", os.devnull)
        assert "SECRET" not in ei.value.message


# ===========================================================================
# T6 — PDF multi-pages portable (chemin non-Windows forcé)
# ===========================================================================
_LONG = "Contenu — avec • puces, « guillemets » ’typo’ € ✓ → ≥ émoji 😀 " * 80
_CURRICULUM = {
    "title": "Formation — test", "level": "débutant", "duration": "2 h",
    "objectives": ["Comprendre — les bases", "Pratiquer • vite"],
    "modules": [{"title": "Module — 1", "summary": "Résumé ’x’",
                 "chapters": [{"title": "Chapitre 1", "content": _LONG, "key_points": ["a → b"]}],
                 "quiz": [{"question": "Q ?", "choices": ["oui", "non"], "answer": 0}]}],
    "glossary": [{"term": "API", "definition": "Interface — programmation"}],
    "faq": [{"question": "Pourquoi ?", "answer": "Parce que…"}],
}


class TestPortablePdf:
    def test_bundled_font_and_license_shipped(self):
        for name in ("DejaVuSans.ttf", "DejaVuSans-Bold.ttf", "DejaVuSans-Oblique.ttf", "LICENSE-DejaVu.txt"):
            assert os.path.isfile(os.path.join(pdf._ASSETS_FONTS, name)), name
        assert pdf.FONT_CANDIDATES[0][0].endswith("DejaVuSans.ttf")

    def test_multipage_non_windows_uses_bundled_font(self, tmp_path):
        # Simule Linux : aucun chemin C:\Windows, seule la police livrée existe.
        linux_like = [c for c in pdf.FONT_CANDIDATES if "windows" not in c[0].lower()]
        assert len(linux_like) == len(pdf.FONT_CANDIDATES) - 1
        info = pdf.build_formation_pdf(_CURRICULUM, str(tmp_path / "f.pdf"), font_candidates=linux_like)
        assert info["pages"] >= 2 and info["font"] == "Uni"
        assert (tmp_path / "f.pdf").read_bytes().startswith(b"%PDF")

    def test_multipage_without_any_ttf_core_fallback(self, tmp_path):
        info = pdf.build_formation_pdf(_CURRICULUM, str(tmp_path / "g.pdf"),
                                       font_candidates=[("/nope/a.ttf", "/nope/b.ttf", "/nope/c.ttf")])
        assert info["pages"] >= 2 and info["font"] == "Helvetica"

    def test_core_safe(self):
        out = pdf.core_safe("a — b • c → d 😀")
        out.encode("cp1252")  # ne lève pas
        assert "—" in out and "->" in out

    def test_endpoint_multipage_pdf(self, client, media_dir):
        r = client.post("/formation/pdf", json={"formationId": VALID_ID, "curriculum": _CURRICULUM})
        assert r.status_code == 200, r.text
        assert r.json()["pages"] >= 2


# ===========================================================================
# T27 (partiel) — TTS en parallèle borné + annulation
# ===========================================================================
class TestVideoConcurrency:
    def test_tts_runs_concurrently_bounded(self, monkeypatch, tmp_path):
        monkeypatch.setenv("VIDEO_TTS_CONCURRENCY", "3")
        state = {"active": 0, "peak": 0}
        lock = threading.Lock()

        def fake_synth(text, out, timeout_s=None):
            with lock:
                state["active"] += 1
                state["peak"] = max(state["peak"], state["active"])
            time.sleep(0.15)
            with open(out, "wb") as f:
                f.write(text.encode())
            with lock:
                state["active"] -= 1

        monkeypatch.setattr(video, "_synthesize", fake_synth)
        slides = [{"narration": f"n{i}"} for i in range(7)]
        paths = video._synthesize_all(slides, str(tmp_path), lambda: False)
        assert 2 <= state["peak"] <= 3
        assert [open(p, encoding="utf-8").read() for p in paths] == [f"n{i}" for i in range(7)]

    def test_cancel_stops_pending_tts(self, monkeypatch, tmp_path):
        monkeypatch.setenv("VIDEO_TTS_CONCURRENCY", "1")
        monkeypatch.setattr(video, "_CANCEL_POLL_S", 0.02)
        calls = []

        def fake_synth(text, out, timeout_s=None):
            calls.append(text)
            time.sleep(0.1)

        monkeypatch.setattr(video, "_synthesize", fake_synth)
        slides = [{"narration": f"n{i}"} for i in range(8)]
        with pytest.raises(video.VideoCancelled):
            video._synthesize_all(slides, str(tmp_path), lambda: len(calls) >= 1)
        assert len(calls) < 8

    def test_cancelled_before_start_no_tts(self, monkeypatch, tmp_path):
        called = []
        monkeypatch.setattr(video, "_synthesize", lambda t, o, timeout_s=None: called.append(t))
        out = tmp_path / "v.mp4"
        with pytest.raises(video.VideoCancelled):
            video.build_formation_video("T", [{"title": "L", "content": "c"}], str(out), should_cancel=lambda: True)
        assert not called and not out.exists() and not list(tmp_path.iterdir())

    def test_endpoint_cancel_returns_499(self, client, monkeypatch):
        def cancelled(*a, **k):
            assert callable(k.get("should_cancel"))
            raise video.VideoCancelled()

        monkeypatch.setattr(main, "build_formation_video", cancelled)
        r = client.post("/generate/formation-video", json={"formationId": VALID_ID, "title": "t",
                                                           "lessons": [{"title": "a"}]})
        assert r.status_code == 499

    def test_endpoint_cancel_checker_not_cancelled_while_connected(self, client, monkeypatch):
        seen = {}

        def fake_build(title, lessons, out_path, max_slides, should_cancel=None):
            seen["cancel"] = should_cancel()
            return {"slides": 1, "duration_s": 1.0}

        monkeypatch.setattr(main, "build_formation_video", fake_build)
        r = client.post("/generate/formation-video", json={"formationId": VALID_ID, "title": "t",
                                                           "lessons": [{"title": "a"}]})
        assert r.status_code == 200, r.text
        assert seen["cancel"] is False


def test_video_cancelled_when_client_disconnects(monkeypatch):
    """Bout en bout ASGI : le client se déconnecte (http.disconnect) pendant la
    production -> should_cancel() devient vrai -> 499, plus aucun travail."""
    checks = []

    def fake_build(title, lessons, out_path, max_slides, should_cancel=None):
        for _ in range(100):
            checks.append(1)
            if should_cancel():
                raise video.VideoCancelled()
            time.sleep(0.01)
        return {"slides": 1, "duration_s": 1.0}

    monkeypatch.setattr(main, "build_formation_video", fake_build)
    body = json.dumps({"formationId": VALID_ID, "title": "t", "lessons": [{"title": "a"}]}).encode()
    pending = [{"type": "http.request", "body": body, "more_body": False}]
    sent = []

    async def receive():
        return pending.pop(0) if pending else {"type": "http.disconnect"}

    async def send(message):
        sent.append(message)

    scope = {
        "type": "http", "method": "POST", "path": "/generate/formation-video",
        "raw_path": b"/generate/formation-video", "query_string": b"", "root_path": "",
        "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())],
        "http_version": "1.1", "scheme": "http", "server": ("test", 80), "client": ("c", 1),
        "asgi": {"version": "3.0"},
    }
    run(main.app(scope, receive, send))
    assert sent[0]["status"] == 499
    assert len(checks) < 100


def test_streamed_multi_chunk_body_counted(monkeypatch, fake_llm):
    """ASGI direct : 3 messages http.request (more_body) sans Content-Length,
    total > limite -> 413 sans appel LLM."""
    monkeypatch.setattr(main, "MAX_BODY_BYTES", 100)
    parts = [b'{"goal": "' + b"x" * 50, b"y" * 50, b'"}']
    pending = [{"type": "http.request", "body": p, "more_body": i < len(parts) - 1} for i, p in enumerate(parts)]
    sent = []

    async def receive():
        return pending.pop(0) if pending else {"type": "http.disconnect"}

    async def send(message):
        sent.append(message)

    scope = {
        "type": "http", "method": "POST", "path": "/agent/plan", "raw_path": b"/agent/plan",
        "query_string": b"", "root_path": "", "http_version": "1.1", "scheme": "http",
        "headers": [(b"content-type", b"application/json"), (b"transfer-encoding", b"chunked")],
        "server": ("test", 80), "client": ("c", 1), "asgi": {"version": "3.0"},
    }
    run(main.app(scope, receive, send))
    assert sent[0]["status"] == 413
    assert not fake_llm.calls
