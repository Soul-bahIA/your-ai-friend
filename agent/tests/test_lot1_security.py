"""LOT 1 — sécurité de l'agent : workspace + deny-list (S1), git (S2, PoC du hook),
contrôle d'entrée (S3, S6, S25, T22), confirmations complètes (S5, S7), presse-papier
(S8), fenêtres (S24), TOCTOU (S28), captures (S17), interpréteur Store (T42)."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import types

import pytest

import permissions
import soulbah_agent
from executor import Executor
from permissions import PermissionGate, workspace_errors
from skills import REGISTRY
from skills import type_text as tt
from skills.base import SkillResult
from skills.filesystem import FileOpsSkill, content_details
from skills.hotkey import HotkeySkill, hotkey_risk, normalize_keys
from skills.mouse import MouseSkill
from skills.move_file import MoveFileSkill
from skills.phone import PhoneSkill
from skills.run_command import (
    GIT_HARDENING,
    RunCommandSkill,
    _find_executable,
    _missing_message,
    check_command,
    describe_command,
    effective_args,
    is_store_stub,
)
from skills.safety import AGENT_DIR, REPO_ROOT, deny_reason
from skills.type_text import TypeTextSkill
from skills.window import WindowSkill

WIN = sys.platform == "win32"


@pytest.fixture()
def ws(tmp_path):
    root = tmp_path / "workspace"
    (root / "proj").mkdir(parents=True)
    outside = tmp_path / "outside"
    outside.mkdir()
    return root, outside


def _asker(monkeypatch, answer="n"):
    calls = []

    def fake(prompt, timeout, should_stop=None):
        calls.append(prompt)
        return answer

    monkeypatch.setattr(permissions, "_timed_input", fake)
    return calls


# --- S1 : sondes de la deny-list (critère de sortie du LOT 1) -----------------------------
@pytest.mark.skipif(REPO_ROOT is None, reason="dépôt SoulBah introuvable")
def test_probe_read_backend_env_refused_even_if_repo_whitelisted(monkeypatch):
    calls = _asker(monkeypatch, "o")
    gate = PermissionGate("auto", [REPO_ROOT], dry_run=False)  # mauvaise config volontaire
    ok, reason = gate.authorize(FileOpsSkill(), {"type": "read_file",
                                                 "path": os.path.join(REPO_ROOT, "backend", ".env")})
    assert not ok and "interdit" in reason and calls == []


@pytest.mark.skipif(REPO_ROOT is None, reason="dépôt SoulBah introuvable")
def test_probe_write_agent_code_refused(monkeypatch):
    _asker(monkeypatch, "o")
    gate = PermissionGate("auto", [REPO_ROOT], dry_run=False)
    for name in ("permissions.py", ".env", os.path.join("skills", "run_command.py")):
        ok, reason = gate.authorize(FileOpsSkill(), {"type": "write_file", "content": "x",
                                                     "path": os.path.join(AGENT_DIR, name)})
        assert not ok and "interdit" in reason


def test_probe_phone_tap_auto_requires_confirmation(ws, monkeypatch):
    root, _ = ws
    calls = _asker(monkeypatch, "n")
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    ok, _ = gate.authorize(PhoneSkill(), {"type": "phone_tap", "x": 10, "y": 20})
    assert not ok and len(calls) == 1
    # Sans console : refus.
    monkeypatch.setattr(permissions, "_timed_input", lambda *a, **k: (_ for _ in ()).throw(EOFError()))
    assert not gate.authorize(PhoneSkill(), {"type": "phone_key", "keycode": "KEYCODE_HOME"})[0]


@pytest.mark.parametrize("rel", [
    ".env", "sub/.env", "app/prod.env", ".env.local", ".ssh/config", ".gnupg/pubring.kbx",
    "id_rsa", "keys/id_ed25519.pub", "certs/server.pem", "tls/server.key", "x.ppk",
    ".git/config", "repo/.git/hooks/pre-commit",
])
def test_deny_list_inside_workspace(ws, rel):
    root, _ = ws
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    path = str(root / rel)
    assert deny_reason(path) is not None
    assert not gate.authorize(FileOpsSkill(), {"type": "read_file", "path": path})[0]


def test_deny_list_bare_git_dir(ws):
    root, _ = ws
    gd = root / "gd"
    (gd / "objects").mkdir(parents=True)
    (gd / "refs").mkdir()
    (gd / "HEAD").write_text("ref: refs/heads/main\n")
    assert deny_reason(str(gd / "hooks" / "pre-commit")) == "données internes d'un dépôt git"
    assert deny_reason(str(root / "proj" / "ok.txt")) is None


def test_workspace_errors():
    assert workspace_errors([AGENT_DIR])
    assert workspace_errors([os.path.dirname(AGENT_DIR)])  # contient l'agent
    if REPO_ROOT:
        assert workspace_errors([REPO_ROOT])
        assert workspace_errors([os.path.join(REPO_ROOT, "frontend")])  # dans le dépôt
        assert workspace_errors([os.path.dirname(REPO_ROOT)])  # contient le dépôt


def test_workspace_outside_repo_ok(tmp_path):
    assert workspace_errors([str(tmp_path)]) == []


@pytest.mark.skipif(REPO_ROOT is None, reason="dépôt SoulBah introuvable")
def test_main_refuses_repo_as_workspace(monkeypatch):
    monkeypatch.setattr(soulbah_agent, "_setup_logging", lambda: None)
    monkeypatch.setattr(soulbah_agent, "TaskClient", lambda *a: pytest.fail("ne doit pas démarrer"))
    monkeypatch.setenv("SOULBAH_AGENT_KEY", "k")
    monkeypatch.setenv("SOULBAH_ALLOWED_DIRS", REPO_ROOT)
    assert soulbah_agent.main(["--once"]) == 2


def test_main_creates_default_workspace(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(soulbah_agent, "_setup_logging", lambda: None)
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    monkeypatch.setenv("SOULBAH_ALLOWED_DIRS", "")
    plan = tmp_path / "plan.json"
    plan.write_text(json.dumps([{"type": "wait", "seconds": 0}]), encoding="utf-8")
    assert soulbah_agent.main(["--plan", str(plan)]) == 0
    assert (tmp_path / "SoulbahWorkspace").is_dir()
    capsys.readouterr()


# --- S2 : git ---------------------------------------------------------------------------------
GIT_REFUSED = [
    ["init", "--separate-git-dir=../gd"],
    ["init", "--separate-git-dir", "gd"],
    ["init", "--sep=gd"],
    ["init", "--separate-git=gd"],
    ["init", "--template=tpl"],
    ["init", "--templ=tpl"],
    ["init", "--bare"],
    ["init", "--shared"],
    ["init", "a", "b"],
    ["init", "../../outside"],
    ["branch", "-D", "x"],
    ["branch", "--delete", "--force", "x"],
    ["branch", "-df", "x"],
    ["branch", "-fd", "x"],
    ["branch", "-f", "x", "HEAD"],
    ["branch", "--forc", "x"],
    ["branch", "-M", "a", "b"],
    ["commit", "-c", "HEAD"],
    ["diff", "--out=x.txt"],
    ["log", "--output=x.txt"],
    ["add", ".env"],
    ["add", "config/.env.local"],
    ["show", "HEAD:.env"],
    ["add", "id_rsa"],
    ["add", "server.pem"],
    ["add", ".git/hooks/pre-commit"],
]


@pytest.mark.parametrize("args", GIT_REFUSED)
def test_git_dangerous_options_refused(ws, args):
    root, _ = ws
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    assert check_command("git", args, str(root / "proj"), gate.path_allowed) is not None


GIT_OK = [
    ["init"], ["init", "-b", "main"], ["init", "--initial-branch=main"], ["init", "-q", "newrepo"],
    ["branch", "-d", "old"], ["branch", "-m", "old", "new"], ["commit", "-m", "fix .env loading"],
    ["diff", "--output-indicator-new=+"], ["log", "--oneline", "--name-only"],
]


@pytest.mark.parametrize("args", GIT_OK)
def test_git_legit_options_accepted(ws, args):
    root, _ = ws
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    assert check_command("git", args, str(root / "proj"), gate.path_allowed) is None


def test_git_branch_delete_is_l3(ws, monkeypatch):
    root, _ = ws
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    step = {"type": "run_command", "program": "git", "args": ["branch", "-d", "old"], "cwd": str(root / "proj")}
    assert RunCommandSkill().confirm_level(step) == 3
    _asker(monkeypatch, "o")
    assert not gate.authorize(RunCommandSkill(), step)[0]  # « o » ne suffit pas en L3
    _asker(monkeypatch, "confirmer")
    assert gate.authorize(RunCommandSkill(), step)[0]


def test_git_always_hardened():
    step = {"program": "git", "args": ["status"]}
    assert effective_args(step)[: len(GIT_HARDENING)] == list(GIT_HARDENING)
    assert "core.hooksPath=/dev/null" in effective_args(step)


def test_hook_poc_refused(ws, monkeypatch):
    """PoC de l'audit : git init --separate-git-dir, écriture d'un hook, git commit."""
    root, _ = ws
    _asker(monkeypatch, "o")
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    proj = root / "proj"
    step1 = {"type": "run_command", "program": "git", "cwd": str(proj),
             "args": ["init", f"--separate-git-dir={root / 'gd'}"]}
    assert not gate.authorize(RunCommandSkill(), step1)[0]
    # Même si un tel dépôt existait déjà (créé avant le LOT 1), ses hooks sont intouchables.
    gd = root / "gd"
    (gd / "objects").mkdir(parents=True)
    (gd / "refs").mkdir()
    (gd / "HEAD").write_text("ref: refs/heads/main\n")
    hook = {"type": "write_file", "path": str(gd / "hooks" / "pre-commit"), "content": "#!/bin/sh\ncalc\n"}
    assert not gate.authorize(FileOpsSkill(), hook)[0]
    assert not gate.authorize(FileOpsSkill(), dict(hook, path=str(proj / ".git" / "hooks" / "pre-commit")))[0]
    assert not gate.authorize(FileOpsSkill(), {"type": "make_dir", "path": str(proj / ".git" / "hooks")})[0]
    (root / "evil.sh").write_text("#!/bin/sh\n")
    assert not gate.authorize(MoveFileSkill(), {"type": "move_file", "src": str(root / "evil.sh"),
                                                "dest": str(gd / "hooks" / "post-commit")})[0]
    assert not os.path.exists(gd / "hooks")


@pytest.mark.skipif(shutil.which("git") is None, reason="git absent")
def test_existing_hook_never_runs_on_agent_commit(ws, monkeypatch):
    """Un hook déjà présent (planté avant le LOT 1) ne s'exécute pas via l'agent."""
    root, _ = ws
    proj = root / "proj"
    for k, v in (("GIT_AUTHOR_NAME", "t"), ("GIT_AUTHOR_EMAIL", "t@t"),
                 ("GIT_COMMITTER_NAME", "t"), ("GIT_COMMITTER_EMAIL", "t@t")):
        monkeypatch.setenv(k, v)
    subprocess.run(["git", "init", "-q"], cwd=proj, check=True)
    hook = proj / ".git" / "hooks" / "pre-commit"
    hook.write_text("#!/bin/sh\necho hooked > marker.txt\n", newline="\n")
    hook.chmod(0o755)
    (proj / "a.txt").write_text("a")
    subprocess.run(["git", "add", "a.txt"], cwd=proj, check=True)
    res = RunCommandSkill().run({"program": "git", "args": ["commit", "-q", "-m", "agent"], "cwd": str(proj)})
    assert res.ok, res.detail
    assert not (proj / "marker.txt").exists(), "le hook ne doit pas s'exécuter via l'agent"
    # Témoin : le même commit hors agent exécute bien le hook.
    (proj / "b.txt").write_text("b")
    subprocess.run(["git", "add", "b.txt"], cwd=proj, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "direct"], cwd=proj, check=True)
    assert (proj / "marker.txt").exists()


# --- S5 : confirmation de run_command avec le contenu exécuté --------------------------------
def test_npm_run_shows_script_lines(ws):
    root, _ = ws
    proj = root / "proj"
    (proj / "package.json").write_text(json.dumps({"scripts": {
        "prebuild": "node gen.js", "build": "vite build", "postbuild": "echo done"}}))
    d = describe_command({"program": "npm", "args": ["run", "build"], "cwd": str(proj)})
    assert '"build": "vite build"' in d and '"prebuild": "node gen.js"' in d and '"postbuild"' in d
    assert "Commande complète" in d and str(proj) in d


def test_npm_install_ignore_scripts_by_default(ws, monkeypatch):
    root, _ = ws
    proj = root / "proj"
    (proj / "package.json").write_text(json.dumps({"scripts": {"postinstall": "node evil.js"}}))
    step = {"type": "run_command", "program": "npm", "args": ["install"], "cwd": str(proj)}
    assert effective_args(step) == ["install", "--ignore-scripts"]
    assert effective_args(dict(step, args=["ci"])) == ["ci", "--ignore-scripts"]
    assert RunCommandSkill().confirm_level(step) == 2
    d = describe_command(step)
    assert "--ignore-scripts" in d and '"postinstall": "node evil.js"' in d


def test_npm_install_scripts_need_l3(ws, monkeypatch):
    root, _ = ws
    proj = root / "proj"
    (proj / "package.json").write_text("{}")
    gate = PermissionGate("auto", [str(root)], dry_run=False, allow_input_control=True)
    step = {"type": "run_command", "program": "npm", "args": ["install"], "cwd": str(proj), "allow_scripts": True}
    assert effective_args(step) == ["install"]
    assert RunCommandSkill().confirm_level(step) == 3
    assert "L3" in describe_command(step)
    _asker(monkeypatch, "oui")
    assert not gate.authorize(RunCommandSkill(), step)[0]
    _asker(monkeypatch, "confirmer")
    assert gate.authorize(RunCommandSkill(), step)[0]
    assert not gate.authorize(RunCommandSkill(), dict(step, allow_scripts="yes"))[0]


def test_python_and_pytest_content_shown(ws):
    root, _ = ws
    proj = root / "proj"
    (proj / "app.py").write_text("import os\nprint('hello agent')\n")
    d = describe_command({"program": "python", "args": ["app.py"], "cwd": str(proj)})
    assert "print('hello agent')" in d and "sha256" in d
    (proj / "tests").mkdir()
    (proj / "tests" / "conftest.py").write_text("import subprocess  # code exécuté par pytest\n")
    (proj / "pytest.ini").write_text("[pytest]\naddopts = -p myplugin\n")
    d = describe_command({"program": "pytest", "args": ["-q"], "cwd": str(proj)})
    assert "conftest.py" in d and "import subprocess" in d and "addopts" in d


def test_confirmation_prints_full_command(ws, monkeypatch, capsys):
    root, _ = ws
    calls = _asker(monkeypatch, "n")
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    gate.authorize(RunCommandSkill(), {"type": "run_command", "program": "git",
                                       "args": ["commit", "-m", "message complet"], "cwd": str(root / "proj")})
    out = capsys.readouterr().out
    assert calls and "message complet" in out and "core.hooksPath=/dev/null" in out and str(root / "proj") in out


# --- S7 / S8 : contenu complet à la confirmation, masqué ailleurs -------------------------------
def test_write_file_details_full_or_truncated():
    short = "contenu court"
    assert short in content_details(short) and "sha256" in content_details(short)
    long = "A" * 2500 + "FIN-SECRETE"
    d = content_details(long)
    assert "2511 caractères" in d and "FIN-SECRETE" not in d and "tronqué" in d


def test_type_text_describe_masked_details_full():
    step = {"type": "type_text", "text": "secret123"}
    assert "secret123" not in TypeTextSkill().describe(step)
    assert "secret123" in TypeTextSkill().confirm_details(step)
    assert "secret" not in FileOpsSkill().describe({"type": "write_file", "path": "x", "content": "secret"})
    assert "secret" not in PhoneSkill().describe({"type": "phone_type", "text": "secret"})


def test_approval_summary_masked_console_full(ws, monkeypatch, capsys):
    root, _ = ws
    _asker(monkeypatch, "n")
    events = []
    gate = PermissionGate("confirm", [str(root)], dry_run=False)
    gate.authorize(TypeTextSkill(), {"type": "type_text", "text": "texte-tres-prive"},
                   {"emit": lambda t, m, d: events.append((t, m, d)), "step_index": 3})
    assert "texte-tres-prive" not in json.dumps(events, ensure_ascii=False)
    assert "texte-tres-prive" in capsys.readouterr().out


@pytest.fixture()
def fake_pyautogui(monkeypatch):
    calls = []
    mod = types.SimpleNamespace(
        hotkey=lambda *a: calls.append(("hotkey",) + a),
        press=lambda k: calls.append(("press", k)),
        typewrite=lambda t, interval=0: calls.append(("typewrite", len(t))),
        click=lambda *a, **k: calls.append(("click", a, k)),
        moveTo=lambda *a, **k: calls.append(("moveTo", a)),
        dragTo=lambda *a, **k: calls.append(("dragTo", a)),
        scroll=lambda *a: calls.append(("scroll", a)),
    )
    monkeypatch.setitem(sys.modules, "pyautogui", mod)
    return calls


def _clip(monkeypatch, snapshot):
    rec = {"set": [], "restore": [], "unicode": []}
    monkeypatch.setattr(tt, "_snapshot_clipboard", lambda: snapshot)
    monkeypatch.setattr(tt, "_set_clipboard", lambda text: rec["set"].append(text) or True)
    monkeypatch.setattr(tt, "_restore_clipboard", lambda snap: rec["restore"].append(snap) or True)
    monkeypatch.setattr(tt, "_send_unicode_windows", lambda text, interval=0: rec["unicode"].append(text))
    monkeypatch.setattr(tt, "_PASTE_SETTLE_SECONDS", 0.0)
    return rec


def test_clipboard_restored_after_paste(monkeypatch, fake_pyautogui):
    rec = _clip(monkeypatch, ("text", "presse-papier de l'utilisateur"))
    res = TypeTextSkill().run({"type": "type_text", "text": "à taper"})
    assert res.ok and "restauré" in res.detail
    assert rec["set"] == ["à taper"] and rec["restore"] == [("text", "presse-papier de l'utilisateur")]
    assert ("hotkey", "ctrl", "v") in fake_pyautogui


def test_clipboard_restored_even_if_paste_fails(monkeypatch, fake_pyautogui):
    rec = _clip(monkeypatch, ("empty", None))
    sys.modules["pyautogui"].hotkey = lambda *a: (_ for _ in ()).throw(RuntimeError("boom"))
    res = TypeTextSkill().run({"type": "type_text", "text": "x"})
    assert not res.ok and rec["restore"] == [("empty", None)]


@pytest.mark.skipif(not WIN, reason="saisie Unicode Windows")
def test_non_text_clipboard_untouched_unicode_used(monkeypatch, fake_pyautogui):
    rec = _clip(monkeypatch, ("other", None))
    res = TypeTextSkill().run({"type": "type_text", "text": "héllo"})
    assert res.ok and rec["set"] == [] and rec["restore"] == [] and rec["unicode"] == ["héllo"]


@pytest.mark.skipif(not WIN, reason="structures Win32")
def test_unicode_input_structures():
    import ctypes

    assert ctypes.sizeof(tt.INPUT) == (40 if sys.maxsize > 2**32 else 28)
    events = tt.build_unicode_inputs("a😀\n")
    # a : 2 évènements ; emoji (paire de substitution) : 4 ; \n (Entrée) : 2
    assert len(events) == 8
    assert events[0].u.ki.wScan == ord("a") and events[-1].u.ki.wVk == 0x0D


def test_type_text_validation():
    s = TypeTextSkill()
    assert s.validate({"text": 42}, lambda p: True)
    assert s.validate({"text": ""}, lambda p: True)
    assert s.validate({"text": "x", "method": "shell"}, lambda p: True)
    assert s.validate({"text": "x", "interval": "0.1"}, lambda p: True)
    assert s.validate({"text": "x", "window_title": 3}, lambda p: True)
    assert s.validate({"text": "x" * 20001}, lambda p: True)
    assert s.validate({"text": "ok", "method": "unicode", "interval": 0.01}, lambda p: True) is None


# --- S3 : contrôle d'entrée = exécution de code ----------------------------------------------------
@pytest.mark.parametrize("keys", ["win+r", "Win+X", ["winleft", "r"], "ctrl+shift+esc", "ctrl+`",
                                  "ctrl+shift+`", "ctrl+shift+p", "f1", "ctrl+alt+delete", "win"])
def test_risky_hotkeys_confirmed_even_preauthorized(keys, ws, monkeypatch):
    root, _ = ws
    calls = _asker(monkeypatch, "n")
    gate = PermissionGate("auto", [str(root)], dry_run=False, allow_input_control=True)
    assert not gate.authorize(HotkeySkill(), {"type": "hotkey", "keys": keys})[0]
    assert len(calls) == 1


@pytest.mark.parametrize("keys", ["ctrl+s", "ctrl+c", "alt+tab", "enter", "ctrl+shift+t"])
def test_plain_hotkeys_preauthorized(keys, ws, monkeypatch):
    root, _ = ws
    calls = _asker(monkeypatch, "n")
    gate = PermissionGate("auto", [str(root)], dry_run=False, allow_input_control=True)
    assert gate.authorize(HotkeySkill(), {"type": "hotkey", "keys": keys})[0] and calls == []


@pytest.mark.parametrize("fg,risky", [
    ({"exe": r"C:\Windows\System32\notepad.exe", "title": "Sans titre - Bloc-notes", "class": "Notepad"}, False),
    ({"exe": r"C:\Program Files\Google\Chrome\Application\chrome.exe", "title": "Google", "class": "x"}, False),
    ({"exe": r"C:\Windows\System32\cmd.exe", "title": "Invite de commandes", "class": "x"}, True),
    ({"exe": r"C:\Program Files\WindowsApps\WindowsTerminal.exe", "title": "PowerShell", "class": "x"}, True),
    ({"exe": r"C:\Windows\explorer.exe", "title": "Exécuter", "class": "#32770"}, True),
    ({"exe": r"C:\Tools\inconnu.exe", "title": "Outil", "class": "x"}, True),
    (None, True),
])
def test_type_text_foreground_window_risk(fg, risky, ws, monkeypatch):
    root, _ = ws
    monkeypatch.delenv("SOULBAH_ALLOWED_APPS", raising=False)
    monkeypatch.setattr(tt.desktop, "foreground_window", lambda: fg)
    calls = _asker(monkeypatch, "n")
    gate = PermissionGate("auto", [str(root)], dry_run=False, allow_input_control=True)
    ok, _ = gate.authorize(TypeTextSkill(), {"type": "type_text", "text": "dir"})
    assert ok is (not risky) and len(calls) == (1 if risky else 0)


def test_type_text_window_title_mismatch_confirmed(monkeypatch):
    monkeypatch.delenv("SOULBAH_ALLOWED_APPS", raising=False)
    monkeypatch.setattr(tt.desktop, "foreground_window",
                        lambda: {"exe": r"C:\x\notepad.exe", "title": "Autre - Bloc-notes", "class": "Notepad"})
    risk = TypeTextSkill().input_risk({"text": "x", "window_title": "rapport.txt"})
    assert risk and "ne correspond pas" in risk
    assert TypeTextSkill().input_risk({"text": "x", "window_title": "bloc-notes"}) is None


# --- T22 : raccourcis --------------------------------------------------------------------------------
@pytest.mark.parametrize("raw,expected", [
    ("ctrl+s", ["ctrl", "s"]),
    ("Ctrl+S", ["ctrl", "s"]),
    (["Ctrl", "S"], ["ctrl", "s"]),
    (["ctrl+s"], ["ctrl", "s"]),
    ("Control + Shift + Escape", ["ctrl", "shift", "esc"]),
    ("ctrl++", ["ctrl", "+"]),
    ("Entrée", ["enter"]),
    ("alt+F4", ["alt", "f4"]),
    ("cmd+space", ["win", "space"]),
])
def test_hotkey_normalization(raw, expected):
    assert normalize_keys(raw) == (expected, None)


@pytest.mark.parametrize("raw", ["ctrl+foo", "", None, 42, ["ctrl", 3], "a+b+c+d+e+f", "ctrl+ctrl", "ctrl+!"])
def test_hotkey_invalid_rejected(raw):
    keys, err = normalize_keys(raw)
    assert err and keys == []
    assert HotkeySkill().validate({"keys": raw}, lambda p: True)


def test_hotkey_ctrl_s_sends_exactly_ctrl_s(fake_pyautogui):
    res = HotkeySkill().run({"type": "hotkey", "keys": "Ctrl+S"})
    assert res.ok and fake_pyautogui == [("hotkey", "ctrl", "s")]
    res = HotkeySkill().run({"type": "press", "keys": "Unknown"})
    assert not res.ok and len(fake_pyautogui) == 1


def test_hotkey_names_exist_in_pyautogui():
    pyautogui = pytest.importorskip("pyautogui")
    from skills import hotkey

    known = set(pyautogui.KEYBOARD_KEYS)
    assert not [k for k in hotkey._NAMED | hotkey._CHARS if k not in known]


def test_hotkey_risk_helper():
    assert hotkey_risk(["winleft", "r"]) and hotkey_risk(["ctrlleft", "shift", "esc"])
    assert hotkey_risk(["ctrl", "s"]) is None


# --- S25 / T22 : souris ---------------------------------------------------------------------------------
@pytest.mark.parametrize("step", [
    {"type": "click", "x": "C:/secret/img.png", "y": 10},
    {"type": "click", "x": "100", "y": "200"},
    {"type": "click", "x": True, "y": 1},
    {"type": "click", "x": 1},
    {"type": "click", "x": float("nan"), "y": 1},
    {"type": "click", "x": 1, "y": 2, "clicks": 9},
    {"type": "click", "x": 1, "y": 2, "button": "evil"},
    {"type": "drag"},
    {"type": "move_mouse"},
    {"type": "scroll", "dy": "3"},
])
def test_mouse_invalid_params_refused(step, fake_pyautogui):
    assert MouseSkill().validate(step, lambda p: True)
    assert not MouseSkill().run(step).ok and fake_pyautogui == []


def test_mouse_valid_click(fake_pyautogui):
    assert MouseSkill().validate({"type": "click", "x": 10.4, "y": 20}, lambda p: True) is None
    assert MouseSkill().run({"type": "double_click", "x": 10.4, "y": 20}).ok
    assert fake_pyautogui[-1][0] == "click" and fake_pyautogui[-1][2]["x"] == 10


def test_phone_coordinates_must_be_numbers(ws):
    root, _ = ws
    gate = PermissionGate("auto", [str(root)], dry_run=False, allow_input_control=True)
    assert not gate.authorize(PhoneSkill(), {"type": "phone_tap", "x": "1", "y": 2})[0]
    assert gate.authorize(PhoneSkill(), {"type": "phone_tap", "x": 1, "y": 2})[0]


# --- S24 : close_window ------------------------------------------------------------------------------------
class _W:
    def __init__(self, title, h):
        self.title, self._hWnd, self.closed = title, h, False

    def close(self):
        self.closed = True

    def activate(self):
        pass


@pytest.fixture()
def fake_windows(monkeypatch):
    wins = [_W("Sans titre - Bloc-notes", 1), _W("rapport.txt - Bloc-notes", 2), _W("Google Chrome", 3)]
    monkeypatch.setitem(sys.modules, "pygetwindow", types.SimpleNamespace(getAllWindows=lambda: wins))
    return wins


def test_close_window_requires_exact_or_regex():
    s = WindowSkill()
    assert s.validate({"type": "close_window", "window_title": "Bloc-notes", "match": "contains"}, None)
    assert s.validate({"type": "close_window", "window_title": "Bloc-notes"}, None) is None  # exact par défaut
    assert s.validate({"type": "close_window", "window_title": "([", "match": "regex"}, None)
    assert s.validate({"type": "window", "action": "explode", "window_title": "x"}, None)


def test_close_window_exact_match_only(fake_windows):
    res = WindowSkill().run({"type": "close_window", "window_title": "Bloc-notes"})
    assert not res.ok and not any(w.closed for w in fake_windows)  # sous-chaîne : pas de correspondance exacte
    res = WindowSkill().run({"type": "close_window", "window_title": "rapport.txt - Bloc-notes"})
    assert res.ok and fake_windows[1].closed and not fake_windows[0].closed


def test_close_window_ambiguous_regex_refused(fake_windows):
    res = WindowSkill().run({"type": "close_window", "window_title": "Bloc-notes$", "match": "regex"})
    assert not res.ok and "ambiguë" in res.detail and not any(w.closed for w in fake_windows)


def test_focus_ambiguous_substring_refused(fake_windows):
    res = WindowSkill().run({"type": "focus_window", "window_title": "bloc-notes"})
    assert not res.ok and "ambiguë" in res.detail
    assert WindowSkill().run({"type": "focus_window", "window_title": "chrome"}).ok


# --- S17 : contexte goal_meta transmis par l'executor ------------------------------------------------------
def test_executor_passes_goal_meta_context(tmp_path, monkeypatch):
    gate = PermissionGate("confirm", [str(tmp_path)], dry_run=False)
    seen = []
    monkeypatch.setattr(gate, "authorize", lambda skill, step, ctx=None: seen.append(ctx) or (False, "test"))
    ex = Executor(gate)
    ex.run_task({"steps": [{"type": "screenshot"}], "goal_meta": {"attempt": 1}})
    ex.run_task({"steps": [{"type": "screenshot"}]})
    assert seen[0]["goal_meta"] is True and seen[1]["goal_meta"] is False


# --- S28 : TOCTOU ------------------------------------------------------------------------------------------
@pytest.mark.skipif(not WIN, reason="jonction NTFS")
def test_toctou_junction_swap_refused_before_execution(ws, monkeypatch):
    import _winapi

    root, outside = ws
    data = root / "data"
    data.mkdir()
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    original = gate.authorize

    def authorize_then_swap(skill, step, ctx=None):
        result = original(skill, step, ctx)
        data.rmdir()  # pendant la « confirmation », le dossier devient une jonction vers l'extérieur
        _winapi.CreateJunction(str(outside), str(data))
        return result

    monkeypatch.setattr(gate, "authorize", authorize_then_swap)
    report = Executor(gate).run_task({"steps": [{"type": "write_file", "path": str(data / "a.txt"), "content": "x"}]})
    assert not report["ok"] and "revalidation" in report["steps"][0]["detail"]
    assert not (outside / "a.txt").exists()
    os.rmdir(data)


def test_recheck_runs_validation_again(ws):
    root, outside = ws
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    assert gate.recheck(FileOpsSkill(), {"type": "read_file", "path": str(root / "x")}) is None
    assert "revalidation" in gate.recheck(FileOpsSkill(), {"type": "read_file", "path": str(outside / "x")})


# --- T42 : python3 → raccourci Microsoft Store ---------------------------------------------------------------
@pytest.mark.skipif(not WIN, reason="raccourcis WindowsApps propres à Windows")
def test_store_stub_skipped_and_real_python_used(tmp_path, monkeypatch):
    stub_dir = tmp_path / "Microsoft" / "WindowsApps"
    stub_dir.mkdir(parents=True)
    (stub_dir / "python3.exe").write_bytes(b"")
    (stub_dir / "python.exe").write_bytes(b"")
    monkeypatch.setenv("PATH", str(stub_dir))
    assert _find_executable("python3") is None and _find_executable("python") is None
    assert "WindowsApps" in _missing_message("python3")
    real = tmp_path / "Python311"
    real.mkdir()
    (real / "python.exe").write_bytes(b"MZ-real")
    monkeypatch.setenv("PATH", os.pathsep.join([str(stub_dir), str(real)]))
    assert _find_executable("python3") == str(real / "python.exe")
    assert is_store_stub(str(stub_dir / "python3.exe")) and not is_store_stub(str(real / "python.exe"))


def test_run_command_reports_missing_interpreter(ws, monkeypatch):
    root, _ = ws
    proj = root / "proj"
    (proj / "s.py").write_text("print(1)\n")
    monkeypatch.setenv("PATH", "")
    res = RunCommandSkill().run({"program": "python3", "args": ["s.py"], "cwd": str(proj)})
    assert not res.ok and "introuvable" in res.detail


# --- Registre : toutes les étapes sensibles décrites sans texte en clair ------------------------------------
def test_every_skill_describe_masks_text():
    for skill in set(REGISTRY.values()):
        d = skill.describe({"type": skill.step_types[0], "text": "ZZSECRETZZ", "content": "ZZSECRETZZ"})
        assert "ZZSECRETZZ" not in d, skill.name


def test_skill_result_dataclass_unchanged():
    assert SkillResult(ok=True, detail="x").data is None
