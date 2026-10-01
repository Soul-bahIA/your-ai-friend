"""Skill : organisation de fichiers — écrire, lire, lister, créer un dossier (sensible).

Tous les chemins sont validés par le gate contre la liste blanche de dossiers ET
la deny-list permanente (code de l'agent, .env, clés, .git…), puis revalidés
juste avant l'exécution.
  write_file : {"type": "write_file", "path": "...", "content": "..."}
  read_file  : {"type": "read_file", "path": "..."}
  list_dir   : {"type": "list_dir", "path": "..."}
  make_dir   : {"type": "make_dir", "path": "..."}

S7 : la confirmation affiche le contenu à écrire (en entier jusqu'à 2000
caractères, sinon le début) avec sa taille et son sha256. S8 : le contenu
n'apparaît jamais dans les journaux, évènements ni résultats.
"""
from __future__ import annotations

import hashlib
import os

from skills.base import PathCheck, Skill, SkillResult, mask_text
from skills.safety import deny_reason, is_git_internal

_MAX_READ = 8000
_MAX_PREVIEW = 2000
_WRITE_OPS = ("write_file", "make_dir")


def touches_git_dir(path: str) -> bool:
    """True si le chemin (résolu) passe par un dossier `.git` ou se trouve dans un
    dépôt git nu / un `--separate-git-dir`. Y écrire permettrait de planter un
    hook (pre-commit…) exécuté ensuite par un `git commit` autorisé."""
    return is_git_internal(path)


def content_details(content: str) -> str:
    raw = content.encode("utf-8")
    digest = hashlib.sha256(raw).hexdigest()
    head = f"Contenu à écrire : {len(content)} caractères, {len(raw)} octets, sha256 {digest}"
    if len(content) <= _MAX_PREVIEW:
        return f"{head}\n{content}"
    return f"{head}\n(début, {_MAX_PREVIEW} premiers caractères)\n{content[:_MAX_PREVIEW]}\n[… tronqué]"


class FileOpsSkill(Skill):
    name = "file_ops"
    step_types = ("write_file", "read_file", "list_dir", "make_dir")
    category = "filesystem"
    sensitive = True

    def describe(self, step: dict) -> str:
        base = f"{step.get('type')} : {step.get('path', '?')}"
        if step.get("type") == "write_file":
            base += f" ({mask_text(step.get('content', ''))})"
        return base

    def confirm_details(self, step: dict) -> str | None:
        if step.get("type") != "write_file":
            return None
        content = step.get("content", "")
        return content_details(content if isinstance(content, str) else str(content))

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        path = step.get("path")
        if not isinstance(path, str) or not path.strip():
            return "champ 'path' manquant"
        if str(step.get("type")) in _WRITE_OPS and touches_git_dir(path):
            return f"écriture refusée dans un dossier .git : {path}"
        if step.get("type") == "write_file" and "content" in step and not isinstance(step["content"], str):
            return "champ 'content' invalide (texte attendu)"
        return None

    def run(self, step: dict) -> SkillResult:
        t = str(step.get("type"))
        path = step.get("path")
        if not path or not isinstance(path, str):
            return SkillResult(ok=False, detail="champ 'path' manquant")
        # Défense en profondeur : la deny-list est revérifiée au moment d'agir.
        reason = deny_reason(path)
        if reason:
            return SkillResult(ok=False, detail=f"chemin interdit ({reason}) : {path}")
        if t in _WRITE_OPS and touches_git_dir(path):
            return SkillResult(ok=False, detail=f"écriture refusée dans un dossier .git : {path}")

        try:
            if t == "write_file":
                os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
                content = str(step.get("content", ""))
                with open(path, "w", encoding="utf-8") as f:
                    f.write(content)
                return SkillResult(ok=True, detail=f"{len(content)} caractères écrits dans {path}",
                                   data={"path": path})

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
