"""Skill : gestion des fenêtres — focus, minimiser, maximiser, fermer (sensible).

Exemple : {"type": "window", "action": "focus", "window_title": "Bloc-notes"}
Actions : focus | minimize | maximize | close
"""
from __future__ import annotations

from skills.base import Skill, SkillResult


class WindowSkill(Skill):
    name = "window"
    step_types = ("window", "focus_window", "minimize_window", "maximize_window", "close_window")
    category = "window"
    sensitive = True

    def _action(self, step: dict) -> str:
        t = step.get("type", "")
        if t.endswith("_window") and t != "window":
            return t.replace("_window", "")
        return str(step.get("action", "focus"))

    def describe(self, step: dict) -> str:
        return f"{self._action(step)} la fenêtre « {step.get('window_title', '?')} »"

    def run(self, step: dict) -> SkillResult:
        try:
            import pygetwindow as gw
        except ImportError:
            return SkillResult(ok=False, detail="dépendance 'pygetwindow' non installée")

        title = step.get("window_title") or step.get("title")
        if not title:
            return SkillResult(ok=False, detail="champ 'window_title' manquant")

        try:
            matches = [w for w in gw.getAllWindows() if title.lower() in (w.title or "").lower()]
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"énumération fenêtres impossible : {e}")
        if not matches:
            return SkillResult(ok=False, detail=f"aucune fenêtre contenant « {title} »")

        win = matches[0]
        action = self._action(step)
        try:
            if action == "focus":
                win.activate()
            elif action == "minimize":
                win.minimize()
            elif action == "maximize":
                win.maximize()
            elif action == "close":
                win.close()
            else:
                return SkillResult(ok=False, detail=f"action inconnue : {action}")
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec {action} : {e}")
        return SkillResult(ok=True, detail=f"{action} → « {win.title} »")
