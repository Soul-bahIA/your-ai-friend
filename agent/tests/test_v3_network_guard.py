"""V3 — NetworkGuard : en mode OFFLINE, les connexions vers Internet sont REFUSÉES techniquement.

Preuves sans dépendre d'Internet : la garde refuse AVANT toute résolution DNS, donc un hôte
d'Internet n'est jamais contacté ; les connexions locales (serveur de test sur 127.0.0.1)
continuent de fonctionner. Processus séparés : Python de l'agent, Python enfant (sitecustomize),
Node enfant (NODE_OPTIONS --require), et run_tree de l'agent.
"""
from __future__ import annotations

import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import threading

import pytest

import network_guard
import soulbah_settings as S
from skills.proctree import run_tree

ROOT = pathlib.Path(__file__).resolve().parents[2]
AGENT = ROOT / "agent"
CASES = json.loads((ROOT / "shared" / "config" / "network_guard_cases.json").read_text(encoding="utf-8"))
HYBRID = S.resolve({})["settings"]


def offline(allow: str = "") -> dict:
    env = {"SOULBAH_MODE": "OFFLINE"}
    if allow:
        env["SOULBAH_NETWORK_ALLOW_HOSTS"] = allow
    return S.resolve(env)["settings"]


@pytest.fixture()
def guard_offline():
    """Garde OFFLINE dans le processus de test, toujours remise en HYBRID ensuite."""
    network_guard._reset_for_tests()
    network_guard.install(offline())
    yield
    network_guard.install(HYBRID)
    network_guard._reset_for_tests()
    network_guard.install(HYBRID)


@pytest.fixture()
def local_server():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(5)
    port = srv.getsockname()[1]
    stop = threading.Event()

    def serve():
        srv.settimeout(0.2)
        while not stop.is_set():
            try:
                c, _ = srv.accept()
                c.sendall(b"ok")
                c.close()
            except OSError:
                continue

    t = threading.Thread(target=serve, daemon=True)
    t.start()
    yield port
    stop.set()
    srv.close()


def test_copies_identical_to_source():
    src = (ROOT / "shared" / "config" / "network_guard.py").read_bytes()
    assert (AGENT / "network_guard.py").read_bytes() == src
    assert (AGENT / "guard_site" / "network_guard.py").read_bytes() == src
    for name in ("sitecustomize.py", "network_guard_child.cjs"):
        assert (AGENT / "guard_site" / name).read_bytes() == (ROOT / "shared" / "config" / "guard_site" / name).read_bytes()
    assert (AGENT / "guard_site" / "soulbah_settings.py").read_bytes() == (ROOT / "shared" / "config" / "soulbah_settings.py").read_bytes()


@pytest.mark.parametrize("host,allowed", sorted(CASES["offline"]["expect"].items()))
def test_common_cases_offline(host, allowed):
    s = offline(",".join(CASES["offline"]["allow_hosts"]))
    assert (network_guard.refusal(s, host) is None) is allowed, host


def test_common_cases_other_modes():
    for key, mode in (("hybrid", "HYBRID"), ("local_internet", "LOCAL_INTERNET")):
        s = S.resolve({"SOULBAH_MODE": mode})["settings"]
        for host, allowed in CASES[key]["expect"].items():
            assert (network_guard.refusal(s, host) is None) is allowed, (mode, host)


def test_in_process_dns_and_connect_refused_local_allowed(guard_offline, local_server):
    with pytest.raises(network_guard.NetworkGuardError, match="example.com"):
        socket.getaddrinfo("example.com", 443)
    with pytest.raises(network_guard.NetworkGuardError, match="1.1.1.1"):
        socket.create_connection(("1.1.1.1", 80), timeout=2)
    with socket.create_connection(("127.0.0.1", local_server), timeout=2) as c:
        assert c.recv(2) == b"ok"
    st = network_guard.status()
    assert st["active"] and st["blocked"] == 2 and {r["host"] for r in st["recent"]} == {"example.com", "1.1.1.1"}


def test_libraries_are_covered(guard_offline):
    import requests

    with pytest.raises(requests.exceptions.ConnectionError) as e:
        requests.get("https://example.com/", timeout=2)
    assert "NetworkGuard" in repr(e.value)


def test_hybrid_never_blocks():
    network_guard._reset_for_tests()
    network_guard.install(HYBRID)
    assert network_guard.refusal(network_guard._state["settings"], "example.com") is None
    assert network_guard.child_env() is None and not network_guard.status()["active"]


