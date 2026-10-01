"""LOT 2 — contrat d'outils unique : manifestes ↔ registre des skills ↔ validate(),
gate de permissions, catalogue généré (scripts/gen_catalog.py --check)."""
from __future__ import annotations

import copy
import importlib.util
import inspect
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

import skills
import soulbah_agent
from permissions import _PATH_KEYS, _PATH_LIST_KEYS, SERVER_CONFIRM_STEP_TYPES, INPUT_CONTROL_CATEGORIES, \
    PermissionGate
from skills import BUILTIN_REGISTRY, manifests
from skills.base import MASKED_KEYS, Skill
from skills.run_command import RunCommandSkill

AGENT_DIR = Path(__file__).resolve().parents[1]
REPO = AGENT_DIR.parent
GEN = REPO / "scripts" / "gen_catalog.py"
GENERATED = (
    "shared/tools/catalog.json",
    "backend/node-api/src/generated/tool_catalog.json",
    "backend/python-ia/app/generated/tool_catalog.json",
)
GUI_MODULES = ("pyautogui", "pygetwindow", "pyscreeze", "mss", "cv2", "PIL", "moviepy", "numpy", "pyperclip",
               "tkinter")
ALLOW_ALL = lambda _p: True  # noqa: E731 - validate() seul : la whitelist est testée par le gate


def _concrete(value, root: Path):
    """Remplace le marqueur « <dossier autorisé> » des exemples par un vrai dossier."""
    ph = manifests.WORKSPACE_PLACEHOLDER
    if isinstance(value, str) and value.startswith(ph):
        return str(root) + value[len(ph):]
    if isinstance(value, list):
        return [_concrete(v, root) for v in value]
    return value


def _example(m: dict, root: Path, index: int = 0) -> dict:
    return {k: _concrete(v, root) for k, v in m["examples"][index].items()}


def _skill(m: dict) -> Skill:
    return BUILTIN_REGISTRY[m["name"]]


# --- Registre ↔ manifestes (aussi vérifié au démarrage de l'agent) -------------------
def test_registry_and_manifests_agree():
    assert skills.manifest_errors() == []
    assert manifests.manifest_problems() == []
    declared = {t for m in manifests.MANIFESTS for t in manifests.step_types(m)}
    assert declared == set(BUILTIN_REGISTRY)


def test_manifest_errors_detects_each_kind_of_drift():
    class _Orphan(Skill):
        name = "orphan"
        step_types = ("orphan_step",)
        category = "generic"

    reg = dict(BUILTIN_REGISTRY)
    reg["orphan_step"] = _Orphan()
    assert any("orphan_step" in e and "sans manifeste" in e for e in skills.manifest_errors(reg))

    reg = dict(BUILTIN_REGISTRY)
    del reg["launch"]
    assert any("open_app" in e and "launch" in e for e in skills.manifest_errors(reg))

    class _WrongCategory(type(BUILTIN_REGISTRY["wait"])):
        category = "shell"

    reg = dict(BUILTIN_REGISTRY)
    reg["sleep"] = _WrongCategory()
    errors = skills.manifest_errors(reg)
    assert any("catégorie" in e for e in errors) and any("plusieurs skills" in e for e in errors)


def test_agent_refuses_to_start_on_manifest_drift(monkeypatch, caplog):
    monkeypatch.setattr(soulbah_agent, "_setup_logging", lambda: None)
    monkeypatch.setattr(skills, "manifest_errors", lambda registry=None: ["type « x » enregistré sans manifeste"])
    with caplog.at_level("ERROR"):
        assert soulbah_agent.main(["--dry-run", "--plan", "inexistant.json"]) == 2
    assert "Catalogue d'outils" in caplog.text


def test_manifests_import_without_gui_libraries():
    code = (
        "import importlib.util, sys\n"
        f"spec = importlib.util.spec_from_file_location('m', {str(AGENT_DIR / 'skills' / 'manifests.py')!r})\n"
        "mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)\n"
        f"sys.path.insert(0, {str(AGENT_DIR)!r})\n"
        "import skills.manifests, skills\n"
        f"loaded = [m for m in {GUI_MODULES!r} if m in sys.modules]\n"
        "print(len(mod.MANIFESTS), loaded)\n"
        "sys.exit(1 if loaded else 0)\n"
    )
    env = dict(os.environ, SOULBAH_NO_DOTENV="1")
    proc = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=env, timeout=60)
    assert proc.returncode == 0, proc.stdout + proc.stderr


# --- Manifestes ↔ paramètres réellement lus et validés par chaque skill -------------
def test_declared_params_equal_params_read_by_each_skill_module():
    by_module: dict[str, set[str]] = {}
    for step_type, skill in BUILTIN_REGISTRY.items():
        by_module.setdefault(inspect.getsourcefile(type(skill)), set()).add(step_type)
    for path, types in by_module.items():
        src = Path(path).read_text(encoding="utf-8")
        read = set(re.findall(r"\bstep\.get\(\s*[\"']([a-z_0-9]+)[\"']", src))
        read |= set(re.findall(r"\bstep\[\s*[\"']([a-z_0-9]+)[\"']\s*\]", src))
        read.discard("type")
        declared = {p["name"] for t in types for p in manifests.get_manifest(t)["params"]}
        assert declared == read, f"{Path(path).name} : déclarés {sorted(declared)} ≠ lus {sorted(read)}"


