"""V3 LOT 6 — Resource Manager côté modèle : politique mémoire commune, file d'inférence des
serveurs locaux (capacité, priorité, occupation réelle du serveur, attente bornée, repli),
temps de file non imputé au délai de l'appel, GET /v2/resources.

V3 LOT 4 — planificateur multi-agents compact pour un modèle local (rôles et outils pertinents,
DAG contraint par schéma)."""
from __future__ import annotations

import asyncio
import json
import pathlib
import time

import pytest

from app import compact_planner as CP
from app import config, inference_gate, reasoning, soulbah_resources as R
from app.providers import orchestrator
from app.providers.base import LLMError
from app.providers.fake import FakeProvider

ROOT = pathlib.Path(__file__).resolve().parents[3]


@pytest.fixture(autouse=True)
def _clean_gates():
    inference_gate.gates.reset()
    yield
    inference_gate.gates.reset()
    orchestrator.set_providers(None)


# --- politique commune -----------------------------------------------------------------------------
def test_shared_copy_is_identical():
    src = (ROOT / "shared" / "config" / "soulbah_resources.py").read_bytes()
    assert (ROOT / "backend" / "python-ia" / "app" / "soulbah_resources.py").read_bytes() == src, \
        "copie modifiée : python scripts/sync_shared.py"


def test_worker_slots_follow_free_memory():
    pol = R.ResourcePolicy(reserve_mb=400, critical_mb=200, worker_mb=150)
    assert R.worker_slots_allowed(2000, 0, 6, pol) == 6           # (2000-400)/150 = 10 → plafonné à 6
    assert R.worker_slots_allowed(1000, 0, 6, pol) == 4           # (1000-400)/150 = 4
    assert R.worker_slots_allowed(1000, 5, 6, pol) == 1           # slots libres
    assert R.worker_slots_allowed(450, 2, 6, pol) == 0            # budget nul, d'autres tournent
    assert R.worker_slots_allowed(450, 0, 6, pol) == 1            # garantie de progression
    assert R.worker_slots_allowed(150, 0, 6, pol) == 0            # critique : jamais
    assert R.worker_slots_allowed(None, 2, 6, pol) == 4           # mémoire inconnue : slots seuls
    assert R.pressure(150, pol) == "critical" and R.pressure(500, pol) == "high" and R.pressure(3000, pol) == "ok"
    assert R.inference_capacity(2, 3000, pol) == 2 and R.inference_capacity(2, 100, pol) == 1
    assert R.inference_capacity(None, None, pol) == 1


def test_memory_reading_is_real():
    mem = R.memory()
    assert mem["total_mb"] and mem["total_mb"] > 256
    assert mem["free_mb"] is not None and 0 <= mem["free_mb"] <= mem["total_mb"]


# --- file d'inférence ------------------------------------------------------------------------------
def test_priority_order_interactive_then_agents_then_background():
    gate = inference_gate.Gate("t", None, probe=False)
    order: list[str] = []

    async def scenario():
        await gate.acquire("automation", 5)  # place occupée

        async def one(task):
            await gate.acquire(task, 5)
            order.append(task)
            await asyncio.sleep(0.01)
            gate.release()

        jobs = [asyncio.create_task(one(t)) for t in ("code", "evaluation", "chat")]
        await asyncio.sleep(0.1)
        assert gate.waiting() == 3 and gate.snapshot()["active"] == 1
        gate.release()
        await asyncio.gather(*jobs)

    asyncio.run(scenario())
    assert order == ["chat", "evaluation", "code"]
    snap = gate.snapshot()
    assert snap["served"] == 4 and snap["max_waiting"] == 3 and snap["max_active"] == 1 and snap["active"] == 0


def test_busy_gate_rejects_after_timeout_and_cleans_queue():
    gate = inference_gate.Gate("t", None, probe=False)

    async def scenario():
        await gate.acquire("automation", 5)
        with pytest.raises(inference_gate.GateBusy) as exc:
            await gate.acquire("evaluation", 0.3)
        assert "occupé" in str(exc.value) and exc.value.snapshot["active"] == 1
        assert gate.waiting() == 0
        gate.release()
        assert await gate.acquire("evaluation", 1) == 0.0

    asyncio.run(scenario())
    assert gate.snapshot()["rejected_busy"] == 1


