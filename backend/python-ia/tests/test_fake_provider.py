"""LOT 3 — FakeProvider d'exécution (LLM_FAKE_PROVIDER) : registre, garde d'environnement,
squelette de schéma, bout en bout sur /agent/plan. Aucun appel réseau."""
from __future__ import annotations

import asyncio
import json

import pytest

from app import config
from app.providers import registry
from app.providers.fake import DEFAULT_TEXT_REPLY, FakeProvider, skeleton_from_schema


def _no_real_keys(monkeypatch):
    for spec in registry.SPECS.values():
        monkeypatch.delenv(spec["key_env"], raising=False)
    monkeypatch.delenv(registry.LOCAL_URL_ENV, raising=False)


class TestSkeleton:
    def test_object_required_only(self):
        schema = {"type": "object", "required": ["verdict", "reason"],
                  "properties": {"verdict": {"enum": ["success", "failure"]},
                                 "reason": {"type": "string"},
                                 "optional": {"type": "integer"}}}
        assert skeleton_from_schema(schema) == {"verdict": "success", "reason": "fake"}

    def test_object_without_required_takes_all_properties(self):
        schema = {"type": "object", "properties": {"a": {"type": "boolean"}, "b": {"type": "number"}}}
        assert skeleton_from_schema(schema) == {"a": True, "b": 0.0}

    def test_arrays_const_default_anyof_and_nullable(self):
        assert skeleton_from_schema({"type": "array", "items": {"type": "string"}}) == []
        assert skeleton_from_schema({"type": "array", "minItems": 2, "items": {"type": "integer"}}) == [0, 0]
        assert skeleton_from_schema({"const": "x"}) == "x"
        assert skeleton_from_schema({"type": "string", "default": "d"}) == "d"
        assert skeleton_from_schema({"anyOf": [{"type": "integer"}, {"type": "string"}]}) == 0
        assert skeleton_from_schema({"type": ["null", "string"]}) == "fake"
        assert skeleton_from_schema("pas un schéma") is None

    def test_generate_without_script_follows_schema_then_text(self):
        p = FakeProvider("fake")
        schema = {"type": "object", "required": ["feasible", "steps"],
                  "properties": {"feasible": {"type": "boolean"}, "steps": {"type": "array"}}}
        r = asyncio.run(p.generate("s", [{"role": "user", "content": "u"}], 100, json_schema=schema))
        assert json.loads(r.text) == {"feasible": True, "steps": []}
        assert r.provider == "fake" and r.input_tokens == 11 and r.stop_reason == "end_turn"
        r2 = asyncio.run(p.generate("s", [{"role": "user", "content": "u"}], 100))
        assert r2.text == DEFAULT_TEXT_REPLY
        assert p.calls[0]["json_schema"] == schema and p.calls[1]["json_schema"] is None


class TestRegistry:
    def test_disabled_by_default(self, monkeypatch):
        _no_real_keys(monkeypatch)
        monkeypatch.delenv("LLM_FAKE_PROVIDER", raising=False)
        assert registry.build_providers() == {}
        assert config.fake_provider_enabled() is False

    @pytest.mark.parametrize("value", ["1", "true", "YES", " on "])
    def test_enabled_in_dev_replaces_every_real_provider(self, monkeypatch, value):
        _no_real_keys(monkeypatch)
        monkeypatch.setenv("SOULBAH_ENV", "dev")
        monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-should-be-ignored")
        monkeypatch.setenv("LLM_FAKE_PROVIDER", value)
        provs = registry.build_providers()
        assert list(provs) == ["fake"]
        desc = provs["fake"].describe()
        assert desc["family"] == "fake" and desc["supports_vision"] is True and desc["supports_json_schema"] is True

    def test_warning_in_dev_and_test(self, monkeypatch):
        monkeypatch.setenv("LLM_FAKE_PROVIDER", "1")
        for env in ("dev", "test"):
            monkeypatch.setenv("SOULBAH_ENV", env)
            assert any("LLM_FAKE_PROVIDER" in w for w in config.check_startup_config())

    @pytest.mark.parametrize("env", ["staging", "production"])
    def test_refused_outside_dev_test(self, monkeypatch, env):
        _no_real_keys(monkeypatch)
        monkeypatch.setenv("SOULBAH_ENV", env)
        monkeypatch.setenv("IA_SERVICE_TOKEN", "t")
        monkeypatch.setenv("LLM_FAKE_PROVIDER", "1")
        with pytest.raises(RuntimeError, match="LLM_FAKE_PROVIDER"):
            config.check_startup_config()
        with pytest.raises(RuntimeError, match="LLM_FAKE_PROVIDER"):
            registry.build_providers()

    def test_zero_is_disabled(self, monkeypatch):
        _no_real_keys(monkeypatch)
        monkeypatch.setenv("LLM_FAKE_PROVIDER", "0")
        assert registry.build_providers() == {}


class TestEndToEnd:
    def test_plan_endpoint_with_scripted_fake(self, client, use_providers):
        fake = FakeProvider("fake", script=[json.dumps({
            "understanding": "attendre une seconde", "feasible": True,
            "steps": [{"type": "wait", "seconds": 1, "note": "test"}],
        })])
        use_providers({"fake": fake})
        r = client.post("/agent/plan", json={"goal": "attends une seconde"})
        assert r.status_code == 200, r.text
        plan = r.json()["plan"]
        assert plan["feasible"] is True and plan["steps"][0]["type"] == "wait"
        assert len(fake.calls) == 1

    def test_plan_endpoint_default_reply_is_not_feasible(self, client, use_providers):
        use_providers({"fake": FakeProvider("fake")})
        r = client.post("/agent/plan", json={"goal": "n'importe quoi"})
        assert r.status_code == 200, r.text
        plan = r.json()["plan"]
        assert plan["feasible"] is False and plan["steps"] == []

    def test_providers_endpoint_lists_fake(self, client, use_providers):
        use_providers({"fake": FakeProvider("fake", vision=True)})
        r = client.get("/providers")
        assert r.status_code == 200
        assert r.json()["configured"] == ["fake"] and r.json()["default"] == "fake"
