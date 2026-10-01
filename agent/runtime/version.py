"""Version du runtime et du protocole runtime ↔ P1 (poignée de main `register`).

Le serveur refuse (426) un runtime dont la version est inférieure à
`SOULBAH_RUNTIME_MIN_VERSION` ou dont le protocole diffère : le superviseur affiche
l'erreur et sort avec le code 4."""
from __future__ import annotations

RUNTIME_VERSION = "2.0.0"
PROTOCOL = 1
