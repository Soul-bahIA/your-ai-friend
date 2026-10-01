"""LOT 1 — cycle des tâches : stop → cancelled (T4), plan vide (T5), double exécution
(T9, scénarios sim (a) et (b)), dry-run local (T10), pause (T39), Ctrl+C (T40),
clé révoquée (T41), heartbeat joint (T51), 410 (S9 / contrat §3), évènements
d'approbation (S22 / §13) et masquage (S8 / §12).

Aucune action réelle : skills factices, faux serveur reproduisant les gardes CAS
de node (status + requeue_count) et la remise en file des tâches muettes > 180 s."""
from __future__ import annotations

import json
import threading
import time

import pytest

import executor as ex
import pending as pending_mod
import permissions
import soulbah_agent
from client import AUTH, CONFLICT, GONE, OK, REJECTED, RETRY
from config import Config
from executor import Executor
from pending import PendingUpdates
from permissions import PermissionGate
from skills import REGISTRY
from skills.base import Skill, SkillResult, sleep_or_cancel

EXECUTIONS = {"n": 0}


class _CountSkill(Skill):
    """Compte les exécutions RÉELLES et produit un artefact."""
    name = "count_test"
    step_types = ("count_test",)
    category = "generic"
    sensitive = False

    def run(self, step):
        EXECUTIONS["n"] += 1
        return SkillResult(ok=True, detail="exécuté", data={"path": "C:/ws/out.mp4"})


class _WaitSkill(Skill):
    name = "wait_test"
    step_types = ("wait_test",)
    category = "generic"
    sensitive = False

    def run(self, step):
        if not sleep_or_cancel(float(step.get("seconds", 30))):
            return SkillResult(ok=False, detail="interrompu")
        return SkillResult(ok=True, detail="fini")


class _SensitiveSkill(_CountSkill):
    name = "sensitive_test"
    step_types = ("sensitive_test",)
    category = "filesystem"
    sensitive = True

    def describe(self, step):
        return "action sensible de test"


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    REGISTRY["count_test"] = _CountSkill()
    REGISTRY["wait_test"] = _WaitSkill()
    REGISTRY["sensitive_test"] = _SensitiveSkill()
    EXECUTIONS["n"] = 0
    monkeypatch.setattr(soulbah_agent, "_running", True)
    monkeypatch.setattr(soulbah_agent, "_interrupts", 0)
    monkeypatch.setattr(soulbah_agent, "_current_token", None)
    monkeypatch.setattr(pending_mod, "_BASE_DELAY", 0.0)
    monkeypatch.setattr(pending_mod, "_MAX_DELAY", 0.0)
    monkeypatch.setattr(pending_mod, "KEEPALIVE_SECONDS", 0.0)
    yield
    for k in ("count_test", "wait_test", "sensitive_test"):
        REGISTRY.pop(k, None)


