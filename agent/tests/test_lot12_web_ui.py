"""LOT 12 — navigateur (lecture), inspection d'interface, VS Code, DPI.

- browser_get : vrai serveur HTTP local (autorisé par SOULBAH_BROWSER_ALLOW_PRIVATE=1),
  adresses privées refusées par défaut, redirections revérifiées, taille bornée, preuves.
- ui_snapshot : vraie fenêtre Win32 créée par le test (champ texte + champ mot de passe) :
  empreinte du texte sans le texte, mot de passe ignoré, < 2 s par itération.
- Scénario Bloc-notes réel (fichier ouvert → empreinte lue dans l'interface = empreinte du
  fichier) : `desktop`, lancé seulement avec SOULBAH_DESKTOP_TESTS=1 (ouvre une fenêtre).
"""
from __future__ import annotations

import hashlib
import http.server
import os
import subprocess
import sys
import threading
import time

import pytest

from permissions import PermissionGate
from runtime.evidence import build_evidence
from skills import REGISTRY, browser, vscode
from skills.desktop import ensure_dpi_awareness

IS_WIN = sys.platform == "win32"
PAGE = "<html><head><title>Page &amp; test</title><style>p{}</style></head><body><p>Bonjour  le monde</p>" \
       "<script>var secret=1;</script></body></html>"


class _Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_a):  # silencieux
        pass

    def do_GET(self):  # noqa: N802
        if self.path == "/page":
            body = PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/page")
            self.end_headers()
        elif self.path == "/to-file":
            self.send_response(302)
            self.send_header("Location", "file:///C:/Windows/win.ini")
            self.end_headers()
        elif self.path == "/loop":
            self.send_response(302)
            self.send_header("Location", "/loop")
            self.end_headers()
        elif self.path == "/big":
            body = b"x" * 4096
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()


@pytest.fixture()
def server():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()
    srv.server_close()


@pytest.fixture()
def allow_private(monkeypatch):
    monkeypatch.setenv("SOULBAH_BROWSER_ALLOW_PRIVATE", "1")


def _get(url, **extra):
    return REGISTRY["browser_get"].run({"type": "browser_get", "url": url, **extra})


# --- browser_get ------------------------------------------------------------------
def test_browser_get_reads_local_page_with_evidence(server, allow_private):
    res = _get(server + "/page")
    assert res.ok, res.detail
    d = res.data
    assert d["status"] == 200 and d["title"] == "Page & test"
    assert d["sha256"] == hashlib.sha256(PAGE.encode("utf-8")).hexdigest()
    assert "Bonjour le monde" in d["excerpt"] and "secret" not in d["excerpt"]
    ev = {e["kind"]: e for e in build_evidence("browser_get", res.ok, res.detail, res.data)}
    assert ev["http_status"]["value"] == {"status": 200, "url": server + "/page", "final_url": server + "/page"}
    assert ev["sha256"]["sha256"] == d["sha256"]


def test_browser_get_refuses_private_addresses_by_default(server, monkeypatch):
    monkeypatch.delenv("SOULBAH_BROWSER_ALLOW_PRIVATE", raising=False)
    res = _get(server + "/page")
    assert not res.ok and "non publique" in res.detail


def test_browser_get_redirects_are_followed_and_rechecked(server, allow_private):
    res = _get(server + "/redirect")
    assert res.ok and res.data["final_url"] == server + "/page"
    res = _get(server + "/to-file")
    assert not res.ok and "redirection refusée" in res.detail and "schéma" in res.detail
    res = _get(server + "/loop")
    assert not res.ok and "redirections" in res.detail


def test_browser_get_size_cap_and_http_errors(server, allow_private, monkeypatch):
    monkeypatch.setattr(browser, "MAX_BYTES", 1000)
    res = _get(server + "/big")
    assert not res.ok and "volumineuse" in res.detail
    res = _get(server + "/absent")
    assert not res.ok and res.data["status"] == 404


@pytest.mark.parametrize("url,fragment", [
    ("file:///C:/Windows/win.ini", "schéma"),
    ("ftp://example.com/x", "schéma"),
    ("javascript:alert(1)", "schéma"),
    ("http://user:pass@example.com/", "identifiants"),
    ("http:///x", "hôte"),
    ("", "requis"),
])
def test_browser_get_url_validation(url, fragment):
    gate = PermissionGate("auto", [], dry_run=False)
    ok, why = gate.authorize(REGISTRY["browser_get"], {"type": "browser_get", "url": url})
    assert not ok and fragment in why


@pytest.mark.parametrize("ip,refused", [
    ("10.0.0.1", True), ("192.168.1.1", True), ("172.16.5.4", True), ("127.0.0.1", True),
    ("169.254.169.254", True), ("0.0.0.0", True), ("::1", True), ("::ffff:127.0.0.1", True),
    ("fe80::1", True), ("fc00::1", True), ("224.0.0.1", True), ("8.8.8.8", False), ("1.1.1.1", False),
    ("2606:4700:4700::1111", False),
])
def test_ip_refusal(ip, refused):
    assert (browser._ip_refusal(ip) is not None) is refused


