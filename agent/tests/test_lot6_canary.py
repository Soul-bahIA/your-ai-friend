"""LOT 6 — rédaction des secrets et test « canari » (audit §13 : le secret canari est
absent des lignes, des logs et des prompts ; S1, S8).

(a) canari dans un fichier HORS des dossiers autorisés → read_file refusé par le gate ;
(b) canari dans SOULBAH_REDACT_VALUES + type_text / write_file simulés (dry-run) → absent
    des logs capturés, des évènements envoyés par le client HTTP (faux `requests`) et du
    rapport final (`update`) ;
(c) redact_text sur une ligne de journal contenant une clé `sbk_…`."""
from __future__ import annotations

import json
import logging

import pytest

import client as client_mod
import redaction
import soulbah_agent
from client import TaskClient
from config import Config
from executor import Executor
from permissions import PermissionGate
from redaction import SECRET_MASK, RedactingFormatter, redact_obj, redact_text
from skills.filesystem import FileOpsSkill

CANARY = "SOULBAH_CANARY_TEST_7f3a9c-ne-doit-jamais-sortir"


# --- redact_text --------------------------------------------------------------------------
@pytest.mark.parametrize("line", [
    "clé OpenAI sk-abcdefghijklmnop1234567890",
    "x-agent-key: sbk_0123456789abcdefABCDEF",
    "jeton sbap_eyJ2IjoxfQ.abcdef0123456789",
    "AKIAIOSFODNN7EXAMPLE",
    "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    "xoxb-1234567890-abcdefghijkl",
    "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
    "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----",
    "-----BEGIN PRIVATE KEY-----\nMIIEpAIBAAKCAQEA (END manquant)",
    "password=hunter2",
    "passwd: 'motdepasse'",
    "secret=\"s3cr3t\"",
    "token=t0k3n-abc",
    "api_key=k-123456",
    "Authorization: Bearer abc.def.ghi",
    "sha " + "a" * 40,
    "digest " + "0123456789abcdef" * 4,
])
def test_redact_text_masks_known_patterns(line):
    out = redact_text(line)
    assert SECRET_MASK in out
    for token in ("sk-abc", "sbk_0", "sbap_", "AKIA", "ghp_", "xoxb-", "eyJhbGci", "MIIEpAIBAA", "hunter2",
                  "motdepasse", "s3cr3t", "t0k3n", "k-123456", "abc.def.ghi", "a" * 40, "0123456789abcdef0123"):
        assert token not in out, (line, out)


def test_redact_text_keeps_key_names_and_harmless_text():
    assert redact_text("password=hunter2") == f"password={SECRET_MASK}"
    assert redact_text("Authorization: Bearer xyz123") == f"Authorization: Bearer {SECRET_MASK}"
    harmless = ("uuid 2e876509-aaaa-bbbb-cccc-123456789012", "chemin hors liste blanche : C:/x/y.txt",
                "Le secret canari est absent des journaux", "12 caractères écrits dans notes.txt", "")
    for s in harmless:
        assert redact_text(s) == s
    assert redact_text(redact_text("token=abc")) == redact_text("token=abc")  # idempotent


def test_redact_text_masks_env_values_and_agent_key(monkeypatch):
    monkeypatch.setenv("SOULBAH_REDACT_VALUES", f"{CANARY};autre-valeur-secrete; ;ab")
    monkeypatch.setenv("SOULBAH_AGENT_KEY", "cle-agent-en-clair-1234")
    out = redact_text(f"log {CANARY} puis autre-valeur-secrete puis cle-agent-en-clair-1234 et ab")
    assert CANARY not in out and "autre-valeur-secrete" not in out and "cle-agent-en-clair" not in out
    assert out.endswith("et ab")  # valeurs trop courtes ignorées


def test_canary_c_log_line_with_sbk_key():
    line = "12:00:01  INFO    soulbah.client  en-tête x-agent-key: sbk_LiveKeyABCDEF0123456789 refusé (401)"
    out = redact_text(line)
    assert "sbk_" not in out and SECRET_MASK in out and "refusé (401)" in out


# --- redact_obj ---------------------------------------------------------------------------
def test_redact_obj_masks_secret_keys_with_lot1_label():
    obj = {
        "text": "Bonjour !", "content": "x" * 10, "password": "p", "api_key": "k", "authorization": "Bearer z",
        "key_hash": "h", "approval_token": "sbap_abc", "token": 42,
        "note": "ok", "nested": [{"text": "a"}, {"detail": "token=abc", "n": 3}],
        "already": {"content": "[texte masqué : 3 car.]"}, "empty": {"text": "", "content": None},
    }
    out = redact_obj(obj)
    assert out["text"] == "[texte masqué : 9 car.]" and out["content"] == "[texte masqué : 10 car.]"
    for k in ("password", "api_key", "authorization", "key_hash", "approval_token", "token"):
        assert out[k].startswith("[texte masqué : "), k
    assert out["note"] == "ok" and out["nested"][0]["text"] == "[texte masqué : 1 car.]"
    assert out["nested"][1] == {"detail": f"token={SECRET_MASK}", "n": 3}
    assert out["already"]["content"] == "[texte masqué : 3 car.]"  # pas remasqué
    assert out["empty"] == {"text": "", "content": None}
    assert obj["text"] == "Bonjour !"  # copie profonde : l'original est intact
    assert isinstance(redact_obj((1, "sbk_1234567890ab")), list)