class FakeServer:
    """Contrat node simulé : claim gardé par status='pending' AND requeue_count=attempt ;
    update/event gardés par status='in_progress' AND requeue_count=attempt ;
    poll : remise en file des tâches in_progress muettes depuis > 180 s (3 fois max)."""

    def __init__(self):
        self.tasks: dict[str, dict] = {}
        self.now = 0.0
        self.updates_down = False
        self.reject_full_results = False
        self.reject_all_finals = False
        self.polls = 0
        self.claims: list = []
        self.updates: list = []
        self.events: list = []
        self.last_error = None
        self.last_status = None
        self.last_detail = None

    def add(self, task_id, steps, **payload):
        self.tasks[task_id] = {"status": "pending", "requeue_count": 0, "updated_at": self.now,
                               "payload": {"steps": steps, **payload}, "control": "none", "result": None}

    def requeue_stale(self, stale=180.0):
        for t in self.tasks.values():
            if t["status"] == "in_progress" and self.now - t["updated_at"] > stale:
                if t["requeue_count"] >= 3:
                    t["status"] = "failed"
                else:
                    t["status"] = "pending"
                    t["requeue_count"] += 1

    # --- API du client ---
    def poll(self):
        self.polls += 1
        self.requeue_stale()
        return [{"id": i, "task_type": "test", "payload": t["payload"], "requeue_count": t["requeue_count"]}
                for i, t in self.tasks.items() if t["status"] == "pending"]

    def claim(self, task_id, attempt):
        self.claims.append((task_id, attempt))
        t = self.tasks.get(task_id)
        if t is None:
            return GONE, "HTTP 410", None
        if t["status"] == "pending" and t["requeue_count"] == attempt:
            t["status"], t["updated_at"] = "in_progress", self.now
            return OK, "ok", t["requeue_count"]
        return CONFLICT, "HTTP 409", None

    def event(self, task_id, type, message=None, data=None, attempt=0):
        self.events.append((task_id, type, attempt))
        t = self.tasks.get(task_id)
        if t is None:
            return GONE
        if t["status"] == "in_progress" and t["requeue_count"] == attempt:
            t["updated_at"] = self.now
            return OK
        return CONFLICT

    def get_control(self, task_id):
        t = self.tasks.get(task_id)
        return "gone" if t is None else t["control"]

    def update(self, task_id, status, result=None, error_message=None, attempt=0):
        self.updates.append((task_id, status, attempt))
        if self.updates_down:
            return RETRY
        t = self.tasks.get(task_id)
        if t is None:
            return GONE
        minimal = isinstance(result, dict) and result.get("final_rejected")
        if self.reject_all_finals or (self.reject_full_results and not minimal):
            self.last_detail = "HTTP 400 — result invalide"
            return REJECTED
        if t["status"] == "in_progress" and t["requeue_count"] == attempt:
            t["status"], t["result"], t["error"] = status, result, error_message
            return OK
        return CONFLICT


def _setup(tmp_path, mode="auto"):
    executor = Executor(PermissionGate(mode, [str(tmp_path)], dry_run=False), step_timeout=30)
    pending = PendingUpdates(str(tmp_path / "pending.json"))
    cfg = Config(api_url="http://test", agent_key="k", poll_interval=0.5)
    return executor, pending, cfg, soulbah_agent.LoopState()


# --- T9 (a) : final bloqué > 180 s dans l'outbox -----------------------------------
def test_t9a_final_stuck_in_outbox_runs_once(tmp_path):
    srv = FakeServer()
    srv.add("t-a", [{"type": "count_test"}])
    executor, pending, cfg, state = _setup(tmp_path)

    srv.updates_down = True
    soulbah_agent.run_cycle(srv, executor, pending, cfg, state)
    assert EXECUTIONS["n"] == 1 and pending.has("t-a")

    # > 180 s sans que le final passe : l'agent reste « en finalisation ».
    srv.now += 200
    polls = srv.polls
    for _ in range(3):
        soulbah_agent.run_cycle(srv, executor, pending, cfg, state)
    assert srv.polls == polls, "aucune nouvelle tâche ne doit être prise pendant la finalisation"
    assert ("t-a", "heartbeat", 0) in srv.events  # la tâche est gardée vivante
    srv.requeue_stale()
    assert srv.tasks["t-a"]["status"] == "in_progress"  # heartbeat => pas de remise en file

    # Un autre poller (2e PC, reaper) la remet malgré tout en file.
    srv.now += 400
    srv.requeue_stale()
    assert srv.tasks["t-a"]["status"] == "pending" and srv.tasks["t-a"]["requeue_count"] == 1
    soulbah_agent.run_cycle(srv, executor, pending, cfg, state)  # heartbeat 409 => rejeu
    assert not pending.has("t-a") and pending.replay_entry("t-a")

    srv.updates_down = False
    for _ in range(2):
        soulbah_agent.run_cycle(srv, executor, pending, cfg, state)
    assert EXECUTIONS["n"] == 1, "la tâche ne doit JAMAIS être ré-exécutée"
    assert srv.tasks["t-a"]["status"] == "completed"
    assert srv.tasks["t-a"]["result"]["final_replayed"] is True


