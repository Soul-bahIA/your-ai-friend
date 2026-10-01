"""Executor : exécute la suite d'étapes (`steps`) du payload d'une tâche."""
from __future__ import annotations

import logging
import threading
import time
from typing import Any, Callable

from permissions import PermissionGate
from skills import REGISTRY, get_skill
from skills import record_bg
from skills.base import Skill, SkillResult, cancel_event

log = logging.getLogger("soulbah.executor")

# Callbacks optionnels branchés par l'agent pour le poste de pilotage temps réel.
EventFn = Callable[[str, str, dict], None]  # (type, message, data)
ControlFn = Callable[[], str]  # -> "none" | "pause" | "stop"

DEFAULT_STEP_TIMEOUT = 900.0
_CONTROL_POLL_SECONDS = 3.0  # lecture de l'ordre stop pendant une étape longue
_CANCEL_GRACE_SECONDS = 10.0  # délai laissé au skill pour s'arrêter proprement


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
    ) -> tuple[SkillResult, str | None]:
        """Exécute le skill dans un thread de travail avec délai.

        Retourne (résultat, interruption) où interruption ∈ {None, "timeout", "stop", "abort"}.
        Un skill bloqué ne peut pas être tué : on pose le drapeau d'annulation, on
        lui laisse un court délai de grâce, puis on l'abandonne (thread démon)."""
        box: dict[str, SkillResult] = {}

        def target() -> None:
            try:
                box["result"] = skill.run(step)
            except Exception as e:  # noqa: BLE001 - un skill ne doit jamais tuer l'agent
                log.exception("Exception dans le skill %s", skill.name)
                box["result"] = SkillResult(ok=False, detail=f"erreur interne du skill : {e}")

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
                    interrupt = "abort"
                elif now >= deadline:
                    interrupt = "timeout"
                elif now >= next_control:
                    if control() == "stop":
                        interrupt = "stop"
                    next_control = time.monotonic() + _CONTROL_POLL_SECONDS
                if interrupt:
                    cancel_event.set()
                    grace_deadline = time.monotonic() + _CANCEL_GRACE_SECONDS
            elif now >= grace_deadline:
                log.error("Le skill %s ne répond pas à l'annulation — abandonné en arrière-plan", skill.name)
                break

        if interrupt == "timeout":
            return SkillResult(ok=False, detail=f"délai dépassé ({int(timeout)} s) — étape abandonnée"), interrupt
        result = box.get("result")
        if result is None:
            result = SkillResult(ok=False, detail="étape interrompue")
        if interrupt == "stop" and result.ok:
            result = SkillResult(ok=False, detail="étape interrompue (arrêt demandé)", data=result.data)
        return result, interrupt

    def run_task(
        self,
        payload: dict[str, Any],
        on_event: EventFn | None = None,
        check_control: ControlFn | None = None,
        abort: threading.Event | None = None,
    ) -> dict[str, Any]:
        """Exécute chaque étape et retourne un rapport structuré.

        Retour : { ok, steps: [ {index, type, ok, detail} ], summary, stopped, aborted, timed_out }
        Émet des évènements (timeline + captures) via on_event et respecte les ordres
        de contrôle (pause/stop) lus via check_control, entre chaque étape et pendant
        les étapes longues. `abort` est posé par l'agent quand le backend indique
        (409) que la tâche n'est plus la nôtre : on s'arrête sans rien émettre.
        """
        emit = on_event or (lambda *_a, **_k: None)
        control = check_control or (lambda: "none")
        abort = abort or threading.Event()

        if not isinstance(payload, dict):
            return {"ok": False, "steps": [], "summary": "payload invalide", "stopped": False,
                    "aborted": False, "timed_out": False}
        steps = payload.get("steps") or []
        if not isinstance(steps, list):
            return {"ok": False, "steps": [], "summary": "payload.steps invalide", "stopped": False,
                    "aborted": False, "timed_out": False}

        cancel_event.clear()
        report: list[dict[str, Any]] = []
        all_ok = True
        stopped = False
        aborted = False
        timed_out = False

        try:
            emit("task_started", f"Début — {len(steps)} étape(s)", {"total": len(steps)})

            for i, step in enumerate(steps):
                if abort.is_set():
                    aborted = True
                    break
                # Contrôle utilisateur : pause (attente) ou stop (abandon propre).
                ctrl = control()
                while ctrl == "pause" and not abort.is_set():
                    emit("info", "En pause…", {"index": i})
                    time.sleep(1.0)
                    ctrl = control()
                if abort.is_set():
                    aborted = True
                    break
                if ctrl == "stop":
                    emit("task_failed", "Arrêt demandé par l'utilisateur", {"index": i})
                    stopped = True
                    break

                if not isinstance(step, dict):
                    report.append({"index": i, "type": "?", "ok": False, "detail": "étape invalide"})
                    emit("step_failed", "étape invalide", {"index": i})
                    all_ok = False
                    break

                step_type = str(step.get("type", "")).strip()
                skill = get_skill(step_type)
                emit("step_started", skill.describe(step) if skill else f"étape « {step_type} »",
                     {"index": i, "step_type": step_type})

                if skill is None:
                    report.append({"index": i, "type": step_type, "ok": False, "detail": "skill inconnu"})
                    emit("step_failed", "skill inconnu", {"index": i, "step_type": step_type})
                    all_ok = False
                    log.warning("Étape %d : type inconnu '%s'", i, step_type)
                    break

                allowed, reason = self.gate.authorize(skill, step)
                if not allowed:
                    report.append({"index": i, "type": step_type, "ok": False, "detail": f"non autorisé ({reason})"})
                    emit("step_failed", f"non autorisé ({reason})", {"index": i, "step_type": step_type})
                    all_ok = False
                    log.info("Étape %d refusée : %s", i, reason)
                    break
                if abort.is_set():  # 409 reçu pendant la confirmation
                    aborted = True
                    break

                t0 = time.monotonic()
                interrupt = None
                if self.gate.dry_run:
                    result = SkillResult(ok=True, detail=f"[dry-run] {skill.describe(step)}")
                else:
                    log.info("Étape %d : %s", i, skill.describe(step))
                    result, interrupt = self._run_step(skill, step, self.timeout_for(skill), control, abort)
                duration_s = round(time.monotonic() - t0, 3)

                entry = {
                    "index": i, "type": step_type, "ok": result.ok,
                    "detail": result.detail, "duration_s": duration_s,
                }
                if result.data:
                    entry["data"] = result.data
                report.append(entry)

                if interrupt == "abort":
                    aborted = True
                    break

                # Capture d'écran → évènement "screenshot" (écran live) avec l'image.
                if result.data and result.data.get("image_b64"):
                    emit("screenshot", "Capture d'écran", {
                        "index": i,
                        "image_b64": result.data["image_b64"],
                        "media_type": result.data.get("media_type", "image/jpeg"),
                    })

                if interrupt == "stop":
                    emit("task_failed", "Arrêt demandé par l'utilisateur", {"index": i})
                    stopped = True
                    break
                if interrupt == "timeout":
                    timed_out = True

                if result.ok:
                    emit("step_done", result.detail, {"index": i, "step_type": step_type, "duration_s": duration_s})
                else:
                    emit("step_failed", result.detail, {"index": i, "step_type": step_type})
                    all_ok = False
                    log.error("Étape %d échouée : %s", i, result.detail)
                    break
        finally:
            # Libère les ressources longues (skills abandonnés, enregistrements en
            # arrière-plan) : un MP4 non finalisé serait illisible.
            cancel_event.set()
            try:
                n = record_bg.stop_all("fin de tâche")
                if n:
                    log.info("%d enregistrement(s) en arrière-plan finalisé(s) en fin de tâche", n)
            except Exception:  # noqa: BLE001
                log.exception("Échec de la finalisation des enregistrements")

        if aborted:
            all_ok = False
            summary = "tâche reprise par le serveur (409) — exécution interrompue"
        elif stopped:
            all_ok = False
            summary = "arrêt demandé par l'utilisateur"
        elif all_ok:
            summary = "toutes les étapes réussies"
            emit("task_completed", summary, {})
        elif timed_out:
            summary = "arrêt : étape trop longue (délai dépassé)"
        else:
            summary = "arrêt sur étape en échec/refus"
        return {"ok": all_ok, "steps": report, "summary": summary, "stopped": stopped,
                "aborted": aborted, "timed_out": timed_out}
