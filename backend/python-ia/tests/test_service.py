from __future__ import annotations

import asyncio
import json
import os

import anthropic
import httpx
import pytest

from app import llm, main, reasoning
from app.llm import LLMError
from app.providers import anthropic_provider, openai_compat
from app.providers.anthropic_provider import AnthropicProvider
from app.providers.openai_compat import OpenAICompatProvider

VALID_ID = "123e4567-e89b-12d3-a456-426614174000"


# ---------------------------------------------------------------------------
# Authentification service-à-service (x-ia-token)
# ---------------------------------------------------------------------------
class TestTokenAuth:
    def test_open_when_token_unset(self, client):
        assert client.get("/agents").status_code == 200

    def test_health_always_public(self, client, monkeypatch):
        monkeypatch.setenv("IA_SERVICE_TOKEN", "s3cret-token")
        assert client.get("/health").status_code == 200

    def test_missing_token_rejected(self, client, monkeypatch):
        monkeypatch.setenv("IA_SERVICE_TOKEN", "s3cret-token")
        assert client.get("/agents").status_code == 401
        assert client.get("/providers").status_code == 401
        assert client.get("/openapi.json").status_code == 401
        r = client.post("/agent/plan", json={"goal": "x"})
        assert r.status_code == 401

    def test_wrong_token_rejected(self, client, monkeypatch):
        monkeypatch.setenv("IA_SERVICE_TOKEN", "s3cret-token")
        r = client.get("/agents", headers={"x-ia-token": "s3cret-tokeN"})
        assert r.status_code == 401

    def test_non_ascii_token_rejected_not_500(self, client, monkeypatch):
        monkeypatch.setenv("IA_SERVICE_TOKEN", "s3cret-token")
        r = client.get("/agents", headers={"x-ia-token": bytes([0xC3, 0xA9, 0x74, 0xE9])})
        assert r.status_code == 401

    def test_good_token_accepted(self, client, monkeypatch):
        monkeypatch.setenv("IA_SERVICE_TOKEN", "s3cret-token")
        r = client.get("/agents", headers={"x-ia-token": "s3cret-token"})
        assert r.status_code == 200

    def test_post_health_not_public(self, client, monkeypatch):
        monkeypatch.setenv("IA_SERVICE_TOKEN", "s3cret-token")
        assert client.post("/health").status_code == 401

    def test_body_too_large(self, client, monkeypatch):
        monkeypatch.setattr(main, "MAX_BODY_BYTES", 100)
        r = client.post("/agent/plan", json={"goal": "x" * 500})
        assert r.status_code == 413


# ---------------------------------------------------------------------------
# formationId : UUID obligatoire (anti path traversal)
# ---------------------------------------------------------------------------
class TestFormationIdValidation:
    @pytest.mark.parametrize("bad", [
        "../../etc/passwd",
        "..\\..\\windows\\win.ini",
        "abc",
        "123e4567-e89b-12d3-a456-426614174000/../../x",
        "",
    ])
    def test_pdf_rejects_traversal(self, client, bad, monkeypatch):
        called = []
        monkeypatch.setattr(main, "build_formation_pdf", lambda *a: called.append(a))
        r = client.post("/formation/pdf", json={"formationId": bad, "curriculum": {}})
        assert r.status_code == 422
        assert not called

    def test_video_rejects_traversal(self, client, monkeypatch):
        called = []
        monkeypatch.setattr(main, "build_formation_video", lambda *a: called.append(a))
        r = client.post("/generate/formation-video", json={
            "formationId": "../../../evil", "title": "t", "lessons": [{"title": "a"}],
        })
        assert r.status_code == 422
        assert not called

    def test_pdf_valid_uuid_writes_inside_media(self, client, media_dir, monkeypatch):
        seen = {}

        def fake_pdf(curriculum, out_path):
            seen["path"] = out_path
            return {"pages": 3}

        monkeypatch.setattr(main, "build_formation_pdf", fake_pdf)
        r = client.post("/formation/pdf", json={"formationId": VALID_ID, "curriculum": {}})
        assert r.status_code == 200, r.text
        assert r.json() == {"filename": f"formation_{VALID_ID}.pdf", "pages": 3}
        assert os.path.dirname(seen["path"]) == os.path.realpath(media_dir)

    def test_real_pdf_generation(self, client, media_dir):
        r = client.post("/formation/pdf", json={
            "formationId": VALID_ID,
            "curriculum": {"title": "Test", "modules": [{"title": "M1", "chapters": [
                {"title": "C1", "content": "Contenu é à ü", "key_points": ["a"]}]}]},
        })
        assert r.status_code == 200, r.text
        path = os.path.join(media_dir, f"formation_{VALID_ID}.pdf")
        assert os.path.isfile(path)
        # Aucun fichier temporaire .part laissé derrière.
        assert not [f for f in os.listdir(media_dir) if f.endswith(".part")]

    def test_media_path_guard(self):
        from uuid import UUID
        name, path = main._media_path("formation", UUID(VALID_ID), "mp4")
        assert name == f"formation_{VALID_ID}.mp4"
        assert os.path.dirname(path) == main.MEDIA_DIR

    def test_sync_heavy_endpoints_are_plain_def(self):
        import inspect
        assert not inspect.iscoroutinefunction(main.gen_formation_video)
        assert not inspect.iscoroutinefunction(main.formation_pdf)


