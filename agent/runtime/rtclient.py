"""Client HTTP des routes runtime V2 (`/api/v2/runtime/*`, en-tête `x-agent-key`).

Mêmes conventions que `client.TaskClient` (dont il hérite : en-têtes, délais courts,
classification des codes HTTP, approbations LOT 6) :

  - lectures et commandes (register, lease, keepalive, reconcile, GET …) : réponse
    immédiate `(issue, détail, json, code HTTP)` ; jamais mises en attente ;
  - écritures durables (result, message, checkpoint, actions, ack) : une issue réseau /
    5xx / 401 les place dans l'**outbox** du journal (`QUEUED`) ; elles sont rejouées en
    ordre avec backoff par `flush_outbox`. 409 (bail non détenu / régression d'état),
    410 (tâche disparue) et 400 (rejet) sont **définitifs** : journalisés, jamais rejoués.
    Tant qu'une écriture d'une tâche attend, les suivantes de la même tâche vont
    directement en outbox (l'ordre planned → attempted → executed est préservé).

Tout ce qui part vers le serveur passe par `redaction` (LOT 6) : résultats, paramètres,
preuves et messages ne contiennent jamais un secret. Les preuves brutes sont compactées
(pas de base64 d'image dans le journal ni dans la base : LOT 9).
"""
from __future__ import annotations

import hashlib
import re
import logging
import socket
from typing import Any

from client import AUTH, CONFLICT, GONE, OK, REJECTED, RETRY, TaskClient
from config import Config
from redaction import _env_values, redact_obj, redact_text
from runtime.journal import Journal
from runtime.version import PROTOCOL, RUNTIME_VERSION

log = logging.getLogger("soulbah.runtime.client")

# Issues propres au runtime (en plus de celles de client.py)
QUEUED = "queued"  # écriture mise en outbox, sera rejouée
UPGRADE_REQUIRED = "upgrade_required"  # 426 : version / protocole refusés
NOT_FOUND = "not_found"  # 404 : serveur sans routes V2 (→ legacy_adapter)

DEFINITIVE = frozenset({CONFLICT, GONE, REJECTED})
_TIMEOUT_SHORT = 10
_TIMEOUT_LONG = 20
_MAX_STRING = 4000
_MAX_ITEMS = 50

# Types acceptés en téléversement par node-api (v2/routes/artifacts.ts : ARTIFACT_CONTENT_TYPES).
_ARTIFACT_MIMES = frozenset({"application/octet-stream", "image/png", "image/jpeg", "image/webp", "video/mp4",
                             "application/pdf"})

KIND_RESULT = "result"
KIND_MESSAGE = "message"
KIND_CHECKPOINT = "checkpoint"
KIND_ACTION = "action"
KIND_ACK = "ack"
KIND_FINAL_MESSAGE = "final_message"  # ERROR qui clôt la tentative
# Écritures qui closent une tentative : tant qu'une d'elles attend, la tâche est
# « en finalisation » (bail maintenu, aucun nouveau bail — §9.9).
FINAL_KINDS = frozenset({KIND_RESULT, KIND_FINAL_MESSAGE})


def compact_evidence(data: Any, depth: int = 0) -> Any:
    """Preuve brute compactée : images base64 remplacées par leur taille, chaînes et listes
    bornées, profondeur limitée."""
    if depth > 6:
        return "[trop profond]"
    if isinstance(data, dict):
        out: dict[str, Any] = {}
        for k, v in list(data.items())[:_MAX_ITEMS]:
            if k in ("image_b64", "b64", "base64") and isinstance(v, str):
                out[f"{k}_bytes"] = len(v)
            else:
                out[k] = compact_evidence(v, depth + 1)
        return out
    if isinstance(data, (list, tuple)):
        return [compact_evidence(v, depth + 1) for v in list(data)[:_MAX_ITEMS]]
    if isinstance(data, str) and len(data) > _MAX_STRING:
        return data[:_MAX_STRING] + f"… [{len(data) - _MAX_STRING} car. tronqués]"
    return data


