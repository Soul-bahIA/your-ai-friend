"""Client HTTP vers le backend Node (`/api/agent-tasks`, file de tâches).

Contrat « tentative » (anti double exécution) : chaque tâche reçue par poll porte
`requeue_count`, mémorisé comme `attempt` pour toute l'exécution et renvoyé dans
le corps de CHAQUE POST /update et /event. Le backend répond 409 si la tentative
est périmée ou si la tâche n'est plus in_progress : l'agent doit alors cesser
d'agir pour cette tâche. 410 (contrat §3) : la tâche a été supprimée — l'agent
l'abandonne immédiatement et oublie toute mise à jour en attente pour elle.
"""
from __future__ import annotations

import logging
from typing import Any

import requests

from config import Config
from redaction import redact_obj, redact_text

log = logging.getLogger("soulbah.client")

# Issues normalisées d'un POST (update / event / claim)
OK = "ok"
CONFLICT = "conflict"  # 409 : tâche déjà prise / tentative périmée / plus in_progress
RETRY = "retry"  # réseau, timeout, 5xx, 408/425/429 : réessayable
REJECTED = "rejected"  # autre 4xx (400, 404…) : inutile de réessayer tel quel
AUTH = "auth"  # 401/403 : clé agent révoquée ou invalide (T41)
GONE = "gone"  # 410 : tâche supprimée côté serveur (contrat §3)

# Valeurs renvoyées par get_control en plus de none | pause | stop
CONTROL_GONE = "gone"
CONTROL_ERROR = "error"
_CONTROLS = frozenset({"none", "pause", "stop"})

AUTH_HINT = ("clé agent révoquée ou invalide — vérifiez SOULBAH_AGENT_KEY "
             "(page Sécurité de l'app : « Clés de l'agent local »)")


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
    if status_code == 410:
        return GONE
    if status_code in (401, 403):
        return AUTH
    if status_code >= 500 or status_code in (408, 425, 429):
        return RETRY
    return REJECTED


