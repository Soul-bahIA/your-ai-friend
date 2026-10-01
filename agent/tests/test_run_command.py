"""Validateur de run_command : contournements refusés, commandes légitimes acceptées.

Aucune commande n'est exécutée : seuls check_command / gate.authorize sont appelés."""
from __future__ import annotations

import os

import pytest

from permissions import PermissionGate
from skills.run_command import RunCommandSkill, check_command


@pytest.fixture()
def ws(tmp_path):
    root = tmp_path / "workspace"
    (root / "proj" / "src").mkdir(parents=True)
    (root / "proj" / "tests").mkdir()
    (root / "proj" / "app.py").write_text("print('ok')\n")
    (root / "proj" / "app.js").write_text("console.log('ok')\n")
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "evil.py").write_text("print('evil')\n")
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    return {"root": root, "cwd": str(root / "proj"), "outside": outside, "gate": gate}


def _check(ws, program, args, cwd=None):
    return check_command(program, args, ws["cwd"] if cwd is None else cwd, ws["gate"].path_allowed)


BYPASSES = [
    # Drapeaux d'évaluation, toutes formes (collés, =, préfixes)
    ("python", ["-c", "import os"]),
    ("python", ["-c__import__('os').system('calc')"]),
    ("python", ["-cimport os"]),
    ("python", ["-m", "http.server"]),
    ("python", ["-mhttp.server"]),
    ("python3", ["-c", "1"]),
    ("python", ["app.py", "-c", "x"]),
    ("python", ["-I", "app.py"]),
    ("node", ["-e", "require('child_process')"]),
    ("node", ["--eval=require('child_process')"]),
    ("node", ["--eval", "1"]),
    ("node", ["-p", "1"]),
    ("node", ["-r", "evil", "app.js"]),
    ("node", ["--require=evil", "app.js"]),
    ("node", ["--import=data:text/javascript,1", "app.js"]),
    ("node", ["app.js", "--require=./x"]),
    # Script hors liste blanche / mauvais type
    ("python", ["__OUTSIDE__/evil.py"]),
    ("python", ["../../outside/evil.py"]),
    ("python", ["app.txt"]),
    ("node", ["app.py"]),
    # Programmes retirés
    ("npx", ["--yes", "pkg"]),
    ("pip", ["install", "requests"]),
    ("pnpm", ["install"]),
    ("cmd", ["/c", "calc"]),
    ("powershell", ["-c", "calc"]),
    # git : config arbitraire, options globales, sous-commandes non listées
    ("git", ["-c", "core.sshCommand=calc", "status"]),
    ("git", ["-ccore.pager=calc", "log"]),
    ("git", ["status", "-c", "x=y"]),
    ("git", ["--config-env=core.pager=X", "log"]),
    ("git", ["-C", "..", "status"]),
    ("git", ["--git-dir=../x", "status"]),
    ("git", ["--exec-path=.", "status"]),
    ("git", ["push"]),
    ("git", ["fetch", "--upload-pack=calc"]),
    ("git", ["config", "core.pager", "calc"]),
    ("git", ["clone", "https://example.com/x"]),
    ("git", []),
    # git : écriture/lecture hors whitelist via options à valeur
    ("git", ["diff", "--output=__OUTSIDE__/x.txt"]),
    ("git", ["diff", "--output=../../outside/x.txt"]),
    ("git", ["commit", "-F../../outside/msg.txt"]),
    ("git", ["add", "../../outside/evil.py"]),
    ("git", ["add", "__OUTSIDE__/evil.py"]),
    ("git", ["add", "~/secret"]),
    # npm : arguments supplémentaires / sous-commandes
    ("npm", ["install", "lodash"]),
    ("npm", ["install", "--global", "x"]),
    ("npm", ["exec", "x"]),
    ("npm", ["test", "--", "--foo"]),
    ("npm", ["run", "build&calc"]),
    ("npm", ["run", "build", "extra"]),
    ("npm", ["run"]),
    ("npm", []),
    # pytest : chargement de plugin / config arbitraire
    ("pytest", ["-p", "evil"]),
    ("pytest", ["-c", "../../outside/pytest.ini"]),
    ("pytest", ["../../outside"]),
    # Opérateurs shell
    ("git", ["status", "&&", "calc"]),
    ("git", ["log", "|", "calc"]),
    ("git", ["commit", "-m", "a\nb"]),
]


