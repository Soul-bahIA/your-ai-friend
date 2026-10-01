"""Configuration pytest : rend les modules de l'agent importables (sans GUI)."""
from __future__ import annotations

import os
import sys

AGENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if AGENT_DIR not in sys.path:
    sys.path.insert(0, AGENT_DIR)
