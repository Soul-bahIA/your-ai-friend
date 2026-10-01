"""T15 : jeton d'annulation par tâche/étape (fin du drapeau global cancel_event)."""
from __future__ import annotations

import threading
import time

import pytest

import executor as ex
from executor import Executor
from permissions import PermissionGate
from skills import REGISTRY
from skills import base
from skills.base import CancelToken, Skill, SkillResult, bind_token, current_token, sleep_or_cancel


def test_no_global_cancel_event_anymore():
    assert not hasattr(base, "cancel_event")


def test_child_cancelled_with_parent():
    parent = CancelToken()
    child = parent.child()
    grandchild = child.child()
    parent.cancel("stop")
    assert child.is_cancelled() and grandchild.is_cancelled()
    assert grandchild.reason == "stop"


def test_child_created_after_cancel_is_cancelled():
    parent = CancelToken()
    parent.cancel("fin")
    assert parent.child().is_cancelled()


def test_child_cancel_does_not_touch_parent_or_sibling():
    parent = CancelToken()
    a, b = parent.child(), parent.child()
    a.cancel("timeout")
    assert a.is_cancelled() and not parent.is_cancelled() and not b.is_cancelled()


def test_first_reason_is_kept():
    t = CancelToken()
    t.cancel("interruption")
    t.cancel("fin de tâche")
    assert t.reason == "interruption"


def test_current_token_unbound_is_never_cancelled():
    t1 = current_token()
    t1.cancel("x")
    assert not current_token().is_cancelled()  # jeton neuf : aucun état global partagé


def test_sleep_or_cancel_uses_bound_token():
    token = CancelToken()
    out = {}

    def worker():
        bind_token(token)
        t0 = time.monotonic()
        out["completed"] = sleep_or_cancel(10)
        out["elapsed"] = time.monotonic() - t0

    th = threading.Thread(target=worker)
    th.start()
    time.sleep(0.2)
    token.cancel("stop")
    th.join(3)
    assert out["completed"] is False and out["elapsed"] < 2


class _ZombieSkill(Skill):
    """Ignore l'annulation (bloqué), puis tente d'annuler « le » jeton courant."""
    name = "zombie_test"
    step_types = ("zombie_test",)
    category = "generic"
    sensitive = False
    seen: dict = {}

    def run(self, step):
        tok = current_token()
        self.seen["zombie_token"] = tok
        time.sleep(0.6)  # bloqué : le délai de l'étape expire, l'executor l'abandonne
        self.seen["zombie_still_cancelled"] = tok.is_cancelled()
        tok.cancel("le zombie se réveille")  # ne doit affecter QUE son propre jeton
        return SkillResult(ok=True, detail="zombie fini")


class _ObserverSkill(Skill):
    name = "observer_test"
    step_types = ("observer_test",)
    category = "generic"
    sensitive = False
    seen: dict = {}

    def run(self, step):
        tok = current_token()
        self.seen["observer_token"] = tok
        completed = sleep_or_cancel(1.2)
        self.seen["observer_completed"] = completed
        return SkillResult(ok=completed, detail="observé")


@pytest.fixture()
def _skills():
    REGISTRY["zombie_test"] = _ZombieSkill()
    REGISTRY["observer_test"] = _ObserverSkill()
    _ZombieSkill.seen.clear()
    _ObserverSkill.seen.clear()
    yield
    REGISTRY.pop("zombie_test", None)
    REGISTRY.pop("observer_test", None)


def test_zombie_thread_cannot_affect_next_task(_skills, monkeypatch):
    monkeypatch.setattr(ex, "_CANCEL_GRACE_SECONDS", 0.1)
    executor = Executor(PermissionGate("auto", [], dry_run=False), step_timeout=0.2)
    report_a = executor.run_task({"steps": [{"type": "zombie_test"}]})
    assert report_a["timed_out"] and not report_a["ok"]

    # Tâche suivante pendant que le zombie dort encore puis « annule » son jeton.
    executor_b = Executor(PermissionGate("auto", [], dry_run=False), step_timeout=30)
    report_b = executor_b.run_task({"steps": [{"type": "observer_test"}]})
    assert report_b["ok"], report_b
    assert _ObserverSkill.seen["observer_completed"] is True  # jamais interrompu par le zombie
    assert _ZombieSkill.seen["zombie_token"] is not _ObserverSkill.seen["observer_token"]
    assert _ZombieSkill.seen["zombie_still_cancelled"] is True  # pas ré-armé par la tâche B


def test_each_step_gets_its_own_token(_skills):
    tokens = []

    class _Rec(Skill):
        name = "rec_test"
        step_types = ("rec_test",)
        category = "generic"
        sensitive = False

        def run(self, step):
            tokens.append(current_token())
            return SkillResult(ok=True, detail="ok")

    REGISTRY["rec_test"] = _Rec()
    try:
        task_token = CancelToken()
        Executor(PermissionGate("auto", [], dry_run=False)).run_task(
            {"steps": [{"type": "rec_test"}, {"type": "rec_test"}]}, cancel=task_token)
    finally:
        REGISTRY.pop("rec_test", None)
    assert len(tokens) == 2 and tokens[0] is not tokens[1]
    assert all(t.is_cancelled() for t in tokens)  # libérés en fin de tâche
    assert task_token.is_cancelled()
