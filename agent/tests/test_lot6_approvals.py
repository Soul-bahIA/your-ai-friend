"""LOT 6 — approbations distantes HMAC côté agent (approvals.py, gate, executor, client).

Faux client (aucun réseau) qui rejoue le contrat de /api/v2/approvals :
  request → 201 {id, status, payload_sha256, expires_at} ; get → statut (+ token si approved) ;
  verify → {ok, approval_id, level} | {ok: false, reason}."""
from __future__ import annotations

import hashlib
import json

import pytest
import requests

import client as client_mod
import permissions
from approvals import RemoteApprover, canonical_json, canonical_sha256
from client import OK, REJECTED, RETRY, TaskClient
from config import Config
from executor import Executor
from permissions import PermissionGate
from redaction import SECRET_MASK
from skills.base import Skill, SkillResult
from skills.filesystem import FileOpsSkill
from skills.type_text import TypeTextSkill

TOKEN = "sbap_eyJ2IjoxfQ.signature0123456789"


# --- Empreinte canonique (identique à node : canonicalJson / payloadSha256) ------------------
def test_canonical_sha256_fixed_example():
    step = {"b": 1, "a": "é"}
    assert canonical_json(step) == '{"a":"é","b":1}'
    expected = hashlib.sha256('{"a":"é","b":1}'.encode("utf-8")).hexdigest()
    assert expected == "aa58fba8483623bed37c1b02edfccbdd9a53123837c20bfa4cb4049993a2872e"
    assert canonical_sha256(step) == expected
    assert canonical_sha256({"a": "é", "b": 1}) == expected  # ordre des clés indifférent


def test_canonical_json_mirrors_javascript():
    step = {"z": [1, 2.0, 2.5, True, None, 'x\n"y"'], "é": {"b": 1, "a": 0}, "t": "ü€"}
    assert canonical_json(step) == '{"t":"ü€","z":[1,2,2.5,true,null,"x\\n\\"y\\""],"é":{"a":0,"b":1}}'
    assert canonical_sha256({"n": 3.0}) == canonical_sha256({"n": 3})  # JS : 3.0 → 3


# --- Faux client --------------------------------------------------------------------------------
class FakeApprovalClient:
    """`decisions` : statuts renvoyés par get (dans l'ordre, le dernier répété) ;
    `verify_ok` / `verify_reason` : réponse de verify ; `request_status` : code HTTP du POST."""

    def __init__(self, decisions=("pending", "approved"), verify_ok=True, verify_reason=None,
                 request_status=201, get_error=None, token=TOKEN):
        self.decisions = list(decisions)
        self.verify_ok = verify_ok
        self.verify_reason = verify_reason
        self.request_status = request_status
        self.get_error = get_error
        self.token = token
        self.requests: list[dict] = []
        self.gets: list[str] = []
        self.verifies: list[tuple[str, dict]] = []

    def request_approval(self, body):
        self.requests.append(body)
        if self.request_status == 404:
            return REJECTED, "HTTP 404 — Route not found", {"error": "Route not found"}, 404
        if self.request_status == 403:
            return REJECTED, "HTTP 403 — action refusée par la politique", {"reason": "deny"}, 403
        if self.request_status is None:
            return RETRY, "backend injoignable (ConnectionError)", None, None
        return OK, "ok", {"id": "a1b2c3d4-0000-4000-8000-000000000001", "status": "pending",
                          "payload_sha256": canonical_sha256(body["payload"]), "expires_at": "2026-10-01T00:10:00Z"}, 201

    def get_approval(self, approval_id):
        self.gets.append(approval_id)
        if self.get_error is not None:
            return self.get_error
        status = self.decisions.pop(0) if len(self.decisions) > 1 else self.decisions[0]
        out = {"id": approval_id, "status": status, "expires_at": None, "decided_at": None, "reason": None}
        if status == "approved":
            out["token"] = self.token
        if status == "denied":
            out["reason"] = "pas maintenant"
        return OK, "ok", out, 200

    def verify_approval(self, token, payload):
        self.verifies.append((token, payload))
        if self.verify_ok:
            return OK, "ok", {"ok": True, "approval_id": "a1b2c3d4-0000-4000-8000-000000000001", "level": "L2"}, 200
        return OK, "ok", {"ok": False, "reason": self.verify_reason or "payload_mismatch"}, 200