# ---------------------------------------------------------------------------
# _parse_json : sorties non-objet
# ---------------------------------------------------------------------------
class TestParseJson:
    def test_object(self):
        assert llm._parse_json('{"a": 1}') == {"a": 1}

    def test_markdown_fenced(self):
        assert llm._parse_json('```json\n{"a": 1}\n```') == {"a": 1}

    def test_single_item_list_unwrapped(self):
        assert llm._parse_json('[{"a": 1}]') == {"a": 1}

    @pytest.mark.parametrize("raw", ['[1, 2]', '[{"a":1},{"b":2}]', '"txt"', '42', 'null'])
    def test_non_object_raises_502(self, raw):
        with pytest.raises(LLMError) as ei:
            llm._parse_json(raw)
        assert ei.value.status == 502

    def test_garbage_raises_502(self):
        with pytest.raises(LLMError) as ei:
            llm._parse_json("pas du json")
        assert ei.value.status == 502

    def test_plan_endpoint_list_reply_gives_502_not_500(self, client, fake_llm):
        fake_llm.reply = '[{"type": "wait"}, {"type": "click"}]'
        r = client.post("/agent/plan", json={"goal": "ouvre notepad"})
        assert r.status_code == 502
        assert "objet JSON" in r.json()["detail"]

    def test_self_improve_list_reply_gives_502(self, client, fake_llm):
        fake_llm.reply = "[]"
        r = client.post("/agent/self-improve", json={"summary": "x"})
        assert r.status_code == 502

    def test_plan_endpoint_ok(self, client, fake_llm):
        fake_llm.reply = json.dumps({"understanding": "u", "feasible": True,
                                     "steps": [{"type": "open_app", "app": "notepad"},
                                               {"type": "rm_rf"}]})
        r = client.post("/agent/plan", json={"goal": "ouvre notepad"})
        assert r.status_code == 200
        plan = r.json()["plan"]
        assert [s["type"] for s in plan["steps"]] == ["open_app"]


