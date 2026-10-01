"""Skill : contrôle de la souris — clic, déplacement, glisser, molette (sensible)."""
from __future__ import annotations

from skills.base import Skill, SkillResult


class MouseSkill(Skill):
    name = "mouse"
    step_types = ("mouse", "click", "move_mouse", "drag", "scroll", "double_click", "right_click")
    category = "mouse"
    sensitive = True

    def describe(self, step: dict) -> str:
        t = step.get("type", "mouse")
        x, y = step.get("x"), step.get("y")
        if t == "scroll":
            return f"molette : {step.get('dy', 0)}"
        if x is not None and y is not None:
            return f"{t} en ({x}, {y})"
        return f"{t} (position actuelle)"

    def run(self, step: dict) -> SkillResult:
        try:
            import pyautogui
        except ImportError:
            return SkillResult(ok=False, detail="dépendance 'pyautogui' non installée")

        t = str(step.get("type", "click"))
        x = step.get("x")
        y = step.get("y")
        try:
            if t in ("move_mouse", "move"):
                pyautogui.moveTo(x, y, duration=0.2)
                return SkillResult(ok=True, detail=f"souris déplacée en ({x}, {y})")
            if t == "scroll":
                pyautogui.scroll(int(step.get("dy", 0)))
                return SkillResult(ok=True, detail=f"molette : {step.get('dy', 0)}")
            if t == "drag":
                if x is not None and y is not None:
                    pyautogui.dragTo(x, y, duration=0.3, button="left")
                    return SkillResult(ok=True, detail=f"glissé jusqu'à ({x}, {y})")
                return SkillResult(ok=False, detail="drag nécessite x et y")
            # Variantes de clic
            button = "right" if t == "right_click" else str(step.get("button", "left"))
            clicks = 2 if t == "double_click" else int(step.get("clicks", 1))
            if x is not None and y is not None:
                pyautogui.click(x=x, y=y, clicks=clicks, button=button)
            else:
                pyautogui.click(clicks=clicks, button=button)
            return SkillResult(ok=True, detail=f"clic {button} x{clicks}")
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec souris : {e}")