def test_redact_obj_bounds_depth():
    deep: dict = {"v": "sbk_1234567890ab"}
    for _ in range(redaction.MAX_DEPTH + 3):
        deep = {"d": deep}
    out = redact_obj(deep)
    assert redaction.TOO_DEEP_MASK in json.dumps(out, ensure_ascii=False)
    assert "sbk_" not in json.dumps(out, ensure_ascii=False)


# --- Formateur de journaux ---------------------------------------------------------------
def test_redacting_formatter_masks_args_and_traceback(monkeypatch, caplog):
    monkeypatch.setenv("SOULBAH_REDACT_VALUES", CANARY)
    caplog.handler.setFormatter(RedactingFormatter("%(levelname)s %(message)s"))
    logger = logging.getLogger("soulbah.test.redaction")
    with caplog.at_level(logging.INFO, logger="soulbah.test.redaction"):
        logger.info("valeur %s et clé %s", CANARY, "sbk_0123456789abcdef")
        try:
            raise RuntimeError(f"échec avec {CANARY}")
        except RuntimeError:
            logger.exception("exception")
    assert CANARY not in caplog.text and "sbk_" not in caplog.text and "RuntimeError" in caplog.text


def test_setup_logging_uses_redacting_formatter(tmp_path, monkeypatch):
    root = logging.getLogger()
    before = list(root.handlers)
    monkeypatch.setattr(soulbah_agent, "_logging_ready", False)
    monkeypatch.setattr(soulbah_agent, "LOG_DIR", str(tmp_path / "logs"))
    try:
        soulbah_agent._setup_logging()
        added = [h for h in root.handlers if h not in before]
        assert len(added) == 2 and all(isinstance(h.formatter, RedactingFormatter) for h in added)
    finally:
        for h in root.handlers:
            if h not in before:
                root.removeHandler(h)
                h.close()


# --- Canari (a) : fichier hors whitelist ---------------------------------------------------
def test_canary_a_read_outside_workspace_refused(tmp_path, monkeypatch):
    allowed = tmp_path / "ws"
    allowed.mkdir()
    outside = tmp_path / "ailleurs"
    outside.mkdir()
    secret_file = outside / "config.txt"
    secret_file.write_text(f"API={CANARY}\n", encoding="utf-8")
    monkeypatch.setattr("permissions._timed_input", lambda *a, **k: pytest.fail("aucune confirmation attendue"))
    gate = PermissionGate("auto", [str(allowed)], dry_run=False)
    ok, reason = gate.authorize(FileOpsSkill(), {"type": "read_file", "path": str(secret_file)})
    assert not ok and "hors liste blanche" in reason and CANARY not in reason
    # Même via l'executor : aucune lecture, le rapport ne contient pas le canari.
    report = Executor(gate).run_task({"steps": [{"type": "read_file", "path": str(secret_file)}]})
    assert not report["ok"] and CANARY not in json.dumps(report, ensure_ascii=False)


# --- Canari (b) : type_text / write_file simulés, logs, évènements, rapport ---------------
@pytest.fixture()
def http_sink(monkeypatch):
    """Faux `requests` : capture les corps JSON envoyés par TaskClient (aucun réseau)."""
    sent: list[dict] = []

    class _Resp:
        status_code = 200

        @staticmethod
        def json():
            return {"success": True}

    def fake_post(url, headers=None, json=None, timeout=None):
        sent.append({"url": url, "headers": headers, "body": json})
        return _Resp()

    monkeypatch.setattr(client_mod.requests, "post", fake_post)
    return sent


def test_canary_b_absent_from_logs_events_and_final_report(tmp_path, monkeypatch, caplog, http_sink):
    monkeypatch.setenv("SOULBAH_REDACT_VALUES", CANARY)
    caplog.handler.setFormatter(RedactingFormatter("%(name)s %(message)s"))
    allowed = tmp_path / "ws"
    allowed.mkdir()
    gate = PermissionGate("confirm", [str(allowed)], dry_run=True)
    executor = Executor(gate)
    tc = TaskClient(Config(api_url="http://test", agent_key="cle-de-test-1234"))
    steps = [
        {"type": "type_text", "text": f"mot de passe : {CANARY}", "window_title": "Bloc-notes"},
        {"type": "write_file", "path": str(allowed / "notes.txt"), "content": f"token={CANARY}"},
        {"type": "wait", "seconds": 0, "note": f"canari dans une note {CANARY}"},
    ]
    with caplog.at_level(logging.DEBUG):
        logging.getLogger("soulbah.test").info("étape avec %s", CANARY)  # un log imprudent…
        report = executor.run_task({"steps": steps}, on_event=lambda t, m, d: tc.event("t1", t, m, d))
        assert tc.update("t1", "completed", result=report, error_message=f"rien {CANARY}") == "ok"
    assert report["ok"] and report["simulated"]
    wire = json.dumps([s["body"] for s in http_sink], ensure_ascii=False)
    assert CANARY not in wire, wire
    assert CANARY not in caplog.text
    # Le texte libre reste masqué au libellé du LOT 1 ; la note est rédigée par motif/valeur.
    assert "[texte masqué" in wire and SECRET_MASK in wire
    assert any(s["url"].endswith("/event") for s in http_sink) and http_sink[-1]["url"].endswith("/update")
    assert (allowed / "notes.txt").exists() is False  # dry-run : rien n'a été écrit
