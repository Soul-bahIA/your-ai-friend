"""Approbations distantes HMAC (LOT 6 — audit §9.1 : toute action L2/L3 peut exiger une
approbation émise par P1, liée au `payload_sha256` de l'étape et vérifiée par jeton).

Côté agent :
  1. POST /api/v2/approvals/request  (payload = l'étape COMPLÈTE, voir ci-dessous) ;
  2. GET  /api/v2/approvals/<id>     toutes les `poll_s` secondes jusqu'à décision,
     expiration, arrêt demandé (`stop_check`) ou délai local (`confirm_timeout`) ;
  3. si approuvée : POST /api/v2/approvals/verify avec le jeton ET le payload réellement
     exécuté — `ok: false` (signature, expiration, payload_mismatch, denied, revoked,
     unknown) ⇒ refus.
Toute erreur réseau, réponse illisible ou statut inattendu ⇒ REFUS. Il n'existe aucune
approbation par défaut.

Pourquoi `payload` part NON rédigé : le serveur doit afficher à l'utilisateur ce qui va
réellement être exécuté (contenu complet, S7) et le hacher pour lier l'approbation à ce
contenu exact (payload_sha256 recalculé à la vérification : un contenu modifié entre la
demande et l'exécution est rejeté). Il le rédige lui-même pour l'affichage
(payload_presented) et ne le journalise jamais en clair. Tous les AUTRES champs de la
demande (summary, tool, identifiants) passent par redaction.redact_obj.

`canonical_sha256(step)` reproduit exactement l'empreinte de node
(backend/node-api/src/v2/security/approvals.ts : canonicalJson) : clés triées, séparateurs
`,` et `:`, non-ASCII conservé, UTF-8. Exemple : {"b": 1, "a": "é"} → sha256('{"a":"é","b":1}').
"""
from __future__ import annotations

import hashlib
import json
import logging
import math
import time
from dataclasses import dataclass
from typing import Any, Callable

from redaction import redact_obj, redact_text

log = logging.getLogger("soulbah.approvals")

TOKEN_PREFIX = "sbap_"
DEFAULT_POLL_SECONDS = 2.0
# Erreurs réseau consécutives tolérées pendant l'ATTENTE (GET) avant de refuser :
# une micro-coupure ne doit pas annuler une approbation en cours, une panne si.
MAX_POLL_ERRORS = 3
_WAIT_SLICE = 0.25

# Issues normalisées du client (dupliquées de client.py pour rester importable sans requests)
_OK = "ok"
_REJECTED = "rejected"