class CountingSkill(Skill):
    name = "count_approval_test"
    step_types = ("count_approval_test",)
    category = "filesystem"
    sensitive = True
    runs = 0

    def describe(self, step):
        return "action sensible de test"

    def run(self, step):
        CountingSkill.runs += 1
        return SkillResult(ok=True, detail="exécutée")


@pytest.fixture()
def no_console(monkeypatch):
    monkeypatch.setattr(permissions, "_timed_input", lambda *a, **k: pytest.fail("console non attendue"))


def _gate(tmp_path, fake, mode="remote", approval_mode="remote"):
    approver = RemoteApprover(fake, timeout_s=5, poll_s=0.01)
    return PermissionGate(mode, [str(tmp_path)], dry_run=False, approval_mode=approval_mode, approver=approver)


def _ctx(events, **extra):
    ctx = {"emit": lambda t, m, d: events.append((t, d)), "step_index": 2, "task_id": "f0e1d2c3-0000-4000-8000-0000000000aa",
           "attempt": 1, "stop_check": lambda: False}
    ctx.update(extra)
    return ctx


# --- Décisions ------------------------------------------------------------------------------------
def test_remote_approved_then_verified(tmp_path, no_console):
    fake = FakeApprovalClient(decisions=("pending", "pending", "approved"))
    gate = _gate(tmp_path, fake, mode="confirm")
    events = []
    ctx = _ctx(events)
    step = {"type": "list_dir", "path": str(tmp_path)}
    ok, reason = gate.authorize(FileOpsSkill(), step, ctx)
    assert ok and "approuvée" in reason
    assert ctx["approval_token"] == TOKEN and ctx["approval_id"].startswith("a1b2c3d4")
    assert len(fake.gets) == 3 and fake.verifies == [(TOKEN, step)]  # payload réellement exécuté
    req = dict(events)["approval_required"]
    assert req["approval_id"].startswith("a1b2c3d4") and req["level"] == "L2" and req["step_index"] == 2
    res = dict(events)["approval_result"]
    assert res == {"step_index": 2, "approved": True, "reason": reason, "remote": True, "approval_id": ctx["approval_id"]}
    assert TOKEN not in json.dumps(events)  # le jeton ne sort jamais dans un évènement


def test_remote_denied(tmp_path, no_console):
    fake = FakeApprovalClient(decisions=("denied",))
    gate = _gate(tmp_path, fake, mode="confirm")
    events = []
    ctx = _ctx(events)
    ok, reason = gate.authorize(FileOpsSkill(), {"type": "list_dir", "path": str(tmp_path)}, ctx)
    assert not ok and "refusée dans l'app" in reason and "pas maintenant" in reason
    assert fake.verifies == [] and "approval_token" not in ctx
    assert dict(events)["approval_result"]["approved"] is False and dict(events)["approval_result"]["remote"] is True


@pytest.mark.parametrize("status,word", [("expired", "expirée"), ("revoked", "révoquée")])
def test_remote_expired_or_revoked(tmp_path, no_console, status, word):
    fake = FakeApprovalClient(decisions=("pending", status))
    ok, reason = _gate(tmp_path, fake, mode="confirm").authorize(
        FileOpsSkill(), {"type": "list_dir", "path": str(tmp_path)}, _ctx([]))
    assert not ok and word in reason and fake.verifies == []


