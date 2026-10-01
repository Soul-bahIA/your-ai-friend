"""Client HTTP : classement des réponses (T41 : 401/403 ≠ backend injoignable ;
contrat §3 : 410 = tâche supprimée ; T39 : erreur de lecture du contrôle ≠ reprise)."""
from __future__ import annotations

import pytest
import requests

import client as client_mod
from client import AUTH, CONFLICT, GONE, OK, REJECTED, RETRY, TaskClient, _classify
from config import Config


class _Resp:
    def __init__(self, status, payload=None):
        self.status_code = status
        self._payload = payload

    def json(self):
        if self._payload is None:
            raise ValueError("pas de json")
        return self._payload


@pytest.fixture()
def http(monkeypatch):
    state = {"resp": _Resp(200, {}), "exc": None, "calls": []}

    def fake(url, **kw):
        state["calls"].append(url)
        if state["exc"]:
            raise state["exc"]
        return state["resp"]

    monkeypatch.setattr(client_mod.requests, "post", fake)
    monkeypatch.setattr(client_mod.requests, "get", fake)
    return state


@pytest.fixture()
def tc():
    return TaskClient(Config(api_url="http://test", agent_key="k"))


@pytest.mark.parametrize("code,expected", [
    (200, OK), (204, OK), (409, CONFLICT), (410, GONE), (401, AUTH), (403, AUTH),
    (500, RETRY), (503, RETRY), (429, RETRY), (408, RETRY), (400, REJECTED), (404, REJECTED),
])
def test_classify(code, expected):
    assert _classify(code) == expected


def test_poll_401_is_auth_not_unreachable(http, tc, caplog):
    http["resp"] = _Resp(401, {"error": "clé invalide"})
    assert tc.poll() is None and tc.last_error == AUTH and tc.last_status == 401
    assert "révoquée ou invalide" in caplog.text and "injoignable" not in caplog.text


def test_poll_network_error_is_retry(http, tc):
    http["exc"] = requests.ConnectionError("down")
    assert tc.poll() is None and tc.last_error == RETRY


def test_poll_ok_filters_garbage(http, tc):
    http["resp"] = _Resp(200, {"tasks": [{"id": "a"}, "x", None]})
    assert tc.poll() == [{"id": "a"}] and tc.last_error is None


@pytest.mark.parametrize("resp,exc,expected", [
    (_Resp(200, {"control": "pause"}), None, "pause"),
    (_Resp(200, {"control": "stop"}), None, "stop"),
    (_Resp(200, {"control": "bizarre"}), None, "none"),
    (_Resp(410, {"error": "gone"}), None, "gone"),
    (_Resp(500, None), None, "error"),
    (_Resp(200, None), None, "error"),
    (None, requests.Timeout("t"), "error"),
])
def test_get_control_mapping(http, tc, resp, exc, expected):
    http["resp"], http["exc"] = resp, exc
    assert tc.get_control("t1") == expected


def test_update_rejected_keeps_detail(http, tc):
    http["resp"] = _Resp(400, {"error": "result invalide"})
    assert tc.update("t1", "completed", result={}) == REJECTED
    assert "400" in tc.last_detail and "result invalide" in tc.last_detail
    http["resp"] = _Resp(200, {"success": True})
    assert tc.update("t1", "completed") == OK and tc.last_detail is None


def test_event_and_claim_410(http, tc):
    http["resp"] = _Resp(410, {"error": "gone"})
    assert tc.event("t1", "step_started") == GONE
    assert tc.claim("t1", 0)[0] == GONE


def test_announce_auth_sets_last_error(http, tc):
    http["resp"] = _Resp(403, {"error": "révoquée"})
    assert tc.announce(["C:/ws"]) is False and tc.last_error == AUTH
