"""Client HTTP vers le backend Node (`/api/agent-tasks`, file de tâches).

Contrat « tentative » (anti double exécution) : chaque tâche reçue par poll porte
`requeue_count`, mémorisé comme `attempt` pour toute l'exécution et renvoyé dans
le corps de CHAQUE POST /update et /event. Le backend répond 409 si la tentative
est périmée ou si la tâche n'est plus in_progress : l'agent doit alors cesser
d'agir pour cette tâche.
"""
from __future__ import annotations

import logging
from typing import Any

import requests

from config import Config

log = logging.getLogger("soulbah.client")

# Issues normalisées d'un POST (update / event / claim)
OK = "ok"
CONFLICT = "conflict"  # 409 : tâche déjà prise / tentative périmée / plus in_progress
RETRY = "retry"  # réseau, timeout, 5xx, 429, 401/403 : réessayable
REJECTED = "rejected"  # autre 4xx (400, 404…) : inutile de réessayer


def task_attempt(task: dict[str, Any]) -> int:
    """`requeue_count` de la tâche (0 si absent/invalide)."""
    try:
        return max(0, int(task.get("requeue_count") or 0))
    except (TypeError, ValueError):
        return 0


def _classify(status_code: int) -> str:
    if 200 <= status_code < 300:
        return OK
    if status_code == 409:
        return CONFLICT
    if status_code >= 500 or status_code in (401, 403, 408, 425, 429):
        return RETRY
    return REJECTED


class TaskClient:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        # Backend Node (fonctionnalité migrée depuis l'edge function agent-tasks)
        self.base = f"{cfg.api_url}/api/agent-tasks"

    def _headers(self) -> dict[str, str]:
        return {
            "Content-Type": "application/json",
            "x-agent-key": self.cfg.agent_key,
        }

    def _post(self, path: str, body: dict[str, Any], timeout: float) -> tuple[str, str, Any]:
        """POST JSON. Retourne (issue, description lisible, json de réponse ou None)."""
        try:
            resp = requests.post(f"{self.base}/{path}", headers=self._headers(), json=body, timeout=timeout)
        except requests.RequestException as e:
            return RETRY, f"backend injoignable ({e.__class__.__name__})", None
        outcome = _classify(resp.status_code)
        try:
            payload = resp.json()
        except ValueError:
            payload = None
        if outcome == OK:
            return OK, "ok", payload
        msg = payload.get("error") if isinstance(payload, dict) else None
        return outcome, f"HTTP {resp.status_code}" + (f" — {msg}" if msg else ""), payload

    def announce(self, allowed_dirs: list[str]) -> bool:
        """Déclare la whitelist de dossiers au backend (au démarrage).

        Le planificateur l'injecte dans le contexte pour ne générer que des
        chemins autorisés (sinon le gate refuse et la tâche échoue)."""
        outcome, detail, _ = self._post("announce", {"allowed_dirs": allowed_dirs}, timeout=15)
        if outcome != OK:
            log.warning("Annonce de la whitelist échouée : %s", detail)
            return False
        return True

    def poll(self) -> list[dict[str, Any]] | None:
        """Récupère jusqu'à 5 tâches en attente (user_id déduit de la clé côté backend).

        Retourne None si le backend est injoignable ou en erreur (=> backoff)."""
        try:
            resp = requests.get(f"{self.base}/poll", headers=self._headers(), timeout=15)
            resp.raise_for_status()
            tasks = resp.json().get("tasks", [])
            return [t for t in tasks if isinstance(t, dict)] if isinstance(tasks, list) else []
        except (requests.RequestException, ValueError, AttributeError) as e:
            log.warning("Poll échoué : %s", e)
            return None

    def claim(self, task_id: str, attempt: int) -> tuple[str, str, int | None]:
        """Claim atomique (passage pending → in_progress).

        Retourne (issue, description, attempt confirmé par le serveur ou None)."""
        outcome, detail, payload = self._post(
            "update", {"task_id": task_id, "status": "in_progress", "attempt": attempt}, timeout=15
        )
        server_attempt = None
        if outcome == OK and isinstance(payload, dict):
            # Réponse { success, status, requeue_count } (ou { task: {...} }).
            task = payload.get("task") if isinstance(payload.get("task"), dict) else payload
            if "requeue_count" in task:
                server_attempt = task_attempt(task)
        return outcome, detail, server_attempt

    def event(
        self,
        task_id: str,
        type: str,
        message: str | None = None,
        data: dict | None = None,
        attempt: int = 0,
    ) -> str:
        """Émet un évènement d'exécution (timeline + captures live, heartbeat).

        Best-effort : seule l'issue CONFLICT (409) doit être traitée par l'appelant."""
        outcome, detail, _ = self._post(
            "event",
            {"task_id": task_id, "type": type, "message": message, "data": data or {}, "attempt": attempt},
            timeout=10,
        )
        if outcome not in (OK, CONFLICT):
            log.debug("Évènement %s non transmis : %s", type, detail)
        return outcome

    def get_control(self, task_id: str) -> str:
        """Ordre de contrôle courant posé par l'utilisateur : none | pause | stop."""
        try:
            resp = requests.get(
                f"{self.base}/{task_id}/control",
                headers=self._headers(),
                timeout=10,
            )
            resp.raise_for_status()
            return resp.json().get("control", "none")
        except (requests.RequestException, ValueError, AttributeError):
            return "none"

    def update(
        self,
        task_id: str,
        status: str,
        result: dict | None = None,
        error_message: str | None = None,
        attempt: int = 0,
    ) -> str:
        """Met à jour le statut final d'une tâche (completed / failed). Retourne l'issue."""
        body: dict[str, Any] = {"task_id": task_id, "status": status, "attempt": attempt}
        if result is not None:
            body["result"] = result
        if error_message is not None:
            body["error_message"] = error_message
        outcome, detail, _ = self._post("update", body, timeout=15)
        if outcome != OK:
            log.error("Update %s échoué pour %s : %s", status, str(task_id)[:8], detail)
        return outcome
