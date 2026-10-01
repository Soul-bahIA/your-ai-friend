"""Configuration pytest : rend les modules de l'agent importables (sans GUI) et
garantit des tests hermétiques (T53) : agent/.env n'est JAMAIS chargé."""
from __future__ import annotations

import os
import sys

# Avant tout import de config.py (qui chargerait agent/.env).
os.environ["SOULBAH_NO_DOTENV"] = "1"

AGENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if AGENT_DIR not in sys.path:
    sys.path.insert(0, AGENT_DIR)
