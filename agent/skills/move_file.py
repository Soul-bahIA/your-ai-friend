"""Skill : déplacer un fichier (sensible, soumis à la whitelist de dossiers)."""
from __future__ import annotations

import os
import shutil

from skills.base import PathCheck, Skill, SkillResult, path_refusal_now
from skills.filesystem import touches_git_dir
from skills.safety import deny_reason


class MoveFileSkill(Skill):
    name = "move_file"
    step_types = ("move_file", "move")
    category = "filesystem"
    sensitive = True

    def describe(self, step: dict) -> str:
        return f"déplacer {step.get('src')} → {step.get('dest')}"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        src, dest = step.get("src"), step.get("dest")
        if not isinstance(src, str) or not isinstance(dest, str) or not src or not dest:
            return "champs 'src' et 'dest' requis"
        if touches_git_dir(src) or touches_git_dir(dest):
            return "déplacement refusé depuis/vers un dossier .git"
        return None

    def run(self, step: dict) -> SkillResult:
        src = step.get("src")
        dest = step.get("dest")
        if not isinstance(src, str) or not isinstance(dest, str) or not src or not dest:
            return SkillResult(ok=False, detail="champs 'src' et 'dest' requis")
        if touches_git_dir(src) or touches_git_dir(dest):
            return SkillResult(ok=False, detail="déplacement refusé depuis/vers un dossier .git")
        for p in (src, dest):
            reason = deny_reason(p)
            if reason:
                return SkillResult(ok=False, detail=f"chemin interdit ({reason}) : {p}")
            # Whitelist du gate revérifiée au moment d'agir (liée par l'executor).
            refusal = path_refusal_now(p)
            if refusal:
                return SkillResult(ok=False, detail=f"chemin refusé au moment d'agir : {refusal}")
        if not os.path.exists(src):
            return SkillResult(ok=False, detail=f"source introuvable : {src}")

        try:
            os.makedirs(os.path.dirname(os.path.abspath(dest)), exist_ok=True)
            final = shutil.move(src, dest)
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec déplacement : {e}")

        return SkillResult(ok=True, detail=f"déplacé vers {final}", data={"path": final})
