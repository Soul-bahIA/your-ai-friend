"""Ouverture d'un dossier ou d'un fichier dans VS Code (LOT 12, rôle desktop_operator).

`vscode_open` lance `Code.exe` DIRECTEMENT (jamais `code.cmd` : un fichier .cmd passe par
cmd.exe, où un argument peut injecter des commandes). Le chemin ouvert est contrôlé par le gate
(dossiers autorisés, deny-list) ; seules deux options sont transmises : `--new-window` et
`--goto <fichier>:<ligne>`.

Recherche de Code.exe : SOULBAH_VSCODE_EXE, installation utilisateur (%LOCALAPPDATA%), machine
(%ProgramFiles%), puis `code.cmd` du PATH (on remonte de `bin\\` à `Code.exe`).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys

from skills.base import PathCheck, Skill, SkillResult
from skills.manifests import declared_param_error

_NOT_FOUND = ("VS Code introuvable sur ce poste (installer Visual Studio Code, ou définir SOULBAH_VSCODE_EXE "
              "avec le chemin de Code.exe)")


def find_vscode() -> str | None:
    override = os.environ.get("SOULBAH_VSCODE_EXE", "").strip()
    if override:
        return override if os.path.isfile(override) and override.lower().endswith(".exe") else None
    candidates: list[str] = []
    for base in (os.environ.get("LOCALAPPDATA", ""), os.environ.get("ProgramFiles", ""),
                 os.environ.get("ProgramFiles(x86)", "")):
        if base:
            sub = os.path.join("Programs", "Microsoft VS Code") if base == os.environ.get("LOCALAPPDATA") \
                else "Microsoft VS Code"
            candidates.append(os.path.join(base, sub, "Code.exe"))
    cli = shutil.which("code.cmd") if sys.platform == "win32" else None
    if cli:
        candidates.append(os.path.join(os.path.dirname(os.path.dirname(cli)), "Code.exe"))
    for c in candidates:
        if os.path.isfile(c):
            return c
    return None


def vscode_env() -> dict[str, str]:
    """Environnement du lancement : SANS les variables d'Electron et de VS Code héritées.

    Un agent démarré depuis un terminal de VS Code hérite de ELECTRON_RUN_AS_NODE=1 : Code.exe
    démarrerait alors comme un simple Node et tenterait d'exécuter le dossier comme un script
    (échec silencieux, aucune fenêtre). Les VSCODE_* (canal IPC, PID…) visent l'instance parente."""
    return {k: v for k, v in os.environ.items() if not k.upper().startswith(("ELECTRON_", "VSCODE_"))}


def vscode_args(step: dict) -> list[str]:
    path = str(step["path"])
    args: list[str] = []
    if step.get("new_window"):
        args.append("--new-window")
    line = step.get("line")
    if line is not None and os.path.isfile(path):
        args += ["--goto", f"{path}:{int(line)}"]
    else:
        args.append(path)
    return args


class VsCodeOpenSkill(Skill):
    name = "vscode_open"
    step_types = ("vscode_open",)
    category = "app_launch"
    sensitive = True

    def describe(self, step: dict) -> str:
        return f"ouvrir dans VS Code : {step.get('path')}"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        declared = declared_param_error(step)
        if declared:
            return declared
        path = step.get("path")
        if not isinstance(path, str) or not path.strip() or not os.path.isabs(path):
            return "champ 'path' requis (chemin absolu d'un dossier ou d'un fichier)"
        if path.lstrip().startswith("-"):
            return "champ 'path' invalide"
        if not path_allowed(path):
            return f"chemin hors des dossiers autorisés : {path}"
        line = step.get("line")
        if line is not None and (isinstance(line, bool) or not isinstance(line, int) or not 1 <= line <= 1_000_000):
            return "champ 'line' : entier ≥ 1"
        if not isinstance(step.get("new_window", False), bool):
            return "champ 'new_window' : booléen"
        return None

    def run(self, step: dict) -> SkillResult:
        path = str(step["path"])
        if not os.path.exists(path):
            return SkillResult(ok=False, detail=f"chemin introuvable : {path}")
        exe = find_vscode()
        if not exe:
            return SkillResult(ok=False, detail=_NOT_FOUND)
        argv = [exe, *vscode_args(step)]
        env = vscode_env()
        try:
            if sys.platform == "win32":
                from skills.proctree import CREATE_BREAKAWAY_FROM_JOB

                try:
                    subprocess.Popen(argv, shell=False, close_fds=True, env=env, creationflags=CREATE_BREAKAWAY_FROM_JOB)
                except OSError:
                    subprocess.Popen(argv, shell=False, close_fds=True, env=env)
            else:
                subprocess.Popen(argv, shell=False, close_fds=True, env=env)
        except OSError as e:
            return SkillResult(ok=False, detail=f"lancement de VS Code impossible : {e}")
        return SkillResult(ok=True, detail=f"VS Code ouvert sur {path}", data={"exe": exe, "path": path})