def test_external_load_on_server_is_respected(monkeypatch):
    """Le chat de node-api appelle llama-server directement : la file attend un slot inoccupé."""
    state = {"slots": [{"id": 0, "is_processing": True}, {"id": 1, "is_processing": True}]}

    def fake_get(url):
        if url.endswith("/props"):
            return {"total_slots": 2}
        return state["slots"]

    monkeypatch.setattr(inference_gate, "_get_json", fake_get)
    gate = inference_gate.Gate("srv", "http://127.0.0.1:8091/v1", probe=True)

    async def scenario():
        task = asyncio.create_task(gate.acquire("automation", 5))
        await asyncio.sleep(0.8)
        assert not task.done() and gate.waiting() == 1  # deux slots occupés par d'autres clients
        state["slots"] = [{"id": 0, "is_processing": False}, {"id": 1, "is_processing": True}]
        waited = await task
        assert waited >= 0.7

    asyncio.run(scenario())
    assert gate.capacity(free_mb=4000) == 2
    assert gate.capacity(free_mb=50) == 1  # mémoire critique : une seule inférence


def test_router_serialises_local_inferences_and_counts_queue(monkeypatch):
    live = {"now": 0, "max": 0}

    class Tracking(FakeProvider):
        async def generate(self, *a, **kw):
            live["now"] += 1
            live["max"] = max(live["max"], live["now"])
            try:
                return await super().generate(*a, **kw)
            finally:
                live["now"] -= 1

    local = Tracking("local", "qwen", delay=0.2, family="local")
    orchestrator.set_providers({"local": local})

    async def six_agents():
        return await asyncio.gather(*[
            orchestrator.generate("automation", "s", [{"role": "user", "content": f"agent {i}"}], 50)
            for i in range(6)])

    results = asyncio.run(six_agents())
    assert len(results) == 6 and all(r.provider == "local" for r in results)
    assert live["max"] == 1  # 6 agents logiques, 1 inférence à la fois (1 slot)
    snap = inference_gate.gates.snapshot()[0]
    assert snap["served"] == 6 and snap["max_waiting"] == 5 and snap["max_active"] == 1
    assert snap["wait_s"]["max"] >= 0.8


def test_queue_wait_does_not_consume_the_model_call_timeout(monkeypatch):
    """Délai par appel 1 s, appel de 0,6 s : la 2e requête attend 0,6 s en file puis dispose
    encore de son délai complet (l'attente ne compte que pour l'échéance globale)."""
    monkeypatch.setenv("LLM_TIMEOUT_S", "1")
    monkeypatch.setenv("LLM_BUDGET_S", "20")
    local = FakeProvider("local", "qwen", delay=0.6, family="local")
    orchestrator.set_providers({"local": local})

    async def two():
        return await asyncio.gather(*[
            orchestrator.generate("automation", "s", [{"role": "user", "content": "x"}], 10) for _ in range(2)])

    assert len(asyncio.run(two())) == 2


def test_local_busy_falls_back_to_next_hop(monkeypatch):
    config.settings_resolution.cache_clear()
    monkeypatch.setattr(inference_gate.InferenceGates, "queue_max_s", lambda self: 0.3)
    local = FakeProvider("local", "qwen", delay=1.0, family="local")
    small = FakeProvider("local_small", "tiny", family="local", script=["réponse du petit modèle"])
    orchestrator.set_providers({"local": local, "local_small": small})

    async def scenario():
        first = asyncio.create_task(orchestrator.generate("automation", "s", [{"role": "user", "content": "a"}], 10))
        await asyncio.sleep(0.05)
        second = await orchestrator.generate("automation", "s", [{"role": "user", "content": "b"}], 10)
        return await first, second

    first, second = asyncio.run(scenario())
    assert first.provider == "local"
    assert second.provider == "local_small" and second.fallback_from == ["local"]
    snaps = {s["key"]: s for s in inference_gate.gates.snapshot()}
    assert snaps["local"]["rejected_busy"] == 1


