"""LOT 1 — configuration : tests hermétiques (T53), workspace par défaut (S1/§14),
dépendances (S27), lanceur Windows avec .venv (T52), compilation de tous les modules."""
from __future__ import annotations

import os
import py_compile
import re
import shutil
import subprocess
import sys

import pytest

import config
from config import default_workspace, load_config

AGENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def test_conftest_disables_dotenv():
    assert os.environ.get("SOULBAH_NO_DOTENV") == "1" and config.dotenv_disabled()


@pytest.mark.parametrize("flag,expected", [("1", "UNSET"), ("", "SET")])
def test_no_dotenv_flag_controls_env_file(tmp_path, flag, expected):
    """Copie isolée de config.py + un .env factice : seul SOULBAH_NO_DOTENV décide."""
    pytest.importorskip("dotenv")
    shutil.copy(os.path.join(AGENT_DIR, "config.py"), tmp_path / "config.py")
    (tmp_path / ".env").write_text("SOULBAH_AGENT_KEY=cle-factice-de-test\n", encoding="utf-8")
    env = {k: v for k, v in os.environ.items() if k not in ("SOULBAH_AGENT_KEY", "SOULBAH_NO_DOTENV")}
    if flag:
        env["SOULBAH_NO_DOTENV"] = flag
    out = subprocess.run(
        [sys.executable, "-c", "import os, config; print('SET' if os.environ.get('SOULBAH_AGENT_KEY') else 'UNSET')"],
        cwd=tmp_path, env=env, capture_output=True, text=True, timeout=60,
    )
    assert out.stdout.strip() == expected, out.stderr


def test_default_workspace_when_unset(tmp_path, monkeypatch):
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    monkeypatch.delenv("SOULBAH_ALLOWED_DIRS", raising=False)
    cfg = load_config(require_key=False)
    assert cfg.allowed_dirs == [os.path.join(str(tmp_path), "SoulbahWorkspace")] and cfg.default_workspace
    assert default_workspace() == cfg.allowed_dirs[0]


def test_explicit_allowed_dirs(tmp_path, monkeypatch):
    a, b = tmp_path / "a", tmp_path / "b"
    monkeypatch.setenv("SOULBAH_ALLOWED_DIRS", f"{a}{os.pathsep} {b} ")
    cfg = load_config(require_key=False)
    assert cfg.allowed_dirs == [str(a), str(b)] and not cfg.default_workspace


def test_agent_key_required_unless_dry_run(monkeypatch):
    monkeypatch.delenv("SOULBAH_AGENT_KEY", raising=False)
    with pytest.raises(SystemExit):
        load_config()
    assert load_config(require_key=False).agent_key == ""


def test_requests_pinned_to_patched_version():
    """S27 : CVE-2024-47081 corrigée à partir de requests 2.32.4."""
    with open(os.path.join(AGENT_DIR, "requirements.txt"), encoding="utf-8") as f:
        line = next(ln.strip() for ln in f if ln.strip().lower().startswith("requests"))
    m = re.match(r"requests\s*(>=|==)\s*(\d+)\.(\d+)\.(\d+)", line)
    assert m, line
    assert tuple(int(x) for x in m.groups()[1:]) >= (2, 32, 4)


def test_launcher_uses_venv():
    """T52 : Lancer_Agent.bat active/crée agent/.venv et installe requirements.txt."""
    with open(os.path.join(AGENT_DIR, "Lancer_Agent.bat"), encoding="utf-8", errors="replace") as f:
        bat = f.read()
    assert r".venv\Scripts\python.exe" in bat
    assert "-m venv" in bat and "requirements.txt" in bat and "pip install" in bat
    assert re.search(r'"%VENV_PY%"\s+soulbah_agent\.py', bat)


def test_all_modules_compile():
    files = [os.path.join(AGENT_DIR, f) for f in os.listdir(AGENT_DIR) if f.endswith(".py")]
    files += [os.path.join(AGENT_DIR, "skills", f) for f in os.listdir(os.path.join(AGENT_DIR, "skills"))
              if f.endswith(".py")]
    for path in files:
        py_compile.compile(path, doraise=True)
    assert len(files) >= 20
