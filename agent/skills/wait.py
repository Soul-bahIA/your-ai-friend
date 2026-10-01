"""Skill : attendre un délai (non sensible). Interruptible par un ordre d'arrêt."""
from __future__ import annotations

from skills.base import Skill, SkillResult, sleep_or_cancel


class WaitSkill(Skill):
    name = "wait"
    step_types = ("wait", "sleep")
    category = "generic"
    sensitive = False

    def describe(self, step: dict) -> str:
        return f"attendre {step.get('seconds', 1)} s"

    def run(self, step: dict) -> SkillResult:
        try:
            seconds = float(step.get("seconds", 1))
        except (TypeError, ValueError):
            return SkillResult(ok=False, detail="champ 'seconds' invalide")
        seconds = max(0.0, min(seconds, 300.0))  # borne de sécurité
        if not sleep_or_cancel(seconds):
            return SkillResult(ok=False, detail="attente interrompue (arrêt demandé)")
        return SkillResult(ok=True, detail=f"attendu {seconds} s")
