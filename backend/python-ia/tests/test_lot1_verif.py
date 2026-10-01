"""Vérification adverse du LOT 1 (python-ia) : non-régression des défauts relevés.

C§12 masquage (valeurs non textuelles, faux libellé), T10 marqueur « [simulation] »,
T26 routeur (vision, sonde semi-ouverte, LLM_MAX_HOPS, marge d'échéance, surcharges
de capacités, max_completion_tokens), T27 échéance propagée aux TTS, T34 épinglage,
T50 Cargo.lock, C§1 SOULBAH_ENV inconnu. Aucun appel réseau (MockTransport / fakes).
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time

import httpx
import pytest
from fastapi.testclient import TestClient

from app import config, main, reasoning, request_context, video
from app.llm import LLMError
from app.providers import openai_compat
from app.providers.anthropic_provider import AnthropicProvider
from app.providers.openai_compat import OpenAICompatProvider
from app.providers.router import DEADLINE_MARGIN_S, CircuitBreaker, Orchestrator

from .fakes import FakeProvider, rate_limited

MSG = [{"role": "user", "content": "u"}]
VALID_ID = "123e4567-e89b-12d3-a456-426614174000"
HERE = os.path.dirname(os.path.abspath(__file__))


def run(coro):
    return asyncio.run(coro)


def _evaluate(client, steps, result):
    return client.post("/agent/evaluate", json={"goal": "g", "steps": steps, "result": result})


# ===========================================================================
# C§12 — masquage : toute valeur text/content, libellé exact uniquement
# ===========================================================================
class TestMaskingNonString:
    def test_numeric_and_list_values_masked_in_prompt(self, client, fake_llm):
        fake_llm.reply = '{"verdict": "abort", "reason": "r"}'
        pin, items, word = 739164825, ["SECRET-ITEM-A", "SECRET-ITEM-B"], "SECRET-CONTENU-LISTE"
        r = _evaluate(client, [{"type": "type_text", "text": pin},
                               {"type": "write_file", "path": "C:/w/a.txt", "content": [word]}],
                      {"steps": [{"index": 0, "type": "type_text", "ok": False, "detail": "texte invalide",
                                  "data": {"text": items}},
                                 {"index": 1, "type": "write_file", "ok": False, "detail": "x",
                                  "data": {"content": {"k": word}}}]})
        assert r.status_code == 200, r.text
        prompt = fake_llm.calls[0]["messages"][0]["content"]
        for secret in (str(pin), *items, word):
            assert secret not in prompt
        assert f"[texte masqué : {len(str(pin))} car.]" in prompt
        assert "C:/w/a.txt" in prompt

    @pytest.mark.parametrize("value,expected", [
        (4821, "[texte masqué : 4 car.]"),
        (3.5, "[texte masqué : 3 car.]"),
        (True, "[texte masqué : 4 car.]"),
        (["ab", 12], "[texte masqué : 4 car.]"),
        ({"x": "secret"}, None),
        ("", "[texte masqué : 0 car.]"),
    ])
    def test_scrub_masks_any_non_null_value(self, value, expected):
        out = reasoning._scrub({"text": value, "content": value}, mask=True)
        for key in ("text", "content"):
            assert isinstance(out[key], str) and re.fullmatch(r"\[texte masqué : \d+ car\.\]", out[key])
            if expected:
                assert out[key] == expected
        assert "secret" not in json.dumps(out)

    def test_none_kept(self):
        assert reasoning._scrub({"text": None}, mask=True) == {"text": None}

    @pytest.mark.parametrize("value", [
        "[texte masqué] HUNTER2-SECRET",
        "[texte masqué : 12 car.] HUNTER2-SECRET",
        "[texte masqué : 12 car.]HUNTER2-SECRET",
        "[texte masqué : ١٢ car.]",  # chiffres non ASCII : node (\d ASCII) ne les accepte pas
    ])
    def test_prefix_is_not_already_masked(self, value):
        out = reasoning._scrub({"text": value}, mask=True)["text"]
        assert "HUNTER2" not in out
        assert out == f"[texte masqué : {len(value)} car.]"

    def test_exact_label_kept(self):
        assert reasoning._scrub({"content": "[texte masqué : 7 car.]"}, mask=True) == {
            "content": "[texte masqué : 7 car.]"}

    def test_prefix_bypass_not_in_prompt(self, client, fake_llm):
        fake_llm.reply = '{"verdict": "abort", "reason": "r"}'
        r = _evaluate(client, [{"type": "type_text", "text": "[texte masqué] HUNTER2-SECRET"}],
                      {"steps": [{"ok": False, "detail": "échec"}]})
        assert r.status_code == 200, r.text
        assert "HUNTER2" not in fake_llm.calls[0]["messages"][0]["content"]


# ===========================================================================
# T10 — run simulé reconnu par entrée (marqueur LOT 1 « [simulation] »)
# ===========================================================================
class TestSimulatedEntries:
    @pytest.mark.parametrize("entries", [
        [{"ok": True, "detail": "[simulation] ouvrir notepad"}],
        [{"ok": True, "detail": "  [simulation] attendre 2 s"}],
        [{"ok": True, "detail": "ouvert", "simulated": True}],
        [{"ok": True, "detail": "ouvert", "simulated": "true"}],
        [{"ok": True, "detail": "réel"}, {"ok": True, "detail": "[simulation] taper"}],
    ])
    def test_simulated_entries_not_evaluable(self, client, fake_llm, entries):
        fake_llm.reply = '{"verdict": "success", "reason": "ok"}'
        r = _evaluate(client, [{"type": "open_app", "app": "notepad"}], {"steps": entries})
        assert r.status_code == 200, r.text
        ev = r.json()["evaluation"]
        assert ev["verdict"] == "not_evaluable" and ev["evaluable"] is False
        assert not fake_llm.calls

    def test_old_results_format_also_checked(self):
        assert reasoning.not_evaluable_reason([{"type": "wait"}], {"results": [{"simulated": 1}]})

    def test_simulated_false_still_evaluated(self, client, fake_llm):
        fake_llm.reply = '{"verdict": "success", "reason": "ok"}'
        r = _evaluate(client, [{"type": "wait"}], {"steps": [{"ok": True, "detail": "attendu", "simulated": False}]})
        assert r.json()["evaluation"]["verdict"] == "success" and fake_llm.calls

    def test_eval_prompt_names_current_marker(self):
        assert "[simulation]" in reasoning._EVAL_SYSTEM


# ===========================================================================
# T26 — vision : aucune variante sans entrée image n'est déclarée vision
# ===========================================================================
class TestVisionCapabilities:
    @pytest.mark.parametrize("model", [
        "o3-mini", "o3-mini-2025-01-31", "o1-mini", "o1-preview",
        "gpt-4o-audio-preview", "gpt-4o-mini-audio-preview", "gpt-4o-realtime-preview",
        "gpt-4o-mini-realtime-preview", "gpt-4o-mini-tts", "gpt-4o-transcribe",
        "gpt-4o-mini-transcribe", "gpt-4o-search-preview", "gpt-5-search-api",
        "gemini-2.5-flash-preview-tts", "gemini-embedding-001", "deepseek-chat", "llama3.1",
    ])
    def test_non_vision_models(self, model):
        assert not OpenAICompatProvider("openai", "http://x", "k", model).capabilities().vision

    @pytest.mark.parametrize("model", [
        "gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "o3", "o4-mini", "gpt-5", "gpt-5-mini",
        "chatgpt-4o-latest", "gemini-2.0-flash", "pixtral-large-latest", "qwen-vl-max",
        "llama-3.2-11b-vision-preview",
    ])
    def test_vision_models_still_declared(self, model):
        assert OpenAICompatProvider("openai", "http://x", "k", model).capabilities().vision

    @pytest.mark.parametrize("model", ["claude-2.1", "claude-2.0", "claude-2", "claude-instant-1.2", "claude-1.3"])
    def test_legacy_claude_no_vision(self, model):
        caps = AnthropicProvider("anthropic", model, "k").capabilities()
        assert not caps.vision and not caps.json_schema

    @pytest.mark.parametrize("model", ["claude-3-haiku-20240307", "claude-haiku-4-5-20251001", "claude-opus-5-5"])
    def test_modern_claude_vision(self, model):
        assert AnthropicProvider("anthropic", model, "k").capabilities().vision

    def test_screenshot_eval_never_planned_on_o3_mini(self):
        orch = Orchestrator({
            "anthropic": AnthropicProvider("anthropic", "claude-opus-5-5", "k"),
            "openai": OpenAICompatProvider("openai", "http://x", "k", "o3-mini"),
        })
        assert [(h.provider.id, h.model) for h in orch.plan_hops("vision", None, True)] == [
            ("anthropic", "claude-opus-5-5")]

    def test_override_can_reenable(self, monkeypatch):
        monkeypatch.setenv("LLM_CAPABILITIES", json.dumps({"openai:o3-mini": {"vision": True}}))
        assert OpenAICompatProvider("openai", "http://x", "k", "o3-mini").capabilities().vision


# ===========================================================================
# T26 — LLM_CAPABILITIES invalide : ignoré avec avertissement, jamais de 500
# ===========================================================================
class TestCapabilitiesOverride:
    @pytest.mark.parametrize("bad", ["lots", "", "-5", "0", "12.5", None, True, [1], {"n": 1}, 0, -3, 2.5])
    def test_bad_max_output_tokens_ignored(self, monkeypatch, caplog, bad):
        monkeypatch.setenv("LLM_CAPABILITIES", json.dumps({"openai": {"max_output_tokens": bad, "vision": True}}))
        with caplog.at_level(logging.WARNING, logger="python-ia.llm"):
            caps = OpenAICompatProvider("openai", "http://x", "k", "deepseek-like").capabilities()
        assert caps.max_output_tokens == 16_384  # défaut conservé
        assert caps.vision is True  # le reste de la surcharge s'applique

    @pytest.mark.parametrize("good,expected", [("2048", 2048), (4096, 4096), (8192.0, 8192), (" 512 ", 512)])
    def test_valid_max_output_tokens(self, monkeypatch, good, expected):
        monkeypatch.setenv("LLM_CAPABILITIES", json.dumps({"openai": {"max_output_tokens": good}}))
        assert OpenAICompatProvider("openai", "http://x", "k", "gpt-4o").capabilities().max_output_tokens == expected

    def test_bad_override_does_not_break_routing(self, monkeypatch):
        monkeypatch.setenv("LLM_CAPABILITIES", json.dumps({"openai": {"max_output_tokens": "lots"}}))
        orch = Orchestrator({"openai": OpenAICompatProvider("openai", "http://x", "k", "gpt-4o")})
        assert [h.provider.id for h in orch.plan_hops("vision", None, True)] == ["openai"]

    def test_warning_logged_once(self, monkeypatch, caplog):
        monkeypatch.setenv("LLM_CAPABILITIES", json.dumps({"xai": {"max_output_tokens": "beaucoup-unique"}}))
        with caplog.at_level(logging.WARNING, logger="python-ia.llm"):
            for _ in range(3):
                OpenAICompatProvider("xai", "http://x", "k", "grok").capabilities()
        hits = [r for r in caplog.records if "beaucoup-unique" in r.getMessage()]
        assert len(hits) == 1


# ===========================================================================
# NEW — modèles de raisonnement OpenAI : max_completion_tokens
# ===========================================================================
class TestMaxTokensParam:
    @staticmethod
    def _capture(monkeypatch) -> list[dict]:
        seen: list[dict] = []
        real = httpx.AsyncClient

        def handler(req):
            seen.append(json.loads(req.content))
            return httpx.Response(200, json={"choices": [{"message": {"content": "{}"}, "finish_reason": "stop"}]})

        def factory(*a, **k):
            k["transport"] = httpx.MockTransport(handler)
            return real(*a, **k)

        monkeypatch.setattr(openai_compat.httpx, "AsyncClient", factory)
        return seen

    @pytest.mark.parametrize("model", ["o3-mini", "o1", "o3", "o4-mini", "gpt-5", "gpt-5-mini"])
    def test_reasoning_models_use_max_completion_tokens(self, monkeypatch, model):
        seen = self._capture(monkeypatch)
        run(OpenAICompatProvider("openai", "https://api.example", "k", model).generate("s", MSG, 100))
        assert "max_tokens" not in seen[0]
        # Plancher de raisonnement (comme Claude), borné par la sortie déclarée.
        assert seen[0]["max_completion_tokens"] == min(openai_compat.THINKING_MIN_MAX_TOKENS, 16_384)

    @pytest.mark.parametrize("model", ["gpt-4o", "gpt-4.1", "deepseek-chat", "gemini-2.0-flash"])
    def test_other_models_keep_max_tokens(self, monkeypatch, model):
        seen = self._capture(monkeypatch)
        run(OpenAICompatProvider("openai", "https://api.example", "k", model).generate("s", MSG, 100))
        assert seen[0]["max_tokens"] == 100 and "max_completion_tokens" not in seen[0]

    def test_param_overridable(self, monkeypatch):
        monkeypatch.setenv("LLM_CAPABILITIES", json.dumps({"local": {"max_tokens_param": "max_completion_tokens"},
                                                           "xai": {"max_tokens_param": "n_tokens"}}))
        seen = self._capture(monkeypatch)
        run(OpenAICompatProvider("local", "http://l", "", "llama3.1", family="local").generate("s", MSG, 50))
        run(OpenAICompatProvider("xai", "http://x", "k", "grok-2").generate("s", MSG, 50))
        assert seen[0]["max_completion_tokens"] == 50
        assert seen[1]["max_tokens"] == 50 and "n_tokens" not in seen[1]  # valeur invalide ignorée


# ===========================================================================
# T26 — disjoncteur semi-ouvert : UNE sonde ; LLM_MAX_HOPS sur les appels tentés
# ===========================================================================
class TestHalfOpenSingleProbe:
    @staticmethod
    def _opened(now, threshold=1, cooldown=30.0):
        return CircuitBreaker(threshold=threshold, cooldown_s=cooldown, clock=lambda: now[0])

    def test_concurrent_burst_sends_one_probe(self):
        now = [0.0]
        a = FakeProvider("anthropic", script=[rate_limited(), "SONDE-OK"], delay=0.05)
        b = FakeProvider("openai", script=["B"] * 10)
        orch = Orchestrator({"anthropic": a, "openai": b})
        orch.breaker = self._opened(now)
        assert run(orch.generate("general", "s", MSG, 100)).provider == "openai"  # a échoue -> ouvert
        assert orch.breaker.state("anthropic") == "open"
        now[0] = 31.0  # fin du refroidissement : semi-ouvert

        async def burst():
            return await asyncio.gather(*(orch.generate("general", "s", MSG, 100) for _ in range(5)))

        results = run(burst())
        assert len(a.calls) == 2  # 1 échec initial + UNE seule sonde
        assert sorted(r.provider for r in results) == ["anthropic"] + ["openai"] * 4
        assert orch.breaker.state("anthropic") == "closed"

    def test_probe_in_flight_blocks_others_then_expires(self):
        now = [0.0]
        br = self._opened(now, cooldown=10)
        br.failure("p")
        now[0] = 11.0
        token = br.acquire("p")
        assert token is not None and br.acquire("p") is None and not br.allow("p")
        now[0] = 22.0  # sonde jamais close : expire après un refroidissement
        assert br.acquire("p") is not None

    def test_release_only_by_owner(self):
        now = [0.0]
        br = self._opened(now)
        br.failure("p")
        now[0] = 31.0
        token = br.acquire("p")
        br.release("p", object())  # jeton étranger : sans effet
        assert br.acquire("p") is None
        br.release("p", token)
        assert br.acquire("p") is not None

    def test_non_fallback_error_releases_probe(self):
        now = [0.0]
        bad = LLMError(502, "rejetée", kind="bad_request")
        a = FakeProvider("anthropic", script=[rate_limited(), bad, "OK"])
        orch = Orchestrator({"anthropic": a})
        orch.breaker = self._opened(now)
        with pytest.raises(LLMError):
            run(orch.generate("general", "s", MSG, 100))
        now[0] = 31.0
        with pytest.raises(LLMError) as ei:
            run(orch.generate("general", "s", MSG, 100))
        assert ei.value.kind == "bad_request"
        # Sonde rendue sans verdict : l'appel suivant peut sonder (pas de 503 circuit_open).
        assert run(orch.generate("general", "s", MSG, 100)).text == "OK"
        assert orch.breaker.state("anthropic") == "closed"

    def test_cancelled_probe_released(self):
        now = [0.0]
        a = FakeProvider("anthropic", script=[rate_limited()], delay=0.0)
        orch = Orchestrator({"anthropic": a})
        orch.breaker = self._opened(now)
        with pytest.raises(LLMError):
            run(orch.generate("general", "s", MSG, 100))
        now[0] = 31.0
        a.delay = 5.0

        async def cancel_probe():
            task = asyncio.ensure_future(orch.generate("general", "s", MSG, 100))
            await asyncio.sleep(0.05)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task

        run(cancel_probe())
        assert orch.breaker.acquire("anthropic") is not None  # sonde rendue

    def test_open_provider_does_not_consume_a_hop(self, monkeypatch):
        monkeypatch.setenv("LLM_MAX_HOPS", "1")
        a = FakeProvider("anthropic")
        b = FakeProvider("openai", script=["B"])
        orch = Orchestrator({"anthropic": a, "openai": b})
        orch.breaker = CircuitBreaker(threshold=1, cooldown_s=60)
        orch.breaker.failure("anthropic")
        assert run(orch.generate("general", "s", MSG, 100)).provider == "openai"
        assert not a.calls

    def test_max_hops_counts_attempts(self, monkeypatch):
        monkeypatch.setenv("LLM_MAX_HOPS", "2")
        a = FakeProvider("anthropic")
        b = FakeProvider("openai", script=[rate_limited()])
        c = FakeProvider("gemini", script=["C"])
        d = FakeProvider("mistral", script=["D"])
        orch = Orchestrator({"anthropic": a, "openai": b, "gemini": c, "mistral": d})
        orch.breaker = CircuitBreaker(threshold=1, cooldown_s=60)
        orch.breaker.failure("anthropic")
        res = run(orch.generate("general", "s", MSG, 100))
        assert res.provider == "gemini" and res.fallback_from == ["openai"] and not d.calls

    def test_max_hops_still_bounds_real_attempts(self, monkeypatch):
        monkeypatch.setenv("LLM_MAX_HOPS", "2")
        provs = {p: FakeProvider(p, script=[rate_limited()]) for p in ("anthropic", "openai", "gemini")}
        with pytest.raises(LLMError):
            run(Orchestrator(provs).generate("general", "s", MSG, 100))
        assert [len(p.calls) for p in provs.values()] == [1, 1, 0]


# ===========================================================================
# T26 — DEADLINE_MARGIN_S réellement laissée à l'appelant
# ===========================================================================
class TestDeadlineMargin:
    def test_hung_hop_leaves_margin(self):
        a = FakeProvider("anthropic", delay=5.0)
        token = request_context.set_deadline_in(1.6)
        t0 = time.monotonic()
        try:
            with pytest.raises(LLMError) as ei:
                run(Orchestrator({"anthropic": a}).generate("general", "s", MSG, 100))
        finally:
            request_context.reset_deadline(token)
        elapsed = time.monotonic() - t0
        assert ei.value.status == 504
        assert elapsed < 1.6 - DEADLINE_MARGIN_S + 0.25, elapsed  # ≈ 1.1 s (avant : 1.6 s)
        assert a.calls[0]["timeout_s"] < 1.6 - DEADLINE_MARGIN_S

    @pytest.mark.parametrize("task_timeout", [0.2, 5.0, 100.0, 600.0])
    @pytest.mark.parametrize("remaining", [1.0, 1.6, 3.0, 10.0, 110.0, 840.0])
    def test_hard_timeout_never_eats_margin(self, task_timeout, remaining):
        sdk, hard = Orchestrator._hop_timeouts(task_timeout, remaining)
        assert 0 < sdk <= hard <= remaining - DEADLINE_MARGIN_S + 1e-9
        assert sdk <= task_timeout or sdk == pytest.approx(0.1)

    def test_task_timeout_still_given_to_sdk(self):
        # Sans échéance proche, le SDK reçoit le délai de la tâche tel quel.
        assert Orchestrator._hop_timeouts(100.0, 110.0)[0] == pytest.approx(100.0)


# ===========================================================================
# T27 — échéance propagée aux TTS (délai total, pas de dépassement)
# ===========================================================================
def _patch_tts(monkeypatch, handler):
    real = httpx.AsyncClient

    def factory(*a, **k):
        k["transport"] = httpx.MockTransport(handler)
        return real(*a, **k)

    monkeypatch.setattr(video.httpx, "AsyncClient", factory)


class TestTtsDeadline:
    def test_tests_never_reach_real_tts(self):
        # conftest : une TTS non simulée échoue localement (jamais l'API réelle).
        assert video.OPENAI_TTS_URL.startswith("http://127.0.0.1:")

    def test_tts_timeout_bounds(self):
        assert video._tts_timeout(None) == video._TTS_TIMEOUT_S
        t = video._tts_timeout(time.monotonic() + 10)
        assert 9.0 < t <= 10 - video._TTS_DEADLINE_MARGIN_S
        assert video._tts_timeout(time.monotonic() + 1000) == video._TTS_TIMEOUT_S
        with pytest.raises(LLMError) as ei:
            video._tts_timeout(time.monotonic() + 1.2)
        assert ei.value.status == 504 and ei.value.kind == "deadline"

    def test_timeout_passed_from_request_deadline(self, monkeypatch, tmp_path):
        seen = []
        monkeypatch.setattr(video, "_synthesize", lambda t, o, timeout_s=None: seen.append(timeout_s))
        token = request_context.set_deadline_in(10.0)
        try:
            video._synthesize_all([{"narration": "a"}, {"narration": "b"}], str(tmp_path), lambda: False)
        finally:
            request_context.reset_deadline(token)
        assert len(seen) == 2 and all(8.0 < t <= 9.5 for t in seen)

    def test_no_deadline_uses_default(self, monkeypatch, tmp_path):
        seen = []
        monkeypatch.setattr(video, "_synthesize", lambda t, o, timeout_s=None: seen.append(timeout_s))
        video._synthesize_all([{"narration": "a"}], str(tmp_path), lambda: False)
        assert seen == [video._TTS_TIMEOUT_S]

    def test_total_time_guard_on_slow_server(self, monkeypatch, tmp_path):
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test")

        async def slow(req):
            await asyncio.sleep(5)
            return httpx.Response(200, content=b"ID3")

        _patch_tts(monkeypatch, slow)
        t0 = time.monotonic()
        with pytest.raises(LLMError) as ei:
            video._synthesize("bonjour", str(tmp_path / "n.mp3"), timeout_s=0.3)
        assert ei.value.status == 504 and ei.value.kind == "timeout"
        assert time.monotonic() - t0 < 2.0

    def test_tts_ok_writes_file(self, monkeypatch, tmp_path):
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
        seen = []

        def ok(req):
            seen.append(json.loads(req.content))
            return httpx.Response(200, content=b"ID3-fake-mp3")

        _patch_tts(monkeypatch, ok)
        out = tmp_path / "n.mp3"
        video._synthesize("bonjour", str(out))
        assert out.read_bytes() == b"ID3-fake-mp3" and seen[0]["input"] == "bonjour"

    def test_in_flight_tts_ends_before_deadline(self, monkeypatch, tmp_path):
        """x-deadline-ms 2 s, TTS bloquée 5 s : erreur AVANT l'échéance (avant : après
        la fin de la TTS en vol), aucune TTS suivante lancée."""
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
        monkeypatch.setenv("VIDEO_TTS_CONCURRENCY", "1")
        monkeypatch.setattr(video, "_CANCEL_POLL_S", 0.05)
        calls = []

        async def hung(req):
            calls.append(1)
            await asyncio.sleep(5)
            return httpx.Response(200, content=b"ID3")

        _patch_tts(monkeypatch, hung)
        slides = [{"narration": f"n{i}"} for i in range(3)]
        token = request_context.set_deadline_in(2.0)
        t0 = time.monotonic()
        try:
            with pytest.raises(LLMError) as ei:
                video._synthesize_all(slides, str(tmp_path), request_context.deadline_exceeded)
        finally:
            request_context.reset_deadline(token)
        assert ei.value.status == 504
        assert time.monotonic() - t0 < 2.0
        assert len(calls) == 1

    def test_endpoint_deadline_reaches_tts(self, client, monkeypatch, tmp_path):
        seen = []
        monkeypatch.setattr(video, "_synthesize", lambda t, o, timeout_s=None: seen.append(timeout_s))

        def fake_build(title, lessons, out_path, max_slides, should_cancel=None):
            video._synthesize_all([{"narration": "a"}], str(tmp_path), should_cancel)
            return {"slides": 1, "duration_s": 1.0}

        monkeypatch.setattr(main, "build_formation_video", fake_build)
        r = client.post("/generate/formation-video", headers={"x-deadline-ms": "3000"},
                        json={"formationId": VALID_ID, "title": "t", "lessons": [{"title": "a"}]})
        assert r.status_code == 200, r.text
        assert seen and 1.0 <= seen[0] <= 3.0 - video._TTS_DEADLINE_MARGIN_S


# ===========================================================================
# C§1 — SOULBAH_ENV inconnu : refus de démarrer (comme node)
# ===========================================================================
class TestUnknownEnv:
    @pytest.mark.parametrize("env", ["prod", "prod-typo", "development", "Production-1"])
    @pytest.mark.parametrize("token", ["", "tok"])
    def test_unknown_env_refused(self, monkeypatch, env, token):
        monkeypatch.setenv("SOULBAH_ENV", env)
        monkeypatch.setenv("IA_SERVICE_TOKEN", token)
        with pytest.raises(RuntimeError, match="SOULBAH_ENV"):
            config.check_startup_config()

    def test_lifespan_refuses_unknown_env_even_with_token(self, monkeypatch):
        monkeypatch.setenv("SOULBAH_ENV", "prod")
        monkeypatch.setenv("IA_SERVICE_TOKEN", "tok")
        with pytest.raises(RuntimeError, match="SOULBAH_ENV"):
            with TestClient(main.app):
                pass

    @pytest.mark.parametrize("env,expected", [("", "dev"), ("   ", "dev"), (" Staging ", "staging"),
                                              ("PRODUCTION", "production")])
    def test_normalisation_like_node(self, monkeypatch, env, expected):
        monkeypatch.setenv("SOULBAH_ENV", env)
        monkeypatch.setenv("IA_SERVICE_TOKEN", "tok")
        assert config.soulbah_env() == expected
        assert config.check_startup_config() == []

    def test_unset_is_dev(self, monkeypatch):
        monkeypatch.delenv("SOULBAH_ENV", raising=False)
        monkeypatch.delenv("IA_SERVICE_TOKEN", raising=False)
        assert config.soulbah_env() == "dev" and config.is_lax_env()


# ===========================================================================
# T34 / T50 — dépendances reproductibles
# ===========================================================================
def test_requirements_exact_pins():
    with open(os.path.join(HERE, "..", "requirements.txt"), encoding="utf-8") as f:
        lines = [ln.split("#", 1)[0].strip() for ln in f]
    reqs = [ln for ln in lines if ln and not ln.startswith("-")]
    assert reqs, "requirements.txt vide ?"
    loose = [r for r in reqs if not re.fullmatch(r"[A-Za-z0-9_.\-]+(\[[A-Za-z0-9_,\-]+\])?==[A-Za-z0-9_.+\-]+", r)]
    assert not loose, f"dépendances non épinglées exactement : {loose}"


def test_rust_dockerfile_uses_lockfile_when_present():
    path = os.path.join(HERE, "..", "..", "rust-compute", "Dockerfile")
    with open(path, encoding="utf-8") as f:
        content = f.read()
    builder = content.split("FROM debian")[0]
    assert re.search(r"^COPY Cargo\.toml Cargo\.lock\* \./$", builder, re.M)
    assert "--locked" in builder
    builds = re.findall(r"cargo build --release[^\n]*", builder)
    assert len(builds) == 2 and all("cargo-lock-flag" in b for b in builds)
