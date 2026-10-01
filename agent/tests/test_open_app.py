"""Validateur de open_app : noms piégés refusés, noms légitimes acceptés."""
from __future__ import annotations

import sys

import pytest

from skills import open_app
from skills.open_app import OpenAppSkill, validate_app_name


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    monkeypatch.delenv("SOULBAH_ALLOWED_APPS", raising=False)


BAD = [
    r"x\&calc&\code",
    r"C:\allowed\code.bat",
    r"C:\Windows\System32\calc.exe",
    "code.bat",
    "code.cmd",
    "code&calc",
    "code|calc",
    "code;calc",
    "code\ncalc",
    '"code"',
    "'code'",
    "%COMSPEC%",
    "notepad^",
    "code!",
    "(code)",
    "code,calc",
    "../code",
    "./code",
    "code --disable-extensions",
    "cmd",
    "cmd.exe",
    "powershell.exe",
    "PowerShell",
    "wscript",
    "mshta",
    "rundll32",
    "python",
    "totally-unknown-app",
    "",
    None,
    123,
]


@pytest.mark.parametrize("name", BAD)
def test_bad_names_rejected(name):
    key, err = validate_app_name(name)
    assert key is None and err


GOOD = [
    ("code", "code"),
    ("VSCode", "code"),
    ("vs code", "code"),
    ("Visual Studio Code", "code"),
    ("notepad.exe", "notepad"),
    ("notepad++", "notepad++"),
    ("Chrome", "chrome"),
    ("navigateur", "chrome"),
    ("calc", "calc"),
    ("explorer", "explorer"),
]


@pytest.mark.parametrize("name,expected", GOOD)
def test_good_names_accepted(name, expected):
    key, err = validate_app_name(name)
    assert err is None and key == expected


def test_extra_allowed_apps_are_sanitized(monkeypatch):
    monkeypatch.setenv("SOULBAH_ALLOWED_APPS", r"myapp, cmd, C:\evil\x, bad&name, Other.exe")
    assert validate_app_name("myapp") == ("myapp", None)
    assert validate_app_name("other")[0] == "other"
    assert validate_app_name("cmd")[0] is None
    assert validate_app_name("bad&name")[0] is None


def test_gate_validation_rejects_injection():
    from permissions import PermissionGate

    gate = PermissionGate("auto", [], dry_run=False, allow_input_control=True)
    ok, reason = gate.authorize(OpenAppSkill(), {"type": "open_app", "app": r"x\&calc&\code"})
    assert not ok and "refusé" in reason


@pytest.mark.skipif(sys.platform != "win32", reason="résolution .exe spécifique à Windows")
def test_resolution_ignores_bat_cmd_and_relative_path(tmp_path, monkeypatch):
    (tmp_path / "myapp.bat").write_text("@echo off\n")
    (tmp_path / "myapp.cmd").write_text("@echo off\n")
    monkeypatch.setenv("PATH", f".;relative\\dir;{tmp_path}")
    monkeypatch.setattr(open_app, "_from_app_paths", lambda key: None)
    assert open_app.resolve_executable("myapp") is None

    (tmp_path / "myapp.exe").write_bytes(b"")
    resolved = open_app.resolve_executable("myapp")
    assert resolved and resolved.lower().endswith("myapp.exe")


def test_run_does_not_launch_rejected_app(monkeypatch):
    launched = []
    monkeypatch.setattr(open_app.subprocess, "Popen", lambda *a, **k: launched.append(a))
    res = OpenAppSkill().run({"app": r"x\&calc&\code"})
    assert not res.ok and launched == []
