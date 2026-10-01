"""Skill : gestion des fenêtres — focus, minimiser, maximiser, fermer (sensible).

Exemple : {"type": "window", "action": "focus", "window_title": "Bloc-notes"}
Actions : focus | minimize | maximize | close

Correspondance du titre (`match`) :
  - "contains" (défaut pour focus/minimize/maximize) : sous-chaîne, insensible à la casse ;
  - "exact" (défaut pour close) : titre identique (casse et espaces de bord ignorés) ;
  - "regex" : expression régulière explicite (re.search, insensible à la casse).
S24 : `close` n'accepte que "exact" ou "regex", et si plusieurs fenêtres
correspondent (ambiguïté), l'action est REFUSÉE — jamais « la première venue ».
"""
from __future__ import annotations

import re

from skills.base import PathCheck, Skill, SkillResult

_ACTIONS = ("focus", "minimize", "maximize", "close")
_MATCHES = ("contains", "exact", "regex")
_MAX_TITLE = 256


class WindowSkill(Skill):
    name = "window"
    step_types = ("window", "focus_window", "minimize_window", "maximize_window", "close_window")
    category = "window"
    sensitive = True

    def _action(self, step: dict) -> str:
        t = str(step.get("type", ""))
        if t.endswith("_window") and t != "window":
            return t.replace("_window", "")
        return str(step.get("action", "focus"))

    def _title(self, step: dict) -> object:
        return step.get("window_title") or step.get("title")

    def _match_mode(self, step: dict) -> str:
        mode = step.get("match")
        if mode is None:
            return "exact" if self._action(step) == "close" else "contains"
        return str(mode)

    def describe(self, step: dict) -> str:
        return f"{self._action(step)} la fenêtre « {self._title(step) or '?'} » ({self._match_mode(step)})"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        action = self._action(step)
        if action not in _ACTIONS:
            return f"action inconnue : {action} ({' | '.join(_ACTIONS)})"
        title = self._title(step)
        if not isinstance(title, str) or not title.strip() or len(title) > _MAX_TITLE:
            return "champ 'window_title' manquant ou invalide"
        mode = self._match_mode(step)
        if mode not in _MATCHES:
            return f"champ 'match' invalide ({' | '.join(_MATCHES)})"
        if action == "close" and mode == "contains":
            return "close : correspondance « exact » ou « regex » explicite requise (pas de sous-chaîne)"
        if mode == "regex":
            try:
                re.compile(title)
            except re.error as e:
                return f"expression régulière invalide : {e}"
        return None

    def find_matches(self, windows: list, step: dict) -> list:
        """Fenêtres (distinctes) correspondant au titre demandé."""
        title = str(self._title(step)).strip()
        mode = self._match_mode(step)
        named = [w for w in windows if (getattr(w, "title", "") or "").strip()]
        if mode == "exact":
            matches = [w for w in named if w.title.strip().casefold() == title.casefold()]
        elif mode == "regex":
            rx = re.compile(title, re.IGNORECASE)
            matches = [w for w in named if rx.search(w.title)]
        else:
            matches = [w for w in named if title.casefold() in w.title.casefold()]
            if len(matches) > 1:
                exact = [w for w in matches if w.title.strip().casefold() == title.casefold()]
                if len(exact) == 1:
                    matches = exact
        seen: set = set()
        unique = []
        for w in matches:
            key = getattr(w, "_hWnd", None) or id(w)
            if key not in seen:
                seen.add(key)
                unique.append(w)
        return unique

    def run(self, step: dict) -> SkillResult:
        err = self.validate(step, lambda _p: True)
        if err:
            return SkillResult(ok=False, detail=err)
        try:
            import pygetwindow as gw
        except ImportError:
            return SkillResult(ok=False, detail="dépendance 'pygetwindow' non installée")

        title = str(self._title(step))
        try:
            matches = self.find_matches(gw.getAllWindows(), step)
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"énumération fenêtres impossible : {e}")
        if not matches:
            return SkillResult(ok=False, detail=f"aucune fenêtre ne correspond à « {title} »")
        if len(matches) > 1:
            names = ", ".join(f"« {w.title[:50]} »" for w in matches[:5])
            return SkillResult(ok=False, detail=(f"fenêtre ambiguë : {len(matches)} fenêtres correspondent "
                                                 f"à « {title} » ({names}) — précisez le titre exact"))

        win = matches[0]
        action = self._action(step)
        try:
            if action == "focus":
                win.activate()
            elif action == "minimize":
                win.minimize()
            elif action == "maximize":
                win.maximize()
            else:
                win.close()
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec {action} : {e}")
        return SkillResult(ok=True, detail=f"{action} → « {win.title} »")
