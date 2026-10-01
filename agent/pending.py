"""File locale des mises à jour finales (completed/failed) non encore acceptées
par le backend.

Sans elle, une mise à jour finale perdue (backend injoignable, 5xx…) laisse la
tâche en in_progress : le backend la croit orpheline, la remet en file, et elle
est EXÉCUTÉE UNE SECONDE FOIS. On persiste donc l'update dans un fichier JSON
(survit à un redémarrage de l'agent) et on la renvoie avec un backoff
exponentiel, avant chaque poll et au démarrage, pendant ~10 minutes.

Une réponse 409 (tentative périmée / tâche plus en cours) retire l'entrée : le
serveur a déjà tranché, la renvoyer ne servirait à rien.
"""
from __future__ import annotations

import json
import logging
import os
import tempfile
import time
from typing import Any

log = logging.getLogger("soulbah.pending")

DEFAULT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".pending_updates.json")
MAX_AGE_SECONDS = 600.0  # au-delà, on abandonne (le backend aura requeué la tâche)
_BASE_DELAY = 2.0
_MAX_DELAY = 120.0

# Issues renvoyées par TaskClient.update — doivent rester identiques à client.py
# (dupliquées pour que ce module reste importable sans `requests`).
OK = "ok"
CONFLICT = "conflict"
RETRY = "retry"
REJECTED = "rejected"


class PendingUpdates:
    def __init__(self, path: str = DEFAULT_PATH, max_age: float = MAX_AGE_SECONDS):
        self.path = path
        self.max_age = max_age
        self.entries: list[dict[str, Any]] = self._load()

    # --- persistance -------------------------------------------------------
    def _load(self) -> list[dict[str, Any]]:
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except FileNotFoundError:
            return []
        except (OSError, ValueError) as e:
            log.error("Fichier des mises à jour en attente illisible (%s) — ignoré : %s", self.path, e)
            return []
        if not isinstance(data, list):
            return []
        return [e for e in data if isinstance(e, dict) and e.get("task_id") and e.get("status")]

    def _save(self) -> None:
        try:
            if not self.entries:
                if os.path.exists(self.path):
                    os.remove(self.path)
                return
            directory = os.path.dirname(self.path) or "."
            fd, tmp = tempfile.mkstemp(prefix=".pending_", suffix=".tmp", dir=directory)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(self.entries, f, ensure_ascii=False)
            os.replace(tmp, self.path)  # écriture atomique
        except OSError as e:
            log.error("Impossible d'enregistrer les mises à jour en attente : %s", e)

    # --- API -----------------------------------------------------------------
    def __len__(self) -> int:
        return len(self.entries)

    def has(self, task_id: str) -> bool:
        return any(e.get("task_id") == task_id for e in self.entries)

    def add(
        self,
        task_id: str,
        status: str,
        attempt: int,
        result: dict | None = None,
        error_message: str | None = None,
        tries: int = 1,
    ) -> None:
        now = time.time()
        self.entries = [e for e in self.entries if e.get("task_id") != task_id]
        self.entries.append({
            "task_id": task_id,
            "status": status,
            "attempt": attempt,
            "result": result,
            "error_message": error_message,
            "created_at": now,
            "tries": tries,
            "next_try": now + self._delay(tries),
        })
        self._save()

    @staticmethod
    def _delay(tries: int) -> float:
        return min(_BASE_DELAY * (2 ** max(0, tries - 1)), _MAX_DELAY)

    def flush(self, client: Any, force: bool = False) -> None:
        """Renvoie les mises à jour dues (toutes si force=True)."""
        if not self.entries:
            return
        now = time.time()
        changed = False
        remaining: list[dict[str, Any]] = []
        for e in self.entries:
            if not force and e.get("next_try", 0) > now:
                remaining.append(e)
                continue
            short = str(e["task_id"])[:8]
            outcome = client.update(
                e["task_id"], e["status"],
                result=e.get("result"), error_message=e.get("error_message"),
                attempt=int(e.get("attempt") or 0),
            )
            changed = True
            if outcome == OK:
                log.info("✔ Mise à jour finale de %s (%s) enfin acceptée par le backend", short, e["status"])
                continue
            if outcome == CONFLICT:
                log.warning("Mise à jour finale de %s refusée (409 : tentative périmée) — abandonnée", short)
                continue
            if outcome == REJECTED:
                log.error("Mise à jour finale de %s rejetée définitivement par le backend — abandonnée", short)
                continue
            tries = int(e.get("tries") or 1) + 1
            if time.time() - float(e.get("created_at") or now) > self.max_age:
                log.error(
                    "✖ Mise à jour finale de %s impossible depuis %d min — abandonnée "
                    "(le backend remettra probablement la tâche en file)",
                    short, int(self.max_age // 60),
                )
                continue
            e["tries"] = tries
            e["next_try"] = time.time() + self._delay(tries)
            remaining.append(e)
        self.entries = remaining
        if changed:
            self._save()
