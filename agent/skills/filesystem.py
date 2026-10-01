"""Skill : organisation de fichiers — écrire, lire, lister, créer un dossier (sensible).

Tous les chemins sont validés par le gate contre la liste blanche de dossiers.
  write_file : {"type": "write_file", "path": "...", "content": "..."}
  read_file  : {"type": "read_file", "path": "..."}
  list_dir   : {"type": "list_dir", "path": "..."}
  make_dir   : {"type": "make_dir", "path": "..."}
"""
from __future__ import annotations

import os

from skills.base import Skill, SkillResult

_MAX_READ = 8000


class FileOpsSkill(Skill):
    name = "file_ops"
    step_types = ("write_file", "read_file", "list_dir", "make_dir")
    category = "filesystem"
    sensitive = True

    def describe(self, step: dict) -> str:
        return f"{step.get('type')} : {step.get('path', '?')}"

    def run(self, step: dict) -> SkillResult:
        t = str(step.get("type"))
        path = step.get("path")
        if not path:
            return SkillResult(ok=False, detail="champ 'path' manquant")

        try:
            if t == "write_file":
                os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
                content = str(step.get("content", ""))
                with open(path, "w", encoding="utf-8") as f:
                    f.write(content)
                return SkillResult(ok=True, detail=f"{len(content)} caractères écrits dans {path}")

            if t == "read_file":
                if not os.path.isfile(path):
                    return SkillResult(ok=False, detail=f"fichier introuvable : {path}")
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    data = f.read(_MAX_READ)
                return SkillResult(ok=True, detail=f"{len(data)} caractères lus", data={"content": data})

            if t == "list_dir":
                if not os.path.isdir(path):
                    return SkillResult(ok=False, detail=f"dossier introuvable : {path}")
                entries = sorted(os.listdir(path))
                return SkillResult(
                    ok=True,
                    detail=f"{len(entries)} entrées : {', '.join(entries[:30])}",
                    data={"entries": entries},
                )

            if t == "make_dir":
                os.makedirs(path, exist_ok=True)
                return SkillResult(ok=True, detail=f"dossier prêt : {path}")

        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec {t} : {e}")

        return SkillResult(ok=False, detail=f"opération inconnue : {t}")
