"""Skill : raccourci clavier — combinaison de touches (sensible).

Exemple de step : {"type": "hotkey", "keys": ["ctrl", "s"]}
Ou touche unique : {"type": "press", "keys": ["enter"]}
"""
from __future__ import annotations

from skills.base import Skill, SkillResult


class HotkeySkill(Skill):
    name = "hotkey"
    step_types = ("hotkey", "press", "key")
    category = "keyboard"
    sensitive = True

    def _keys(self, step: dict) -> list[str]:
        keys = step.get("keys")
        if isinstance(keys, str):
            return [k.strip() for k in keys.replace("+", " ").split() if k.strip()]
        if isinstance(keys, list):
            return [str(k).strip().lower() for k in keys if str(k).strip()]
        return []

    def describe(self, step: dict) -> str:
        return f"raccourci : {'+'.join(self._keys(step)) or '(vide)'}"

    def run(self, step: dict) -> SkillResult:
        try:
            import pyautogui
        except ImportError:
            return SkillResult(ok=False, detail="dépendance 'pyautogui' non installée")

        keys = self._keys(step)
        if not keys:
            return SkillResult(ok=False, detail="champ 'keys' manquant")
        try:
            if len(keys) == 1:
                pyautogui.press(keys[0])
            else:
                pyautogui.hotkey(*keys)
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec raccourci : {e}")
        return SkillResult(ok=True, detail=f"raccourci envoyé : {'+'.join(keys)}")
