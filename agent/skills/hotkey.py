"""Skill : raccourci clavier — combinaison de touches (sensible).

Exemple de step : {"type": "hotkey", "keys": ["ctrl", "s"]}  ou  {"type": "hotkey", "keys": "Ctrl+S"}
Ou touche unique : {"type": "press", "keys": ["enter"]}

T22 : toutes les touches sont normalisées en minuscules (« Ctrl+S » envoie
exactement ctrl+s, et non ctrl+shift+s) et validées contre une liste fermée :
une touche inconnue est une ERREUR de validation (plus de faux « ok »).

S3 : un raccourci qui ouvre un moyen d'exécuter du code (Exécuter, terminal,
palette de commandes, gestionnaire des tâches, touche Windows…) reste confirmé
même quand le contrôle d'entrée est pré-autorisé.
"""
from __future__ import annotations

import re

from skills.base import PathCheck, Skill, SkillResult

_ALIASES = {
    "control": "ctrl", "ctl": "ctrl", "strg": "ctrl", "ctrl_l": "ctrlleft", "ctrl_r": "ctrlright",
    "windows": "win", "super": "win", "meta": "win", "cmd": "win", "command": "win", "os": "win",
    "option": "alt", "altgr": "altright", "maj": "shift", "majuscule": "shift",
    "escape": "esc", "echap": "esc", "échap": "esc", "échappement": "esc",
    "return": "enter", "entrée": "enter", "entree": "enter",
    "del": "delete", "suppr": "delete", "supprimer": "delete", "ins": "insert", "inser": "insert",
    "bksp": "backspace", "retour": "backspace",
    "pgup": "pageup", "page_up": "pageup", "pgdn": "pagedown", "page_down": "pagedown",
    "spacebar": "space", "espace": "space", "tabulation": "tab",
    "arrowup": "up", "arrowdown": "down", "arrowleft": "left", "arrowright": "right",
    "haut": "up", "bas": "down", "gauche": "left", "droite": "right",
    "début": "home", "debut": "home", "fin": "end",
    "plus": "+", "minus": "-", "moins": "-", "backtick": "`", "backquote": "`",
    "prtsc": "printscreen", "prtscr": "printscreen", "impr": "printscreen",
    "menu": "apps", "contextmenu": "apps",
}

_NAMED = frozenset({
    "ctrl", "ctrlleft", "ctrlright", "shift", "shiftleft", "shiftright",
    "alt", "altleft", "altright", "win", "winleft", "winright",
    "enter", "esc", "tab", "space", "backspace", "delete", "insert",
    "home", "end", "pageup", "pagedown", "up", "down", "left", "right",
    "capslock", "numlock", "scrolllock", "printscreen", "pause", "apps",
    "volumemute", "volumeup", "volumedown", "playpause", "nexttrack", "prevtrack", "stop",
    "add", "subtract", "multiply", "divide", "decimal",
    *(f"f{i}" for i in range(1, 25)),
    *(f"num{i}" for i in range(10)),
})
# Caractères simples (non « shiftés » sur un clavier US, + « + » pour le zoom).
_CHARS = frozenset("abcdefghijklmnopqrstuvwxyz0123456789`-=[]\\;',./+")
_MAX_KEYS = 5

_MODIFIER_FAMILY = {
    "ctrlleft": "ctrl", "ctrlright": "ctrl", "shiftleft": "shift", "shiftright": "shift",
    "altleft": "alt", "altright": "alt", "winleft": "win", "winright": "win",
}

# S3 : combinaisons qui donnent accès à l'exécution de code ou de commandes.
_RISKY_COMBOS: dict[frozenset[str], str] = {
    frozenset({"ctrl", "shift", "esc"}): "ouvre le gestionnaire des tâches (Exécuter une nouvelle tâche)",
    frozenset({"ctrl", "alt", "delete"}): "ouvre l'écran de sécurité Windows",
    frozenset({"ctrl", "`"}): "ouvre le terminal intégré de VS Code",
    frozenset({"ctrl", "shift", "`"}): "ouvre un nouveau terminal VS Code",
    frozenset({"ctrl", "shift", "c"}): "ouvre un terminal externe depuis VS Code",
    frozenset({"ctrl", "shift", "p"}): "ouvre la palette de commandes (tâches, terminal…)",
    frozenset({"f1"}): "ouvre la palette de commandes de VS Code",
    frozenset({"alt", "f2"}): "ouvre la boîte « Exécuter » (Linux)",
    frozenset({"ctrl", "alt", "t"}): "ouvre un terminal (Linux)",
}


def _split_combo(raw: str) -> list[str]:
    s = raw.strip()
    if not s:
        return []
    if s == "+":
        return ["+"]
    trailing_plus = s.endswith("++")
    if trailing_plus:
        s = s[:-2]
    parts = [p for p in re.split(r"[+\s]+", s) if p]
    if trailing_plus:
        parts.append("+")
    return parts


def normalize_keys(raw: object) -> tuple[list[str], str | None]:
    """Normalise `keys` (liste ou « Ctrl+S »). Retourne (touches, erreur|None)."""
    if isinstance(raw, str):
        tokens = _split_combo(raw)
    elif isinstance(raw, list):
        tokens = []
        for k in raw:
            if not isinstance(k, str):
                return [], f"touche invalide (texte attendu) : {k!r}"
            tokens.extend(_split_combo(k) if k.strip() != "+" else ["+"])
    else:
        return [], "champ 'keys' manquant (liste de touches ou « ctrl+s »)"
    if not tokens:
        return [], "champ 'keys' vide"
    if len(tokens) > _MAX_KEYS:
        return [], f"trop de touches (max {_MAX_KEYS})"
    keys: list[str] = []
    for tok in tokens:
        k = tok.strip().lower()
        k = _ALIASES.get(k, k)
        if k not in _NAMED and k not in _CHARS:
            return [], f"touche inconnue : '{tok}'"
        if k in keys:
            return [], f"touche répétée : '{tok}'"
        keys.append(k)
    return keys, None


def hotkey_risk(keys: list[str]) -> str | None:
    """Raison de confirmer ce raccourci malgré la pré-autorisation (S3), ou None."""
    family = frozenset(_MODIFIER_FAMILY.get(k, k) for k in keys)
    if "win" in family:
        return "raccourci avec la touche Windows (menu Démarrer, Exécuter, Win+X…)"
    return _RISKY_COMBOS.get(family)


class HotkeySkill(Skill):
    name = "hotkey"
    step_types = ("hotkey", "press", "key")
    category = "keyboard"
    sensitive = True

    def describe(self, step: dict) -> str:
        keys, err = normalize_keys(step.get("keys"))
        return f"raccourci : {'+'.join(keys) if not err else '(invalide)'}"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        _, err = normalize_keys(step.get("keys"))
        return err

    def input_risk(self, step: dict) -> str | None:
        keys, err = normalize_keys(step.get("keys"))
        return None if err else hotkey_risk(keys)

    def run(self, step: dict) -> SkillResult:
        keys, err = normalize_keys(step.get("keys"))
        if err:
            return SkillResult(ok=False, detail=err)
        try:
            import pyautogui
        except ImportError:
            return SkillResult(ok=False, detail="dépendance 'pyautogui' non installée")
        try:
            if len(keys) == 1:
                pyautogui.press(keys[0])
            else:
                pyautogui.hotkey(*keys)
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec raccourci : {e}")
        return SkillResult(ok=True, detail=f"raccourci envoyé : {'+'.join(keys)}")
