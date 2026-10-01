"""LOT 6 — politique du gate testée pour CHAQUE outil du catalogue (manifests.MANIFESTS),
à partir des exemples des manifestes :

  - L0 → autorisé sans confirmation (mode auto, hors dry-run) ;
  - `requires_confirmation` → confirmation exigée quand le serveur pose
    payload.requires_confirmation (même en auto + allow_input_control) ;
  - catégorie `shell` → toujours confirmée ;
  - `requires_desktop_input` sans allow_input_control → confirmation ;
  - paramètres `is_path` hors dossiers autorisés → refus (même en dry-run) ;
  - dry-run → validé puis autorisé sans confirmation."""
from __future__ import annotations

import os

import pytest

import permissions
from permissions import PermissionGate
from skills import REGISTRY
from skills import type_text as tt
from skills.manifests import MANIFESTS, WORKSPACE_PLACEHOLDER

NAMES = [m["name"] for m in MANIFESTS]
BY_NAME = {m["name"]: m for m in MANIFESTS}


def _subst(value, root: str):
    if isinstance(value, str):
        # Seuls les chemins (préfixés par le dossier autorisé) changent de séparateur : une
        # branche git (soulbah/s1/t1) ou une URL garde ses « / ».
        if value.startswith(WORKSPACE_PLACEHOLDER):
            return value.replace(WORKSPACE_PLACEHOLDER, root).replace("/", os.sep)
        return value
    if isinstance(value, list):
        return [_subst(v, root) for v in value]
    return value


def _example(name: str, root: str) -> dict:
    ex = BY_NAME[name]["examples"][0]
    return {k: _subst(v, root) for k, v in ex.items()}


@pytest.fixture()
def ws(tmp_path, monkeypatch):
    allowed = tmp_path / "ws"
    allowed.mkdir()
    (allowed / "app").mkdir()
    outside = tmp_path / "ailleurs"
    outside.mkdir()
    # Fenêtre au premier plan inconnue : déterministe (type_text.input_risk).
    monkeypatch.setattr(tt.desktop, "foreground_window", lambda: None)
    return str(allowed), str(outside)


@pytest.fixture()
def asker(monkeypatch):
    calls = []
    monkeypatch.setattr(permissions, "_timed_input", lambda p, t, should_stop=None: calls.append(p) or "n")
    return calls


def test_every_tool_has_an_example_and_a_skill():
    for m in MANIFESTS:
        assert m["examples"], m["name"]
        assert m["name"] in REGISTRY, m["name"]


@pytest.mark.parametrize("name", NAMES)
def test_dry_run_authorizes_valid_example_without_confirmation(name, ws, asker):
    allowed, _ = ws
    gate = PermissionGate("confirm", [allowed], dry_run=True)
    step = _example(name, allowed)
    ok, reason = gate.authorize(REGISTRY[name], step, {"requires_confirmation": True})
    assert ok and reason == "dry-run" and asker == []


@pytest.mark.parametrize("name", [n for n in NAMES if BY_NAME[n]["security_level"] == "L0"])
def test_l0_tools_run_without_confirmation(name, ws, asker):
    allowed, _ = ws
    gate = PermissionGate("auto", [allowed], dry_run=False)
    ok, reason = gate.authorize(REGISTRY[name], _example(name, allowed), {})
    assert ok and asker == [], (name, reason)
    assert not BY_NAME[name]["requires_confirmation"] and not BY_NAME[name]["requires_desktop_input"]


@pytest.mark.parametrize("name", [n for n in NAMES if BY_NAME[n]["requires_confirmation"]])
def test_requires_confirmation_tools_confirmed_when_server_asks(name, ws, asker):
    allowed, _ = ws
    gate = PermissionGate("auto", [allowed], dry_run=False, allow_input_control=True)
    ok, reason = gate.authorize(REGISTRY[name], _example(name, allowed), {"requires_confirmation": True})
    assert not ok and len(asker) == 1, (name, reason)
    assert "refus" in reason


@pytest.mark.parametrize("name", [n for n in NAMES if BY_NAME[n]["category"] == "shell"])
def test_shell_tools_always_confirmed(name, ws, asker):
    allowed, _ = ws
    gate = PermissionGate("auto", [allowed], dry_run=False, allow_input_control=True)
    ok, _ = gate.authorize(REGISTRY[name], _example(name, allowed), {})
    assert not ok and len(asker) == 1, name


@pytest.mark.parametrize("name", [n for n in NAMES if BY_NAME[n]["requires_desktop_input"]])
def test_desktop_input_tools_confirmed_without_preauthorization(name, ws, asker):
    allowed, _ = ws
    gate = PermissionGate("auto", [allowed], dry_run=False, allow_input_control=False)
    ok, _ = gate.authorize(REGISTRY[name], _example(name, allowed), {})
    assert not ok and len(asker) == 1, name
    assert REGISTRY[name].category in permissions.INPUT_CONTROL_CATEGORIES


@pytest.mark.parametrize("name", [n for n in NAMES if any(p["is_path"] for p in BY_NAME[n]["params"])])
def test_path_params_outside_workspace_refused(name, ws, asker):
    allowed, outside = ws
    gate_live = PermissionGate("auto", [allowed], dry_run=False, allow_input_control=True)
    gate_dry = PermissionGate("auto", [allowed], dry_run=True, allow_input_control=True)
    good = _example(name, allowed)
    for p in BY_NAME[name]["params"]:
        if not p["is_path"] or p["name"] not in good:
            continue
        bad = dict(good)
        if isinstance(good[p["name"]], list):
            bad[p["name"]] = [os.path.join(outside, os.path.basename(str(v))) for v in good[p["name"]]]
        else:
            bad[p["name"]] = os.path.join(outside, os.path.basename(str(good[p["name"]])))
        for gate in (gate_live, gate_dry):
            ok, reason = gate.authorize(REGISTRY[name], bad, {})
            assert not ok and "hors liste blanche" in reason, (name, p["name"], reason)
    assert asker == []  # un refus de chemin ne demande jamais de confirmation


@pytest.mark.parametrize("name", [n for n in NAMES if BY_NAME[n]["security_level"] in ("L1", "L2")
                                  and not BY_NAME[n]["requires_desktop_input"]
                                  and not BY_NAME[n]["requires_confirmation"]
                                  and BY_NAME[n]["category"] not in ("shell", "phone")])
def test_confined_l1_l2_tools_run_in_auto_without_server_flag(name, ws, asker):
    """Fichiers, captures, vidéo : en mode auto sans drapeau serveur, pas de confirmation
    (bornés par la whitelist et la deny-list)."""
    allowed, _ = ws
    gate = PermissionGate("auto", [allowed], dry_run=False)
    ok, reason = gate.authorize(REGISTRY[name], _example(name, allowed), {"goal_meta": True})
    assert ok and asker == [], (name, reason)
