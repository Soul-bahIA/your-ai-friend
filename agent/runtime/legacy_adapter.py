"""Adaptateur legacy (LOT 8, audit §9.2) : quand le serveur n'a pas l'API runtime V2
(`register` → 404) ou sur demande (`SOULBAH_RUNTIME_LEGACY=1`, `--legacy`), le superviseur
exécute la boucle de l'agent V1 (`/api/agent-tasks`) DANS son propre processus, avec un
seul « slot ». Aucun code n'est dupliqué : on appelle `soulbah_agent._serve_locked`.

La garde d'instance est celle du superviseur (déjà prise, kind=runtime) : on n'appelle
PAS `soulbah_agent._serve`, qui prendrait puis RELÂCHERAIT le verrou du même processus.
Ctrl+C / SIGTERM passent par le gestionnaire de l'agent V1 (arrêt de la boucle et
interruption de la tâche en cours, comme en V1).
"""
from __future__ import annotations

import logging
import signal
from typing import Any

log = logging.getLogger("soulbah.runtime.legacy")


def run(cfg: Any, executor: Any, once: bool = False) -> int:
    import soulbah_agent  # import tardif : module lourd (skills, client V1)

    log.warning("Mode legacy : boucle de l'agent V1 (un seul slot, /api/agent-tasks)")
    soulbah_agent._running = True
    soulbah_agent._interrupts = 0
    old_int = signal.signal(signal.SIGINT, soulbah_agent._stop)
    old_term = signal.signal(signal.SIGTERM, soulbah_agent._stop)
    try:
        return soulbah_agent._serve_locked(cfg, executor, once)
    finally:
        signal.signal(signal.SIGINT, old_int)
        signal.signal(signal.SIGTERM, old_term)