def test_examples_pass_validate_for_name_and_aliases(tmp_path):
    for m in manifests.MANIFESTS:
        for i in range(len(m["examples"])):
            step = _example(m, tmp_path, i)
            for step_type in manifests.step_types(m):
                assert _skill(m).validate(dict(step, type=step_type), ALLOW_ALL) is None, (step_type, step)


def test_required_params_and_groups_are_enforced_by_validate(tmp_path):
    for m in manifests.MANIFESTS:
        base = _example(m, tmp_path)
        for p in m["params"]:
            if p["required"]:
                step = {k: v for k, v in base.items() if k != p["name"]}
                assert _skill(m).validate(step, ALLOW_ALL), f"{m['name']} accepte sans « {p['name']} »"
        for group in m["required_any"]:
            step = {k: v for k, v in base.items() if k not in group}
            assert _skill(m).validate(step, ALLOW_ALL), f"{m['name']} accepte sans {group}"


def test_declared_constraints_are_enforced_by_validate(tmp_path):
    """enum, bornes non « clamped », longueur, nombre d'éléments, motif et extensions."""
    checked = 0
    for m in manifests.MANIFESTS:
        base = _example(m, tmp_path)
        for p in m["params"]:
            if p["deprecated"]:
                continue
            bad: list[object] = []
            if "enum" in p:
                bad.append("__hors_enum__")
            if not p.get("clamped"):
                if "max" in p:
                    bad.append(p["max"] + 1)
                if "min" in p:
                    bad.append(p["min"] - 1)
            if "max_length" in p:
                bad.append("a" * (p["max_length"] + 1))
            if "max_items" in p:
                sample = base.get(p["name"]) or ["a"]
                bad.append([sample[0]] * (p["max_items"] + 1))
            if "pattern" in p:
                bad.append("!! invalide !!")
            if p.get("extensions"):
                bad.append(str(tmp_path / "fichier.txt"))
            for value in bad:
                step = dict(base, **{p["name"]: value})
                assert _skill(m).validate(step, ALLOW_ALL), f"{m['name']}.{p['name']} accepte {value!r}"
                checked += 1
    assert checked > 30


def test_clamped_bounds_are_accepted_then_clamped(tmp_path):
    for m in manifests.MANIFESTS:
        base = _example(m, tmp_path)
        for p in m["params"]:
            if p.get("clamped"):
                assert _skill(m).validate(dict(base, **{p["name"]: p["max"] * 10}), ALLOW_ALL) is None, p["name"]


def test_skill_metadata_matches_manifests():
    for m in manifests.MANIFESTS:
        skill = _skill(m)
        assert skill.category == m["category"], m["name"]
        assert skill.timeout_s == m["timeout_s"], m["name"]
        assert m["requires_desktop_input"] == (m["category"] in INPUT_CONTROL_CATEGORIES - {"phone"}), m["name"]
        if m["security_level"] == "L0" and m["category"] in ("generic", "phone"):
            assert skill.sensitive is False, m["name"]


def test_escalation_matches_confirm_level(tmp_path):
    rc = manifests.get_manifest("run_command")
    assert rc["escalation"]["level"] == "L3"
    step = {"type": "run_command", "program": "npm", "args": ["install"], "cwd": str(tmp_path), "allow_scripts": True}
    assert RunCommandSkill().confirm_level(step) == 3
    for m in manifests.MANIFESTS:
        if "escalation" not in m:
            assert _skill(m).confirm_level(_example(m, tmp_path)) == 2, m["name"]


# --- Gate de permissions : mêmes clés que le catalogue, compatibles LOT 1 ------------
def test_gate_path_keys_and_confirm_types_come_from_manifests():
    assert set(_PATH_KEYS) == {"src", "dest", "path", "cwd", "output", "audio"}
    assert _PATH_LIST_KEYS == ("clips",)
    assert SERVER_CONFIRM_STEP_TYPES == frozenset({
        "run_command", "run_script", "shell", "write_file", "move_file", "move", "type_text", "type", "keyboard",
        "hotkey", "press", "key", "phone_tap", "phone_swipe", "phone_type", "phone_key", "phone_open_app",
    })
    assert manifests.secret_param_names() <= set(MASKED_KEYS)


