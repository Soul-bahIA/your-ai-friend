"""LOT 12 — codeurs en worktrees git (audit §13, critères de sortie) :

  - 3 codeurs travaillent EN MÊME TEMPS, chacun dans sa worktree et sa branche soulbah/… ;
  - leurs branches sont fusionnées dans soulbah/<session>/integration avec des tests verts ;
  - des tests rouges annulent la fusion, un conflit l'abandonne ;
  - `branch -D` est refusé sans L3 (run_command le refuse toujours ; git_branch_delete exige
    « confirmer » ou une approbation L3, même en mode auto).

Vrai git, dépôts temporaires : aucun mock du code testé.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import threading

import pytest

import permissions
from executor import Executor
from permissions import PermissionGate
from runtime.evidence import build_evidence
from skills import REGISTRY
from skills.git_workspace import TASK_BRANCH_RE, branch_exists, worktree_branch
from skills.run_command import check_command

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="git absent du PATH")

CHECK_PY = '''import os, sys
ok = True
for name in sorted(os.listdir(".")):
    if name.startswith("mod_") and name.endswith(".py"):
        src = open(name, encoding="utf-8").read()
        if "BROKEN" in src:
            print("FAIL", name)
            ok = False
        else:
            print("ok", name)
sys.exit(0 if ok else 1)
'''


def _git(cwd, *args):
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd,
                          capture_output=True, text=True, check=True).stdout.strip()


@pytest.fixture()
def ws(tmp_path, monkeypatch):
    """Workspace autorisé + dépôt « app » avec un premier commit et un lanceur de tests."""
    # Le programme de tests « python » doit être un vrai interpréteur (celui des tests).
    monkeypatch.setenv("PATH", os.path.dirname(sys.executable) + os.pathsep + os.environ.get("PATH", ""))
    root = tmp_path / "ws"
    app = root / "app"
    app.mkdir(parents=True)
    _git(app, "init", "-q", "-b", "main")
    (app / "check.py").write_text(CHECK_PY, encoding="utf-8")
    (app / "README.md").write_text("# app\n", encoding="utf-8")
    _git(app, "add", "-A")
    _git(app, "commit", "-q", "-m", "init")
    return root


def _executor(root, mode="auto"):
    return Executor(PermissionGate(mode, [str(root)], dry_run=False), step_timeout=120)


def _run(root, steps, mode="auto"):
    return _executor(root, mode).run_task({"steps": steps})


def _merge_step(root, source, **extra):
    step = {"type": "git_merge", "repo": str(root / "app"), "path": str(root / "wt" / "integration"),
            "source": source, "target": "soulbah/s1/integration", "base": "main",
            "test_program": "python", "test_args": ["check.py"]}
    step.update(extra)
    return step


@pytest.fixture()
def console_yes(monkeypatch):
    """Console qui approuve (o / confirmer selon le niveau demandé) et note les invites."""
    prompts: list[str] = []

    def _answer(prompt, timeout, should_stop=None):
        prompts.append(prompt)
        return "confirmer" if "confirmer" in prompt else "o"

    monkeypatch.setattr(permissions, "_timed_input", _answer)
    return prompts


# --- 3 codeurs en parallèle, fusion avec tests verts ----------------------------
def test_three_coders_in_parallel_worktrees_then_green_merges(ws, console_yes):
    app = ws / "app"
    results: dict[int, dict] = {}
    inside = {"now": 0, "max": 0}
    lock = threading.Lock()
    barrier = threading.Barrier(3)

    def coder(i: int) -> None:
        wt = ws / "wt" / f"t{i}"
        barrier.wait()
        with lock:
            inside["now"] += 1
            inside["max"] = max(inside["max"], inside["now"])
        try:
            results[i] = _run(ws, [
                {"type": "git_worktree", "repo": str(app), "path": str(wt), "branch": f"soulbah/s1/t{i}"},
                {"type": "write_file", "path": str(wt / f"mod_t{i}.py"), "content": f"VALUE = {i}\n"},
                {"type": "git_commit", "cwd": str(wt), "message": f"codeur {i}"},
            ])
        finally:
            with lock:
                inside["now"] -= 1

    threads = [threading.Thread(target=coder, args=(i,)) for i in (1, 2, 3)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(120)
    assert inside["max"] == 3, "les trois codeurs doivent travailler en même temps"
    for i in (1, 2, 3):
        assert results[i]["ok"], results[i]
        assert worktree_branch(str(ws / "wt" / f"t{i}")) == f"soulbah/s1/t{i}"
    # Isolation : chaque worktree ne voit que son propre module.
    assert sorted(p.name for p in (ws / "wt" / "t2").glob("mod_*.py")) == ["mod_t2.py"]
    # La branche de l'utilisateur n'a pas bougé.
    assert _git(app, "rev-parse", "--abbrev-ref", "HEAD") == "main"
    assert not list(app.glob("mod_*.py"))

    # Fusions séquentielles dans l'intégration, tests verts à chaque fois (git_merge est
    # toujours confirmé : la console de test approuve).
    for i in (1, 2, 3):
        report = _run(ws, [_merge_step(ws, f"soulbah/s1/t{i}")])
        assert report["ok"], report
    assert len(console_yes) == 3 and all("[o/N]" in p for p in console_yes)
    integ = ws / "wt" / "integration"
    assert sorted(p.name for p in integ.glob("mod_*.py")) == ["mod_t1.py", "mod_t2.py", "mod_t3.py"]
    log = _git(app, "log", "--format=%s", "soulbah/s1/integration")
    assert "codeur 1" in log and "codeur 3" in log
    assert _git(app, "rev-parse", "main") != _git(app, "rev-parse", "soulbah/s1/integration")


def test_merge_with_red_tests_is_rolled_back(ws, console_yes):
    app = ws / "app"
    assert _run(ws, [
        {"type": "git_worktree", "repo": str(app), "path": str(ws / "wt" / "ok"), "branch": "soulbah/s1/ok"},
        {"type": "write_file", "path": str(ws / "wt" / "ok" / "mod_ok.py"), "content": "A = 1\n"},
        {"type": "git_commit", "cwd": str(ws / "wt" / "ok"), "message": "ok"},
        {"type": "git_worktree", "repo": str(app), "path": str(ws / "wt" / "bad"), "branch": "soulbah/s1/bad"},
        {"type": "write_file", "path": str(ws / "wt" / "bad" / "mod_bad.py"), "content": "BROKEN = True\n"},
        {"type": "git_commit", "cwd": str(ws / "wt" / "bad"), "message": "bad"},
    ])["ok"]
    assert _run(ws, [_merge_step(ws, "soulbah/s1/ok")])["ok"]
    before = _git(app, "rev-parse", "soulbah/s1/integration")

    report = _run(ws, [_merge_step(ws, "soulbah/s1/bad")])
    assert not report["ok"]
    assert "tests rouges" in report["steps"][0]["detail"]
    assert _git(app, "rev-parse", "soulbah/s1/integration") == before, "la fusion rouge doit être annulée"
    assert not (ws / "wt" / "integration" / "mod_bad.py").exists()


def test_merge_conflict_is_aborted(ws, console_yes):
    app = ws / "app"
    for name, text in (("a", "x = 1\n"), ("b", "x = 2\n")):
        wt = ws / "wt" / name
        assert _run(ws, [
            {"type": "git_worktree", "repo": str(app), "path": str(wt), "branch": f"soulbah/s1/{name}"},
            {"type": "write_file", "path": str(wt / "mod_shared.py"), "content": text},
            {"type": "git_commit", "cwd": str(wt), "message": name},
        ])["ok"]
    assert _run(ws, [_merge_step(ws, "soulbah/s1/a")])["ok"]
    before = _git(app, "rev-parse", "soulbah/s1/integration")
    report = _run(ws, [_merge_step(ws, "soulbah/s1/b")])
    assert not report["ok"] and "conflit" in report["steps"][0]["detail"]
    integ = ws / "wt" / "integration"
    assert _git(integ, "status", "--porcelain") == "", "aucune fusion à moitié faite ne doit rester"
    assert _git(app, "rev-parse", "soulbah/s1/integration") == before


def test_worktree_is_idempotent_and_refuses_foreign_branches(ws):
    app, wt = ws / "app", ws / "wt" / "t1"
    step = {"type": "git_worktree", "repo": str(app), "path": str(wt), "branch": "soulbah/s1/t1"}
    assert _run(ws, [step])["ok"]
    again = _run(ws, [step])
    assert again["ok"] and "déjà prête" in again["steps"][0]["detail"]
    for bad in ("main", "feature/x", "soulbah/S1/t1", "soulbah/s1/../main", "-D", "soulbah/s1"):
        r = _run(ws, [{**step, "branch": bad, "path": str(ws / "wt" / "x")}])
        assert not r["ok"], bad
    # Worktree hors du workspace autorisé : refusée par le gate.
    outside = ws.parent / "outside"
    r = _run(ws, [{**step, "path": str(outside), "branch": "soulbah/s1/t9"}])
    assert not r["ok"] and not outside.exists()
    # Merge vers une branche de l'utilisateur : refusé avant toute action.
    r = _run(ws, [_merge_step(ws, "soulbah/s1/t1", target="main")])
    assert not r["ok"] and "intégration" in r["steps"][0]["detail"]


def test_commit_refused_outside_soulbah_branch(ws):
    app = ws / "app"
    (app / "x.txt").write_text("x", encoding="utf-8")
    r = _run(ws, [{"type": "git_commit", "cwd": str(app), "message": "sur main"}])
    assert not r["ok"] and "hors d'une branche Soulbah" in r["steps"][0]["detail"]


def test_merge_test_command_is_checked_like_run_command(ws):
    r = _run(ws, [_merge_step(ws, "soulbah/s1/t1", test_program="python", test_args=["-c", "print(1)"])])
    assert not r["ok"] and "commande de tests refusée" in r["steps"][0]["detail"]


# --- branch -D refusé sans L3 ------------------------------------------------------
def test_run_command_branch_force_delete_is_always_refused(ws):
    assert check_command("git", ["branch", "-D", "soulbah/s1/t1"], str(ws / "app")) is not None
    r = _run(ws, [{"type": "run_command", "program": "git", "args": ["branch", "-D", "soulbah/s1/t1"],
                   "cwd": str(ws / "app")}])
    assert not r["ok"]


def test_branch_delete_refused_without_l3_even_in_auto_mode(ws, monkeypatch):
    app = ws / "app"
    _git(app, "branch", "soulbah/s1/t1")
    step = {"type": "git_branch_delete", "repo": str(app), "branch": "soulbah/s1/t1", "force": True}

    # 1. Mode auto sans console : refusé (jamais exécuté sans confirmation L3).
    def _no_console(prompt, timeout, should_stop=None):
        raise EOFError

    monkeypatch.setattr(permissions, "_timed_input", _no_console)
    r = _run(ws, [step], mode="auto")
    assert not r["ok"] and branch_exists(str(app), "soulbah/s1/t1")

    # 2. Un simple « o » (niveau L2) ne suffit pas : « confirmer » est exigé.
    prompts: list[str] = []
    monkeypatch.setattr(permissions, "_timed_input", lambda p, t, should_stop=None: prompts.append(p) or "o")
    r = _run(ws, [step], mode="auto")
    assert not r["ok"] and branch_exists(str(app), "soulbah/s1/t1")
    assert "confirmer" in prompts[0]

    # 3. Même avec le contrôle d'entrée pré-autorisé : toujours confirmé.
    gate = PermissionGate("auto", [str(ws)], dry_run=False, allow_input_control=True)
    ok, why = gate.authorize(REGISTRY["git_branch_delete"], step)
    assert not ok and "confirmer" in why

    # 4. Avec « confirmer » (L3) : supprimée.
    monkeypatch.setattr(permissions, "_timed_input", lambda p, t, should_stop=None: "confirmer")
    r = _run(ws, [step], mode="auto")
    assert r["ok"], r
    assert not branch_exists(str(app), "soulbah/s1/t1")


def test_branch_delete_and_push_refuse_foreign_branches(ws):
    gate = PermissionGate("auto", [str(ws)], dry_run=False)
    for tool in ("git_branch_delete", "git_push"):
        ok, why = gate.authorize(REGISTRY[tool], {"type": tool, "repo": str(ws / "app"), "branch": "main"})
        assert not ok and "soulbah/" in why
    ok, why = gate.authorize(REGISTRY["git_push"], {"type": "git_push", "repo": str(ws / "app"),
                                                    "branch": "soulbah/s1/t1", "remote": "--force"})
    assert not ok


def test_remote_approval_level_is_l3_for_branch_delete(ws):
    """L'approbation demandée dans l'app pour une suppression de branche est de niveau L3."""
    asked: list = []

    class _Approver:
        def request(self, step, skill, level, summary, ctx, on_requested=None):
            asked.append(level)
            return (False, "refusé dans l'app", None)

    gate = PermissionGate("auto", [str(ws)], dry_run=False, approval_mode="remote", approver=_Approver())
    _git(ws / "app", "branch", "soulbah/s1/t1")
    ok, _ = gate.authorize(REGISTRY["git_branch_delete"], {"type": "git_branch_delete", "repo": str(ws / "app"),
                                                          "branch": "soulbah/s1/t1"})
    assert not ok and asked == [3]


# --- preuves ------------------------------------------------------------------
def test_merge_evidence_carries_test_report_and_summary(ws, console_yes):
    app = ws / "app"
    assert _run(ws, [
        {"type": "git_worktree", "repo": str(app), "path": str(ws / "wt" / "t1"), "branch": "soulbah/s1/t1"},
        {"type": "write_file", "path": str(ws / "wt" / "t1" / "mod_t1.py"), "content": "A = 1\n"},
        {"type": "git_commit", "cwd": str(ws / "wt" / "t1"), "message": "t1"},
    ])["ok"]
    res = REGISTRY["git_merge"].run(_merge_step(ws, "soulbah/s1/t1"))
    assert res.ok, res.detail
    ev = build_evidence("git_merge", res.ok, res.detail, res.data)
    kinds = {e["kind"]: e for e in ev}
    assert kinds["test_report"]["value"]["passed"] is True
    assert kinds["exit_code"]["value"] == 0
    assert "soulbah/s1/integration" in kinds["command_output"]["value"]
    assert "soulbah/s1/t1" in kinds["command_output"]["value"]


def test_branch_patterns():
    assert TASK_BRANCH_RE.match("soulbah/s1/t1") and TASK_BRANCH_RE.match("soulbah/abc-1/fix_2.b")
    for bad in ("soulbah//t", "soulbah/s1/", "Soulbah/s1/t", "soulbah/s1/t/u", "soulbah/s1/-x"):
        assert not TASK_BRANCH_RE.match(bad), bad
