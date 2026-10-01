"""LOT 11 — /v2/planner/propose : le modèle propose un DAG, python-ia n'en nettoie que la forme
(la validation métier est faite par node-api). FakeProvider uniquement, aucun appel réseau."""
from __future__ import annotations

import json

from app.v2.planner import PLAN_SCHEMA, sanitize_plan

from .fakes import FakeProvider

ROLES = [
    {"name": "desktop_operator", "description": "bureau", "executor": "runtime", "max_security_level": "L2",
     "tools": ["screenshot", "type_text", "wait"]},
    {"name": "qa_reviewer", "description": "relecture", "executor": "p1", "max_security_level": "L0", "tools": []},
]


def test_propose_returns_sanitized_plan_and_prompt_lists_roles(client, use_providers):
    reply = {
        "understanding": "taper bonjour", "feasible": True, "reason": "",
        "nodes": [
            {"key": "observe", "title": "Observer", "role": "desktop_operator", "security_level": "L1",
             "steps": [{"type": "screenshot"}]},
            {"key": "act", "title": "Taper", "role": "desktop_operator", "security_level": "L2",
             "steps": [{"type": "type_text", "text": "bonjour"}, "pas un objet"],
             "acceptance_criteria": [{"type": "ui_element_state", "window_title": "Bloc-notes"}], "extra": 1},
            "ignoré",
        ],
        "edges": [{"from": "observe", "to": "act"}, {"from": "x"}],
    }
    fake = FakeProvider("fake", script=[json.dumps(reply)])
    use_providers({"fake": fake})
    r = client.post("/v2/planner/propose", json={"goal": "Tape bonjour dans le bloc-notes", "roles": ROLES,
                                                "allowed_dirs": [r"C:\w"], "max_security_level": "L2"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["feasible"] is True and body["understanding"] == "taper bonjour"
    plan = body["plan"]
    assert [n["key"] for n in plan["nodes"]] == ["observe", "act"]
    assert plan["nodes"][1]["spec"]["steps"] == [{"type": "type_text", "text": "bonjour"}]
    assert "extra" not in plan["nodes"][1]
    assert plan["edges"] == [{"from": "observe", "to": "act", "kind": "hard"}]
    assert fake.calls[0]["json_schema"] == PLAN_SCHEMA
    assert body["usage"]["provider"] == "fake"
    prompt = fake.calls[0]["messages"][0]["content"]
    assert "Tape bonjour" in prompt


def test_propose_infeasible_and_validation(client, use_providers):
    use_providers({"fake": FakeProvider("fake", script=[json.dumps({"understanding": "?", "feasible": True,
                                                                   "reason": "", "nodes": [], "edges": []})])})
    r = client.post("/v2/planner/propose", json={"goal": "x", "roles": ROLES})
    assert r.status_code == 200 and r.json()["feasible"] is False  # aucun nœud : jamais « faisable »
    assert client.post("/v2/planner/propose", json={"goal": "  ", "roles": ROLES}).status_code == 400
    assert client.post("/v2/planner/propose", json={"goal": "x", "roles": []}).status_code == 422
    assert client.post("/v2/planner/propose", json={"goal": "x", "roles": [{"name": "Bad Name"}]}).status_code == 422


def test_sanitize_plan_bounds_and_defaults():
    plan = sanitize_plan({"nodes": [{"key": "a", "role": "coder", "security_level": "L9"}] * 40,
                          "edges": [{"from": "a", "to": "b", "kind": "weird"}]})
    assert len(plan["nodes"]) == 30
    assert plan["nodes"][0]["security_level"] == "L1" and plan["nodes"][0]["title"] == "a"
    assert plan["nodes"][0]["acceptance_criteria"] == []
    assert plan["edges"] == [{"from": "a", "to": "b", "kind": "hard"}]