def test_t9a_old_attempt_final_409_then_replayed(tmp_path):
    srv = FakeServer()
    srv.add("t-b", [{"type": "count_test"}])
    executor, pending, cfg, state = _setup(tmp_path)
    srv.updates_down = True
    soulbah_agent.run_cycle(srv, executor, pending, cfg, state)
    srv.now += 400
    srv.requeue_stale()  # remise en file par un autre poller
    srv.updates_down = False
    pending_mod_keep = pending_mod.KEEPALIVE_SECONDS
    try:
        pending_mod.KEEPALIVE_SECONDS = 10_000  # pas de heartbeat : c'est le final qui reçoit 409
        soulbah_agent.run_cycle(srv, executor, pending, cfg, state)
    finally:
        pending_mod.KEEPALIVE_SECONDS = pending_mod_keep
    soulbah_agent.run_cycle(srv, executor, pending, cfg, state)
    assert EXECUTIONS["n"] == 1
    assert srv.tasks["t-b"]["status"] == "completed"


# --- T9 (b) : final REJETÉ ------------------------------------------------------------
def test_t9b_rejected_final_replaced_by_minimal_failed(tmp_path):
    srv = FakeServer()
    srv.add("t-c", [{"type": "count_test"}])
    srv.reject_full_results = True
    executor, pending, cfg, state = _setup(tmp_path)
    soulbah_agent.run_cycle(srv, executor, pending, cfg, state)
    t = srv.tasks["t-c"]
    assert t["status"] == "failed"
    assert t["result"]["final_rejected"] is True and t["result"]["original_status"] == "completed"
    assert {"index": 0, "type": "count_test", "path": "C:/ws/out.mp4"} in t["result"]["artifacts"]
    for _ in range(4):
        srv.now += 400
        soulbah_agent.run_cycle(srv, executor, pending, cfg, state)
    assert EXECUTIONS["n"] == 1


def test_t9b_all_finals_rejected_never_reexecuted(tmp_path):
    srv = FakeServer()
    srv.add("t-d", [{"type": "count_test"}])
    srv.reject_all_finals = True
    executor, pending, cfg, state = _setup(tmp_path)
    for _ in range(6):
        soulbah_agent.run_cycle(srv, executor, pending, cfg, state)
        srv.now += 400
    assert EXECUTIONS["n"] == 1, "4 exécutions avant le LOT 1, 1 maintenant"
    assert srv.tasks["t-d"]["status"] == "failed"  # le serveur abandonne après 3 remises en file


def test_pending_flush_rejected_goes_minimal(tmp_path):
    p = PendingUpdates(str(tmp_path / "p.json"))
    p.add("t1", "completed", attempt=0, result={"ok": True, "steps": []})

    class C:
        last_detail = "HTTP 400"

        def __init__(self):
            self.calls = []

        def update(self, task_id, status, result=None, error_message=None, attempt=0):
            self.calls.append((status, bool(result and result.get("final_rejected"))))
            return REJECTED if len(self.calls) == 1 else OK

    c = C()
    p.flush(c, force=True)
    assert c.calls == [("completed", False), ("failed", True)] and len(p) == 0


# --- 410 (S9, contrat §3) --------------------------------------------------------------
class FlowClient:
    def __init__(self, control=lambda: "none", event_outcome=lambda t: OK, update_outcome=OK, claim=OK):
        self.control = control
        self.event_outcome = event_outcome
        self.update_outcome = update_outcome
        self.claim_outcome = claim
        self.events, self.updates, self.claims = [], [], []
        self.log = []
        self.last_detail = None

    def claim(self, task_id, attempt):
        self.claims.append(attempt)
        return self.claim_outcome, "x", None

    def event(self, task_id, type, message=None, data=None, attempt=0):
        self.events.append((type, message, data))
        self.log.append(("event", type, time.monotonic()))
        return self.event_outcome(type)

    def get_control(self, task_id):
        return self.control()

    def update(self, task_id, status, result=None, error_message=None, attempt=0):
        self.updates.append((status, result, error_message))
        self.log.append(("update", status, time.monotonic()))
        return self.update_outcome


TASK = {"id": "task-410", "task_type": "t", "requeue_count": 0, "payload": {"steps": [{"type": "wait_test", "seconds": 0}]}}


def test_410_on_event_abandons_and_drops_pending(tmp_path):
    executor, pending, _, _ = _setup(tmp_path)
    c = FlowClient(event_outcome=lambda t: GONE if t == "task_started" else OK)
    out = soulbah_agent.handle_task(dict(TASK), c, executor, pending)
    assert out == "gone" and c.updates == [] and len(pending) == 0 and not pending.entries
    assert EXECUTIONS["n"] == 0


