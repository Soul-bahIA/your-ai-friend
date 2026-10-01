"""Skill : déplacer un fichier (sensible, soumis à la whitelist de dossiers)."""
from __future__ import annotations

import os
import shutil

from skills.base import Skill, SkillResult


class MoveFileSkill(Skill):
    name = "move_file"
    step_types = ("move_file", "move")
    category = "filesystem"
    sensitive = True

    def describe(self, step: dict) -> str:
        return f"déplacer {step.get('src')} → {step.get('dest')}"

    def run(self, step: dict) -> SkillResult:
        src = step.get("src")
        dest = step.get("dest")
        if not src or not dest:
            return SkillResult(ok=False, detail="champs 'src' et 'dest' requis")
        if not os.path.exists(src):
            return SkillResult(ok=False, detail=f"source introuvable : {src}")

        try:
            os.makedirs(os.path.dirname(os.path.abspath(dest)), exist_ok=True)
            final = shutil.move(src, dest)
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec déplacement : {e}")

        return SkillResult(ok=True, detail=f"déplacé vers {final}", data={"path": final})
