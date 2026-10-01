"""LOT 2 — contrat d'outils unique : le prompt du planificateur est construit depuis le
catalogue généré (app/generated/tool_catalog.json), jamais depuis une liste à la main."""
from __future__ import annotations

import asyncio
import copy
import json
from pathlib import Path

import pytest

from app import reasoning, tool_catalog

CATALOG = tool_catalog.load_catalog()
SHARED = Path(__file__).resolve().parents[3] / "shared" / "tools" / "catalog.json"


def _tool_block(prompt: str, name: str) -> list[str]:
    """Lignes du bloc d'un outil dans le prompt : « - name [niveau] … » et ses champs."""
    lines = prompt.splitlines()
    start = next((i for i, ln in enumerate(lines) if ln.startswith(f"- {name} [")), None)
    assert start is not None, f"outil absent du prompt : {name}"
    block = [lines[start]]
    for ln in lines[start + 1:]:
        if not ln.startswith("    "):
            break
        block.append(ln)
    return block


@pytest.mark.skipif(not SHARED.is_file(), reason="shared/ absent (image Docker)")
def test_generated_copy_matches_shared_catalog():
    norm = lambda p: p.read_text(encoding="utf-8").replace("\r\n", "\n")  # noqa: E731
    assert norm(tool_catalog.CATALOG_PATH) == norm(SHARED)


@pytest.mark.parametrize("system", ["_PLAN_SYSTEM", "_EVAL_SYSTEM", "_IMPROVE_SYSTEM"])
def test_prompt_lists_every_catalog_tool_with_level_and_params(system):
    prompt = getattr(reasoning, system)
    for tool in CATALOG["tools"]:
        block = _tool_block(prompt, tool["name"])
        head = block[0]
        assert head.startswith(f"- {tool['name']} [{tool['security_level']}"), head
        if tool.get("escalation"):
            assert f"{tool['escalation']['level']} si" in head
        body = "\n".join(block[1:])
        deprecated = {p["name"] for p in tool["params"] if p["deprecated"]}
        group_heads = {next(g for g in group if g not in deprecated) for group in tool["required_any"]}
        for p in tool["params"]:
            if p["deprecated"]:
                assert f"· {p['name']}" not in body, (tool["name"], p["name"])
                continue
            starred = p["required"] or p["name"] in group_heads
            marker = f"· {p['name']}*" if starred else f"· {p['name']} ("
            assert marker in body, (tool["name"], p["name"])
            for value in p.get("enum", []):
                assert value in body, (tool["name"], p["name"], value)
        if not [p for p in tool["params"] if not p["deprecated"]]:
            assert "aucun champ" in body


def test_aliases_are_never_offered_to_the_planner():
    prompt = reasoning._PLAN_SYSTEM
    for tool in CATALOG["tools"]:
        for alias in tool["aliases"]:
            assert f"- {alias} [" not in prompt, alias


def test_required_any_groups_mark_the_current_param_required():
    open_app = "\n".join(_tool_block(reasoning.SKILLS_CATALOG, "open_app"))
    assert "· app*" in open_app and "software" not in open_app
    window = "\n".join(_tool_block(reasoning.SKILLS_CATALOG, "window"))
    assert "· window_title*" in window and "· title" not in window


def test_valid_step_types_are_the_catalog_names():
    assert reasoning.VALID_STEP_TYPES == frozenset(t["name"] for t in CATALOG["tools"])
    steps = [{"type": t["name"]} for t in CATALOG["tools"]] + [{"type": "rm_rf"}, {"type": "sleep"}, "x"]
    kept = reasoning._sanitize_steps(steps)
    assert [s["type"] for s in kept] == [t["name"] for t in CATALOG["tools"]]


def test_path_constraint_lists_every_catalog_path_param():
    paths = tool_catalog.path_params()
    assert paths == ["audio", "clips", "cwd", "dest", "output", "path", "repo", "src"]  # repo : LOT 12 (git)
    assert f"chaque chemin ({', '.join(paths)})" in reasoning.SKILLS_CATALOG


def test_secret_params_are_masked_before_the_llm():
    secrets = tool_catalog.secret_params()
    assert secrets and secrets <= reasoning._MASKED_KEYS


def test_prompt_is_built_from_the_catalog_not_by_hand():
    fake = copy.deepcopy(CATALOG)
    fake["tools"].append({
        "name": "sonde_test", "aliases": [], "version": "0.1.0", "description": "Outil fictif.",
        "category": "inconnue", "security_level": "L3", "requires_desktop_input": False,
        "requires_confirmation": True, "idempotent": False, "timeout_s": None,
        "params": [{"name": "cible", "type": "string", "description": "Cible.", "required": True,
                    "is_path": True, "is_secret_text": False, "deprecated": False}],
        "required_any": [], "evidence": [], "examples": [{"type": "sonde_test", "cible": "<dossier autorisé>/x"}],
        "known_errors": [],
    })
    text = reasoning.build_skills_catalog(fake)
    block = "\n".join(_tool_block(text, "sonde_test"))
    assert block.startswith("- sonde_test [L3] : Outil fictif.")
    assert "· cible* (chemin absolu) : Cible." in block
    assert "Autres :" in text
    assert "chaque chemin (audio, cible, clips" in text
    assert "sonde_test" in reasoning.tool_names(fake)


def test_examples_are_rendered_type_first():
    line = next(ln for ln in _tool_block(reasoning.SKILLS_CATALOG, "start_recording_bg") if "Ex. :" in ln)
    example = json.loads(line.split("Ex. : ", 1)[1])
    assert list(example)[0] == "type" and example["type"] == "start_recording_bg"


def test_corrupted_catalog_is_refused():
    dup = copy.deepcopy(CATALOG)
    dup["tools"][1]["aliases"] = [dup["tools"][0]["name"]]
    with pytest.raises(ValueError, match="en double"):
        tool_catalog._check(dup)
    with pytest.raises(ValueError):
        tool_catalog._check({"tools": []})


def test_plan_keeps_start_recording_bg_path_and_fps(fake_llm):
    steps = [
        {"type": "start_recording_bg", "path": "C:/w/demo.mp4", "fps": 15, "note": "filmer"},
        {"type": "open_app", "app": "notepad"},
        {"type": "stop_recording_bg", "path": "C:/w/demo.mp4"},
    ]
    fake_llm.reply = json.dumps({"understanding": "u", "feasible": True, "steps": steps})
    out = asyncio.run(reasoning.plan_goal("filme une démo", "DOSSIERS AUTORISÉS : C:/w"))
    assert out["feasible"] is True and out["steps"] == steps
    system = fake_llm.calls[0]["system"]
    assert "- start_recording_bg [L1]" in system and "· fps (entier" in system