class TaskClient:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        # Backend Node (fonctionnalité migrée depuis l'edge function agent-tasks)
        self.base = f"{cfg.api_url}/api/agent-tasks"
        # LOT 6 : approbations distantes HMAC (routes V2 ; 404 sur un serveur V1).
        self.approvals_base = f"{cfg.api_url}/api/v2/approvals"
        # Diagnostic du dernier échec de poll : None | AUTH | RETRY ("backend injoignable") | REJECTED
        self.last_error: str | None = None
        self.last_status: int | None = None
        # Description lisible du dernier échec d'update (utilisée dans le final minimal)
        self.last_detail: str | None = None

    def _headers(self) -> dict[str, str]:
        return {
            "Content-Type": "application/json",
            "x-agent-key": self.cfg.agent_key,
        }

    def _request(self, method: str, url: str, body: dict[str, Any] | None, timeout: float
                 ) -> tuple[str, str, Any, int | None]:
        """Requête JSON. Retourne (issue, description lisible, json de réponse ou None,
        code HTTP ou None si le backend est injoignable)."""
        try:
            if method == "GET":
                resp = requests.get(url, headers=self._headers(), timeout=timeout)
            else:
                resp = requests.post(url, headers=self._headers(), json=body, timeout=timeout)
        except requests.RequestException as e:
            return RETRY, f"backend injoignable ({e.__class__.__name__})", None, None
        outcome = _classify(resp.status_code)
        try:
            payload = resp.json()
        except ValueError:
            payload = None
        if outcome == OK:
            return OK, "ok", payload, resp.status_code
        if outcome == AUTH:
            return AUTH, f"HTTP {resp.status_code} — {AUTH_HINT}", payload, resp.status_code
        msg = payload.get("error") if isinstance(payload, dict) else None
        return outcome, f"HTTP {resp.status_code}" + (f" — {msg}" if msg else ""), payload, resp.status_code

    def _post(self, path: str, body: dict[str, Any], timeout: float) -> tuple[str, str, Any]:
        """POST JSON sur /api/agent-tasks/<path>. Retourne (issue, description, json ou None)."""
        outcome, detail, payload, _ = self._request("POST", f"{self.base}/{path}", body, timeout)
        return outcome, detail, payload

    # --- Approbations distantes (LOT 6) ---------------------------------------------------
    # Mêmes conventions que _post, délais courts ; le code HTTP est renvoyé pour que
    # l'approbateur distingue « route absente » (404, serveur V1) d'un refus.
    def request_approval(self, body: dict[str, Any]) -> tuple[str, str, Any, int | None]:
        """POST /api/v2/approvals/request → 201 {id, status, payload_sha256, expires_at}."""
        return self._request("POST", f"{self.approvals_base}/request", body, timeout=10)

    def get_approval(self, approval_id: str) -> tuple[str, str, Any, int | None]:
        """GET /api/v2/approvals/<id> → {id, status, token?, expires_at, decided_at, reason}."""
        return self._request("GET", f"{self.approvals_base}/{approval_id}", None, timeout=10)

    def verify_approval(self, token: str, payload: dict[str, Any]) -> tuple[str, str, Any, int | None]:
        """POST /api/v2/approvals/verify → {ok: true, approval_id, level} | {ok: false, reason}."""
        return self._request("POST", f"{self.approvals_base}/verify", {"token": token, "payload": payload},
                             timeout=10)

    def announce(self, allowed_dirs: list[str]) -> bool:
        """Déclare la whitelist de dossiers au backend (au démarrage).

        Le planificateur l'injecte dans le contexte pour ne générer que des
        chemins autorisés (sinon le gate refuse et la tâche échoue)."""
        outcome, detail, _ = self._post("announce", {"allowed_dirs": allowed_dirs}, timeout=15)
        if outcome != OK:
            self.last_error = outcome
            if outcome == AUTH:
                log.error("Annonce de la whitelist refusée : %s", detail)
            else:
                log.warning("Annonce de la whitelist échouée : %s", detail)
            return False
        return True

    def poll(self) -> list[dict[str, Any]] | None:
        """Récupère jusqu'à 5 tâches en attente (user_id déduit de la clé côté backend).

        Retourne None en cas d'échec ; `last_error` distingue une clé refusée (AUTH,
        401/403) d'un backend injoignable ou en erreur (RETRY/REJECTED)."""
        self.last_error = None
        self.last_status = None
        try:
            resp = requests.get(f"{self.base}/poll", headers=self._headers(), timeout=15)
        except requests.RequestException as e:
            self.last_error = RETRY
            log.warning("Poll échoué : backend injoignable (%s)", e.__class__.__name__)
            return None
        self.last_status = resp.status_code
        outcome = _classify(resp.status_code)
        if outcome != OK:
            self.last_error = outcome
            if outcome == AUTH:
                log.error("Poll refusé (HTTP %d) : %s", resp.status_code, AUTH_HINT)
            else:
                log.warning("Poll échoué : HTTP %d", resp.status_code)
            return None
        try:
            tasks = resp.json().get("tasks", [])
        except (ValueError, AttributeError) as e:
            self.last_error = REJECTED
            log.warning("Poll : réponse illisible (%s)", e)
            return None
        return [t for t in tasks if isinstance(t, dict)] if isinstance(tasks, list) else []

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

        Best-effort : seules les issues CONFLICT (409) et GONE (410) doivent être
        traitées par l'appelant.

        LOT 6 : `message` et `data` sont RÉDIGÉS avant l'envoi (redaction.redact_obj :
        textes libres masqués, motifs de secrets et valeurs connues remplacés) — le
        serveur ne reçoit jamais un secret, même glissé dans un détail d'étape."""
        outcome, detail, _ = self._post(
            "event",
            {"task_id": task_id, "type": type, "message": redact_text(message) if message else message,
             "data": redact_obj(data or {}), "attempt": attempt},
            timeout=10,
        )
        if outcome not in (OK, CONFLICT, GONE):
            log.debug("Évènement %s non transmis : %s", type, detail)
        return outcome

    def get_control(self, task_id: str) -> str:
        """Ordre de contrôle courant : none | pause | stop, ou "gone" (410 : tâche
        supprimée) ou "error" (lecture impossible — l'appelant ne doit PAS en
        déduire une reprise, cf. T39)."""
        try:
            resp = requests.get(
                f"{self.base}/{task_id}/control",
                headers=self._headers(),
                timeout=10,
            )
        except requests.RequestException:
            return CONTROL_ERROR
        if resp.status_code == 410:
            return CONTROL_GONE
        if not 200 <= resp.status_code < 300:
            return CONTROL_ERROR
        try:
            value = resp.json().get("control", "none")
        except (ValueError, AttributeError):
            return CONTROL_ERROR
        return value if value in _CONTROLS else "none"

    def update(
        self,
        task_id: str,
        status: str,
        result: dict | None = None,
        error_message: str | None = None,
        attempt: int = 0,
    ) -> str:
        """Met à jour le statut final d'une tâche (completed / failed / cancelled).
        Retourne l'issue ; `last_detail` décrit l'échec éventuel.

        LOT 6 : `result` et `error_message` sont rédigés avant l'envoi (comme event)."""
        body: dict[str, Any] = {"task_id": task_id, "status": status, "attempt": attempt}
        if result is not None:
            body["result"] = redact_obj(result)
        if error_message is not None:
            body["error_message"] = redact_text(error_message)
        outcome, detail, _ = self._post("update", body, timeout=15)
        self.last_detail = None if outcome == OK else detail
        if outcome != OK:
            log.error("Update %s échoué pour %s : %s", status, str(task_id)[:8], detail)
        return outcome
