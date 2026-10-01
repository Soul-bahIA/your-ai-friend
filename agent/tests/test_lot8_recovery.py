"""LOT 8 — critères de sortie (audit §13) avec de VRAIS processus et un faux plan de contrôle :

  - kill d'un worker → reprise sans rejouer d'étape non idempotente ;
  - étape non idempotente interrompue → QUESTION, rien n'est rejoué sans décision humaine ;
  - kill du superviseur → les workers meurent avec lui (Job Object), puis 0 doublon au
    redémarrage (aucun second bail, un seul résultat, aucune étape vérifiée rejouée).

Les étapes sont `move_file` (non idempotente, effet vérifiable sur disque) et `wait`
(idempotente), autorisées sans console en mode auto.
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from types import SimpleNamespace

import pytest

from runtime import supervisor as sup_mod
from runtime.journal import STATE_WAITING, Journal
from runtime.rtclient import RuntimeClient
from skills.proctree import kill_tree, pid_alive

from fake_control_plane import FakeControlPlane

AGENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="Job Objects : Windows uniquement")


@pytest.fixture
def rt_env(tmp_path, monkeypatch):
    ws = tmp_path / "workspace"
    ws.mkdir()
    rt = tmp_path / "runtime"
    plane = FakeControlPlane(lease_seconds=6).start()
    env = {
        "SOULBAH_API_URL": plane.url,
        "SOULBAH_AGENT_KEY": "sbk_" + "b" * 64,
        "SOULBAH_ALLOWED_DIRS": str(ws),
        "SOULBAH_PERMISSION_MODE": "auto",
        "SOULBAH_APPROVAL_MODE": "console",
        "SOULBAH_RUNTIME_DIR": str(rt),
        "SOULBAH_POLL_INTERVAL": "0.5",
        "SOULBAH_NO_DOTENV": "1",
        "PYTHONUTF8": "1",
    }
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    monkeypatch.delenv("SOULBAH_RUNTIME_LEGACY", raising=False)
    yield SimpleNamespace(plane=plane, ws=ws, rt=rt)
    plane.stop()


def make_supervisor(max_slots: int = 2) -> sup_mod.Supervisor:
    from config import load_config

    cfg = load_config()
    journal = Journal()
    s = sup_mod.Supervisor(cfg, RuntimeClient(cfg, journal), journal, max_slots, tick_s=0.2)
    assert s.handshake() == "ok"
    return s


def drive(s: sup_mod.Supervisor, until, timeout: float = 90.0) -> bool:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        s.tick()
        if until():
            return True
        time.sleep(0.2)
    return False


def wait_for(cond, timeout: float = 90.0) -> bool:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(0.2)
    return False


def test_worker_killed_resumes_without_replaying_non_idempotent_step(rt_env):
    a, b = rt_env.ws / "a.txt", rt_env.ws / "b.txt"
    a.write_text("contenu", encoding="utf-8")
    plane = rt_env.plane
    tid = plane.add_task([
        {"type": "move_file", "src": str(a), "dest": str(b)},  # non idempotente
        {"type": "wait", "seconds": 3},                       # idempotente, interrompue
        {"type": "wait", "seconds": 0.1},
    ])
    s = make_supervisor()
    try:
        s.reconcile()
        assert drive(s, lambda: plane.posted(tid, 1, "attempted") >= 1), "l'étape 1 n'a jamais démarré"
        w = s.workers[tid]
        kill_tree(w.proc, w.job)  # crash brutal du worker (pas un stop serveur)
        w.proc.wait(timeout=10)
        assert drive(s, lambda: plane.status(tid) == "COMPLETED"), "la tâche n'a pas été reprise"
    finally:
        s.shutdown()
        s.journal.close()
    assert plane.leases[tid] == 1                      # aucun second bail
    assert len(plane.results) == 1                     # un seul résultat
    assert plane.posted(tid, 0, "attempted") == 1      # move_file jamais rejoué
    assert plane.posted(tid, 0, "verified") == 1
    assert plane.posted(tid, 1, "attempted") == 2      # wait (idempotente) rejouée une fois
    assert b.exists() and not a.exists()
    steps = plane.results[0][2]["steps"]
    assert steps[0]["index"] == 0 and steps[0].get("resumed") is True


def test_interrupted_non_idempotent_step_asks_before_replay(rt_env):
    a, b = rt_env.ws / "a.txt", rt_env.ws / "b.txt"
    a.write_text("contenu", encoding="utf-8")
    plane = rt_env.plane
    tid = plane.add_task([{"type": "move_file", "src": str(a), "dest": str(b)}, {"type": "wait", "seconds": 0.1}])
    s = make_supervisor()
    try:
        # État « crash au milieu de move_file » : bail détenu, étape 0 attempted (local + serveur).
        outcome, _d, data, _st = s.client.lease(1)
        task = data["tasks"][0]
        s.journal.hold(task)
        s.journal.record_action(tid, 1, 0, "move_file", "attempted", False)
        s.client.post_action(tid, 1, 0, "move_file", {"src": str(a), "dest": str(b)}, "attempted")
        s.reconcile()
        assert tid in s.workers  # reprise lancée
        assert drive(s, lambda: tid not in s.workers and plane.status(tid) == "WAITING")
        question = [m for m in plane.messages if m[0] == tid and m[2] == "QUESTION"]
        assert len(question) == 1 and question[0][3]["step_index"] == 0
        assert s.journal.get_held(tid)["state"] == STATE_WAITING
        assert a.exists() and not b.exists()            # rien n'a été rejoué
        assert plane.posted(tid, 0, "executed") == 0
        # Sans réponse, le superviseur ne relance rien.
        s.keepalive()
        assert tid not in s.workers
        # Décision humaine « oui » : l'étape est rejouée UNE fois, puis la tâche se termine.
        plane.answer(tid, "oui")
        s.keepalive()
        assert tid in s.workers
        assert drive(s, lambda: plane.status(tid) == "COMPLETED")
    finally:
        s.shutdown()
        s.journal.close()
    assert b.exists() and not a.exists()
    assert plane.posted(tid, 0, "executed") == 1
    assert len(plane.results) == 1 and plane.leases[tid] == 1


def test_supervisor_killed_then_restarted_no_duplicate(rt_env, tmp_path):
    plane = rt_env.plane
    a, b = rt_env.ws / "a.txt", rt_env.ws / "b.txt"
    a.write_text("contenu", encoding="utf-8")
    tid = plane.add_task([
        {"type": "move_file", "src": str(a), "dest": str(b)},
        {"type": "wait", "seconds": 4},
        {"type": "wait", "seconds": 0.1},
    ])
    argv = [sys.executable, "-m", "runtime.supervisor", "--tick", "0.3"]
    log1 = open(tmp_path / "sup1.log", "w", encoding="utf-8")
    p1 = subprocess.Popen(argv, cwd=AGENT_DIR, env=dict(os.environ), stdout=log1, stderr=subprocess.STDOUT)
    try:
        assert wait_for(lambda: plane.posted(tid, 1, "attempted") >= 1), (tmp_path / "sup1.log").read_text("utf-8")
    finally:
        p1.kill()  # kill brutal du superviseur : ses handles se ferment, le Job Object tue le worker
        p1.wait(timeout=10)
        log1.close()
    # Le worker est mort avec lui : l'étape de 4 s ne se termine jamais.
    time.sleep(5.5)
    assert plane.posted(tid, 1, "executed") == 0
    assert plane.status(tid) == "RUNNING"

    log2 = open(tmp_path / "sup2.log", "w", encoding="utf-8")
    p2 = subprocess.Popen(argv, cwd=AGENT_DIR, env=dict(os.environ), stdout=log2, stderr=subprocess.STDOUT)
    try:
        assert wait_for(lambda: plane.status(tid) == "COMPLETED"), (tmp_path / "sup2.log").read_text("utf-8")
    finally:
        p2.kill()
        p2.wait(timeout=10)
        log2.close()
    assert plane.registers == 2
    assert len(plane.reconciles) >= 1 and plane.reconciles[0][0]["task_id"] == tid
    assert plane.leases[tid] == 1              # aucun second bail
    assert len(plane.results) == 1             # un seul résultat
    assert plane.posted(tid, 0, "attempted") == 1  # move_file jamais rejoué
    assert b.exists() and not a.exists()
    assert not any(pid_alive(p) for p in (p1.pid, p2.pid))