# ---------------------------------------------------------------------------
# /agent/evaluate : suppression des image_b64 + troncature
# ---------------------------------------------------------------------------
class TestEvaluateScrub:
    def test_scrub_removes_b64_and_truncates(self):
        big = "A" * 50_000
        data = {
            "steps": [{"ok": True, "detail": "fine", "image_b64": big,
                       "nested": {"screenshot_b64": big, "out": big}}],
            "image_b64": big,
        }
        out = reasoning._scrub(data)
        dumped = json.dumps(out)
        assert "image_b64" not in dumped and "screenshot_b64" not in dumped
        assert len(out["steps"][0]["nested"]["out"]) < 5_000
        assert out["steps"][0]["detail"] == "fine"

    def test_dump_for_prompt_bounded(self):
        data = {"items": ["x" * 3_000 for _ in range(100)]}
        assert len(reasoning._dump_for_prompt(data)) <= reasoning._MAX_SECTION_CHARS + 20

    def test_endpoint_prompt_has_no_image(self, client, fake_llm):
        fake_llm.reply = '{"verdict": "success", "reason": "ok"}'
        secret_img = "iVBORw0KGgo" + "Z" * 10_000
        r = client.post("/agent/evaluate", json={
            "goal": "g",
            "steps": [{"type": "screenshot", "note": "n"}],
            "result": {"results": [{"ok": True, "detail": "pris", "image_b64": secret_img}]},
        })
        assert r.status_code == 200, r.text
        assert r.json()["evaluation"]["verdict"] == "success"
        prompt = fake_llm.calls[0]["messages"][0]["content"]
        assert "image_b64" not in prompt and "iVBORw0KGgo" not in prompt

    def test_invalid_verdict_becomes_abort(self, client, fake_llm):
        fake_llm.reply = '{"verdict": ["x"]}'
        # LOT 1 (T10) : un plan vide n'est plus évalué par le LLM -> on fournit une
        # vraie exécution (1 étape planifiée, 1 étape exécutée).
        r = client.post("/agent/evaluate", json={
            "goal": "g", "steps": [{"type": "wait", "seconds": 1}],
            "result": {"steps": [{"index": 0, "type": "wait", "ok": True, "detail": "attendu 1 s"}]},
        })
        assert r.status_code == 200
        assert r.json()["evaluation"]["verdict"] == "abort"


# ---------------------------------------------------------------------------
# Validation des entrées
# ---------------------------------------------------------------------------
class TestInputLimits:
    def test_goal_too_long(self, client, fake_llm):
        r = client.post("/agent/plan", json={"goal": "x" * 20_001})
        assert r.status_code == 422
        assert not fake_llm.calls

    def test_too_many_screenshots(self, client, fake_llm):
        r = client.post("/agent/evaluate", json={
            "goal": "g", "steps": [], "result": {}, "screenshots": ["a"] * 11,
        })
        assert r.status_code == 422

    def test_bad_history_does_not_500(self, client, fake_llm):
        fake_llm.reply = json.dumps({"title": "t", "architecture": "not-a-dict"})
        r = client.post("/generate/application", json={
            "appName": "A", "conversationHistory": [{"foo": 1}, {"role": "user", "content": 5}, {"role": "system", "content": "c"}],
            "existingArchitecture": {"frontend": {}},
        })
        assert r.status_code == 200, r.text
        assert r.json()["application"]["architecture"] == {}
        msgs = fake_llm.calls[0]["messages"]
        assert msgs and all(m["role"] in ("user", "assistant") for m in msgs)


