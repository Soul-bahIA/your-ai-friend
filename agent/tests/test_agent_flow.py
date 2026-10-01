"""Cycle d'une tâche dans l'agent (handle_task) avec un faux client HTTP :
contrat `attempt`, 409 => abandon sans statut final, update en échec => file locale."""
from __future__ import annotations

import pytest

import soulbah_agent
from client import CONFLICT, OK, RETRY
from executor import Executor
from pending import PendingUpdates
from permissions import PermissionGate


class FakeClient:
    def __init__(self, claim=OK, event_outcome=lambda t: OK, update_outcome=OK):
        self.claim_outcome = claim
        self.event_outcome = event_outcome
        self.update_outcome = update_outcome
        self.claims, self.events, self.updates = [], [], []

    def claim(self, task_id, attempt):
        self.claims.append((task_id, attempt))
        return self.claim_outcome, "HTTP 409" if self.claim_outcome == CONFLICT else "ok", None

    def event(self, task_id, type, message=None, data=None, attempt=0):
        self.events.append((type, attempt))
        return self.event_outcome(type)

    def update(self, task_id, status, result=None, error_message=None, attempt=0):
        self.updates.append((status, attempt))
        return self.update_outcome

    def get_control(self, task_id):
        return "none"


@pytest.fixture()
def env(tmp_path):
    executor = Executor(PermissionGate("auto", [], dry_run=False), step_timeout=30)
    pending = PendingUpdates(str(tmp_path / "pending.json"))
    return executor, pending


TASK = {"id": "task-1234", "task_type": "demo", "requeue_count": 3,
        "payload": {"steps": [{"type": "wait", "seconds": 0}]}}


def test_attempt_sent_everywhere(env):
    executor, pending = env
    c = FakeClient()
    soulbah_agent.handle_task(dict(TASK), c, executor, pending)
    assert c.claims == [("task-1234", 3)]
    assert c.events and all(a == 3 for _, a in c.events)
    assert c.updates == [("completed", 3)]


def test_claim_conflict_skips(env):
    executor, pending = env
    c = FakeClient(claim=CONFLICT)
    soulbah_agent.handle_task(dict(TASK), c, executor, pending)
    assert c.events == [] and c.updates == []


def test_event_409_aborts_without_final_update(env):
    executor, pending = env
    c = FakeClient(event_outcome=lambda t: CONFLICT if t == "step_started" else OK)
    soulbah_agent.handle_task(dict(TASK), c, executor, pending)
    assert c.updates == []
    assert len(pending) == 0


def test_final_update_network_error_is_queued(env):
    executor, pending = env
    c = FakeClient(update_outcome=RETRY)
    soulbah_agent.handle_task(dict(TASK), c, executor, pending)
    assert pending.has("task-1234")
    # La tâche réapparaît au poll : elle n'est pas ré-exécutée tant que l'update est en attente.
    c2 = FakeClient()
    soulbah_agent.handle_task(dict(TASK), c2, executor, pending)
    assert c2.claims == []


def test_final_update_409_dropped(env):
    executor, pending = env
    c = FakeClient(update_outcome=CONFLICT)
    soulbah_agent.handle_task(dict(TASK), c, executor, pending)
    assert len(pending) == 0