def test_remote_local_timeout_refuses(tmp_path, no_console):
    fake = FakeApprovalClient(decisions=("pending",))
    approver = RemoteApprover(fake, timeout_s=1, poll_s=0.01)
    gate = PermissionGate("confirm", [str(tmp_path)], dry_run=False, approval_mode="remote", approver=approver)
    ok, reason = gate.authorize(FileOpsSkill(), {"type": "list_dir", "path": str(tmp_path)}, _ctx([]))
    assert not ok and "sans décision" in reason and fake.verifies == []


def test_remote_verify_payload_mismatch_refuses(tmp_path, no_console):
    fake = FakeApprovalClient(decisions=("approved",), verify_ok=False, verify_reason="payload_mismatch")
    ok, reason = _gate(tmp_path, fake, mode="confirm").authorize(
        FileOpsSkill(), {"type": "list_dir", "path": str(tmp_path)}, _ctx([]))
    assert not ok and "payload_mismatch" in reason and len(fake.verifies) == 1


def test_remote_token_missing_or_malformed_refuses(tmp_path, no_console):
    fake = FakeApprovalClient(decisions=("approved",), token="pas-un-jeton")
    ok, reason = _gate(tmp_path, fake, mode="confirm").authorize(
        FileOpsSkill(), {"type": "list_dir", "path": str(tmp_path)}, _ctx([]))
    assert not ok and "jeton" in reason and fake.verifies == []


def test_remote_network_error_on_request_refuses(tmp_path, no_console):
    fake = FakeApprovalClient(request_status=None)
    ok, reason = _gate(tmp_path, fake, mode="confirm").authorize(
        FileOpsSkill(), {"type": "list_dir", "path": str(tmp_path)}, _ctx([]))
    assert not ok and "injoignable" in reason and fake.gets == []


def test_remote_policy_403_refuses(tmp_path, no_console):
    fake = FakeApprovalClient(request_status=403)
    ok, reason = _gate(tmp_path, fake, mode="confirm").authorize(
        FileOpsSkill(), {"type": "list_dir", "path": str(tmp_path)}, _ctx([]))
    assert not ok and "403" in reason


def test_remote_get_errors_eventually_refuse(tmp_path, no_console):
    fake = FakeApprovalClient(get_error=(RETRY, "backend injoignable (Timeout)", None, None))
    ok, reason = _gate(tmp_path, fake, mode="confirm").authorize(
        FileOpsSkill(), {"type": "list_dir", "path": str(tmp_path)}, _ctx([]))
    assert not ok and "lecture impossible" in reason and len(fake.gets) == 3


def test_remote_stop_check_during_wait_refuses(tmp_path, no_console):
    fake = FakeApprovalClient(decisions=("pending",))
    polls = {"n": 0}

    def stop_check():
        polls["n"] += 1
        return polls["n"] > 3  # « Arrêter » cliqué pendant l'attente

    gate = _gate(tmp_path, fake, mode="confirm")
    ok, reason = gate.authorize(FileOpsSkill(), {"type": "list_dir", "path": str(tmp_path)}, _ctx([], stop_check=stop_check))
    assert not ok and "arrêt demandé" in reason and fake.verifies == []


def test_remote_404_refuses_in_remote_mode(tmp_path, no_console):
    fake = FakeApprovalClient(request_status=404)
    events = []
    ok, reason = _gate(tmp_path, fake, mode="confirm", approval_mode="remote").authorize(
        FileOpsSkill(), {"type": "list_dir", "path": str(tmp_path)}, _ctx(events))
    assert not ok and "404" in reason
    assert dict(events)["approval_result"]["remote"] is True


def test_both_404_falls_back_to_console_with_warning(tmp_path, monkeypatch, caplog):
    fake = FakeApprovalClient(request_status=404)
    asked = []
    monkeypatch.setattr(permissions, "_timed_input", lambda p, t, should_stop=None: asked.append(p) or "o")
    events = []
    with caplog.at_level("WARNING"):
        ok, reason = _gate(tmp_path, fake, mode="confirm", approval_mode="both").authorize(
            FileOpsSkill(), {"type": "list_dir", "path": str(tmp_path)}, _ctx(events))
    assert ok and "utilisateur" in reason and len(asked) == 1
    assert "repli" in caplog.text
    req = dict(events)["approval_required"]
    assert req["approval_id"] is None and len(fake.requests) == 1 and fake.gets == []
    assert dict(events)["approval_result"]["remote"] is False


