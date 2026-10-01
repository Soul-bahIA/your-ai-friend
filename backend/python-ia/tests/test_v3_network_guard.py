"""V3 — NetworkGuard dans python-ia : installé au démarrage, exposé par /v2/models, règle commune."""
from __future__ import annotations

import json
import pathlib
import socket

import pytest

from app import network_guard, soulbah_settings

ROOT = pathlib.Path(__file__).resolve().parents[3]
CASES = json.loads((ROOT / "shared" / "config" / "network_guard_cases.json").read_text(encoding="utf-8"))
HYBRID = soulbah_settings.resolve({})["settings"]


def test_copy_identical_to_source():
    assert (ROOT / "backend" / "python-ia" / "app" / "network_guard.py").read_bytes() == \
        (ROOT / "shared" / "config" / "network_guard.py").read_bytes()


def test_common_cases():
    s = soulbah_settings.resolve({"SOULBAH_MODE": "OFFLINE",
                                  "SOULBAH_NETWORK_ALLOW_HOSTS": ",".join(CASES["offline"]["allow_hosts"])})["settings"]
    got = {h: network_guard.refusal(s, h) is None for h in CASES["offline"]["expect"]}
    assert got == CASES["offline"]["expect"]


def test_lifespan_installs_guard_and_status_exposes_it(client):
    st = network_guard.status()
    assert st["installed"] and st["mode"] == "HYBRID" and not st["active"]
    body = client.get("/v2/models").json()
    assert body["network_guard"]["installed"] is True and "recent" not in body["network_guard"]


def test_offline_blocks_provider_hosts_before_dns():
    network_guard.install(soulbah_settings.resolve({"SOULBAH_MODE": "OFFLINE"})["settings"])
    try:
        for host in ("api.anthropic.com", "api.openai.com", "generativelanguage.googleapis.com"):
            with pytest.raises(network_guard.NetworkGuardError):
                socket.getaddrinfo(host, 443)
        assert network_guard.status()["blocked"] >= 3
    finally:
        network_guard.install(HYBRID)


def test_local_provider_sends_schema_for_constrained_json(monkeypatch):
    """V3 LOT 2 : vers llama-server (famille local), le schéma part dans response_format (grammaire) ;
    vers un fournisseur cloud compatible OpenAI, seul json_object est envoyé."""
    import asyncio

    import httpx

    from app.providers import openai_compat
    from app.providers.openai_compat import OpenAICompatProvider

    seen: list[dict] = []

    def handler(req: httpx.Request) -> httpx.Response:
        seen.append(json.loads(req.content))
        return httpx.Response(200, json={"choices": [{"message": {"content": "{\"ok\": true}"}}],
                                         "usage": {"prompt_tokens": 1, "completion_tokens": 1}})

    real = httpx.AsyncClient

    def factory(*a, **k):
        k["transport"] = httpx.MockTransport(handler)
        return real(*a, **k)

    monkeypatch.setattr(openai_compat.httpx, "AsyncClient", factory)
    schema = {"type": "object", "properties": {"ok": {"type": "boolean"}}}
    msgs = [{"role": "user", "content": "x"}]
    asyncio.run(OpenAICompatProvider("local", "http://127.0.0.1:8091/v1", "", "m", family="local")
                .generate("s", msgs, 50, json_schema=schema))
    asyncio.run(OpenAICompatProvider("openai", "http://127.0.0.1:9/v1", "k", "gpt-4o").generate("s", msgs, 50, json_schema=schema))
    assert seen[0]["response_format"] == {"type": "json_object", "schema": schema}
    assert seen[1]["response_format"] == {"type": "json_object"}