# ---------------------------------------------------------------------------
# Mapping des erreurs des fournisseurs amont
# ---------------------------------------------------------------------------
def _patch_httpx(monkeypatch, module, status: int, body: str = '{"error":"x"}'):
    real = httpx.AsyncClient

    def handler(request):
        return httpx.Response(status, text=body)

    def factory(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(handler)
        return real(*args, **kwargs)

    monkeypatch.setattr(module.httpx, "AsyncClient", factory)


class TestProviderErrorMapping:
    @pytest.mark.parametrize("upstream,expected", [
        (401, 502), (403, 502), (429, 429), (500, 502), (400, 502), (404, 502), (402, 402),
    ])
    def test_openai_compat(self, monkeypatch, upstream, expected):
        _patch_httpx(monkeypatch, openai_compat, upstream,
                     body='{"error":"Incorrect API key provided: sk-abc***xyz"}')
        p = OpenAICompatProvider("openai", "https://api.example", "sk-test", "m")
        with pytest.raises(LLMError) as ei:
            asyncio.run(p.complete("s", [{"role": "user", "content": "u"}], 10))
        assert ei.value.status == expected
        if upstream in (401, 403):
            assert "invalide" in ei.value.message.lower()
            assert "sk-" not in ei.value.message  # pas de fuite d'extrait de clé

    def test_openai_compat_success(self, monkeypatch):
        _patch_httpx(monkeypatch, openai_compat, 200,
                     body='{"choices":[{"message":{"content":"hello"}}]}')
        p = OpenAICompatProvider("openai", "https://api.example", "k", "m")
        assert asyncio.run(p.complete("s", [{"role": "user", "content": "u"}], 10)) == "hello"

    @pytest.mark.parametrize("exc_cls,status,expected", [
        (anthropic.AuthenticationError, 401, 502),
        (anthropic.PermissionDeniedError, 403, 502),
        (anthropic.RateLimitError, 429, 429),
        (anthropic.InternalServerError, 500, 502),
        (anthropic.BadRequestError, 400, 502),
    ])
    def test_anthropic(self, monkeypatch, exc_cls, status, expected):
        p = AnthropicProvider("anthropic", "claude-test", "sk-ant-test")
        resp = httpx.Response(status, request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"))

        async def boom(**kwargs):
            raise exc_cls("upstream error", response=resp, body=None)

        monkeypatch.setattr(p._client.messages, "create", boom)
        with pytest.raises(LLMError) as ei:
            asyncio.run(p.complete("s", [{"role": "user", "content": "u"}], 10))
        assert ei.value.status == expected
        assert ei.value.status != 401

    def test_anthropic_credit_balance_402(self, monkeypatch):
        p = AnthropicProvider("anthropic", "claude-test", "sk-ant-test")
        resp = httpx.Response(400, request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"))

        async def boom(**kwargs):
            raise anthropic.BadRequestError("Your credit balance is too low", response=resp, body=None)

        monkeypatch.setattr(p._client.messages, "create", boom)
        with pytest.raises(LLMError) as ei:
            asyncio.run(p.complete("s", [{"role": "user", "content": "u"}], 10))
        assert ei.value.status == 402

    def test_endpoint_maps_bad_key_to_502(self, client, monkeypatch):
        async def bad_key(*a, **k):
            from app.providers.base import upstream_error
            raise upstream_error("anthropic", 401)

        monkeypatch.setattr(llm.orchestrator, "complete", bad_key)
        r = client.post("/agent/plan", json={"goal": "x"})
        assert r.status_code == 502
        assert "clé api du fournisseur invalide" in r.json()["detail"].lower()

    def test_tts_error_not_propagated_as_401(self, monkeypatch):
        from app import video

        monkeypatch.setenv("OPENAI_API_KEY", "sk-test")

        def fake_post(*a, **k):
            return httpx.Response(401, text='{"error":"Incorrect API key sk-abc"}')

        monkeypatch.setattr(video.httpx, "post", fake_post)
        with pytest.raises(LLMError) as ei:
            video._synthesize("bonjour", os.devnull)
        assert ei.value.status == 502
        assert "sk-" not in ei.value.message

    def test_video_tempdir_cleaned_on_failure(self, monkeypatch, tmp_path):
        from app import video

        created = []
        real_mkdtemp = video.tempfile.mkdtemp

        def tracking_mkdtemp(*a, **k):
            d = real_mkdtemp(*a, **k)
            created.append(d)
            return d

        def fail_tts(text, out):
            raise LLMError(502, "TTS down")

        monkeypatch.setattr(video.tempfile, "mkdtemp", tracking_mkdtemp)
        monkeypatch.setattr(video, "_synthesize", fail_tts)
        out = tmp_path / "v.mp4"
        with pytest.raises(LLMError):
            video.build_formation_video("T", [{"title": "L1", "content": "c"}], str(out))
        assert created and not os.path.exists(created[0])
        assert not out.exists()
        assert not list(tmp_path.iterdir())


def test_anthropic_module_imports():
    # garde-fou : le SDK installé expose bien les classes utilisées
    assert anthropic_provider.anthropic.APIStatusError