def test_browser_engine_requires_playwright(monkeypatch):
    monkeypatch.setattr(browser, "playwright_available", lambda: False)
    res = _get("https://example.com/", engine="browser")
    assert not res.ok and "Playwright" in res.detail


def test_browser_get_is_not_sensitive_and_needs_no_path():
    gate = PermissionGate("confirm", [], dry_run=False)
    ok, why = gate.authorize(REGISTRY["browser_get"], {"type": "browser_get", "url": "https://example.com/"})
    assert ok and why == "action non sensible"


# --- ui_snapshot ------------------------------------------------------------------
class _TestWindow:
    """Fenêtre Win32 de premier niveau avec un champ texte multiligne et un champ mot de passe."""

    def __init__(self, title: str, text: str):
        import ctypes
        from ctypes import wintypes

        u = ctypes.WinDLL("user32", use_last_error=True)
        u.CreateWindowExW.restype = wintypes.HWND
        u.CreateWindowExW.argtypes = [wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD,
                                      ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.HWND,
                                      wintypes.HMENU, wintypes.HINSTANCE, wintypes.LPVOID]
        u.DestroyWindow.argtypes = [wintypes.HWND]
        self._u = u
        ws_overlapped, ws_visible, ws_child, es_multiline, es_password = 0x00CF0000, 0x10000000, 0x40000000, 4, 0x20
        self.hwnd = u.CreateWindowExW(0, "STATIC", title, ws_overlapped | ws_visible, 50, 50, 400, 300,
                                      None, None, None, None)
        assert self.hwnd, ctypes.get_last_error()
        self.edit = u.CreateWindowExW(0, "EDIT", text, ws_child | ws_visible | es_multiline, 10, 10, 360, 150,
                                      self.hwnd, wintypes.HMENU(101), None, None)
        self.pwd = u.CreateWindowExW(0, "EDIT", "motdepasse", ws_child | ws_visible | es_password, 10, 170, 200, 24,
                                     self.hwnd, wintypes.HMENU(102), None, None)
        self.button = u.CreateWindowExW(0, "BUTTON", "Valider", ws_child | ws_visible, 220, 170, 100, 24,
                                        self.hwnd, wintypes.HMENU(103), None, None)

    def close(self):
        self._u.DestroyWindow(self.hwnd)


@pytest.mark.skipif(not IS_WIN, reason="Win32")
def test_ui_snapshot_hashes_text_without_returning_it():
    text = "bonjour\r\nle monde"
    title = f"SoulbahUiTest-{os.getpid()}"
    win = _TestWindow(title, text)
    try:
        times = []
        for _ in range(5):  # boucle observer : chaque itération < 2 s
            res = REGISTRY["ui_snapshot"].run({"type": "ui_snapshot", "window_title": title})
            assert res.ok, res.detail
            times.append(res.data["elapsed_ms"])
        assert max(times) < 2000, times
        d = res.data
        assert d["title"] == title and d["dpi"] >= 96 and d["scale"] >= 1
        assert d["edit"]["length"] == len(text)
        assert d["text_sha256"] == hashlib.sha256(text.encode("utf-8")).hexdigest()
        assert d["edit"]["sha256_lf"] == hashlib.sha256(b"bonjour\nle monde").hexdigest()
        classes = [c["class"].lower() for c in d["controls"]]
        assert classes.count("edit") == 2 and "button" in classes
        pwd = next(c for c in d["controls"] if c.get("password"))
        assert "label" not in pwd
        assert any(c.get("label") == "Valider" for c in d["controls"])
        # Le texte saisi et le mot de passe n'apparaissent NULLE PART dans le résultat.
        dump = repr(d)
        assert "bonjour" not in dump and "motdepasse" not in dump
        ev = {e["kind"]: e for e in build_evidence("ui_snapshot", res.ok, res.detail, res.data)}
        assert ev["window_title"]["value"] == title
        assert ev["ui_state"]["value"]["name"] == title and ev["ui_state"]["value"]["text_length"] == len(text)
        assert ev["sha256"]["sha256"] == d["text_sha256"]
    finally:
        win.close()


@pytest.mark.skipif(not IS_WIN, reason="Win32")
def test_ui_snapshot_unknown_window_and_validation():
    res = REGISTRY["ui_snapshot"].run({"type": "ui_snapshot", "window_title": "fenêtre-qui-n-existe-pas-42"})
    assert not res.ok and "aucune fenêtre" in res.detail
    gate = PermissionGate("confirm", [], dry_run=False)
    ok, why = gate.authorize(REGISTRY["ui_snapshot"], {"type": "ui_snapshot", "max_controls": 5000})
    assert not ok and "max_controls" in why
    ok, why = gate.authorize(REGISTRY["ui_snapshot"], {"type": "ui_snapshot"})
    assert ok and why == "action non sensible"