def test_local_busy_without_fallback_is_a_clear_503(monkeypatch):
    monkeypatch.setattr(inference_gate.InferenceGates, "queue_max_s", lambda self: 0.3)
    orchestrator.set_providers({"local": FakeProvider("local", "qwen", delay=1.0, family="local")})

    async def scenario():
        first = asyncio.create_task(orchestrator.generate("automation", "s", [{"role": "user", "content": "a"}], 10))
        await asyncio.sleep(0.05)
        with pytest.raises(LLMError) as exc:
            await orchestrator.generate("evaluation", "s", [{"role": "user", "content": "b"}], 10)
        await first
        return exc.value

    err = asyncio.run(scenario())
    assert err.status == 503 and err.kind == "local_busy" and "en attente" in str(err)


def test_cloud_providers_never_go_through_the_gate():
    assert inference_gate.gates.gate_for(FakeProvider("anthropic", "claude")) is None
    gate = inference_gate.gates.gate_for(FakeProvider("local", "qwen", family="local"))
    assert gate is not None and gate.probe is False


def test_resources_endpoint(client, monkeypatch):
    orchestrator.set_providers({"local": FakeProvider("local", "qwen", family="local")})
    r = client.get("/v2/resources")
    assert r.status_code == 200
    body = r.json()
    assert body["memory"]["total_mb"] and body["memory"]["pressure"] in ("ok", "high", "critical")
    assert body["memory"]["policy"]["reserve_mb"] >= body["memory"]["policy"]["critical_mb"]
    assert [g["key"] for g in body["inference"]] == ["local"]
    assert body["inference"][0]["capacity"] == 1 and body["inference"][0]["waiting"] == 0


# --- V3 LOT 4 : DAG multi-agents compact -----------------------------------------------------------
ROLES = [
    {"name": "desktop_operator", "description": "Pilote le bureau Windows.", "executor": "runtime",
     "max_security_level": "L2", "tools": ["screenshot", "open_app", "wait", "type_text", "ui_snapshot", "list_dir"]},
    {"name": "coder", "description": "Écrit des fichiers et lance des commandes.", "executor": "runtime",
     "max_security_level": "L2", "tools": ["run_command", "read_file", "list_dir", "write_file", "make_dir", "wait"]},
    {"name": "qa_reviewer", "description": "Relit le travail.", "executor": "p1", "max_security_level": "L0", "tools": []},
]


def test_compact_dag_prompt_lists_relevant_role_tools_only():
    system, schema = CP.dag_system(reasoning._CATALOG, "Crée trois fichiers rapport1.txt, rapport2.txt et rapport3.txt",
                                   ROLES, ["C:\\w"], "L2")
    assert len(system) < 4000
    assert "write_file" in system and "phone_tap" not in system and "git_merge" not in system
    variants = {v["properties"]["role"]["const"]: v for v in schema["properties"]["nodes"]["items"]["anyOf"]}
    assert set(variants) <= {"desktop_operator", "coder"} and "coder" in variants  # jamais un rôle du serveur
    node = variants["coder"]
    assert node["properties"]["security_level"]["enum"] == ["L0", "L1", "L2"]
    tools = {v["properties"]["type"]["const"] for v in node["properties"]["steps"]["items"]["anyOf"]}
    assert "write_file" in tools and tools <= set(ROLES[1]["tools"])  # outils DU rôle seulement
    if "desktop_operator" in variants:
        own = {v["properties"]["type"]["const"] for v in variants["desktop_operator"]["properties"]["steps"]["items"]["anyOf"]}
        assert "write_file" not in own
    steps = node["properties"]["steps"]
    assert steps["maxItems"] == CP.DAG_MAX_STEPS
    assert all("note" not in v["properties"] for v in steps["items"]["anyOf"])  # moins de jetons à générer
    crit = {v["properties"]["type"]["const"] for v in node["properties"]["acceptance_criteria"]["items"]["anyOf"]}
    assert {"file_exists", "file_contains", "llm_rubric"} <= crit
    assert schema["properties"]["nodes"]["maxItems"] == CP.DAG_MAX_NODES


