"""Executor : exécute la suite d'étapes (`steps`) du payload d'une tâche."""
from __future__ import annotations

import logging
import threading
import time
from typing import Any, Callable

from permissions import PermissionGate
from skills import REGISTRY, get_skill
from skills import record_bg
from skills.base import CancelToken, Skill, SkillResult, bind_path_refusal, bind_token

log = logging.getLogger("soulbah.executor")

# Callbacks optionnels branchés par l'agent pour le poste de pilotage temps réel.
EventFn = Callable[[str, str, dict], None]  # (type, message, data)
# -> "none" | "pause" | "stop" | "gone" (410 : tâche supprimée) | "error" (lecture impossible)
ControlFn = Callable[[], str]
# LOT 8 : observateur du cycle d'une étape pour le journal d'actions du runtime.
# (phase, index, step, result) avec phase ∈ {"planned", "attempted", "done"} ;
# `result` n'est fourni (SkillResult) que pour "done".
StepFn = Callable[[str, int, dict, "SkillResult | None"], None]

DEFAULT_STEP_TIMEOUT = 900.0
_CONTROL_POLL_SECONDS = 3.0  # lecture de l'ordre stop pendant une étape longue
_CONFIRM_CONTROL_POLL_SECONDS = 2.0  # lecture de l'ordre stop pendant une confirmation console
_CANCEL_GRACE_SECONDS = 10.0  # délai laissé au skill pour s'arrêter proprement
_PAUSE_POLL_SECONDS = 2.0  # lecture du contrôle pendant une pause (T39 : plus 1 GET/s)
_PAUSE_NOTICE_SECONDS = 60.0  # rappel « toujours en pause » (garde aussi le heartbeat vivant)

# Interruptions d'une étape
_STOP = "stop"  # arrêt demandé depuis l'app (control='stop')
_INTERRUPT = "interrupt"  # interruption locale (Ctrl+C) : jeton de la tâche annulé
_ABORT = "abort"  # 409/410 : la tâche n'est plus à nous
_TIMEOUT = "timeout"