def test_410_on_control_stops_long_step_promptly(tmp_path, monkeypatch):
    monkeypatch.setattr(ex, "_CONTROL_POLL_SECONDS", 0.2)
    executor, pending, _, _ = _setup(tmp_path)
    calls = {"n": 0}

    def control():
        calls["n"] += 1
        return "gone" if calls["n"] > 2 else "none"

    task = dict(TASK, payload={"steps": [{"type": "wait_test", "seconds": 60}]})
    t0 = time.monotonic()
    out = soulbah_agent.handle_task(task, FlowClient(control=control), executor, pending)
    assert out == "gone" and time.monotonic() - t0 < 5


def test_410_on_final_update_not_queued(tmp_path):
    executor, pending, _, _ = _setup(tmp_path)
    c = FlowClient(update_outcome=GONE)
    assert soulbah_agent.handle_task(dict(TASK), c, executor, pending) == "completed"
    assert len(pending) == 0 and pending.replay_entry("task-410") is None


def test_410_on_flush_and_keepalive_drops(tmp_path):
    p = PendingUpdates(str(tmp_path / "p.json"))
    p.add("t1", "completed", attempt=0)
    p.add("t2", "completed", attempt=0)

    class C:
        def update(self, *a, **k):
            return GONE

        def event(self, *a, **k):
            return GONE

    p.keepalive(C())
    assert len(p) == 0 and not p.entries


def test_410_on_claim_drops_replay(tmp_path):
    executor, pending, _, _ = _setup(tmp_path)
    pending.remember("task-410", "completed", {"ok": True})
    out = soulbah_agent.handle_task(dict(TASK), FlowClient(claim=GONE), executor, pending)
    assert out == "gone" and pending.replay_entry("task-410") is None


# --- T4 : stop → cancelled ---------------------------------------------------------------
def test_stop_sends_cancelled_final(tmp_path, monkeypatch):
    monkeypatch.setattr(ex, "_CONTROL_POLL_SECONDS", 0.2)
    executor, pending, _, _ = _setup(tmp_path)
    calls = {"n": 0}

    def control():
        calls["n"] += 1
        return "stop" if calls["n"] > 2 else "none"

    c = FlowClient(control=control)
    task = dict(TASK, payload={"steps": [{"type": "wait_test", "seconds": 60}, {"type": "count_test"}]})
    assert soulbah_agent.handle_task(task, c, executor, pending) == "cancelled"
    status, result, _ = c.updates[-1]
    assert status == "cancelled" and result["cancelled"] is True and not result["ok"]
    types = [e[0] for e in c.events]
    assert "task_cancelled" in types and "task_failed" not in types
    assert EXECUTIONS["n"] == 0


def test_stop_before_first_step_is_cancelled_not_failed(tmp_path):
    executor, pending, _, _ = _setup(tmp_path)
    c = FlowClient(control=lambda: "stop")
    task = dict(TASK, payload={"steps": [{"type": "count_test"}]})
    assert soulbah_agent.handle_task(task, c, executor, pending) == "cancelled"
    assert EXECUTIONS["n"] == 0


# --- T5 : plan vide --------------------------------------------------------------------------
def test_empty_plan_fails_with_flag(tmp_path):
    executor, pending, _, _ = _setup(tmp_path)
    c = FlowClient()
    task = dict(TASK, payload={"steps": []})
    assert soulbah_agent.handle_task(task, c, executor, pending) == "failed"
    status, result, err = c.updates[-1]
    assert status == "failed" and result["empty_plan"] is True and "plan vide" in err
    assert "step_started" not in [e[0] for e in c.events]


@pytest.mark.parametrize("payload", [{}, {"steps": None}, {"title": "démo sans étapes"}])
def test_missing_steps_is_empty_plan(payload, tmp_path):
    executor, _, _, _ = _setup(tmp_path)
    report = executor.run_task(payload)
    assert report["empty_plan"] is True and report["ok"] is False


# --- T10 : dry-run local, jamais de tâche serveur ------------------------------------------
class _ExplodingClient:
    def __init__(self, *a, **k):
        raise AssertionError("le dry-run ne doit JAMAIS créer de client serveur (poll/claim)")