def test_propose_uses_the_compact_dag_with_a_local_model(client, monkeypatch):
    seen = {}

    async def fake_generate(task, system, messages, max_tokens, json_schema=None, **kw):
        seen.update(task=task, system=system, schema=json_schema, max_tokens=max_tokens, timeout_s=kw.get("timeout_s"))
        plan = {"understanding": "trois fichiers", "feasible": True, "reason": "",
                "nodes": [{"key": f"f{i}", "title": f"fichier {i}", "role": "coder", "security_level": "L1",
                           "steps": [{"type": "write_file", "path": f"C:\\w\\r{i}.txt", "content": "x", "note": "écrire"}],
                           "acceptance_criteria": [{"type": "file_exists", "path": f"C:\\w\\r{i}.txt"}]} for i in range(3)],
                "edges": []}
        from types import SimpleNamespace
        return SimpleNamespace(text=json.dumps(plan), usage=lambda: {"provider": "local"})

    from app.v2 import planner as v2planner
    monkeypatch.setattr(v2planner, "_local_first", lambda task, vision=False: True)
    monkeypatch.setattr(v2planner.orchestrator, "generate", fake_generate)
    r = client.post("/v2/planner/propose", json={"goal": "Crée trois fichiers rapport", "roles": ROLES,
                                                 "allowed_dirs": ["C:\\w"], "max_security_level": "L2"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["feasible"] is True and len(body["plan"]["nodes"]) == 3 and body["plan"]["edges"] == []
    assert body["plan"]["nodes"][0]["spec"]["steps"][0]["type"] == "write_file"
    assert seen["max_tokens"] == CP.DAG_MAX_TOKENS and len(seen["system"]) < 4000
    assert "SKILLS" not in seen["system"] and seen["schema"]["properties"]["nodes"]["maxItems"] == CP.DAG_MAX_NODES
    assert seen["timeout_s"] == CP.DAG_TIMEOUT_S  # délai long : plusieurs minutes sur CPU
    assert "feasible" not in seen["schema"]["properties"]
    assert list(seen["schema"]["properties"])[:3] == ["understanding", "nodes", "edges"]  # planifier d'abord


def test_call_timeout_can_be_extended_for_slow_local_plans(monkeypatch):
    """Délai ordinaire 1 s, appel de 1,5 s : refusé (504) sans prolongation, accepté avec timeout_s=3."""
    monkeypatch.setenv("LLM_TIMEOUT_S", "1")
    monkeypatch.setenv("LLM_BUDGET_S", "1.2")
    orchestrator.set_providers({"local": FakeProvider("local", "qwen", delay=1.5, family="local")})
    with pytest.raises(LLMError) as exc:
        asyncio.run(orchestrator.generate("automation", "s", [{"role": "user", "content": "x"}], 10))
    assert exc.value.status == 504
    res = asyncio.run(orchestrator.generate("automation", "s", [{"role": "user", "content": "x"}], 10, timeout_s=3))
    assert res.provider == "local"


def test_local_dag_feasibility_comes_from_the_nodes(client, monkeypatch):
    """Modèle local : plan vide = irréalisable (avec la raison) ; sinon le plan part en validation."""
    from types import SimpleNamespace
    from app.v2 import planner as v2planner

    replies = [{"understanding": "x", "nodes": [], "edges": [], "reason": "aucun outil ne convient"}]

    async def fake_generate(*_a, **_kw):
        return SimpleNamespace(text=json.dumps(replies.pop(0)), usage=lambda: {})

    monkeypatch.setattr(v2planner, "_local_first", lambda task, vision=False: True)
    monkeypatch.setattr(v2planner.orchestrator, "generate", fake_generate)
    r = client.post("/v2/planner/propose", json={"goal": "Pilote un avion", "roles": ROLES, "allowed_dirs": ["C:\\w"]})
    assert r.status_code == 200 and r.json()["feasible"] is False and r.json()["reason"] == "aucun outil ne convient"


def test_duplicate_node_keys_are_renamed_only_when_no_edge_cites_them():
    from app.v2.planner import sanitize_plan

    raw = {"nodes": [{"key": "desktop_operator", "role": "coder"}, {"key": "desktop_operator", "role": "coder"},
                     {"key": "x", "role": "coder"}, {"key": "x", "role": "coder"}],
           "edges": [{"from": "x", "to": "x"}]}
    keys = [n["key"] for n in sanitize_plan(raw)["nodes"]]
    assert keys == ["desktop_operator", "desktop_operator_2", "x", "x"]  # « x » cité par une arête : intact
