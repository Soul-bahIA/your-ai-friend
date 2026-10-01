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

AGENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if AGENT_DIR not in sys.path:
    sys.path.insert(0, AGENT_DIR)