@pytest.fixture()
def _main_env(tmp_path, monkeypatch):
    monkeypatch.setattr(soulbah_agent, "_setup_logging", lambda: None)
    monkeypatch.setattr(soulbah_agent, "TaskClient", _ExplodingClient)
    monkeypatch.setattr(soulbah_agent, "PendingUpdates", _ExplodingClient)
    monkeypatch.setenv("SOULBAH_ALLOWED_DIRS", str(tmp_path))
    monkeypatch.delenv("SOULBAH_AGENT_KEY", raising=False)
    monkeypatch.delenv("SOULBAH_DRY_RUN", raising=False)
    return tmp_path


def test_dry_run_runs_local_plan_without_server(_main_env, capsys):
    ws = _main_env
    target = ws / "never.txt"
    plan = ws / "plan.json"
    plan.write_text(json.dumps({"steps": [
        {"type": "count_test"},
        {"type": "write_file", "path": str(target), "content": "secret"},
    ]}), encoding="utf-8")
    assert soulbah_agent.main(["--dry-run", "--plan", str(plan)]) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["simulated"] is True and report["ok"] is True
    assert all(s["simulated"] for s in report["steps"])
    assert EXECUTIONS["n"] == 0 and not target.exists()
    assert "secret" not in json.dumps(report)


def test_dry_run_without_plan_refuses(_main_env):
    assert soulbah_agent.main(["--dry-run"]) == 2


def test_env_dry_run_never_polls(_main_env, monkeypatch):
    monkeypatch.setenv("SOULBAH_DRY_RUN", "true")
    assert soulbah_agent.main(["--once"]) == 2


def test_plan_list_format_and_invalid_plan(_main_env, capsys):
    ws = _main_env
    (ws / "list.json").write_text(json.dumps([{"type": "count_test"}]), encoding="utf-8")
    assert soulbah_agent.main(["--plan", str(ws / "list.json")]) == 0
    assert json.loads(capsys.readouterr().out)["simulated"] is True
    (ws / "bad.json").write_text("{pas du json", encoding="utf-8")
    assert soulbah_agent.main(["--plan", str(ws / "bad.json")]) == 2


def test_dry_run_refused_step_reported(_main_env, capsys, tmp_path_factory):
    outside = tmp_path_factory.mktemp("outside")
    plan = _main_env / "p.json"
    plan.write_text(json.dumps({"steps": [{"type": "read_file", "path": str(outside / "x")}]}), encoding="utf-8")
    assert soulbah_agent.main(["--dry-run", "--plan", str(plan)]) == 1
    report = json.loads(capsys.readouterr().out)
    assert report["simulated"] is True and "hors liste blanche" in report["steps"][0]["detail"]


# --- T39 : pause ------------------------------------------------------------------------------
def test_pause_no_flood_and_error_does_not_resume(tmp_path, monkeypatch):
    monkeypatch.setattr(ex, "_PAUSE_POLL_SECONDS", 0.01)
    executor, _, _, _ = _setup(tmp_path)
    seq = ["pause"] + ["pause"] * 20 + ["error"] * 30 + ["none"]
    calls = {"n": 0}
    ran_while = []

    def control():
        i = calls["n"]
        calls["n"] += 1
        return seq[i] if i < len(seq) else "none"

    events = []

    def on_event(t, m, d):
        events.append(t)
        if t == "step_started":
            ran_while.append(calls["n"])

    report = executor.run_task({"steps": [{"type": "count_test"}]}, on_event=on_event, check_control=control)
    assert report["ok"]
    assert ran_while and ran_while[0] >= len(seq), "l'étape ne doit démarrer qu'après « none »"
    assert events.count("info") <= 3  # entrée en pause + reprise (pas 1 évènement par lecture)


def test_error_while_paused_then_stop_never_runs(tmp_path, monkeypatch):
    monkeypatch.setattr(ex, "_PAUSE_POLL_SECONDS", 0.01)
    executor, _, _, _ = _setup(tmp_path)
    seq = iter(["pause"] + ["error"] * 10 + ["stop"])
    report = executor.run_task({"steps": [{"type": "count_test"}]}, check_control=lambda: next(seq, "stop"))
    assert report["cancelled"] and EXECUTIONS["n"] == 0


