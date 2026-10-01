"""Executor (délai, arrêt, 409) et file des mises à jour finales en attente."""
from __future__ import annotations

import threading
import time

import pytest

import executor as ex
from executor import Executor
from pending import CONFLICT, OK, RETRY, PendingUpdates
from permissions import PermissionGate
from skills import REGISTRY
from skills.base import Skill, SkillResult, sleep_or_cancel


class _SlowSkill(Skill):
    name = "slow_test"
    step_types = ("slow_test",)
    category = "generic"
    sensitive = False

    def run(self, step):
        if not sleep_or_cancel(float(step.get("seconds", 30))):
            return SkillResult(ok=False, detail="interrompu")
        return SkillResult(ok=True, detail="fini")


class _HungSkill(_SlowSkill):
    name = "hung_test"
    step_types = ("hung_test",)

    def run(self, step):  # ignore volontairement le drapeau d'annulation
        time.sleep(float(step.get("seconds", 3)))
        return SkillResult(ok=True, detail="trop tard")


@pytest.fixture(autouse=True)
def _register():
    REGISTRY["slow_test"] = _SlowSkill()
    REGISTRY["hung_test"] = _HungSkill()
    yield
    REGISTRY.pop("slow_test", None)
    REGISTRY.pop("hung_test", None)


def _executor(timeout=1.0):
    return Executor(PermissionGate("auto", [], dry_run=False), step_timeout=timeout)


def test_step_timeout_fails_task(monkeypatch):
    monkeypatch.setattr(ex, "_CANCEL_GRACE_SECONDS", 0.5)
    t0 = time.monotonic()
    report = _executor(1.0).run_task(
        {"steps": [{"type": "slow_test", "seconds": 30}, {"type": "wait", "seconds": 0}]}
    )
    assert time.monotonic() - t0 < 5
    assert not report["ok"] and report["timed_out"]
    assert len(report["steps"]) == 1 and "délai dépassé" in report["steps"][0]["detail"]


def test_hung_skill_is_abandoned(monkeypatch):
    monkeypatch.setattr(ex, "_CANCEL_GRACE_SECONDS", 0.3)
    t0 = time.monotonic()
    report = _executor(0.5).run_task({"steps": [{"type": "hung_test", "seconds": 3}]})
    assert time.monotonic() - t0 < 2.5
    assert report["timed_out"] and not report["ok"]


def test_stop_during_long_wait(monkeypatch):
    monkeypatch.setattr(ex, "_CONTROL_POLL_SECONDS", 0.2)
    state = {"n": 0}

    def control():
        state["n"] += 1
        return "stop" if state["n"] > 2 else "none"

    t0 = time.monotonic()
    report = _executor(60).run_task({"steps": [{"type": "wait", "seconds": 60}]}, check_control=control)
    assert time.monotonic() - t0 < 5
    assert report["stopped"] and not report["ok"]


def test_abort_409_stops_without_completion_event():
    abort = threading.Event()
    events = []

    def on_event(t, m, d):
        events.append(t)
        if t == "step_started":
            threading.Timer(0.3, abort.set).start()

    report = _executor(60).run_task(
        {"steps": [{"type": "slow_test", "seconds": 30}, {"type": "wait", "seconds": 0}]},
        on_event=on_event, abort=abort,
    )
    assert report["aborted"] and not report["ok"]
    assert "task_completed" not in events and "task_failed" not in events
    assert len(report["steps"]) == 1


def test_successful_task():
    report = _executor(5).run_task({"steps": [{"type": "slow_test", "seconds": 0.1}]})
    assert report["ok"] and report["summary"] == "toutes les étapes réussies"


class _FakeClient:
    def __init__(self, outcomes):
        self.outcomes = list(outcomes)
        self.calls = []

    def update(self, task_id, status, result=None, error_message=None, attempt=0):
        self.calls.append((task_id, status, attempt))
        return self.outcomes.pop(0)


def test_pending_retry_then_ok(tmp_path):
    path = str(tmp_path / "pending.json")
    p = PendingUpdates(path)
    p.add("t1", "completed", attempt=2, result={"ok": True})
    assert PendingUpdates(path).has("t1")  # persisté sur disque

    client = _FakeClient([RETRY, OK])
    p.flush(client, force=True)
    assert p.has("t1") and client.calls == [("t1", "completed", 2)]
    p.flush(client)  # pas encore dû (backoff)
    assert len(client.calls) == 1
    p.flush(client, force=True)
    assert not p.has("t1") and len(PendingUpdates(path)) == 0


def test_pending_conflict_dropped(tmp_path):
    p = PendingUpdates(str(tmp_path / "pending.json"))
    p.add("t2", "failed", attempt=0)
    p.flush(_FakeClient([CONFLICT]), force=True)
    assert len(p) == 0


def test_pending_expires(tmp_path):
    p = PendingUpdates(str(tmp_path / "pending.json"), max_age=0.0)
    p.add("t3", "completed", attempt=0)
    p.flush(_FakeClient([RETRY]), force=True)
    assert len(p) == 0