class Executor:
    def __init__(self, gate: PermissionGate, step_timeout: float = DEFAULT_STEP_TIMEOUT):
        self.gate = gate
        self.step_timeout = float(step_timeout)

    def timeout_for(self, skill: Skill) -> float:
        """Délai d'une étape : SOULBAH_STEP_TIMEOUT, étendu pour les skills longs
        par nature (montage, commandes) qui déclarent leur propre borne."""
        return max(self.step_timeout, float(skill.timeout_s or 0))

    def max_step_timeout(self) -> float:
        return max([self.step_timeout] + [float(s.timeout_s or 0) for s in REGISTRY.values()])

    def _run_step(
        self,
        skill: Skill,
        step: dict,
        timeout: float,
        control: ControlFn,
        abort: threading.Event,
        task_token: CancelToken,
    ) -> tuple[SkillResult, str | None]:
        """Exécute le skill dans un thread de travail avec délai.

        Retourne (résultat, interruption) où interruption ∈ {None, "timeout", "stop",
        "interrupt", "abort"}. Chaque étape a SON jeton d'annulation (enfant de celui
        de la tâche) : un skill bloqué qu'on abandonne (thread démon) garde un jeton
        annulé et ne peut ni être relancé ni perturber l'étape ou la tâche suivante.

        Un ordre « stop » lu pendant l'étape l'INTERROMPT (jeton annulé, délai de
        grâce, enregistrements finalisés) au lieu d'attendre sa fin : plus sûr pour
        une commande ou un rendu de plusieurs minutes. L'étape est rapportée
        « interrompue (arrêt demandé) » et la tâche finit en `cancelled`.

        Le contrôle de chemins du gate (whitelist + deny-list) est lié au thread de
        l'étape : les skills de fichiers le revérifient juste avant d'agir."""
        box: dict[str, SkillResult] = {}
        step_token = task_token.child()
        path_refusal = getattr(self.gate, "path_refusal", None)

        def target() -> None:
            bind_token(step_token)
            bind_path_refusal(path_refusal)
            try:
                box["result"] = skill.run(step)
            except Exception as e:  # noqa: BLE001 - un skill ne doit jamais tuer l'agent
                log.exception("Exception dans le skill %s", skill.name)
                box["result"] = SkillResult(ok=False, detail=f"erreur interne du skill : {e}")
            finally:
                bind_token(None)
                bind_path_refusal(None)

        worker = threading.Thread(target=target, daemon=True, name=f"skill-{skill.name}")
        start = time.monotonic()
        worker.start()

        deadline = start + timeout
        next_control = start + _CONTROL_POLL_SECONDS
        interrupt: str | None = None
        grace_deadline = 0.0
        while True:
            worker.join(0.25)
            if not worker.is_alive():
                break
            now = time.monotonic()
            if interrupt is None:
                if abort.is_set():
                    interrupt = _ABORT
                elif task_token.is_cancelled():
                    interrupt = _INTERRUPT
                elif now >= deadline:
                    interrupt = _TIMEOUT
                elif now >= next_control:
                    ctrl = control()
                    if ctrl == "stop":
                        interrupt = _STOP
                    elif ctrl == "gone":
                        interrupt = _ABORT
                    next_control = time.monotonic() + _CONTROL_POLL_SECONDS
                if interrupt:
                    step_token.cancel(interrupt)
                    grace_deadline = time.monotonic() + _CANCEL_GRACE_SECONDS
            elif now >= grace_deadline:
                log.error("Le skill %s ne répond pas à l'annulation — abandonné en arrière-plan", skill.name)
                break

        # Le skill a pu se terminer (en réagissant au jeton) avant que la boucle ne
        # constate l'interruption : on l'attribue quand même à sa vraie cause.
        if interrupt is None:
            if abort.is_set():
                interrupt = _ABORT
            elif task_token.is_cancelled():
                interrupt = _INTERRUPT

        if interrupt == _TIMEOUT:
            return SkillResult(ok=False, detail=f"délai dépassé ({int(timeout)} s) — étape abandonnée"), interrupt
        result = box.get("result")
        if result is None:
            result = SkillResult(ok=False, detail="étape interrompue")
        if interrupt in (_STOP, _INTERRUPT) and result.ok:
            result = SkillResult(ok=False, detail="étape interrompue (arrêt demandé)", data=result.data)
        return result, interrupt

    def _wait_while_paused(
        self,
        control: ControlFn,
        abort: threading.Event,
        token: CancelToken,
        emit: EventFn,
        index: int,
    ) -> str:
        """Lit le contrôle avant une étape et attend tant que la tâche est en pause.

        T39 : un seul évènement à l'entrée en pause (puis un rappel par minute), une
        lecture toutes les 2 s, et une ERREUR de lecture pendant la pause ne relance
        PAS l'exécution (on reste en pause). Retourne "none" | "stop" | "gone"."""
        ctrl = control()
        if ctrl != "pause":
            return ctrl if ctrl in ("stop", "gone") else "none"
        emit("info", "En pause…", {"index": index, "paused": True})
        last_notice = time.monotonic()
        while not abort.is_set() and not token.is_cancelled():
            if token.wait(_PAUSE_POLL_SECONDS):
                break
            if abort.is_set():
                break
            ctrl = control()
            if ctrl in ("pause", "error"):
                if time.monotonic() - last_notice >= _PAUSE_NOTICE_SECONDS:
                    emit("info", "Toujours en pause…", {"index": index, "paused": True})
                    last_notice = time.monotonic()
                continue
            if ctrl == "none":
                emit("info", "Reprise de l'exécution", {"index": index, "paused": False})
            return ctrl if ctrl in ("stop", "gone") else "none"
        return "none"  # l'appelant traite abort / annulation

    def run_task(
        self,
        payload: dict[str, Any],
        on_event: EventFn | None = None,
        check_control: ControlFn | None = None,
        abort: threading.Event | None = None,
        cancel: CancelToken | None = None,
        task_id: str | None = None,
        attempt: int = 0,
        on_step: StepFn | None = None,
    ) -> dict[str, Any]:
        """Exécute chaque étape et retourne un rapport structuré.

        Retour : { ok, steps: [ {index, type, ok, detail, …} ], summary, stopped,
        cancelled, aborted, timed_out } + `empty_plan` (plan vide, T5) et
        `simulated` (dry-run, T10) quand c'est le cas.

        Évènement terminal (cockpit, contrat §13) : `task_completed`,
        `task_cancelled` ou `task_failed` (échec, refus, délai dépassé, plan vide ou
        invalide). Rien sur abort (409/410) : la tâche n'est plus la nôtre.

        - `on_event` : timeline + captures (et évènements d'approbation du gate) ;
        - `check_control` : pause/stop posés depuis l'app, lus entre les étapes,
          pendant les étapes longues et pendant une confirmation console en attente
          (un stop la refuse ; relu après la réponse, avant d'agir) ; "gone" (410)
          = tâche supprimée ;
        - `abort` : posé par l'agent quand le backend indique (409/410) que la tâche
          n'est plus la nôtre — on s'arrête sans rien émettre ;
        - `cancel` : jeton de la tâche (Ctrl+C) — arrêt rapide, statut `cancelled` ;
        - `task_id` / `attempt` : identité de la tâche V1, transmise au gate pour les
          approbations distantes (LOT 6) — None / 0 pour un plan local ;
        - `on_step` (LOT 8) : observateur `(phase, index, step, result)` appelé AVANT
          l'autorisation ("planned"), juste avant l'exécution ("attempted") et après
          ("done", avec le SkillResult) — le worker du runtime en tire l'état des
          actions (planned → attempted → executed/verified/failed). Une exception de
          l'observateur est journalisée et ignorée.
        """
        user_emit = on_event or (lambda *_a, **_k: None)

        def observe(phase: str, index: int, step: dict, result: SkillResult | None = None) -> None:
            if on_step is None:
                return
            try:
                on_step(phase, index, step, result)
            except Exception:  # noqa: BLE001 - l'observateur ne doit pas tuer la tâche
                log.exception("Observateur d'étape en erreur (%s, étape %d)", phase, index)

        def emit(etype: str, message: str, data: dict) -> None:
            try:
                user_emit(etype, message, data)
            except Exception:  # noqa: BLE001 - un évènement ne doit pas tuer la tâche
                log.debug("Évènement %s non émis", etype, exc_info=True)

        control = check_control or (lambda: "none")
        abort = abort or threading.Event()
        token = cancel or CancelToken()
        simulated = bool(self.gate.dry_run)

        def _report(**kw: Any) -> dict[str, Any]:
            base: dict[str, Any] = {"ok": False, "steps": [], "summary": "", "stopped": False,
                                    "cancelled": False, "aborted": False, "timed_out": False}
            base.update(kw)
            if simulated:
                base["simulated"] = True
            return base

        if not isinstance(payload, dict):
            emit("task_failed", "Payload invalide", {"index": 0, "timed_out": False})
            return _report(summary="payload invalide")
        steps = payload.get("steps") or []
        if not isinstance(steps, list):
            emit("task_failed", "payload.steps invalide", {"index": 0, "timed_out": False})
            return _report(summary="payload.steps invalide")
        if not steps:
            # T5 : un plan vide n'est JAMAIS un succès (pas d'évaluation, pas de mémoire).
            emit("task_failed", "Plan vide : aucune étape à exécuter", {"empty_plan": True})
            return _report(summary="plan vide : aucune étape à exécuter", empty_plan=True)

        goal_meta = payload.get("goal_meta")
        planned_by_server = isinstance(goal_meta, dict) and bool(goal_meta)
        # S21 : posé par le serveur (non abaissable par le client) dès qu'une étape a
        # un effet réel → ces étapes sont confirmées sur le PC quel que soit le mode.
        server_requires_confirmation = payload.get("requires_confirmation") is True

        report: list[dict[str, Any]] = []
        all_ok = True
        stopped = False
        aborted = False
        timed_out = False
        interrupted_locally = False

        # Ordre lu PENDANT une confirmation console (C§2/§13) : un « stop » cliqué
        # dans l'app pendant que le PC attend une réponse refuse la confirmation ;
        # l'action ne s'exécute pas, même si l'utilisateur l'approuve ensuite.
        # Une lecture toutes les 2 s au plus (la console interroge en continu).
        confirm_ctl: dict[str, Any] = {"stop": False, "gone": False, "next": 0.0}

        def _read_control() -> str:
            try:
                return str(control())
            except Exception:  # noqa: BLE001 - lecture impossible = pas d'ordre
                log.debug("Lecture du contrôle impossible", exc_info=True)
                return "error"

        def _stop_check() -> bool:
            if token.is_cancelled() or abort.is_set():
                return True
            if not (confirm_ctl["stop"] or confirm_ctl["gone"]):
                now = time.monotonic()
                if now >= confirm_ctl["next"]:
                    confirm_ctl["next"] = now + _CONFIRM_CONTROL_POLL_SECONDS
                    ctrl = _read_control()
                    if ctrl == "stop":
                        confirm_ctl["stop"] = True
                    elif ctrl == "gone":
                        confirm_ctl["gone"] = True
            return bool(confirm_ctl["stop"] or confirm_ctl["gone"])

        approvals = {"asked": 0}

        def gate_emit(etype: str, message: str, data: dict) -> None:
            if etype == "approval_required":
                approvals["asked"] += 1
            emit(etype, message, data)

        try:
            emit("task_started", f"Début — {len(steps)} étape(s)", {"total": len(steps)})

            for i, step in enumerate(steps):
                if abort.is_set():
                    aborted = True
                    break
                if token.is_cancelled():
                    interrupted_locally = stopped = True
                    break
                # Contrôle utilisateur : pause (attente) ou stop (abandon propre).
                ctrl = self._wait_while_paused(control, abort, token, emit, i)
                if abort.is_set() or ctrl == "gone":
                    aborted = True
                    break
                if token.is_cancelled():
                    interrupted_locally = stopped = True
                    break
                if ctrl == "stop":
                    stopped = True
                    break

                if not isinstance(step, dict):
                    report.append({"index": i, "type": "?", "ok": False, "detail": "étape invalide"})
                    emit("step_failed", "étape invalide", {"index": i})
                    all_ok = False
                    break

                step_type = str(step.get("type", "")).strip()
                observe("planned", i, step)
                skill = get_skill(step_type)
                if skill is None:
                    report.append({"index": i, "type": step_type, "ok": False, "detail": "skill inconnu"})
                    emit("step_failed", "skill inconnu", {"index": i, "step_type": step_type})
                    observe("done", i, step, SkillResult(ok=False, detail="skill inconnu"))
                    all_ok = False
                    log.warning("Étape %d : type inconnu '%s'", i, step_type)
                    break

                # Autorisation AVANT step_started (S22) : une confirmation en attente
                # est signalée par approval_required / approval_result.
                ctx: dict[str, Any] = {
                    "emit": gate_emit, "step_index": i, "goal_meta": planned_by_server,
                    "requires_confirmation": server_requires_confirmation, "stop_check": _stop_check,
                    "task_id": task_id, "attempt": attempt,
                }
                asked_before = approvals["asked"]
                # Le contrôle vient d'être lu : prochaine lecture dans 2 s au plus tôt.
                confirm_ctl["next"] = time.monotonic() + _CONFIRM_CONTROL_POLL_SECONDS
                allowed, reason = self.gate.authorize(skill, step, ctx)
                if abort.is_set() or confirm_ctl["gone"]:  # 409/410 reçu pendant la confirmation
                    aborted = True
                    break
                if token.is_cancelled():
                    interrupted_locally = stopped = True
                    break
                if confirm_ctl["stop"]:  # « Arrêter » cliqué pendant la confirmation
                    log.warning("Arrêt demandé depuis l'app pendant la confirmation de l'étape %d — "
                                "action non exécutée", i)
                    stopped = True
                    break
                if approvals["asked"] != asked_before:
                    # La réponse a pu suivre un stop ou une pause demandés depuis l'app :
                    # le contrôle est relu AVANT d'agir (une pause fait attendre).
                    if allowed:
                        ctrl = self._wait_while_paused(control, abort, token, emit, i)
                    else:
                        ctrl = _read_control()
                    if abort.is_set() or ctrl == "gone":
                        aborted = True
                        break
                    if token.is_cancelled():
                        interrupted_locally = stopped = True
                        break
                    if ctrl == "stop":
                        stopped = True
                        break
                if allowed:
                    # S28 : revalidation des chemins juste avant l'exécution.
                    recheck = self.gate.recheck(skill, step)
                    if recheck:
                        allowed, reason = False, recheck
                if not allowed:
                    report.append({"index": i, "type": step_type, "ok": False, "detail": f"non autorisé ({reason})"})
                    emit("step_failed", f"non autorisé ({reason})", {"index": i, "step_type": step_type})
                    observe("done", i, step, SkillResult(ok=False, detail=f"non autorisé ({reason})"))
                    all_ok = False
                    log.info("Étape %d refusée : %s", i, reason)
                    break

                description = skill.describe(step)  # masquée (S8)
                started: dict[str, Any] = {"index": i, "step_type": step_type}
                if ctx.get("approval_id"):
                    # LOT 6 : référence de l'approbation distante — jamais le jeton lui-même.
                    started["approval_id"] = ctx["approval_id"]
                emit("step_started", description, started)
                observe("attempted", i, step)

                t0 = time.monotonic()
                interrupt = None
                if simulated:
                    result = SkillResult(ok=True, detail=f"[simulation] {description}")
                else:
                    log.info("Étape %d : %s", i, description)
                    result, interrupt = self._run_step(
                        skill, step, self.timeout_for(skill), control, abort, token
                    )
                duration_s = round(time.monotonic() - t0, 3)
                if interrupt != _ABORT:
                    observe("done", i, step, result)

                entry: dict[str, Any] = {
                    "index": i, "type": step_type, "ok": result.ok,
                    "detail": result.detail, "duration_s": duration_s,
                }
                if result.data:
                    entry["data"] = result.data
                if simulated:
                    entry["simulated"] = True
                report.append(entry)

                if interrupt == _ABORT:
                    aborted = True
                    break

                # Capture d'écran → évènement "screenshot" (écran live) avec l'image.
                if result.data and result.data.get("image_b64"):
                    emit("screenshot", "Capture d'écran", {
                        "index": i,
                        "image_b64": result.data["image_b64"],
                        "media_type": result.data.get("media_type", "image/jpeg"),
                    })

                if interrupt in (_STOP, _INTERRUPT):
                    stopped = True
                    interrupted_locally = interrupt == _INTERRUPT
                    break
                if interrupt == _TIMEOUT:
                    timed_out = True

                if result.ok:
                    emit("step_done", result.detail, {"index": i, "step_type": step_type, "duration_s": duration_s})
                else:
                    emit("step_failed", result.detail, {"index": i, "step_type": step_type})
                    all_ok = False
                    log.error("Étape %d échouée : %s", i, result.detail)
                    break
        finally:
            # Fin de tâche : le jeton est annulé (threads abandonnés libérés) et les
            # enregistrements en arrière-plan finalisés (un MP4 non finalisé est illisible).
            token.cancel("fin de tâche")
            try:
                n = record_bg.stop_all("fin de tâche")
                if n:
                    log.info("%d enregistrement(s) en arrière-plan finalisé(s) en fin de tâche", n)
            except Exception:  # noqa: BLE001
                log.exception("Échec de la finalisation des enregistrements")

        cancelled = False
        if aborted:
            all_ok = False
            summary = "tâche reprise ou supprimée par le serveur — exécution interrompue"
        elif stopped:
            all_ok = False
            cancelled = True
            if interrupted_locally:
                summary = "interrompu localement (Ctrl+C sur le PC de l'agent)"
            else:
                summary = "arrêt demandé par l'utilisateur"
            emit("task_cancelled", summary, {"index": len(report)})
        elif all_ok:
            summary = "toutes les étapes réussies"
            if simulated:
                summary += " (simulation : aucune action réelle)"
            emit("task_completed", summary, {})
        elif timed_out:
            summary = "arrêt : étape trop longue (délai dépassé)"
            emit("task_failed", summary, {"index": len(report), "timed_out": True})
        else:
            summary = "arrêt sur étape en échec/refus"
            emit("task_failed", summary, {"index": len(report), "timed_out": False})
        return _report(ok=all_ok, steps=report, summary=summary, stopped=stopped, cancelled=cancelled,
                       aborted=aborted, timed_out=timed_out)
