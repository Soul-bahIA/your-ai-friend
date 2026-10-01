"""File locale des mises à jour finales (completed / failed / cancelled) non encore
acceptées par le backend, et registre anti double exécution (T9).

Une mise à jour finale perdue laisse la tâche en in_progress : le backend la croit
orpheline au bout de 180 s, la remet en file, et elle serait EXÉCUTÉE UNE SECONDE
FOIS. Deux mécanismes l'empêchent :

1. **Finalisation** (état `pending`) : l'update est persisté dans un fichier JSON
   (survit à un redémarrage) et renvoyé avec un backoff exponentiel. Tant qu'un
   final est en attente, l'agent NE PREND AUCUNE NOUVELLE TÂCHE et envoie un
   heartbeat pour la tâche en finalisation (le serveur la garde en in_progress).
2. **Rejeu** (état `replay`) : si le serveur ne considère plus la tâche comme la
   nôtre (409 sur le final ou le heartbeat) ou si l'envoi échoue trop longtemps,
   le résultat est conservé (24 h). Si la tâche revient au poll, l'agent la
   réclame et renvoie CE résultat avec la nouvelle tentative, SANS la ré-exécuter.

Un final REJETÉ (400/404…) est remplacé par un final `failed` minimal qui
référence les artefacts produits : la tâche se termine au lieu d'être remise en
file (et ré-exécutée) jusqu'à 3 fois. Un 410 (tâche supprimée) retire tout.
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
MAX_AGE_SECONDS = 600.0  # au-delà, le final passe en « rejeu » et l'agent reprend le poll
REPLAY_TTL_SECONDS = 24 * 3600.0
KEEPALIVE_SECONDS = 30.0  # heartbeat d'une tâche en finalisation
_BASE_DELAY = 2.0
_MAX_DELAY = 120.0

# Issues renvoyées par TaskClient — doivent rester identiques à client.py
# (dupliquées pour que ce module reste importable sans `requests`).
OK = "ok"
CONFLICT = "conflict"
RETRY = "retry"
REJECTED = "rejected"
AUTH = "auth"
GONE = "gone"

STATE_PENDING = "pending"
STATE_REPLAY = "replay"

_ARTIFACT_KEYS = ("path", "output", "paths")


def collect_artifacts(result: Any, limit: int = 50) -> list[dict[str, Any]]:
    """Fichiers produits par les étapes (data.path / data.output / data.paths)."""
    out: list[dict[str, Any]] = []
    steps = result.get("steps") if isinstance(result, dict) else None
    if not isinstance(steps, list):
        return out
    for s in steps:
        if not isinstance(s, dict) or not isinstance(s.get("data"), dict):
            continue
        for key in _ARTIFACT_KEYS:
            value = s["data"].get(key)
            values = value if isinstance(value, list) else [value]
            for v in values:
                if isinstance(v, str) and v and len(out) < limit:
                    out.append({"index": s.get("index"), "type": s.get("type"), "path": v[:500]})
    return out


def minimal_failed_result(status: str, result: Any, detail: str | None = None) -> dict[str, Any]:
    """Final `failed` minimal envoyé quand le serveur rejette le final complet.

    Il conserve les drapeaux qui interdisent l'évaluation côté serveur (contrat
    §2 et §4) : `simulated`, `empty_plan`, et pour un run arrêté `cancelled` /
    `stopped` — un final `cancelled` rejeté puis remplacé par ce `failed` ne doit
    JAMAIS être évalué (node et python-ia ignorent `result.cancelled=true`)."""
    steps = result.get("steps") if isinstance(result, dict) else None
    minimal: dict[str, Any] = {
        "ok": False,
        "final_rejected": True,
        "original_status": status,
        "summary": "résultat final refusé par le serveur — remplacé par un échec minimal",
        "rejection": (detail or "")[:300],
        "steps_count": len(steps) if isinstance(steps, list) else 0,
        "artifacts": collect_artifacts(result),
    }
    for flag in ("simulated", "empty_plan", "cancelled", "stopped", "timed_out"):
        if isinstance(result, dict) and result.get(flag):
            minimal[flag] = True
    if status == "cancelled":
        minimal["cancelled"] = True
    return minimal


class PendingUpdates:
    def __init__(self, path: str = DEFAULT_PATH, max_age: float = MAX_AGE_SECONDS,
                 replay_ttl: float = REPLAY_TTL_SECONDS):
        self.path = path
        self.max_age = max_age
        self.replay_ttl = replay_ttl
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
        now = time.time()
        entries = []
        for e in data:
            if not (isinstance(e, dict) and e.get("task_id") and e.get("status")):
                continue
            e.setdefault("state", STATE_PENDING)
            if e["state"] == STATE_REPLAY and now - float(e.get("replay_since") or now) > self.replay_ttl:
                continue
            entries.append(e)
        return entries

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

    # --- consultation ----------------------------------------------------------
    def _pending(self) -> list[dict[str, Any]]:
        return [e for e in self.entries if e.get("state", STATE_PENDING) == STATE_PENDING]

    def __len__(self) -> int:
        """Nombre de finals en attente d'envoi (tâches « en finalisation »)."""
        return len(self._pending())

    def has(self, task_id: str) -> bool:
        """True si un final est en attente d'envoi pour cette tâche."""
        return any(e.get("task_id") == task_id for e in self._pending())

    def replay_entry(self, task_id: str) -> dict[str, Any] | None:
        """Résultat déjà obtenu pour une tâche que le serveur pourrait remettre en file."""
        now = time.time()
        for e in self.entries:
            if e.get("task_id") == task_id and e.get("state") == STATE_REPLAY:
                if now - float(e.get("replay_since") or now) <= self.replay_ttl:
                    return e
        return None

    # --- modifications -----------------------------------------------------------
    @staticmethod
    def _delay(tries: int) -> float:
        return min(_BASE_DELAY * (2 ** max(0, tries - 1)), _MAX_DELAY)

    def _put(self, entry: dict[str, Any]) -> None:
        self.entries = [e for e in self.entries if e.get("task_id") != entry["task_id"]]
        self.entries.append(entry)
        self._save()

    def add(
        self,
        task_id: str,
        status: str,
        attempt: int,
        result: dict | None = None,
        error_message: str | None = None,
        tries: int = 1,
        created_at: float | None = None,
    ) -> None:
        """Met (ou remet) un final en attente d'envoi : la tâche est « en finalisation »."""
        now = time.time()
        self._put({
            "task_id": task_id,
            "status": status,
            "attempt": attempt,
            "result": result,
            "error_message": error_message,
            "state": STATE_PENDING,
            "created_at": created_at if created_at is not None else now,
            "tries": tries,
            "next_try": now + self._delay(tries),
        })

    def remember(self, task_id: str, status: str, result: dict | None = None,
                 error_message: str | None = None) -> None:
        """Conserve un résultat à rejouer si la tâche revient au poll (pas de ré-exécution)."""
        self._put({
            "task_id": task_id,
            "status": status,
            "attempt": None,
            "result": result,
            "error_message": error_message,
            "state": STATE_REPLAY,
            "replay_since": time.time(),
        })

    def discard(self, task_id: str) -> None:
        """Oublie tout ce qui concerne la tâche (410 : supprimée côté serveur)."""
        before = len(self.entries)
        self.entries = [e for e in self.entries if e.get("task_id") != task_id]
        if len(self.entries) != before:
            self._save()

    # --- envoi -------------------------------------------------------------------
    def deliver(
        self,
        client: Any,
        task_id: str,
        status: str,
        attempt: int,
        result: dict | None = None,
        error_message: str | None = None,
        tries: int = 1,
        created_at: float | None = None,
    ) -> str:
        """Envoie un final et applique la politique selon l'issue. Retourne l'issue finale.

        OK → retiré ; 409 → conservé pour rejeu ; 410 → oublié ; rejet → final
        `failed` minimal ; réseau/5xx/401 → mis en attente (finalisation)."""
        short = str(task_id)[:8]
        outcome = client.update(task_id, status, result=result, error_message=error_message, attempt=attempt)
        if outcome == OK:
            self.discard(task_id)
            return OK
        if outcome == CONFLICT:
            log.warning("Final de %s refusé (409 : la tâche n'est plus à cet agent) — résultat conservé : "
                        "si elle revient, il sera renvoyé sans ré-exécution", short)
            self.remember(task_id, status, result, error_message)
            return CONFLICT
        if outcome == GONE:
            log.warning("Tâche %s supprimée côté serveur (410) — final abandonné", short)
            self.discard(task_id)
            return GONE
        if outcome == REJECTED:
            detail = getattr(client, "last_detail", None)
            if isinstance(result, dict) and result.get("final_rejected"):
                log.error("Final minimal de %s rejeté lui aussi (%s) — conservé pour rejeu, "
                          "la tâche ne sera pas ré-exécutée", short, detail or "?")
                self.remember(task_id, status, result, error_message)
                return REJECTED
            log.error("Final %s de %s rejeté par le backend (%s) — remplacé par un échec minimal",
                      status, short, detail or "?")
            minimal = minimal_failed_result(status, result, detail)
            message = "résultat final refusé par le serveur" + (f" ({detail})" if detail else "")
            return self.deliver(client, task_id, "failed", attempt, minimal, message[:4000],
                                tries=tries, created_at=created_at)
        # RETRY / AUTH : la tâche reste en finalisation, renvoi avec backoff.
        self.add(task_id, status, attempt, result=result, error_message=error_message,
                 tries=tries, created_at=created_at)
        return outcome

    def flush(self, client: Any, force: bool = False) -> None:
        """Renvoie les finals dus (tous si force=True)."""
        now = time.time()
        for e in list(self._pending()):
            if not force and float(e.get("next_try", 0)) > now:
                continue
            task_id = e["task_id"]
            short = str(task_id)[:8]
            created_at = float(e.get("created_at") or now)
            tries = int(e.get("tries") or 1) + 1
            outcome = self.deliver(
                client, task_id, e["status"], int(e.get("attempt") or 0),
                result=e.get("result"), error_message=e.get("error_message"),
                tries=tries, created_at=created_at,
            )
            if outcome == OK:
                log.info("✔ Mise à jour finale de %s enfin acceptée par le backend", short)
            elif outcome in (RETRY, AUTH) and time.time() - created_at >= self.max_age:
                log.error(
                    "✖ Final de %s impossible à envoyer depuis %d min — conservé pour rejeu : "
                    "l'agent reprend le poll, et si la tâche revient elle ne sera PAS ré-exécutée",
                    short, int(self.max_age // 60),
                )
                self.remember(task_id, e["status"], e.get("result"), e.get("error_message"))

    def keepalive(self, client: Any, interval: float | None = None) -> None:
        """Heartbeat des tâches en finalisation : le serveur les garde en in_progress
        (pas de remise en file). 409 → passage en rejeu ; 410 → oubli."""
        interval = KEEPALIVE_SECONDS if interval is None else interval
        now = time.time()
        for e in list(self._pending()):
            if now - float(e.get("last_heartbeat") or 0) < interval:
                continue
            e["last_heartbeat"] = now
            task_id = e["task_id"]
            outcome = client.event(task_id, "heartbeat", None, {"finalizing": True},
                                   attempt=int(e.get("attempt") or 0))
            if outcome == CONFLICT:
                log.warning("Tâche %s en finalisation reprise par le serveur (409) — résultat conservé pour rejeu",
                            str(task_id)[:8])
                self.remember(task_id, e["status"], e.get("result"), e.get("error_message"))
            elif outcome == GONE:
                log.warning("Tâche %s supprimée côté serveur (410) — final abandonné", str(task_id)[:8])
                self.discard(task_id)
