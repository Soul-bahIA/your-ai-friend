"""T23 : un délai dépassé (ou un stop) tue TOUT l'arbre de processus.

Processus inoffensifs : un enfant python qui lance un petit-enfant qui dort."""
from __future__ import annotations

import os
import sys
import threading
import time

import pytest

from skills.base import CancelToken
from skills.proctree import pid_alive, run_tree
from skills.run_command import RunCommandSkill, _find_executable

PARENT = r'''
import os, subprocess, sys, time
here = os.path.dirname(os.path.abspath(__file__))
subprocess.Popen([sys.executable, os.path.join(here, "grandchild.py")])
with open(os.path.join(here, "parent.pid"), "w") as f:
    f.write(str(os.getpid()))
print("parent ready", flush=True)
time.sleep(60)
'''
GRANDCHILD = r'''
import os, time
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "grandchild.pid"), "w") as f:
    f.write(str(os.getpid()))
time.sleep(60)
'''


@pytest.fixture()
def tree(tmp_path):
    (tmp_path / "parent.py").write_text(PARENT, encoding="utf-8")
    (tmp_path / "grandchild.py").write_text(GRANDCHILD, encoding="utf-8")
    return tmp_path


def _pids(d, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            return [int((d / n).read_text()) for n in ("parent.pid", "grandchild.pid")]
        except (OSError, ValueError):
            time.sleep(0.05)
    pytest.fail("les processus de test n'ont pas démarré")


def _all_dead(pids, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not any(pid_alive(p) for p in pids):
            return True
        time.sleep(0.1)
    return False


@pytest.mark.parametrize("use_job", [True, False], ids=["job-object", "taskkill-fallback"])
def test_timeout_kills_child_and_grandchild(tree, use_job):
    t0 = time.monotonic()
    res = run_tree([sys.executable, "parent.py"], cwd=str(tree), timeout=3, use_job=use_job)
    assert time.monotonic() - t0 < 20
    assert res.timed_out and res.tree_killed
    assert "parent ready" in res.stdout
    pids = _pids(tree)
    assert _all_dead(pids), "un descendant a survécu au délai"
    if sys.platform == "win32" and use_job:
        assert res.used_job


def test_cancel_token_kills_tree(tree):
    token = CancelToken()
    threading.Timer(1.5, token.cancel, args=("stop",)).start()
    t0 = time.monotonic()
    res = run_tree([sys.executable, "parent.py"], cwd=str(tree), timeout=60, cancel=token)
    assert time.monotonic() - t0 < 15
    assert res.cancelled and not res.timed_out
    assert _all_dead(_pids(tree))


def test_normal_completion_output(tmp_path):
    (tmp_path / "ok.py").write_text("import sys\nprint('bonjour')\nsys.exit(3)\n", encoding="utf-8")
    res = run_tree([sys.executable, "ok.py"], cwd=str(tmp_path), timeout=30)
    assert res.returncode == 3 and "bonjour" in res.stdout and not res.timed_out


def test_leftover_background_grandchild_killed_after_exit(tmp_path):
    """Un petit-enfant détaché (stdio fermés) survivant au parent est tué à la fermeture du job."""
    if sys.platform != "win32":
        pytest.skip("Job Object Windows")
    (tmp_path / "gc.py").write_text(GRANDCHILD, encoding="utf-8")
    (tmp_path / "p.py").write_text(
        "import os, subprocess, sys\n"
        "here = os.path.dirname(os.path.abspath(__file__))\n"
        "subprocess.Popen([sys.executable, os.path.join(here, 'gc.py')], stdin=subprocess.DEVNULL,\n"
        "                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
        "import time; time.sleep(1)\n", encoding="utf-8")
    res = run_tree([sys.executable, "p.py"], cwd=str(tmp_path), timeout=30)
    assert res.returncode == 0
    pid = int((tmp_path / "grandchild.pid").read_text())
    assert _all_dead([pid])


@pytest.mark.skipif(_find_executable("python") is None, reason="python absent du PATH")
def test_run_command_timeout_kills_tree(tree):
    t0 = time.monotonic()
    res = RunCommandSkill().run({"program": "python", "args": ["parent.py"], "cwd": str(tree), "timeout": 3})
    assert time.monotonic() - t0 < 20
    assert not res.ok and "délai dépassé" in res.detail and res.data["timed_out"]
    assert _all_dead(_pids(tree))
