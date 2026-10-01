"""Executor : exécute la suite d'étapes (`steps`) du payload d'une tâche."""
from __future__ import annotations

import logging
import time
from typing import Any, Callable

from permissions import PermissionGate
from skills import get_skill
from skills.base import SkillResult

log = logging.getLogger("soulbah.executor")

# Callbacks optionnels branchés par l'agent pour le poste de pilotage temps réel.
EventFn = Callable[[str, str, dict], None]  # (type, message, data)
ControlFn = Callable[[], str]  # -> "none" | "pause" | "stop"


class Executor:
    def __init__(self, gate: PermissionGate):
        self.gate = gate

    def run_task(
        self,
        payload: dict[str, Any],
        on_event: EventFn | None = None,
        check_control: ControlFn | None = None,
    ) -> dict[str, Any]:
        """Exécute chaque étape et retourne un rapport structuré.

        Retour : { ok, steps: [ {index, type, ok, detail} ], summary, stopped? }
        Émet des évènements (timeline + captures) via on_event et respecte les ordres
        de contrôle (pause/stop) lus via check_control, entre chaque étape.
        """
        emit = on_event or (lambda *_a, **_k: None)
        control = check_control or (lambda: "none")

        steps = payload.get("steps") or []
        if not isinstance(steps, list):
            return {"ok": False, "steps": [], "summary": "payload.steps invalide"}

        report: list[dict[str, Any]] = []
        all_ok = True
        stopped = False

        emit("task_started", f"Début — {len(steps)} étape(s)", {"total": len(steps)})

        for i, step in enumerate(steps):
            # Contrôle utilisateur : pause (attente) ou stop (abandon propre).
            ctrl = control()
            if ctrl == "stop":
                emit("task_failed", "Arrêt demandé par l'utilisateur", {"index": i})
                stopped = True
                all_ok = False
                break
            while ctrl == "pause":
                emit("info", "En pause…", {"index": i})
                time.sleep(1.0)
                ctrl = control()
                if ctrl == "stop":
                    break
            if ctrl == "stop":
                emit("task_failed", "Arrêt demandé par l'utilisateur", {"index": i})
                stopped = True
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

            t0 = time.monotonic()
            if self.gate.dry_run:
                result = SkillResult(ok=True, detail=f"[dry-run] {skill.describe(step)}")
            else:
                log.info("Étape %d : %s", i, skill.describe(step))
                result = skill.run(step)
            duration_s = round(time.monotonic() - t0, 3)

            entry = {
                "index": i, "type": step_type, "ok": result.ok,
                "detail": result.detail, "duration_s": duration_s,
            }
            if result.data:
                entry["data"] = result.data
            report.append(entry)

            # Capture d'écran → évènement "screenshot" (écran live) avec l'image.
            if result.data and result.data.get("image_b64"):
                emit("screenshot", "Capture d'écran", {
                    "index": i,
                    "image_b64": result.data["image_b64"],
                    "media_type": result.data.get("media_type", "image/jpeg"),
                })

            if result.ok:
                emit("step_done", result.detail, {"index": i, "step_type": step_type, "duration_s": duration_s})
            else:
                emit("step_failed", result.detail, {"index": i, "step_type": step_type})
                all_ok = False
                log.error("Étape %d échouée : %s", i, result.detail)
                break

        if stopped:
            summary = "arrêt demandé par l'utilisateur"
        elif all_ok:
            summary = "toutes les étapes réussies"
            emit("task_completed", summary, {})
        else:
            summary = "arrêt sur étape en échec/refus"
        return {"ok": all_ok, "steps": report, "summary": summary, "stopped": stopped}
