"""Disjoncteur par fournisseur d'IA (LOT 5 : extrait de router.py, inchangé).

Fermé → ouvert après `threshold` échecs consécutifs → semi-ouvert après `cooldown_s`
→ fermé au premier succès. En semi-ouvert, UN SEUL appel d'essai (sonde) passe.
Le routeur (router.py) l'utilise pour ne pas marteler un fournisseur en panne ; il
reste importable depuis `app.providers.router` et `app.providers` (compatibilité).
"""
from __future__ import annotations

import logging
import threading
import time
from typing import Any, Callable

logger = logging.getLogger("python-ia.llm")

# Jeton renvoyé par acquire() quand le disjoncteur est fermé (appel normal, pas une sonde).
_NOT_A_PROBE = object()


class CircuitBreaker:
    """Disjoncteur simple par fournisseur : fermé → ouvert après `threshold` échecs
    consécutifs → semi-ouvert après `cooldown_s` → fermé au premier succès.

    Semi-ouvert : UN SEUL appel d'essai (sonde) passe ; les autres appelants traitent
    le fournisseur comme ouvert tant que la sonde n'a pas abouti (succès → fermé,
    échec → rouvert). Une sonde terminée sans verdict (erreur non imputable au
    fournisseur, requête annulée) est rendue par release() ; par sûreté, une sonde qui
    n'aboutit jamais expire après `cooldown_s` (au plus une sonde par période)."""

    def __init__(self, threshold: int = 3, cooldown_s: float = 30.0,
                 clock: Callable[[], float] = time.monotonic):
        self.threshold = max(1, threshold)
        self.cooldown_s = cooldown_s
        self._clock = clock
        self._failures: dict[str, int] = {}
        self._opened_at: dict[str, float] = {}
        self._probes: dict[str, tuple[object, float]] = {}  # pid -> (jeton, début)
        self._lock = threading.Lock()  # l'orchestrateur est partagé (threads compris)

    def _state(self, pid: str) -> str:
        opened = self._opened_at.get(pid)
        if opened is None:
            return "closed"
        return "half_open" if self._clock() - opened >= self.cooldown_s else "open"

    def state(self, pid: str) -> str:
        with self._lock:
            return self._state(pid)

    def acquire(self, pid: str) -> object | None:
        """Autorise un appel : None si refusé (ouvert, ou sonde déjà en cours), sinon un
        jeton à rendre via release() si l'appel se termine sans verdict."""
        with self._lock:
            state = self._state(pid)
            if state == "closed":
                return _NOT_A_PROBE
            if state == "open":
                return None
            probe = self._probes.get(pid)
            if probe is not None and self._clock() - probe[1] < self.cooldown_s:
                return None
            token = object()
            self._probes[pid] = (token, self._clock())
            return token

    def allow(self, pid: str) -> bool:
        """Compatibilité : acquire() sans conserver le jeton (la sonde éventuelle est
        close par success()/failure())."""
        return self.acquire(pid) is not None

    def release(self, pid: str, token: object) -> None:
        """Rend la sonde détenue par `token` sans verdict : le prochain appelant sondera."""
        with self._lock:
            probe = self._probes.get(pid)
            if probe is not None and probe[0] is token:
                del self._probes[pid]

    def success(self, pid: str) -> None:
        with self._lock:
            self._failures.pop(pid, None)
            self._opened_at.pop(pid, None)
            self._probes.pop(pid, None)

    def failure(self, pid: str) -> None:
        with self._lock:
            self._probes.pop(pid, None)
            n = self._failures.get(pid, 0) + 1
            self._failures[pid] = n
            if n >= self.threshold:
                if pid not in self._opened_at or self._state(pid) == "half_open":
                    logger.warning("Disjoncteur OUVERT pour le fournisseur %s (%d échecs)", pid, n)
                self._opened_at[pid] = self._clock()

    def reset(self) -> None:
        with self._lock:
            self._failures.clear()
            self._opened_at.clear()
            self._probes.clear()

    def snapshot(self) -> dict[str, dict[str, Any]]:
        with self._lock:
            pids = set(self._failures) | set(self._opened_at)
            return {p: {"state": self._state(p), "failures": self._failures.get(p, 0)} for p in sorted(pids)}
