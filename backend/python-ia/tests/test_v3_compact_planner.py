"""V3 — planificateur et évaluateur compacts pour les modèles locaux.

Défaut constaté en conditions réelles : le prompt complet du planificateur (≈ 7 000 jetons)
dépassait le contexte du modèle local (4 096) ; l'interface renvoyait 502 et aucune action n'était
lancée. Quand le premier modèle de la chaîne est local, le prompt ne contient que les outils
pertinents et la sortie est contrainte par un schéma JSON.
"""
from __future__ import annotations

import asyncio
import json
from types import SimpleNamespace

import pytest

from app import compact_planner as CP
from app import reasoning


def test_categories_follow_the_goal():
    assert "filesystem" in CP.categories_for("Crée le dossier rapport et écris bonjour dans note.txt")
    cats = CP.categories_for("Ouvre le bloc-notes et tape bonjour")
    assert "app_launch" in cats and "keyboard" in cats
    assert "shell" in CP.categories_for("Lance les tests npm du projet")
    assert set(CP.DEFAULT) <= set(CP.categories_for("fais quelque chose d'utile"))
    assert "web" not in CP.categories_for("ouvre la page web http://exemple.com", internet=False)
    for cat in CP.ALWAYS:
        assert cat in CP.categories_for("Crée un dossier")


def test_compact_prompt_fits_a_small_context():
    full = len(reasoning._PLAN_SYSTEM)
    for goal in ("Crée le dossier rapport et écris bonjour dans note.txt", "Ouvre le bloc-notes et tape bonjour",
                 "Enregistre l'écran pendant que tu ouvres VS Code puis lance les tests npm"):
        system, schema = CP.plan_system(reasoning._CATALOG, goal)
        assert len(system) < 6000 < full, (len(system), full)
        names = [v["properties"]["type"]["const"] for v in schema["properties"]["steps"]["items"]["anyOf"]]
        assert set(names) <= reasoning.VALID_STEP_TYPES and "wait" in names


def test_plan_goal_uses_compact_prompt_and_schema_with_a_local_model(monkeypatch):
    seen = {}

    async def fake_generate(task, system, messages, max_tokens, json_schema=None, **_kw):
        seen.update(task=task, system=system, schema=json_schema, max_tokens=max_tokens)
        plan = {"understanding": "créer le dossier", "feasible": True, "reason": "",
                "steps": [{"type": "make_dir", "path": "C:\\w\\rapport", "note": "dossier"},
                          {"type": "format_disk", "note": "inventé"}]}
        return SimpleNamespace(text=json.dumps(plan))

    monkeypatch.setattr(reasoning, "_local_first", lambda task, vision=False: True)
    monkeypatch.setattr(reasoning.orchestrator, "generate", fake_generate)
    plan = asyncio.run(reasoning.plan_goal("Crée le dossier rapport", "DOSSIERS AUTORISÉS : C:\\w"))
    assert seen["task"] == "automation" and seen["max_tokens"] == CP.PLAN_MAX_TOKENS
    assert seen["schema"]["required"] == ["understanding", "feasible", "reason", "steps"]
    assert "make_dir" in seen["system"] and len(seen["system"]) < 6000
    assert [s["type"] for s in plan["steps"]] == ["make_dir"]  # outil inventé toujours filtré
    assert plan["feasible"] is True


def test_evaluation_without_vision_model_judges_the_report(monkeypatch):
    seen = {}

    async def fake_generate(task, system, messages, max_tokens, json_schema=None, **_kw):
        seen.update(task=task, user=messages[-1]["content"], schema=json_schema)
        return SimpleNamespace(text=json.dumps({"verdict": "success", "reason": "fichier écrit", "corrective_steps": []}))

    monkeypatch.setattr(reasoning, "_vision_available", lambda: False)
    monkeypatch.setattr(reasoning, "_local_first", lambda task, vision=False: True)
    monkeypatch.setattr(reasoning.orchestrator, "generate", fake_generate)
    steps = [{"type": "write_file", "path": "C:\\w\\a.txt", "content": "bonjour"}]
    result = {"ok": True, "steps": [{"index": 0, "type": "write_file", "ok": True, "detail": "écrit : C:\\w\\a.txt"}]}
    ev = asyncio.run(reasoning.evaluate_execution("écrire bonjour", steps, result, screenshots=["aGVsbG8="]))
    assert ev["verdict"] == "success" and seen["task"] == "evaluation"
    assert seen["schema"] == CP.EVAL_SCHEMA


def test_cloud_path_unchanged_when_first_model_is_not_local(monkeypatch):
    called = {}

    async def fake_text(system, messages, max_tokens=4096, task="reasoning", provider=None):
        called.update(system=system, task=task)
        return {"understanding": "x", "feasible": True, "reason": "", "steps": [{"type": "wait", "seconds": 1}]}

    monkeypatch.setattr(reasoning, "_local_first", lambda task, vision=False: False)
    monkeypatch.setattr(reasoning, "text_generate_json", fake_text)
    asyncio.run(reasoning.plan_goal("attendre"))
    assert called["system"] == reasoning._PLAN_SYSTEM


@pytest.mark.parametrize("goal", ["Crée le dossier rapport", "Ouvre le bloc-notes"])
def test_plan_schema_enum_matches_prompt_tools(goal):
    system, schema = CP.plan_system(reasoning._CATALOG, goal)
    for variant in schema["properties"]["steps"]["items"]["anyOf"]:
        assert f"- {variant['properties']['type']['const']} [" in system


def test_each_tool_variant_requires_its_mandatory_fields():
    """Défaut constaté en direct : le petit modèle oubliait « path » de make_dir. Chaque outil a sa
    variante de schéma avec ses champs obligatoires : la grammaire l'oblige à les écrire."""
    _system, schema = CP.plan_system(reasoning._CATALOG, "Crée le dossier rapport et écris bonjour dans note.txt")
    by_name = {v["properties"]["type"]["const"]: v for v in schema["properties"]["steps"]["items"]["anyOf"]}
    assert by_name["make_dir"]["required"] == ["type", "path", "note"]
    wf = next(t for t in reasoning._CATALOG["tools"] if t["name"] == "write_file")
    assert by_name["write_file"]["required"] == ["type", *[p["name"] for p in wf["params"] if p["required"]], "note"]
    assert by_name["make_dir"]["additionalProperties"] is False
    _system, schema = CP.plan_system(reasoning._CATALOG, "Ouvre le bloc-notes")
    by_name = {v["properties"]["type"]["const"]: v for v in schema["properties"]["steps"]["items"]["anyOf"]}
    assert "app" in by_name["open_app"]["required"]  # groupe « au moins l'un de » : premier champ courant


def test_allowed_dirs_parsed_from_node_context():
    ctx = ("DOSSIERS AUTORISÉS (whitelist de l'agent ciblé) — tout chemin DOIT être absolu :\n"
           "- C:\\Users\\x\\SoulbahWorkspace\\\n- D:\\Projets\nAutre ligne")
    assert CP.allowed_dirs_from_context(ctx) == ["C:\\Users\\x\\SoulbahWorkspace", "D:\\Projets"]
    assert CP.allowed_dirs_from_context(None) == []