def test_both_denied_remotely_does_not_fall_back(tmp_path, no_console):
    fake = FakeApprovalClient(decisions=("denied",))
    ok, _ = _gate(tmp_path, fake, mode="confirm", approval_mode="both").authorize(
        FileOpsSkill(), {"type": "list_dir", "path": str(tmp_path)}, _ctx([]))
    assert not ok


def test_remote_mode_without_approver_refuses(tmp_path, no_console):
    gate = PermissionGate("confirm", [str(tmp_path)], dry_run=False, approval_mode="remote")
    ok, reason = gate.authorize(FileOpsSkill(), {"type": "list_dir", "path": str(tmp_path)}, _ctx([]))
    assert not ok and "aucun client" in reason


def test_console_mode_never_calls_remote(tmp_path, monkeypatch):
    fake = FakeApprovalClient()
    monkeypatch.setattr(permissions, "_timed_input", lambda p, t, should_stop=None: "o")
    gate = _gate(tmp_path, fake, mode="confirm", approval_mode="console")
    assert gate.authorize(FileOpsSkill(), {"type": "list_dir", "path": str(tmp_path)}, _ctx([]))[0]
    assert fake.requests == []


def test_l3_level_sent_to_server(tmp_path, no_console):
    from skills.run_command import RunCommandSkill

    proj = tmp_path / "proj"
    proj.mkdir()
    fake = FakeApprovalClient(decisions=("approved",))
    step = {"type": "run_command", "program": "git", "args": ["branch", "-d", "old"], "cwd": str(proj)}
    ok, _ = _gate(tmp_path, fake, mode="auto").authorize(RunCommandSkill(), step, _ctx([]))
    assert ok and fake.requests[0]["level"] == "L3" and fake.requests[0]["tool"] == "run_command"


# --- Contenu de la demande : rédigée SAUF payload ---------------------------------------------------
def test_request_body_redacted_except_payload(tmp_path, no_console, monkeypatch):
    monkeypatch.setenv("SOULBAH_REDACT_VALUES", "CANARI-APPROBATION-123")
    fake = FakeApprovalClient(decisions=("approved",))
    step = {"type": "type_text", "text": "mot de passe CANARI-APPROBATION-123", "window_title": "Bloc-notes"}
    ok, _ = _gate(tmp_path, fake, mode="confirm").authorize(TypeTextSkill(), step, _ctx([]))
    assert ok
    body = fake.requests[0]
    # Le payload part COMPLET : le serveur l'affiche à l'utilisateur et le hache (payload_sha256).
    assert body["payload"] is step and body["payload"]["text"] == "mot de passe CANARI-APPROBATION-123"
    # Tout le reste est rédigé : le résumé ne contient ni le texte ni le canari.
    rest = {k: v for k, v in body.items() if k != "payload"}
    dumped = json.dumps(rest, ensure_ascii=False)
    assert "CANARI-APPROBATION" not in dumped and "mot de passe" not in dumped
    assert rest["task_id"] == "f0e1d2c3-0000-4000-8000-0000000000aa" and rest["attempt"] == 1
    assert rest["step_index"] == 2 and rest["tool"] == "type_text" and rest["level"] == "L2" and rest["ttl_s"] == 5
    assert set(body) == {"task_id", "attempt", "step_index", "tool", "level", "payload", "summary", "ttl_s"}
    # Le jeton n'est jamais passé dans un évènement, même rédigé.
    assert SECRET_MASK not in dumped