def test_separate_agent_process_offline(local_server):
    """Un processus Python de Soulbah démarré en OFFLINE : refus réel, local permis."""
    code = (
        "import json, socket, soulbah_settings as S, network_guard as G\n"
        "G.install(S.resolve({'SOULBAH_MODE': 'OFFLINE'})['settings'])\n"
        "out = {}\n"
        "try:\n    socket.getaddrinfo('api.anthropic.com', 443); out['dns'] = 'passé'\n"
        "except G.NetworkGuardError as e:\n    out['dns'] = 'refusé'\n"
        f"c = socket.create_connection(('127.0.0.1', {local_server}), timeout=2); out['local'] = c.recv(2).decode(); c.close()\n"
        "print(json.dumps(out))\n"
    )
    r = subprocess.run([sys.executable, "-c", code], cwd=str(AGENT), capture_output=True, text=True, timeout=60,
                       env={**os.environ, "PYTHONPATH": str(AGENT)})
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout.strip().splitlines()[-1]) == {"dns": "refusé", "local": "ok"}


def test_child_processes_inherit_the_guard(guard_offline, local_server):
    """run_tree (toutes les commandes des skills) : Python enfant via sitecustomize."""
    env = network_guard.child_env()
    assert env and env["HTTPS_PROXY"] == network_guard.BLACKHOLE_PROXY and "guard_site" in env["PYTHONPATH"]
    assert "network_guard_child.cjs" in env["NODE_OPTIONS"]
    blocked = run_tree([sys.executable, "-c", "import socket; socket.getaddrinfo('example.com', 80)"],
                       cwd=str(AGENT), timeout=60)
    assert blocked.returncode != 0 and "NetworkGuard" in blocked.stderr
    allowed = run_tree([sys.executable, "-c", f"import socket; c = socket.create_connection(('127.0.0.1', {local_server})); print(c.recv(2).decode())"],
                       cwd=str(AGENT), timeout=60)
    assert allowed.returncode == 0 and allowed.stdout.strip() == "ok", allowed.stderr


@pytest.mark.skipif(shutil.which("node") is None, reason="node absent")
def test_node_child_inherits_the_guard(guard_offline, local_server):
    script = (
        "const net = require('net');"
        "const a = net.connect({host: 'example.com', port: 80});"
        "a.on('error', e => {"
        f"  const b = net.connect({{host: '127.0.0.1', port: {local_server}}});"
        "  b.on('data', d => { console.log(e.code + ' ' + d.toString()); b.end(); });"
        "  b.on('error', e2 => { console.log(e.code + ' local:' + e2.code); });"
        "});"
        "a.on('connect', () => { console.log('passé'); a.end(); });"
    )
    r = run_tree([shutil.which("node"), "-e", script], cwd=str(AGENT), timeout=60)
    assert r.stdout.strip() == "ENETGUARD ok", (r.stdout, r.stderr)


@pytest.mark.skipif(shutil.which("node") is None, reason="node absent")
def test_node_child_guard_follows_common_cases():
    js = (
        "const g = require(process.argv[1]); const cases = JSON.parse(process.argv[2]);"
        "const allow = new Set(cases.offline.allow_hosts);"
        "const out = {}; for (const h of Object.keys(cases.offline.expect)) out[h] = g.refusal(h, allow) === null;"
        "console.log(JSON.stringify(out));"
    )
    r = subprocess.run([shutil.which("node"), "-e", js, str(AGENT / "guard_site" / "network_guard_child.cjs"), json.dumps(CASES)],
                       capture_output=True, text=True, timeout=60, env={k: v for k, v in os.environ.items() if k != "NODE_OPTIONS"})
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout) == CASES["offline"]["expect"]


def test_agent_refuses_offline_with_remote_control_plane(monkeypatch, tmp_path):
    import soulbah_agent
    from config import Config

    monkeypatch.setenv("SOULBAH_MODE", "OFFLINE")
    try:
        remote = Config(api_url="https://soulbah.exemple.com", agent_key="k", allowed_dirs=[str(tmp_path)])
        assert soulbah_agent.build_executor(remote) == (None, 2)
        local = Config(api_url="http://127.0.0.1:3000", agent_key="k", allowed_dirs=[str(tmp_path)])
        executor, code = soulbah_agent.build_executor(local)
        assert code == 0 and network_guard.status()["active"]
    finally:
        network_guard.install(HYBRID)
