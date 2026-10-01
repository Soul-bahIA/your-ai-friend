"""Configuration pytest : rend les modules de l'agent importables (sans GUI) et
garantit des tests hermétiques (T53) : agent/.env n'est JAMAIS chargé."""
from __future__ import annotations

import os
import sys
import tempfile

# Avant tout import de config.py (qui chargerait agent/.env).
os.environ["SOULBAH_NO_DOTENV"] = "1"
# LOT 6 : le coffre DPAPI réel de l'utilisateur (%LOCALAPPDATA%\Soulbah) n'est jamais lu
# ni écrit par les tests — un dossier temporaire vide par session.
os.environ["SOULBAH_SECRETS_DIR"] = tempfile.mkdtemp(prefix="soulbah-tests-secrets-")
# LOT 8 : journal, verrou d'instance et fichiers de tâches du runtime — jamais ceux de
# l'utilisateur (%LOCALAPPDATA%\Soulbah\runtime) ; les tests qui en ont besoin le surchargent.
os.environ["SOULBAH_RUNTIME_DIR"] = tempfile.mkdtemp(prefix="soulbah-tests-runtime-")

# V3 LOT 1 : configuration centrale hermétique — ni variable SOULBAH_* de configuration héritée
# du shell, ni soulbah.config.json local : l'exemple versionné (HYBRID) est imposé.
for _k in ("SOULBAH_MODE", "SOULBAH_MAX_PARALLEL_AGENTS", "SOULBAH_RESOURCE_PROFILE", "SOULBAH_MODEL_POLICY",
           "SOULBAH_NETWORK_ALLOW_HOSTS", "SOULBAH_COMPUTER_CONTROL", "SOULBAH_RECORDING", "SOULBAH_SELF_IMPROVEMENT"):
    os.environ.pop(_k, None)
os.environ["SOULBAH_CONFIG"] = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                                            "shared", "config", "soulbah.config.example.json")

AGENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if AGENT_DIR not in sys.path:
    sys.path.insert(0, AGENT_DIR)


def pytest_configure(config):
    # LOT 12 : tests qui ouvrent de vraies fenêtres sur le bureau (audit §15) — lancés
    # seulement avec SOULBAH_DESKTOP_TESTS=1.
    config.addinivalue_line("markers", "desktop: ouvre des applications sur le bureau (SOULBAH_DESKTOP_TESTS=1)")