# --- Executor : exécution après approbation, approval_id dans step_started, jamais le jeton --------
def test_executor_runs_after_remote_approval_and_tags_step_started(tmp_path, no_console):
    from skills import REGISTRY

    REGISTRY["count_approval_test"] = CountingSkill()
    try:
        CountingSkill.runs = 0
        fake = FakeApprovalClient(decisions=("approved",))
        gate = _gate(tmp_path, fake, mode="confirm")
        events = []
        report = Executor(gate).run_task({"steps": [{"type": "count_approval_test"}]},
                                         on_event=lambda t, m, d: events.append((t, d)),
                                         task_id="f0e1d2c3-0000-4000-8000-0000000000aa", attempt=3)
        assert report["ok"] and CountingSkill.runs == 1
        started = dict(events)["step_started"]
        assert started["approval_id"].startswith("a1b2c3d4") and "approval_token" not in started
        assert TOKEN not in json.dumps(events) and TOKEN not in json.dumps(report)
        assert fake.requests[0]["task_id"] == "f0e1d2c3-0000-4000-8000-0000000000aa" and fake.requests[0]["attempt"] == 3
        # Refus distant : rien n'est exécuté, step_started n'est pas émis.
        fake2 = FakeApprovalClient(decisions=("denied",))
        events2 = []
        report2 = Executor(_gate(tmp_path, fake2, mode="confirm")).run_task(
            {"steps": [{"type": "count_approval_test"}]}, on_event=lambda t, m, d: events2.append((t, d)))
        assert not report2["ok"] and CountingSkill.runs == 1 and "step_started" not in dict(events2)
    finally:
        REGISTRY.pop("count_approval_test", None)


def test_local_plan_has_no_task_identity(tmp_path, no_console):
    fake = FakeApprovalClient(decisions=("approved",))
    gate = _gate(tmp_path, fake, mode="confirm")
    Executor(gate).run_task({"steps": [{"type": "list_dir", "path": str(tmp_path)}]})
    assert fake.requests[0]["task_id"] is None and fake.requests[0]["attempt"] == 0


# --- TaskClient : routes, en-tête, code HTTP renvoyé -----------------------------------------------
class _Resp:
    def __init__(self, status, payload=None):
        self.status_code = status
        self._payload = payload

    def json(self):
        if self._payload is None:
            raise ValueError("pas de json")
        return self._payload


def test_task_client_approval_methods(monkeypatch):
    calls = []

    def fake(url, **kw):
        calls.append((url, kw.get("json"), kw["headers"]["x-agent-key"], kw["timeout"]))
        if url.endswith("/request"):
            return _Resp(201, {"id": "x", "status": "pending"})
        if url.endswith("/verify"):
            return _Resp(200, {"ok": False, "reason": "signature"})
        return _Resp(404, {"error": "Route not found"})

    monkeypatch.setattr(client_mod.requests, "post", fake)
    monkeypatch.setattr(client_mod.requests, "get", fake)
    tc = TaskClient(Config(api_url="http://test", agent_key="k"))
    assert tc.request_approval({"tool": "wait"}) == (OK, "ok", {"id": "x", "status": "pending"}, 201)
    assert tc.get_approval("x")[0] == REJECTED and tc.get_approval("x")[3] == 404
    outcome, _, data, status = tc.verify_approval("sbap_t", {"type": "wait"})
    assert outcome == OK and data == {"ok": False, "reason": "signature"} and status == 200
    assert calls[0][0] == "http://test/api/v2/approvals/request" and calls[1][0] == "http://test/api/v2/approvals/x"
    assert calls[-1][1] == {"token": "sbap_t", "payload": {"type": "wait"}}
    assert all(c[2] == "k" and c[3] <= 15 for c in calls)
    monkeypatch.setattr(client_mod.requests, "post", lambda *a, **k: (_ for _ in ()).throw(requests.ConnectionError("x")))
    assert tc.request_approval({})[0] == RETRY and tc.request_approval({})[3] is None