@pytest.mark.parametrize("program,args", BYPASSES)
def test_bypasses_rejected(ws, program, args):
    args = [a.replace("__OUTSIDE__", str(ws["outside"])) for a in args]
    assert _check(ws, program, args) is not None


LEGIT = [
    ("git", ["status"]),
    ("git", ["status", "--short"]),
    ("git", ["log", "--oneline", "-n", "5"]),
    ("git", ["diff", "HEAD~1..HEAD"]),
    ("git", ["diff", "--cached"]),
    ("git", ["show", "HEAD"]),
    ("git", ["branch", "-a"]),
    ("git", ["add", "."]),
    ("git", ["add", "src/app.py"]),
    ("git", ["commit", "-m", "fix: corrige le bug d'affichage"]),
    ("git", ["init"]),
    ("npm", ["test"]),
    ("npm", ["ci"]),
    ("npm", ["install"]),
    ("npm", ["run", "build"]),
    ("npm", ["run", "test:unit"]),
    ("python", ["app.py"]),
    ("python", ["app.py", "--verbose", "42"]),
    ("python3", ["app.py"]),
    ("node", ["app.js"]),
    ("pytest", []),
    ("pytest", ["-q", "tests"]),
    ("pytest", ["-x", "-k", "foo and not bar", "tests/test_a.py::test_x"]),
    ("pytest", ["--maxfail=2", "--tb=short"]),
]


@pytest.mark.parametrize("program,args", LEGIT)
def test_legit_commands_accepted(ws, program, args):
    assert _check(ws, program, args) is None


def test_absolute_path_inside_whitelist_ok(ws):
    script = os.path.join(ws["cwd"], "app.py")
    assert _check(ws, "python", [script]) is None


def test_cwd_mandatory_and_whitelisted(ws):
    assert _check(ws, "git", ["status"], cwd="") is not None
    assert check_command("git", ["status"], None, ws["gate"].path_allowed) is not None
    assert _check(ws, "git", ["status"], cwd=str(ws["outside"])) is not None


def test_args_must_be_list_of_scalars(ws):
    assert _check(ws, "git", "status") is not None
    assert _check(ws, "git", [{"x": 1}]) is not None


def test_gate_refuses_bypass_before_confirmation(ws, monkeypatch):
    calls = []
    monkeypatch.setattr("permissions._timed_input", lambda *a, **k: calls.append(1) or "o")
    step = {"type": "run_command", "program": "python", "args": ["-c", "1"], "cwd": ws["cwd"]}
    ok, reason = ws["gate"].authorize(RunCommandSkill(), step)
    assert not ok and "refusé" in reason
    assert calls == []  # refus structurel : on ne demande même pas


def test_run_command_always_confirms_even_in_auto(ws, monkeypatch):
    calls = []

    def fake_input(prompt, timeout):
        calls.append(prompt)
        return "n"

    monkeypatch.setattr("permissions._timed_input", fake_input)
    gate = PermissionGate("auto", [str(ws["root"])], dry_run=False, allow_input_control=True)
    step = {"type": "run_command", "program": "git", "args": ["status"], "cwd": ws["cwd"]}
    ok, _ = gate.authorize(RunCommandSkill(), step)
    assert not ok
    assert len(calls) == 1

    monkeypatch.setattr("permissions._timed_input", lambda *a, **k: "o")
    ok, _ = gate.authorize(RunCommandSkill(), step)
    assert ok


def test_run_revalidates_structure(ws):
    # run() revalide la structure même appelé directement (aucune exécution ici).
    res = RunCommandSkill().run({"program": "python", "args": ["-c", "1"], "cwd": ws["cwd"]})
    assert not res.ok
    res = RunCommandSkill().run({"program": "git", "args": ["status"]})
    assert not res.ok and "cwd" in res.detail