# --- Empreinte canonique -------------------------------------------------------------------
def _canonical(value: Any) -> str:
    if value is None or value is True or value is False:
        return json.dumps(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if math.isnan(value) or math.isinf(value):
            return "null"  # JSON.stringify(NaN) === "null"
        return str(int(value)) if value.is_integer() else json.dumps(value)  # JS : 3.0 → "3"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(_canonical(v) for v in value) + "]"
    if isinstance(value, dict):
        items = sorted((str(k), v) for k, v in value.items())
        return "{" + ",".join(f"{json.dumps(k, ensure_ascii=False)}:{_canonical(v)}" for k, v in items) + "}"
    return json.dumps(str(value), ensure_ascii=False)


def canonical_json(step: Any) -> str:
    """JSON canonique (clés triées, compact, non-ASCII conservé) — identique à node."""
    return _canonical(step)


def canonical_sha256(step: Any) -> str:
    """SHA-256 hex du JSON canonique encodé en UTF-8 (= payload_sha256 côté serveur)."""
    return hashlib.sha256(canonical_json(step).encode("utf-8")).hexdigest()


# --- Décision ---------------------------------------------------------------------------------
@dataclass
class Decision:
    """Résultat d'une approbation distante. Itérable en (approved, reason, token) pour le
    contrat `request(...) -> (approved, reason, token)` ; `unavailable` = l'API
    d'approbation n'existe pas sur ce serveur (404 : serveur V1) — le gate en mode `both`
    se replie alors sur la console."""

    approved: bool
    reason: str
    token: str | None = None
    approval_id: str | None = None
    unavailable: bool = False

    def __iter__(self):
        yield self.approved
        yield self.reason
        yield self.token


def _deny(reason: str, approval_id: str | None = None, unavailable: bool = False) -> Decision:
    return Decision(False, reason, None, approval_id, unavailable)


class RemoteApprover:
    """Demande, attend et vérifie une approbation auprès du serveur.

    `client` expose request_approval(body), get_approval(id), verify_approval(token,
    payload) → (issue, détail, json, code HTTP) — voir client.TaskClient."""

    def __init__(self, client: Any, timeout_s: float, poll_s: float = DEFAULT_POLL_SECONDS):
        self.client = client
        self.timeout_s = max(1.0, float(timeout_s))
        self.poll_s = max(0.01, float(poll_s))

    def request(
        self,
        step: dict,
        skill: Any,
        level: int | str,
        summary: str,
        ctx: dict[str, Any],
        on_requested: Callable[[str], None] | None = None,
    ) -> Decision:
        """Approbation d'une étape. `level` : 2/3 ou "L2"/"L3". `on_requested(id)` est
        appelé dès que le serveur a enregistré la demande (évènement approval_required)."""
        stop_check: Callable[[], bool] = ctx.get("stop_check") or (lambda: False)
        lvl = level if isinstance(level, str) else f"L{3 if int(level) >= 3 else 2}"
        tool = str(step.get("type", getattr(skill, "name", "?")))
        body = redact_obj({
            "task_id": ctx.get("task_id"),
            "attempt": int(ctx.get("attempt") or 0),
            "step_index": int(ctx.get("step_index") or 0),
            "tool": tool,
            "level": lvl,
            "summary": redact_text(str(summary))[:500],
            "ttl_s": int(self.timeout_s),
        })
        body["payload"] = step  # complet et non rédigé : affiché et haché par le serveur (voir docstring)

        # 1. Demande
        outcome, detail, data, status = self.client.request_approval(body)
        if outcome != _OK:
            if status == 404:
                return _deny("approbations distantes indisponibles sur ce serveur (404)", unavailable=True)
            return _deny(f"demande d'approbation refusée : {detail}")
        approval_id = data.get("id") if isinstance(data, dict) else None
        if not isinstance(approval_id, str) or not approval_id:
            return _deny("demande d'approbation : réponse du serveur illisible (id manquant)")
        if on_requested is not None:
            try:
                on_requested(approval_id)
            except Exception:  # noqa: BLE001 - un évènement ne doit pas bloquer l'approbation
                log.debug("Rappel on_requested en erreur", exc_info=True)
        log.info("Approbation %s demandée (%s, %s) — en attente de la décision dans l'app…",
                 approval_id[:8], tool, lvl)

        # 2. Attente de la décision
        deadline = time.monotonic() + self.timeout_s
        errors = 0
        token: str | None = None
        while True:
            if stop_check():
                return _deny("approbation interrompue (arrêt demandé)", approval_id)
            outcome, detail, data, status = self.client.get_approval(approval_id)
            if outcome != _OK:
                if status == 404:
                    return _deny("approbation introuvable côté serveur (404)", approval_id)
                errors += 1
                # 4xx (hors 408/425/429) : erreur définitive ; réseau/5xx : quelques essais.
                definitive = status is not None and status < 500 and status not in (408, 425, 429)
                if definitive or errors >= MAX_POLL_ERRORS:
                    return _deny(f"approbation : lecture impossible ({detail})", approval_id)
            else:
                errors = 0
                state = str(data.get("status", "")) if isinstance(data, dict) else ""
                if state == "approved":
                    token = data.get("token") if isinstance(data, dict) else None
                    break
                if state in ("denied", "expired", "revoked"):
                    why = data.get("reason") if isinstance(data, dict) else None
                    label = {"denied": "refusée dans l'app", "expired": "expirée", "revoked": "révoquée"}[state]
                    return _deny(f"approbation {label}" + (f" ({redact_text(str(why))})" if why else ""), approval_id)
                if state != "pending":
                    return _deny(f"approbation : statut inattendu « {state} »", approval_id)
            if time.monotonic() >= deadline:
                return _deny(f"approbation sans décision en {int(self.timeout_s)} s — refusée par défaut", approval_id)
            self._wait(min(self.poll_s, max(0.0, deadline - time.monotonic())), stop_check)

        if not isinstance(token, str) or not token.startswith(TOKEN_PREFIX):
            return _deny("approbation approuvée mais jeton absent ou invalide", approval_id)

        # 3. Vérification du jeton pour le payload réellement exécuté
        outcome, detail, data, status = self.client.verify_approval(token, step)
        if outcome != _OK or not isinstance(data, dict):
            return _deny(f"vérification du jeton impossible ({detail})", approval_id)
        if data.get("ok") is not True:
            reason = str(data.get("reason") or "inconnue")
            return _deny(f"jeton d'approbation rejeté ({reason})", approval_id)
        return Decision(True, f"approuvée dans l'app ({lvl})", token, approval_id)

    @staticmethod
    def _wait(seconds: float, stop_check: Callable[[], bool]) -> None:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if stop_check():
                return
            time.sleep(min(_WAIT_SLICE, max(0.0, deadline - time.monotonic())))
