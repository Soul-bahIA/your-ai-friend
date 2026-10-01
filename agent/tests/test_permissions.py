"""Gate de permissions : whitelist, captures, confirmation avec délai, autres skills."""
from __future__ import annotations

import io

import pytest

import permissions
from permissions import PermissionGate, normalize_dir, path_inside
from skills.filesystem import FileOpsSkill
from skills.move_file import MoveFileSkill
from skills.phone import PhoneSkill
from skills.record_screen import RecordScreenSkill
from skills.screenshot import ScreenshotSkill
from skills.type_text import TypeTextSkill
from skills.wait import WaitSkill


@pytest.fixture()
def ws(tmp_path):
    allowed = tmp_path / "allowed"
    allowed.mkdir()
    (tmp_path / "allowed_sibling").mkdir()
    return allowed, tmp_path


def _never_asked(*_a, **_k):
    pytest.fail("aucune confirmation attendue")


def test_path_inside_basics(ws):
    allowed, root = ws
    dirs = [normalize_dir(str(allowed))]
    assert path_inside(str(allowed), dirs)
    assert path_inside(str(allowed / "a" / "b.txt"), dirs)
    assert not path_inside(str(root / "allowed_sibling" / "x"), dirs)  # préfixe trompeur
    assert not path_inside(str(allowed / ".." / "x"), dirs)
    assert not path_inside("", dirs)
    assert not path_inside(None, dirs)  # type: ignore[arg-type]
    assert not path_inside("a\x00b", dirs)
    assert not path_inside(str(allowed / "x"), [])


def test_screenshot_path_rules(ws, monkeypatch):
    allowed, root = ws
    monkeypatch.setattr(permissions, "_timed_input", _never_asked)
    gate = PermissionGate("confirm", [str(allowed)], dry_run=False)
    skill = ScreenshotSkill()
    assert gate.authorize(skill, {"type": "screenshot"})[0]
    assert gate.authorize(skill, {"type": "screenshot", "path": str(allowed / "cap.png")})[0]
    assert not gate.authorize(skill, {"type": "screenshot", "path": str(root / "cap.png")})[0]
    assert not gate.authorize(skill, {"type": "screenshot", "path": str(allowed / "evil.py")})[0]
    assert not gate.authorize(skill, {"type": "screenshot", "path": str(allowed / "x.bat")})[0]
    assert not gate.authorize(skill, {"type": "screenshot", "path": ["x.png"]})[0]


def test_confirm_timeout_refuses(ws, monkeypatch):
    allowed, _ = ws
    monkeypatch.setattr(permissions, "_timed_input", lambda prompt, timeout: None)
    gate = PermissionGate("confirm", [str(allowed)], dry_run=False, confirm_timeout=5)
    ok, reason = gate.authorize(FileOpsSkill(), {"type": "list_dir", "path": str(allowed)})
    assert not ok and "pas de réponse" in reason


def test_confirm_without_console_refuses(ws, monkeypatch):
    allowed, _ = ws

    def no_console(prompt, timeout):
        raise EOFError

    monkeypatch.setattr(permissions, "_timed_input", no_console)
    gate = PermissionGate("confirm", [str(allowed)], dry_run=False)
    assert not gate.authorize(FileOpsSkill(), {"type": "list_dir", "path": str(allowed)})[0]


def test_timed_input_refuses_when_not_a_tty(monkeypatch):
    monkeypatch.setattr(permissions.sys, "stdin", io.StringIO("o\n"))
    with pytest.raises(EOFError):
        permissions._timed_input("? ", 1)


def test_confirm_accepts_yes(ws, monkeypatch):
    allowed, _ = ws
    monkeypatch.setattr(permissions, "_timed_input", lambda prompt, timeout: "oui")
    gate = PermissionGate("confirm", [str(allowed)], dry_run=False)
    assert gate.authorize(FileOpsSkill(), {"type": "list_dir", "path": str(allowed)})[0]


def test_input_control_requires_confirmation_in_auto(ws, monkeypatch):
    allowed, _ = ws
    calls = []
    monkeypatch.setattr(permissions, "_timed_input", lambda p, t: calls.append(1) or "n")
    gate = PermissionGate("auto", [str(allowed)], dry_run=False)
    assert not gate.authorize(TypeTextSkill(), {"type": "type_text", "text": "x"})[0]
    assert calls == [1]


def test_filesystem_outside_and_git_dir_refused(ws, monkeypatch):
    allowed, root = ws
    monkeypatch.setattr(permissions, "_timed_input", lambda p, t: "o")
    gate = PermissionGate("auto", [str(allowed)], dry_run=False)
    fs = FileOpsSkill()
    assert gate.authorize(fs, {"type": "write_file", "path": str(allowed / "a.txt")})[0]
    assert not gate.authorize(fs, {"type": "write_file", "path": str(root / "a.txt")})[0]
    assert not gate.authorize(fs, {"type": "write_file", "path": str(allowed / ".git" / "hooks" / "pre-commit")})[0]
    assert not gate.authorize(fs, {"type": "write_file", "path": 42})[0]
    mv = MoveFileSkill()
    assert not gate.authorize(mv, {"type": "move_file", "src": str(allowed / "a"), "dest": str(root / "b")})[0]
    assert not gate.authorize(mv, {"type": "move_file", "src": str(allowed / "a"),
                                   "dest": str(allowed / ".git" / "hooks" / "post-commit")})[0]


def test_video_extension_and_whitelist(ws):
    allowed, root = ws
    gate = PermissionGate("auto", [str(allowed)], dry_run=False)
    rec = RecordScreenSkill()
    assert gate.authorize(rec, {"type": "record_screen", "path": str(allowed / "d.mp4")})[0]
    assert not gate.authorize(rec, {"type": "record_screen", "path": str(allowed / "d.py")})[0]
    assert not gate.authorize(rec, {"type": "record_screen", "path": str(root / "d.mp4")})[0]


def test_phone_injection_rejected(ws):
    allowed, _ = ws
    gate = PermissionGate("auto", [str(allowed)], dry_run=False)
    ph = PhoneSkill()
    assert not gate.authorize(ph, {"type": "phone_key", "keycode": "KEYCODE_HOME; reboot"})[0]
    assert not gate.authorize(ph, {"type": "phone_open_app", "package": "com.x;rm -rf /sdcard"})[0]
    assert not gate.authorize(ph, {"type": "phone_tap", "x": 1, "y": 2, "device_id": "abc;reboot"})[0]
    assert gate.authorize(ph, {"type": "phone_key", "keycode": "KEYCODE_HOME"})[0]
    assert gate.authorize(ph, {"type": "phone_open_app", "package": "com.android.chrome"})[0]


def test_dry_run_skips_confirmation_but_keeps_validation(ws, monkeypatch):
    allowed, root = ws
    monkeypatch.setattr(permissions, "_timed_input", _never_asked)
    gate = PermissionGate("confirm", [str(allowed)], dry_run=True)
    assert gate.authorize(WaitSkill(), {"type": "wait", "seconds": 1})[0]
    assert not gate.authorize(FileOpsSkill(), {"type": "write_file", "path": str(root / "x")})[0]