def test_planned_start_recording_bg_is_accepted_by_the_agent(tmp_path):
    """Critère LOT 2 : le start_recording_bg planifié (tel que node le met en file après
    compactStep) est accepté par le gate de l'agent, path et fps compris."""
    gate = PermissionGate("auto", [str(tmp_path)], dry_run=False)
    out = str(tmp_path / "demo.mp4")
    start = {"type": "start_recording_bg", "path": out, "fps": 15, "monitor": 1, "note": "filmer la démo"}
    stop = {"type": "stop_recording_bg", "path": out}
    for step in (start, stop):
        ok, reason = gate.authorize(skills.get_skill(step["type"]), step, {"goal_meta": {"goal": "démo"}})
        assert ok, reason
    outside = dict(start, path=str(tmp_path.parent / "ailleurs.mp4"))
    assert not gate.authorize(skills.get_skill("start_recording_bg"), outside)[0]


def test_gate_checks_every_list_path_param(tmp_path):
    gate = PermissionGate("auto", [str(tmp_path)], dry_run=False)
    step = {"type": "edit_video", "clips": [str(tmp_path / "a.mp4"), "C:/ailleurs/b.mp4"],
            "output": str(tmp_path / "o.mp4")}
    ok, reason = gate.authorize(skills.get_skill("edit_video"), step)
    assert not ok and "b.mp4" in reason
    ok, reason = gate.authorize(skills.get_skill("edit_video"), dict(step, clips="a.mp4"))
    assert not ok and "liste de chemins" in reason


# --- Catalogue généré : --check et dérive ------------------------------------------
def _gen(*args: str) -> subprocess.CompletedProcess:
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    return subprocess.run([sys.executable, str(GEN), *args], capture_output=True, text=True, encoding="utf-8",
                          env=env, timeout=120)


def _copy_outputs(root: Path) -> None:
    for rel in (*GENERATED, "shared/schemas/tool_catalog.schema.json"):
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(REPO / rel, root / rel)


def test_committed_catalog_matches_manifests():
    proc = _gen("--check")
    assert proc.returncode == 0, proc.stdout + proc.stderr


def test_check_detects_a_mutated_catalog(tmp_path):
    _copy_outputs(tmp_path)
    assert _gen("--check", "--root", str(tmp_path)).returncode == 0

    target = tmp_path / GENERATED[0]
    catalog = json.loads(target.read_text(encoding="utf-8"))
    tool = next(t for t in catalog["tools"] if t["name"] == "start_recording_bg")
    tool["params"] = [p for p in tool["params"] if p["name"] != "fps"]
    target.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    proc = _gen("--check", "--root", str(tmp_path))
    assert proc.returncode == 1, proc.stdout + proc.stderr
    assert "shared/tools/catalog.json" in proc.stdout and '+          "name": "fps"' in proc.stdout


def test_check_detects_a_stale_service_copy_and_crlf_is_tolerated(tmp_path):
    _copy_outputs(tmp_path)
    shared = tmp_path / GENERATED[0]
    shared.write_bytes(shared.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))  # checkout Windows
    assert _gen("--check", "--root", str(tmp_path)).returncode == 0
    node_copy = tmp_path / GENERATED[1]
    node_copy.write_text(node_copy.read_text(encoding="utf-8").replace('"L1"', '"L0"', 1), encoding="utf-8")
    proc = _gen("--check", "--root", str(tmp_path))
    assert proc.returncode == 1 and "node-api/src/generated/tool_catalog.json" in proc.stdout


def test_generation_is_deterministic(tmp_path):
    (tmp_path / "shared" / "schemas").mkdir(parents=True)
    shutil.copyfile(REPO / "shared/schemas/tool_catalog.schema.json",
                    tmp_path / "shared/schemas/tool_catalog.schema.json")
    assert _gen("--root", str(tmp_path)).returncode == 0
    for rel in GENERATED:
        produced = (tmp_path / rel).read_bytes()
        assert b"\r\n" not in produced
        assert produced == (REPO / rel).read_bytes().replace(b"\r\n", b"\n"), rel


def test_invalid_manifests_exit_2(tmp_path):
    src = (AGENT_DIR / "skills" / "manifests.py").read_text(encoding="utf-8")
    broken = tmp_path / "manifests.py"
    broken.write_text(src.replace('"move_mouse",', '"drag",', 1), encoding="utf-8")
    _copy_outputs(tmp_path)
    proc = _gen("--check", "--root", str(tmp_path), "--manifests", str(broken))
    assert proc.returncode == 2 and "drag" in proc.stdout


def test_schema_validator_rejects_a_bad_catalog():
    spec = importlib.util.spec_from_file_location("gen_catalog_t", GEN)
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)
    schema = json.loads((REPO / "shared/schemas/tool_catalog.schema.json").read_text(encoding="utf-8"))
    good = manifests.build_catalog()
    assert gen.validate(good, schema, schema) == []
    bad = copy.deepcopy(good)
    bad["tools"][0]["security_level"] = "L9"
    bad["tools"][1]["params"].append({"name": "Pas Un Nom"})
    del bad["tools"][2]["examples"]
    errors = gen.validate(bad, schema, schema)
    assert any("L9" in e for e in errors)
    assert any("Pas Un Nom" in e for e in errors)
    assert any("examples" in e for e in errors)
    with pytest.raises(ValueError, match="non supporté"):
        gen.validate(1, {"oneOf": []}, {})