def test_dpi_awareness_is_idempotent():
    first = ensure_dpi_awareness()
    assert first == ensure_dpi_awareness()
    if IS_WIN:
        assert first in ("per_monitor_v2", "per_monitor", "system", "already_set")


# --- vscode_open ------------------------------------------------------------------
def test_vscode_open_absent_and_path_rules(tmp_path, monkeypatch):
    monkeypatch.setattr(vscode, "find_vscode", lambda: None)
    (tmp_path / "proj").mkdir()
    res = REGISTRY["vscode_open"].run({"type": "vscode_open", "path": str(tmp_path / "proj")})
    assert not res.ok and "VS Code introuvable" in res.detail
    gate = PermissionGate("auto", [str(tmp_path / "proj")], dry_run=False, allow_input_control=True)
    ok, why = gate.authorize(REGISTRY["vscode_open"], {"type": "vscode_open", "path": str(tmp_path)})
    assert not ok and "hors" in why
    ok, why = gate.authorize(REGISTRY["vscode_open"], {"type": "vscode_open", "path": str(tmp_path / "proj")})
    assert ok and "pré-autorisé" in why
    # Sans pré-autorisation du contrôle d'entrée : confirmation (pas de console = refus).
    gate = PermissionGate("auto", [str(tmp_path / "proj")], dry_run=False)
    monkeypatch.setattr("permissions._timed_input", lambda p, t, should_stop=None: None)
    ok, _ = gate.authorize(REGISTRY["vscode_open"], {"type": "vscode_open", "path": str(tmp_path / "proj")})
    assert not ok


def test_vscode_args_and_override(tmp_path, monkeypatch):
    f = tmp_path / "a.py"
    f.write_text("x", encoding="utf-8")
    assert vscode.vscode_args({"path": str(f), "line": 12, "new_window": True}) == ["--new-window", "--goto",
                                                                                   f"{f}:12"]
    assert vscode.vscode_args({"path": str(tmp_path)}) == [str(tmp_path)]
    monkeypatch.setenv("SOULBAH_VSCODE_EXE", str(tmp_path / "absent.exe"))
    assert vscode.find_vscode() is None
    monkeypatch.setenv("SOULBAH_VSCODE_EXE", str(f))  # pas un .exe
    assert vscode.find_vscode() is None


def test_vscode_env_drops_inherited_electron_and_vscode_vars(monkeypatch):
    monkeypatch.setenv("ELECTRON_RUN_AS_NODE", "1")
    monkeypatch.setenv("VSCODE_IPC_HOOK", "pipe-de-l-instance-parente")
    monkeypatch.setenv("SOULBAH_KEEP", "oui")
    env = vscode.vscode_env()
    assert "ELECTRON_RUN_AS_NODE" not in env and "VSCODE_IPC_HOOK" not in env
    assert env["SOULBAH_KEEP"] == "oui"


# --- scénario Bloc-notes réel (manuel) -------------------------------------------------
@pytest.mark.desktop
@pytest.mark.skipif(not IS_WIN or os.environ.get("SOULBAH_DESKTOP_TESTS") != "1",
                    reason="ouvre le Bloc-notes : SOULBAH_DESKTOP_TESTS=1 (audit §15, test de bureau)")
def test_notepad_file_hash_matches_ui_hash(tmp_path):
    """Le Bloc-notes ouvre un fichier ; l'empreinte lue DANS L'INTERFACE (sans clavier ni souris)
    est celle du fichier sur disque, en moins de 2 s par itération d'observation."""
    content = "Rapport SoulBah\r\nligne 2 : éàü\r\n"
    path = tmp_path / f"soulbah_notepad_{os.getpid()}.txt"
    path.write_bytes(content.encode("utf-8"))
    file_sha = hashlib.sha256(path.read_bytes()).hexdigest()
    proc = subprocess.Popen(["notepad.exe", str(path)])
    try:
        res = None
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            res = REGISTRY["ui_snapshot"].run({"type": "ui_snapshot", "window_title": path.stem})
            if res.ok and res.data.get("text_sha256"):
                break
            time.sleep(0.3)
        assert res is not None and res.ok, res and res.detail
        times = []
        for _ in range(5):
            r = REGISTRY["ui_snapshot"].run({"type": "ui_snapshot", "window_title": path.stem})
            assert r.ok
            times.append(r.data["elapsed_ms"])
        assert max(times) < 2000, times
        assert r.data["text_sha256"] == file_sha, "texte affiché ≠ contenu du fichier"
    finally:
        proc.kill()