def test_control_error_outside_pause_continues(tmp_path):
    executor, _, _, _ = _setup(tmp_path)
    report = executor.run_task({"steps": [{"type": "count_test"}]}, check_control=lambda: "error")
    assert report["ok"] and EXECUTIONS["n"] == 1


# --- T40 : Ctrl+C ---------------------------------------------------------------------------------
def test_ctrl_c_interrupts_current_task_promptly(tmp_path):
    executor, pending, _, _ = _setup(tmp_path)
    c = FlowClient()
    task = dict(TASK, payload={"steps": [{"type": "wait_test", "seconds": 120}, {"type": "count_test"}]})
    timer = threading.Timer(0.5, soulbah_agent._stop, args=(2, None))
    timer.start()
    t0 = time.monotonic()
    out = soulbah_agent.handle_task(task, c, executor, pending)
    assert time.monotonic() - t0 < 5
    assert out == "cancelled" and soulbah_agent._running is False
    status, result, _ = c.updates[-1]
    assert status == "cancelled" and "Ctrl+C" in result["summary"]
    assert EXECUTIONS["n"] == 0


def test_second_ctrl_c_forces_exit():
    soulbah_agent._stop(2, None)
    with pytest.raises(KeyboardInterrupt):
        soulbah_agent._stop(2, None)


def test_ctrl_c_interrupts_pending_confirmation(tmp_path, monkeypatch):
    """La confirmation console s'interrompt quand la tâche est annulée."""
    seen = {}

    def fake_input(prompt, timeout, should_stop=None):
        seen["should_stop"] = should_stop
        soulbah_agent._stop(2, None)  # Ctrl+C pendant la question
        assert should_stop is not None and should_stop()
        return None

    monkeypatch.setattr(permissions, "_timed_input", fake_input)
    executor = Executor(PermissionGate("confirm", [str(tmp_path)], dry_run=False))
    pending = PendingUpdates(str(tmp_path / "p.json"))
    c = FlowClient()
    task = dict(TASK, payload={"steps": [{"type": "sensitive_test"}]})
    assert soulbah_agent.handle_task(task, c, executor, pending) == "cancelled"
    assert EXECUTIONS["n"] == 0


# --- T41 : clé révoquée ------------------------------------------------------------------------------
class _AuthFailClient:
    last_error = AUTH
    last_status = 401

    def __init__(self, *a, **k):
        self.polls = 0

    def announce(self, dirs):
        return False

    def poll(self):
        self.polls += 1
        return None

    def update(self, *a, **k):
        return AUTH


def test_repeated_401_stops_polling(tmp_path, caplog):
    executor, pending, cfg, state = _setup(tmp_path)
    c = _AuthFailClient()
    for _ in range(soulbah_agent.MAX_AUTH_FAILURES):
        soulbah_agent.run_cycle(c, executor, pending, cfg, state)
    assert state.exit_code == 3
    assert "révoquée ou invalide" in caplog.text and "injoignable" not in caplog.text


def test_main_exits_after_repeated_401(tmp_path, monkeypatch):
    monkeypatch.setattr(soulbah_agent, "_setup_logging", lambda: None)
    monkeypatch.setattr(soulbah_agent, "_interruptible_sleep", lambda d: None)
    monkeypatch.setattr(soulbah_agent, "TaskClient", _AuthFailClient)
    monkeypatch.setattr(soulbah_agent, "PendingUpdates", lambda: PendingUpdates(str(tmp_path / "p.json")))
    monkeypatch.setenv("SOULBAH_AGENT_KEY", "revoked")
    monkeypatch.setenv("SOULBAH_ALLOWED_DIRS", str(tmp_path))
    monkeypatch.delenv("SOULBAH_DRY_RUN", raising=False)
    assert soulbah_agent.main([]) == 3


def test_network_error_is_not_auth(tmp_path, caplog):
    executor, pending, cfg, state = _setup(tmp_path)

    class Down(_AuthFailClient):
        last_error = RETRY

    for _ in range(5):
        soulbah_agent.run_cycle(Down(), executor, pending, cfg, state)
    assert state.exit_code is None and state.failures == 5