_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def redact_evidence(evidence: list[Any]) -> list[Any]:
    """Preuves rédigées SANS masquer leurs références d'intégrité : la rédaction masque toute
    chaîne hexadécimale de 40 caractères ou plus (clés brutes), ce qui effaçait aussi l'empreinte
    `sha256` d'un fichier produit — le serveur rejetait alors l'action entière (preuve perdue,
    tâche évaluée en échec alors que le fichier existait). Seuls les champs `sha256` (64 hex) et
    `artifact_id` (uuid) sont conservés tels quels ; description et valeur restent rédigées."""
    out: list[Any] = []
    for e in compact_evidence(list(evidence)):
        if not isinstance(e, dict):
            out.append(redact_obj(e))
            continue
        known = _env_values()  # clé agent, SOULBAH_REDACT_VALUES : jamais transmis, même déguisés en empreinte
        keep = {k: e[k] for k in ("sha256", "artifact_id")
                if isinstance(e.get(k), str) and (_SHA256_RE.match(e[k]) if k == "sha256" else _UUID_RE.match(e[k]))
                and not any(v and v.lower() in e[k].lower() for v in known)}
        red = redact_obj({k: v for k, v in e.items() if k not in keep})
        out.append({**red, **keep})
    return out


class RuntimeClient(TaskClient):
    def __init__(self, cfg: Config, journal: Journal | None = None, runtime_id: str | None = None):
        super().__init__(cfg)
        self.v2 = f"{cfg.api_url}/api/v2/runtime"
        self.journal = journal
        self.runtime_id = runtime_id

    # --- helpers -----------------------------------------------------------------------------
    def _url(self, path: str) -> str:
        return f"{self.v2}/{path.lstrip('/')}"

    def _call(self, method: str, path: str, body: dict[str, Any] | None, timeout: float = _TIMEOUT_SHORT
              ) -> tuple[str, str, Any, int | None]:
        return self._request(method, self._url(path), body, timeout)

    def _ident(self, attempt: int) -> dict[str, Any]:
        return {"runtime_id": self.runtime_id, "attempt": int(attempt)}

    # --- poignée de main et commandes ----------------------------------------------------------
    def register(self, max_slots: int, capabilities: dict[str, Any], hostname: str | None = None
                 ) -> tuple[str, str, Any, int | None]:
        """POST register → (OK, …, {runtime_id, max_slots, lease_seconds, max_parallel}) ;
        UPGRADE_REQUIRED (426 : {error, min_version, protocol}) ; NOT_FOUND (404 : serveur V1)."""
        body = {
            "hostname": (hostname or socket.gethostname())[:200],
            "version": RUNTIME_VERSION,
            "protocol": PROTOCOL,
            "max_slots": int(max_slots),
            "capabilities": capabilities,
        }
        outcome, detail, data, status = self._call("POST", "register", body, _TIMEOUT_LONG)
        if status == 426:
            return UPGRADE_REQUIRED, detail, data, status
        if status == 404:
            return NOT_FOUND, detail, data, status
        if outcome == OK and isinstance(data, dict) and data.get("runtime_id"):
            self.runtime_id = str(data["runtime_id"])
        return outcome, detail, data, status

    def lease(self, slots: int) -> tuple[str, str, Any, int | None]:
        return self._call("POST", "lease", {"runtime_id": self.runtime_id, "slots": int(slots)}, _TIMEOUT_LONG)

    def keepalive(self, tasks: list[dict[str, Any]]) -> tuple[str, str, Any, int | None]:
        body = {"runtime_id": self.runtime_id,
                "tasks": [{"task_id": t["task_id"], "attempt": int(t["attempt"])} for t in tasks]}
        return self._call("POST", "keepalive", body, _TIMEOUT_LONG)

    def reconcile(self, tasks: list[dict[str, Any]]) -> tuple[str, str, Any, int | None]:
        body = {"runtime_id": self.runtime_id,
                "tasks": [{"task_id": t["task_id"], "attempt": int(t["attempt"])} for t in tasks]}
        return self._call("POST", "reconcile", body, _TIMEOUT_LONG)

    def get_task(self, task_id: str) -> tuple[str, str, Any, int | None]:
        return self._call("GET", f"tasks/{task_id}", None)

    def get_actions(self, task_id: str, attempt: int) -> tuple[str, str, Any, int | None]:
        return self._call("GET", f"tasks/{task_id}/actions?runtime_id={self.runtime_id}&attempt={int(attempt)}", None)

    # --- écritures durables (outbox) ----------------------------------------------------------
    def _durable(self, kind: str, path: str, body: dict[str, Any], task_id: str | None, attempt: int | None
                 ) -> tuple[str, Any]:
        """Envoie une écriture ; la met en outbox si elle n'est pas acceptée pour une raison
        transitoire. Retourne (issue, json de réponse ou None)."""
        short = str(task_id)[:8] if task_id else "-"
        if self.journal is not None and task_id and self.journal.outbox_has(task_id):
            self.journal.enqueue("POST", path, body, kind=kind, task_id=task_id, attempt=attempt)
            log.info("%s de %s mis en outbox (écritures précédentes en attente)", kind, short)
            return QUEUED, None
        outcome, detail, data, _status = self._call("POST", path, body)
        if outcome == OK:
            return OK, data
        if outcome in DEFINITIVE:
            log.warning("%s de %s refusé définitivement : %s", kind, short, detail)
            return outcome, data
        # RETRY (réseau, 5xx) ou AUTH (clé en cours de rotation ?) : rejoué plus tard.
        if self.journal is None:
            log.warning("%s de %s non transmis (%s) et aucun journal : perdu", kind, short, detail)
            return outcome, data
        self.journal.enqueue("POST", path, body, kind=kind, task_id=task_id, attempt=attempt, attempts=1)
        log.warning("%s de %s mis en outbox (%s) — renvoi automatique avec backoff", kind, short, detail)
        return QUEUED, None

    def post_result(self, task_id: str, attempt: int, result: dict[str, Any], simulated: bool = False) -> str:
        body = {**self._ident(attempt), "result": redact_obj(result), "simulated": bool(simulated)}
        outcome, _ = self._durable(KIND_RESULT, f"tasks/{task_id}/result", body, task_id, attempt)
        return outcome

    def post_message(self, task_id: str, attempt: int, type_: str, payload: dict[str, Any],
                     final: bool = False) -> str:
        """`final=True` : le message clôt la tentative (ERROR) — même traitement qu'un résultat
        dans l'outbox (bail maintenu tant qu'il attend)."""
        body = {**self._ident(attempt), "type": type_, "payload": redact_obj(payload)}
        kind = KIND_FINAL_MESSAGE if final else KIND_MESSAGE
        outcome, _ = self._durable(kind, f"tasks/{task_id}/message", body, task_id, attempt)
        return outcome

    def post_checkpoint(self, task_id: str, attempt: int, seq: int, step_cursor: int,
                        variables: dict[str, Any]) -> str:
        body = {**self._ident(attempt), "seq": int(seq), "step_cursor": int(step_cursor),
                "variables": redact_obj(variables or {})}
        outcome, _ = self._durable(KIND_CHECKPOINT, f"tasks/{task_id}/checkpoint", body, task_id, attempt)
        return outcome

    def post_action(self, task_id: str, attempt: int, step_index: int, tool: str, params: dict[str, Any],
                    status: str, evidence: list[Any] | None = None, error: str | None = None,
                    simulated: bool = False) -> tuple[str, Any]:
        body: dict[str, Any] = {**self._ident(attempt), "step_index": int(step_index), "tool": tool,
                                "params": redact_obj(params or {}), "status": status}
        if evidence is not None:
            body["evidence"] = redact_evidence(list(evidence))
        if error:
            body["error"] = redact_text(str(error))[:2000]
        if simulated:
            body["simulated"] = True
        return self._durable(KIND_ACTION, f"tasks/{task_id}/actions", body, task_id, attempt)

    # --- approbations (LOT 6) pour une tâche V2 (LOT 9) -----------------------------------------
    def request_approval(self, body: dict[str, Any]) -> tuple[str, str, Any, int | None]:
        """Une tâche du runtime est une tâche V2 : son id part dans `v2_task_id` (le serveur
        passe alors la tâche en WAITING pendant l'attente, puis la reprend une seule fois)."""
        body = dict(body)
        task_id = body.pop("task_id", None)
        if task_id:
            body["v2_task_id"] = task_id
        return super().request_approval(body)

    # --- artefacts (LOT 9) ----------------------------------------------------------------------
    def put_artifact(self, content: bytes, mime: str, kind: str, task_id: str | None = None
                     ) -> tuple[str | None, str] | None:
        """PUT /api/v2/artifacts/<sha256> (idempotent). Retourne (artifact_id, sha256) ou None.
        Jamais en outbox : une preuve sans artefact garde son empreinte."""
        import requests  # import local : le module reste importable sans requests (tests purs)

        digest = hashlib.sha256(content).hexdigest()
        params: dict[str, str] = {"kind": kind}
        if task_id:
            params["task_id"] = task_id
        headers = {k: v for k, v in self._headers().items() if k.lower() != "content-type"}
        headers["Content-Type"] = mime if mime in _ARTIFACT_MIMES else "application/octet-stream"
        try:
            resp = requests.put(f"{self.cfg.api_url}/api/v2/artifacts/{digest}", params=params, data=content,
                                headers=headers, timeout=_TIMEOUT_LONG)
        except requests.RequestException as e:
            log.warning("Artefact %s… non téléversé (%s)", digest[:12], e.__class__.__name__)
            return None
        if resp.status_code not in (200, 201):
            log.warning("Artefact %s… refusé (HTTP %s)", digest[:12], resp.status_code)
            return None
        try:
            art = resp.json().get("artifact") or {}
        except ValueError:
            art = {}
        return (str(art["id"]) if art.get("id") else None), digest

    def ack_message(self, message_id: str, task_id: str | None = None) -> str:
        outcome, _ = self._durable(KIND_ACK, f"messages/{message_id}/ack", {"runtime_id": self.runtime_id},
                                   task_id, None)
        return outcome

    # --- rejeu de l'outbox ----------------------------------------------------------------------
    def flush_outbox(self, now: float | None = None) -> dict[str, int]:
        """Rejoue les écritures dues, dans l'ordre. Une écriture qui échoue de façon
        transitoire bloque les suivantes de la même tâche (ordre préservé) ; une écriture
        refusée définitivement est abandonnée et journalisée. Retourne des compteurs."""
        stats = {"sent": 0, "dropped": 0, "kept": 0}
        if self.journal is None:
            return stats
        stalled: set[str] = set()
        for entry in self.journal.outbox_claim_due(now):
            task_id = entry.get("task_id") or ""
            if task_id in stalled:
                self.journal.outbox_release(entry["id"])
                stats["kept"] += 1
                continue
            body = entry["body"]
            if isinstance(body, dict) and "runtime_id" in body and self.runtime_id:
                body["runtime_id"] = self.runtime_id  # le runtime_id est stable (1 par clé) ; au cas où
            outcome, detail, _data, _status = self._call(entry["method"], entry["path"], body)
            short = str(task_id)[:8] or "-"
            if outcome == OK:
                self.journal.outbox_done(entry["id"])
                stats["sent"] += 1
                log.info("✔ Outbox : %s de %s enfin accepté", entry["kind"], short)
            elif outcome in DEFINITIVE:
                self.journal.outbox_done(entry["id"])
                stats["dropped"] += 1
                log.error("✖ Outbox : %s de %s refusé définitivement (%s) — abandonné", entry["kind"], short, detail)
            else:
                self.journal.outbox_retry(entry["id"], now)
                stats["kept"] += 1
                if task_id:
                    stalled.add(task_id)
                log.warning("Outbox : %s de %s toujours impossible (%s)", entry["kind"], short, detail)
        return stats

    def finalizing_task_ids(self) -> set[str]:
        """Tâches dont un final attend dans l'outbox (bail à maintenir, aucun nouveau bail)."""
        if self.journal is None:
            return set()
        return {e["task_id"] for e in self.journal.outbox_all() if e["kind"] in FINAL_KINDS and e["task_id"]}
