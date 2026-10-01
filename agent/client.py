"""Client HTTP vers l'edge function `agent-tasks` (file de tâches Supabase)."""
from __future__ import annotations

import logging
from typing import Any

import requests

from config import Config

log = logging.getLogger("soulbah.client")


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

    def announce(self, allowed_dirs: list[str]) -> bool:
        """Déclare la whitelist de dossiers au backend (au démarrage).

        Le planificateur l'injecte dans le contexte pour ne générer que des
        chemins autorisés (sinon le gate refuse et la tâche échoue)."""
        try:
            resp = requests.post(
                f"{self.base}/announce",
                headers=self._headers(),
                json={"allowed_dirs": allowed_dirs},
                timeout=15,
            )
            resp.raise_for_status()
            return True
        except requests.RequestException as e:
            log.warning("Annonce de la whitelist échouée : %s", e)
            return False

    def poll(self) -> list[dict[str, Any]]:
        """Récupère jusqu'à 5 tâches en attente (user_id déduit de la clé côté backend)."""
        try:
            resp = requests.get(
                f"{self.base}/poll",
                headers=self._headers(),
                timeout=15,
            )
            resp.raise_for_status()
            return resp.json().get("tasks", [])
        except requests.RequestException as e:
            log.warning("Poll échoué : %s", e)
            return []

    def event(
        self,
        task_id: str,
        type: str,
        message: str | None = None,
        data: dict | None = None,
    ) -> None:
        """Émet un évènement d'exécution (timeline + captures live). Best-effort."""
        try:
            requests.post(
                f"{self.base}/event",
                headers=self._headers(),
                json={"task_id": task_id, "type": type, "message": message, "data": data or {}},
                timeout=10,
            )
        except requests.RequestException:
            pass  # le streaming ne doit jamais faire échouer la tâche

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
        except requests.RequestException:
            return "none"

    def update(
        self,
        task_id: str,
        status: str,
        result: dict | None = None,
        error_message: str | None = None,
    ) -> bool:
        """Met à jour le statut d'une tâche (in_progress / completed / failed)."""
        body: dict[str, Any] = {"task_id": task_id, "status": status}
        if result is not None:
            body["result"] = result
        if error_message is not None:
            body["error_message"] = error_message
        try:
            resp = requests.post(
                f"{self.base}/update",
                headers=self._headers(),
                json=body,
                timeout=15,
            )
            resp.raise_for_status()
            return True
        except requests.RequestException as e:
            log.error("Update échoué pour %s : %s", task_id, e)
            return False
