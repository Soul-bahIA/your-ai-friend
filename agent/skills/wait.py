"""Skill : attendre un délai (non sensible)."""
from __future__ import annotations

import time

from skills.base import Skill, SkillResult


class WaitSkill(Skill):
    name = "wait"
    step_types = ("wait", "sleep")
    category = "generic"
    sensitive = False

    def describe(self, step: dict) -> str:
        return f"attendre {step.get('seconds', 1)} s"

    def run(self, step: dict) -> SkillResult:
        seconds = float(step.get("seconds", 1))
        seconds = max(0.0, min(seconds, 300.0))  # borne de sécurité
        time.sleep(seconds)
        return SkillResult(ok=True, detail=f"attendu {seconds} s")
