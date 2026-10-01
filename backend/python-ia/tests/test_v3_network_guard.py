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
