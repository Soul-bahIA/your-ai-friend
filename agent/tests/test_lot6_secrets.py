"""LOT 6 — coffre DPAPI de la clé agent (agent/secrets.py) et chargement par config."""
from __future__ import annotations

import os
import sys

import pytest

import secrets as agent_secrets
import soulbah_agent
from config import load_config

WIN = sys.platform == "win32"


@pytest.fixture()
def vault(tmp_path, monkeypatch):
    """Coffre isolé (conftest pose déjà SOULBAH_SECRETS_DIR sur un dossier temporaire)."""
    d = tmp_path / "coffre"
    monkeypatch.setenv("SOULBAH_SECRETS_DIR", str(d))
    monkeypatch.delenv("SOULBAH_AGENT_KEY", raising=False)
    return d


def test_stdlib_secrets_api_still_available():
    """agent/secrets.py masque le module standard : son API doit rester utilisable."""
    assert len(agent_secrets.token_hex(8)) == 16
    assert agent_secrets.compare_digest("a", "a")


def test_key_file_location(vault, monkeypatch):
    assert agent_secrets.key_file() == os.path.join(str(vault), agent_secrets.KEY_FILE_NAME)
    monkeypatch.setenv("SOULBAH_SECRETS_DIR", "")
    monkeypatch.setenv("LOCALAPPDATA", r"C:\Users\x\AppData\Local")
    assert agent_secrets.key_file() == os.path.join(r"C:\Users\x\AppData\Local", "Soulbah", "agent_key.dpapi")


@pytest.mark.skipif(not WIN, reason="DPAPI Windows")
def test_store_load_delete_roundtrip(vault):
    assert agent_secrets.load_agent_key() is None and not agent_secrets.has_agent_key()
    path = agent_secrets.store_agent_key("  sbk_cle_de_test_0123456789  ")
    assert path == agent_secrets.key_file() and os.path.isfile(path) and agent_secrets.has_agent_key()
    with open(path, "rb") as f:
        blob = f.read()
    assert b"sbk_cle_de_test" not in blob  # jamais en clair sur le disque
    assert agent_secrets.load_agent_key() == "sbk_cle_de_test_0123456789"
    assert agent_secrets.delete_agent_key() is True and agent_secrets.delete_agent_key() is False
    assert agent_secrets.load_agent_key() is None


@pytest.mark.skipif(not WIN, reason="DPAPI Windows")
def test_unreadable_file_returns_none_with_warning(vault, caplog):
    vault.mkdir()
    (vault / agent_secrets.KEY_FILE_NAME).write_bytes(b"pas-un-blob-dpapi")
    with caplog.at_level("WARNING"):
        assert agent_secrets.load_agent_key() is None
    assert "illisible" in caplog.text and "--store-key" in caplog.text


def test_store_rejects_short_key(vault):
    with pytest.raises(ValueError):
        agent_secrets.store_agent_key("court")


@pytest.mark.skipif(WIN, reason="comportement hors Windows")
def test_non_windows_never_falls_back_to_plaintext(vault):
    with pytest.raises(NotImplementedError):
        agent_secrets.store_agent_key("sbk_cle_de_test_0123456789")


# --- config.load_config ---------------------------------------------------------------------
def test_key_missing_everywhere_is_explicit_system_exit(vault):
    with pytest.raises(SystemExit) as e:
        load_config()
    assert "SOULBAH_AGENT_KEY" in str(e.value) and "--store-key" in str(e.value)
    cfg = load_config(require_key=False)
    assert cfg.agent_key == "" and cfg.key_source == ""


@pytest.mark.skipif(not WIN, reason="DPAPI Windows")
def test_config_loads_dpapi_key_when_env_empty(vault, monkeypatch):
    agent_secrets.store_agent_key("sbk_cle_dpapi_0123456789")
    cfg = load_config()
    assert cfg.agent_key == "sbk_cle_dpapi_0123456789" and cfg.key_source == "dpapi"
    # L'environnement garde la priorité (et la source est signalée).
    monkeypatch.setenv("SOULBAH_AGENT_KEY", "cle-env-1234")
    cfg = load_config()
    assert cfg.agent_key == "cle-env-1234" and cfg.key_source == "env"


def test_approval_mode_config(monkeypatch):
    monkeypatch.setenv("SOULBAH_AGENT_KEY", "k")
    for raw, expected in (("", "console"), ("remote", "remote"), (" Both ", "both"), ("bizarre", "console")):
        monkeypatch.setenv("SOULBAH_APPROVAL_MODE", raw)
        assert load_config().approval_mode == expected


# --- options --store-key / --forget-key ------------------------------------------------------
@pytest.mark.skipif(not WIN, reason="DPAPI Windows")
def test_store_key_and_forget_key_cli(vault, monkeypatch, capsys):
    monkeypatch.setattr(soulbah_agent, "_setup_logging", lambda: None)
    monkeypatch.setattr(soulbah_agent, "TaskClient", lambda *a: pytest.fail("ne doit pas démarrer"))
    monkeypatch.setenv("SOULBAH_AGENT_KEY", "sbk_depuis_env_0123456789")
    assert soulbah_agent.main(["--store-key"]) == 0
    out = capsys.readouterr().out
    assert agent_secrets.key_file() in out and "retirez" in out and "sbk_depuis_env" not in out
    assert agent_secrets.load_agent_key() == "sbk_depuis_env_0123456789"
    # Clé lue sur l'entrée standard quand l'environnement est vide.
    monkeypatch.delenv("SOULBAH_AGENT_KEY")
    import io

    monkeypatch.setattr(soulbah_agent.sys, "stdin", io.StringIO("sbk_depuis_stdin_0123456789\n"))
    assert soulbah_agent.main(["--store-key"]) == 0
    assert agent_secrets.load_agent_key() == "sbk_depuis_stdin_0123456789"
    assert soulbah_agent.main(["--forget-key"]) == 0 and not agent_secrets.has_agent_key()
    assert soulbah_agent.main(["--forget-key"]) == 0  # idempotent
    monkeypatch.setattr(soulbah_agent.sys, "stdin", io.StringIO(""))
    assert soulbah_agent.main(["--store-key"]) == 2  # aucune clé fournie


@pytest.mark.skipif(not WIN, reason="DPAPI Windows")
def test_warning_when_env_key_still_present_but_dpapi_exists(vault, tmp_path, monkeypatch, caplog):
    import json

    monkeypatch.setattr(soulbah_agent, "_setup_logging", lambda: None)
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    monkeypatch.setenv("SOULBAH_ALLOWED_DIRS", "")
    agent_secrets.store_agent_key("sbk_copie_dpapi_0123456789")
    monkeypatch.setenv("SOULBAH_AGENT_KEY", "sbk_encore_dans_env_0123456789")
    plan = tmp_path / "plan.json"
    plan.write_text(json.dumps([{"type": "wait", "seconds": 0}]), encoding="utf-8")
    with caplog.at_level("WARNING"):
        assert soulbah_agent.main(["--plan", str(plan)]) == 0
    assert "copie chiffrée" in caplog.text and "sbk_encore_dans_env" not in caplog.text
