"""LOT 8 / LOT 9 (agent) — briques du runtime V2 : journal SQLite, preuves typées, client
runtime, poignée de main (426 / 404 → legacy), garde d'instance mutuelle, arbre bloqué tué
en moins de 10 s."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from types import SimpleNamespace

import pytest

from runtime import supervisor as sup_mod
from runtime.evidence import build_evidence, looks_binary, self_report, sha256_bytes
from runtime.instance_lock import KIND_AGENT_V1, KIND_RUNTIME, InstanceLock
from runtime.journal import STATE_FINALIZING, Journal, action_transition_ok, outbox_delay
from runtime.rtclient import RuntimeClient
from skills.proctree import pid_alive, popen_in_job

from fake_control_plane import FakeControlPlane

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCHEMA = json.load(open(os.path.join(ROOT, "shared", "schemas", "evidence.schema.json"), encoding="utf-8"))


def assert_schema(evidence: list[dict]) -> None:
    """Chaque preuve respecte shared/schemas/evidence.schema.json (clés, énumérations, pas de blob)."""
    props = SCHEMA["properties"]
    for e in evidence:
        assert set(e) <= set(props), e
        assert e["kind"] in props["kind"]["enum"], e
        assert e["confidence"] in props["confidence"]["enum"], e
        if "sha256" in e:
            assert len(e["sha256"]) == 64
        if "value" in e:
            text = e["value"] if isinstance(e["value"], str) else json.dumps(e["value"])
            assert len(text) <= 4000
            assert not looks_binary(e["value"])


@pytest.fixture
def rt_env(tmp_path, monkeypatch):
    """Configuration d'un runtime de test : workspace et dossier d'état temporaires, mode auto."""
    ws = tmp_path / "workspace"
    ws.mkdir()
    rt = tmp_path / "runtime"
    plane = FakeControlPlane(lease_seconds=6).start()
    monkeypatch.setenv("SOULBAH_API_URL", plane.url)
    monkeypatch.setenv("SOULBAH_AGENT_KEY", "sbk_" + "a" * 64)
    monkeypatch.setenv("SOULBAH_ALLOWED_DIRS", str(ws))
    monkeypatch.setenv("SOULBAH_PERMISSION_MODE", "auto")
    monkeypatch.setenv("SOULBAH_APPROVAL_MODE", "console")
    monkeypatch.setenv("SOULBAH_RUNTIME_DIR", str(rt))
    monkeypatch.setenv("SOULBAH_POLL_INTERVAL", "0.5")
    monkeypatch.delenv("SOULBAH_RUNTIME_LEGACY", raising=False)
    yield SimpleNamespace(plane=plane, ws=ws, rt=rt)
    plane.stop()


# --- journal ---------------------------------------------------------------------------------
def test_journal_wal_actions_checkpoints_outbox(tmp_path):
    j = Journal(str(tmp_path / "j.db"))
    assert j.journal_mode().lower() == "wal"
    task = {"id": "t1", "attempt": 1, "lease_owner": "runtime:x", "spec": {"steps": []}}
    j.hold(task)
    assert j.get_held("t1")["attempt"] == 1
    assert j.record_action("t1", 1, 0, "wait", "planned", True)
    assert j.record_action("t1", 1, 0, "wait", "attempted", True)
    assert j.record_action("t1", 1, 0, "wait", "attempted", True)  # identique : accepté
    assert not j.record_action("t1", 1, 0, "wait", "planned", True)  # régression refusée
    assert j.record_action("t1", 1, 0, "wait", "verified", True)
    assert not j.record_action("t1", 1, 0, "wait", "failed", True)  # terminal figé
    assert [a["status"] for a in j.actions("t1", 1)] == ["verified"]
    j.checkpoint("t1", 1, 1, 1, {"k": "v"})
    assert j.last_checkpoint("t1", 1)["step_cursor"] == 1
    # outbox : due immédiatement, réclamée (plus due), backoff exponentiel au nouvel échec
    eid = j.enqueue("POST", "tasks/t1/result", {"a": 1}, kind="result", task_id="t1", attempt=1)
    now = time.time()
    claimed = j.outbox_claim_due(now)
    assert [c["id"] for c in claimed] == [eid]
    assert j.outbox_claim_due(now) == []
    next_at = j.outbox_retry(eid, now)
    assert next_at == pytest.approx(now + outbox_delay(1))
    assert outbox_delay(1) < outbox_delay(3) <= 120
    # Ordre par tâche : une écriture plus récente n'est jamais due avant une plus ancienne qui attend.
    e2 = j.enqueue("POST", "tasks/t1/result", {"b": 2}, kind="result", task_id="t1", attempt=1)
    assert j.outbox_claim_due(now) == []  # eid attend son backoff : e2 aussi
    assert [c["id"] for c in j.outbox_claim_due(next_at + 0.1)] == [eid, e2]
    j.set_state("t1", STATE_FINALIZING)
    assert j.get_held("t1")["state"] == STATE_FINALIZING
    j.purge("t1")
    assert j.get_held("t1") is None and j.outbox_count() == 0 and j.actions("t1") == []
    j.close()


def test_action_transitions_match_server_rules():
    assert action_transition_ok(None, "planned")
    assert action_transition_ok("planned", "executed")
    assert not action_transition_ok("executed", "attempted")
    assert not action_transition_ok("simulated", "verified")
    assert not action_transition_ok("planned", "inconnu")


# --- preuves (LOT 9) -------------------------------------------------------------------------
def test_evidence_typed_and_schema_compliant(tmp_path):
    ev = build_evidence("run_command", True, "ok", {"returncode": 0, "stdout": "bonjour", "stderr": ""}, step_index=2)
    assert [(e["kind"], e["confidence"]) for e in ev] == [("exit_code", "high"), ("command_output", "medium")]
    assert ev[0]["value"] == 0 and ev[0]["step_index"] == 2
    assert_schema(ev)

    secret = "contenu secret password=Hyper5ecret!"
    ev = build_evidence("read_file", True, "34 caractères lus", {"content": secret})
    assert ev[0]["kind"] == "file_content" and ev[0]["sha256"] == sha256_bytes(secret.encode())
    assert "Hyper5ecret" not in json.dumps(ev)
    assert_schema(ev)

    f = tmp_path / "out.txt"
    f.write_text("x", encoding="utf-8")
    ev = build_evidence("move_file", True, "déplacé", {"path": str(f)})
    assert [e["kind"] for e in ev] == ["file_path", "sha256"]
    assert ev[1]["sha256"] == sha256_bytes(b"x")
    assert_schema(ev)

    assert build_evidence("wait", True, "attendu 1 s", None) == []
    assert_schema(build_evidence("click", True, "clic left x1", None))
    assert_schema(self_report("reprise", 3))
    # sortie binaire : jamais transmise
    blob = "A" * 600
    ev = build_evidence("run_command", True, "ok", {"returncode": 0, "stdout": blob, "stderr": ""})
    assert all("value" not in e or e["value"] != blob for e in ev)
    assert_schema(ev)


def test_screenshot_becomes_artifact(tmp_path):
    png = tmp_path / "shot.png"
    content = b"\x89PNG\r\n\x1a\n" + os.urandom(2048)
    png.write_bytes(content)
    uploads = []

    def upload(data: bytes, mime: str, kind: str):
        uploads.append((data, mime, kind))
        return "11111111-1111-4111-8111-111111111111", sha256_bytes(data)

    ev = build_evidence("screenshot", True, "capture", {"path": str(png), "image_b64": "QUJD" * 200,
                                                         "media_type": "image/jpeg"}, step_index=0, upload=upload)
    assert len(uploads) == 1 and uploads[0][0] == content and uploads[0][1] == "image/png"
    shot = next(e for e in ev if e["kind"] == "screenshot")
    assert shot["sha256"] == sha256_bytes(content) and shot["artifact_id"].startswith("1111")
    assert "QUJD" not in json.dumps(ev)
    assert_schema(ev)
    # téléversement impossible : l'empreinte suffit (preuve toujours valide)
    ev = build_evidence("screenshot", True, "capture", {"path": str(png)}, upload=lambda *_a: None)
    assert next(e for e in ev if e["kind"] == "screenshot")["sha256"] == sha256_bytes(content)


# --- client runtime --------------------------------------------------------------------------
def test_approval_request_targets_v2_task(rt_env, monkeypatch):
    from config import load_config

    cfg = load_config()
    client = RuntimeClient(cfg, None)
    seen = {}

    def fake_request(method, url, body, timeout):
        seen.update(url=url, body=body)
        return "ok", "ok", {"id": "x"}, 201

    monkeypatch.setattr(client, "_request", fake_request)
    client.request_approval({"task_id": "abc", "attempt": 1, "tool": "type_text", "payload": {"type": "type_text"}})
    assert seen["url"].endswith("/api/v2/approvals/request")
    assert seen["body"]["v2_task_id"] == "abc" and "task_id" not in seen["body"]


def test_put_artifact_against_fake_plane(rt_env):
    from config import load_config

    client = RuntimeClient(load_config(), None)
    out = client.put_artifact(b"hello", "image/png", "screenshot", task_id="t")
    assert out is not None and out[1] == sha256_bytes(b"hello")
    assert rt_env.plane.artifacts[out[1]] == b"hello"


# --- poignée de main -------------------------------------------------------------------------
def _supervisor(max_slots: int = 2) -> sup_mod.Supervisor:
    from config import load_config

    cfg = load_config()
    journal = Journal()
    return sup_mod.Supervisor(cfg, RuntimeClient(cfg, journal), journal, max_slots, tick_s=0.2)


def test_handshake_upgrade_required_exits_4(rt_env):
    rt_env.plane.register_status = 426
    s = _supervisor()
    assert s.handshake() == "upgrade"
    assert s.run() == sup_mod.EXIT_UPGRADE
    assert sup_mod.main([]) == sup_mod.EXIT_UPGRADE


def test_handshake_404_switches_to_legacy(rt_env, monkeypatch):
    rt_env.plane.register_status = 404
    s = _supervisor()
    assert s.run() == sup_mod.RUN_LEGACY
    calls = []
    monkeypatch.setattr(sup_mod.legacy_adapter, "run", lambda cfg, executor: calls.append(cfg) or 0)
    assert sup_mod.main([]) == 0 and len(calls) == 1
    # SOULBAH_RUNTIME_LEGACY=1 : boucle V1 sans même s'enregistrer
    rt_env.plane.registers = 0
    monkeypatch.setenv("SOULBAH_RUNTIME_LEGACY", "1")
    assert sup_mod.main([]) == 0 and len(calls) == 2 and rt_env.plane.registers == 0


def test_handshake_ok_registers_runtime(rt_env):
    s = _supervisor(3)
    assert s.handshake() == "ok"
    assert s.client.runtime_id == rt_env.plane.runtime_id
    assert s.lease_seconds == 6


# --- garde d'instance mutuelle (§14) ---------------------------------------------------------
def test_single_instance_guard_is_mutual(rt_env):
    holder = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    try:
        os.makedirs(rt_env.rt, exist_ok=True)
        with open(os.path.join(rt_env.rt, "instance.lock"), "w", encoding="utf-8") as f:
            json.dump({"pid": holder.pid, "kind": KIND_AGENT_V1, "started_at": time.time()}, f)
        assert sup_mod.main([]) == sup_mod.EXIT_LOCKED  # le runtime refuse si l'agent V1 tourne
        ok, info = InstanceLock(KIND_RUNTIME, str(rt_env.rt)).acquire()
        assert not ok and info["pid"] == holder.pid

        import soulbah_agent
        from config import load_config

        with open(os.path.join(rt_env.rt, "instance.lock"), "w", encoding="utf-8") as f:
            json.dump({"pid": holder.pid, "kind": KIND_RUNTIME, "started_at": time.time()}, f)
        executor, _ = soulbah_agent.build_executor(load_config())
        assert soulbah_agent._serve(load_config(), executor, once=True) == 5  # et l'agent V1 refuse si le runtime tourne
    finally:
        holder.kill()
        holder.wait()
    # détenteur mort : verrou périmé, repris
    lock = InstanceLock(KIND_RUNTIME, str(rt_env.rt))
    assert lock.acquire()[0]
    lock.release()
    assert not os.path.exists(lock.path)


# --- arbre bloqué tué en < 10 s ---------------------------------------------------------------
def test_blocked_tree_killed_under_10s(tmp_path):
    pids = tmp_path / "pids.txt"
    code = (
        "import subprocess, sys, time\n"
        "g = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(300)'])\n"
        f"open(r'{pids}', 'w').write(f'{{__import__(\"os\").getpid()}} {{g.pid}}')\n"
        "time.sleep(300)\n"
    )
    proc, job = popen_in_job([sys.executable, "-c", code], None, use_job=True, breakaway_ok=True)
    deadline = time.monotonic() + 30
    while not (pids.exists() and pids.read_text().strip()) and time.monotonic() < deadline:
        time.sleep(0.1)
    child, grandchild = (int(x) for x in pids.read_text().split())
    assert pid_alive(child) and pid_alive(grandchild)
    log_handle = open(tmp_path / "w.log", "w", encoding="utf-8")
    w = sup_mod.WorkerHandle("t" * 8, 1, proc, job, time.time(), str(tmp_path / "stop"), log_handle)
    s = sup_mod.Supervisor(SimpleNamespace(step_timeout=900, poll_interval=1), SimpleNamespace(), SimpleNamespace(), 1)
    t0 = time.monotonic()
    s.kill(w, "test : arbre bloqué")
    s._close(w)
    while (pid_alive(child) or pid_alive(grandchild)) and time.monotonic() - t0 < 10:
        time.sleep(0.05)
    elapsed = time.monotonic() - t0
    assert not pid_alive(child) and not pid_alive(grandchild)
    assert elapsed < 10
