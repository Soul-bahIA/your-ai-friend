"""Skill : contrôle de la souris — clic, déplacement, glisser, molette (sensible).

T22 / S25 : les paramètres sont validés AVANT exécution. x/y doivent être des
NOMBRES : une chaîne ferait chercher par pyautogui une image sur l'écran à partir
d'un fichier (lecture hors whitelist).
"""
from __future__ import annotations

from skills.base import PathCheck, Skill, SkillResult, is_number

_BUTTONS = ("left", "right", "middle")
_MAX_COORD = 100_000
_MAX_SCROLL = 10_000
_NEEDS_XY = ("move_mouse", "move", "drag")


def _check_mouse(step: dict) -> str | None:
    t = str(step.get("type", "click"))
    x, y = step.get("x"), step.get("y")
    if (x is None) != (y is None):
        return "champs 'x' et 'y' : les deux ou aucun"
    if x is not None:
        if not is_number(x) or not is_number(y):
            return "champs 'x'/'y' invalides (nombres attendus, jamais de texte ni de chemin)"
        if abs(x) > _MAX_COORD or abs(y) > _MAX_COORD:
            return "coordonnées hors bornes"
    elif t in _NEEDS_XY:
        return f"{t} nécessite x et y"
    if "button" in step and step.get("button") not in _BUTTONS:
        return f"champ 'button' invalide ({' | '.join(_BUTTONS)})"
    clicks = step.get("clicks")
    if clicks is not None and (isinstance(clicks, bool) or not isinstance(clicks, int) or not 1 <= clicks <= 3):
        return "champ 'clicks' invalide (entier de 1 à 3)"
    dy = step.get("dy")
    if dy is not None and (isinstance(dy, bool) or not isinstance(dy, int) or abs(dy) > _MAX_SCROLL):
        return "champ 'dy' invalide (entier)"
    return None


class MouseSkill(Skill):
    name = "mouse"
    step_types = ("mouse", "click", "move_mouse", "drag", "scroll", "double_click", "right_click")
    category = "mouse"
    sensitive = True

    def describe(self, step: dict) -> str:
        t = step.get("type", "mouse")
        x, y = step.get("x"), step.get("y")
        if t == "scroll":
            dy = step.get("dy", 0)
            return f"molette : {dy if is_number(dy) else '?'}"
        if is_number(x) and is_number(y):
            return f"{t} en ({x}, {y})"
        return f"{t} (position actuelle)"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        return _check_mouse(step)

    def run(self, step: dict) -> SkillResult:
        err = _check_mouse(step)
        if err:
            return SkillResult(ok=False, detail=err)
        try:
            import pyautogui
        except ImportError:
            return SkillResult(ok=False, detail="dépendance 'pyautogui' non installée")

        t = str(step.get("type", "click"))
        x = step.get("x")
        y = step.get("y")
        if x is not None:
            x, y = int(round(x)), int(round(y))
        try:
            if t in ("move_mouse", "move"):
                pyautogui.moveTo(x, y, duration=0.2)
                return SkillResult(ok=True, detail=f"souris déplacée en ({x}, {y})")
            if t == "scroll":
                dy = int(step.get("dy") or 0)
                pyautogui.scroll(dy)
                return SkillResult(ok=True, detail=f"molette : {dy}")
            if t == "drag":
                pyautogui.dragTo(x, y, duration=0.3, button="left")
                return SkillResult(ok=True, detail=f"glissé jusqu'à ({x}, {y})")
            # Variantes de clic
            button = "right" if t == "right_click" else str(step.get("button") or "left")
            clicks = 2 if t == "double_click" else int(step.get("clicks") or 1)
            if x is not None:
                pyautogui.click(x=x, y=y, clicks=clicks, button=button)
            else:
                pyautogui.click(clicks=clicks, button=button)
            return SkillResult(ok=True, detail=f"clic {button} x{clicks}")
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec souris : {e}")