# --- T51 : heartbeat joint avant le final -----------------------------------------------------------------
def test_heartbeat_thread_joined_before_final(tmp_path, monkeypatch):
    monkeypatch.setattr(soulbah_agent, "HEARTBEAT_SECONDS", 0.02)
    executor, pending, _, _ = _setup(tmp_path)

    class SlowHb(FlowClient):
        def event(self, task_id, type, message=None, data=None, attempt=0):
            if type == "heartbeat":
                time.sleep(0.3)  # heartbeat en vol au moment de la fin de la tâche
            return super().event(task_id, type, message, data, attempt)

    c = SlowHb()
    task = dict(TASK, payload={"steps": [{"type": "wait_test", "seconds": 0.3}]})
    soulbah_agent.handle_task(task, c, executor, pending)
    time.sleep(0.5)
    kinds = [(k, t) for k, t, _ in c.log]
    final_at = kinds.index(("update", "completed"))
    assert all(t != "heartbeat" for _, t in kinds[final_at + 1:]), kinds


# --- S22 / §13 : approbations visibles ; S8 : textes masqués ------------------------------------------------
def test_approval_events_before_step_started(tmp_path, monkeypatch):
    monkeypatch.setattr(permissions, "_timed_input", lambda p, t, should_stop=None: "o")
    executor = Executor(PermissionGate("confirm", [str(tmp_path)], dry_run=False))
    events = []
    report = executor.run_task({"steps": [{"type": "sensitive_test"}]},
                               on_event=lambda t, m, d: events.append((t, d)))
    assert report["ok"]
    types = [t for t, _ in events]
    assert types.index("approval_required") < types.index("approval_result") < types.index("step_started")
    req = dict(events)["approval_required"]
    assert req["step_index"] == 0 and req["action"] == "sensitive_test" and req["summary"]
    assert dict(events)["approval_result"] == {"step_index": 0, "approved": True}


def test_refused_step_never_emits_step_started(tmp_path, monkeypatch):
    monkeypatch.setattr(permissions, "_timed_input", lambda p, t, should_stop=None: "n")
    executor = Executor(PermissionGate("confirm", [str(tmp_path)], dry_run=False))
    events = []
    report = executor.run_task({"steps": [{"type": "sensitive_test"}]},
                               on_event=lambda t, m, d: events.append((t, d)))
    assert not report["ok"] and EXECUTIONS["n"] == 0
    types = [t for t, _ in events]
    assert "step_started" not in types and ("approval_result", {"step_index": 0, "approved": False}) in events


def test_typed_text_masked_everywhere(tmp_path, monkeypatch, caplog, capsys):
    import sys
    import types as _types

    from skills import type_text as tt

    secret = "MotDePasse-Tres-Secret-42"
    fake = _types.SimpleNamespace(hotkey=lambda *a: None, typewrite=lambda *a, **k: None)
    monkeypatch.setitem(sys.modules, "pyautogui", fake)
    monkeypatch.setattr(tt, "_snapshot_clipboard", lambda: ("text", "ancien"))
    monkeypatch.setattr(tt, "_set_clipboard", lambda text: True)
    monkeypatch.setattr(tt, "_restore_clipboard", lambda snap: True)
    monkeypatch.setattr(tt, "_PASTE_SETTLE_SECONDS", 0.0)
    monkeypatch.setattr(permissions, "_timed_input", lambda p, t, should_stop=None: "o")
    executor = Executor(PermissionGate("confirm", [str(tmp_path)], dry_run=False))
    events = []
    with caplog.at_level("DEBUG"):
        report = executor.run_task(
            {"steps": [{"type": "type_text", "text": secret},
                       {"type": "write_file", "path": str(tmp_path / "f.txt"), "content": secret}]},
            on_event=lambda t, m, d: events.append((t, m, d)))
    assert report["ok"], report
    assert secret not in json.dumps(report, ensure_ascii=False)
    assert secret not in json.dumps(events, ensure_ascii=False)
    assert secret not in caplog.text
    assert "[texte masqué : 25 car.]" in json.dumps(events, ensure_ascii=False)
    # La console LOCALE affiche le contenu complet à la confirmation (S7).
    assert secret in capsys.readouterr().out
