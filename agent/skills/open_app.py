"""Skill : ouvrir une application installée (sensible).

Sécurité : allowlist d'applications. Lancer un shell/hôte de script (cmd,
powershell, wscript…) permettrait de taper ensuite des commandes arbitraires
via type_text/hotkey — ce qui contournerait l'allowlist stricte de run_command.
Ces hôtes sont donc explicitement interdits, et seules les applis de l'allowlist
(par défaut + SOULBAH_ALLOWED_APPS) peuvent être lancées.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys

from skills.base import Skill, SkillResult

# Alias courants → commande réelle
APP_ALIASES = {
    "vscode": "code",
    "vs code": "code",
    "visual studio code": "code",
    "navigateur": "chrome",
    "chrome": "chrome",
    "explorateur": "explorer" if sys.platform == "win32" else "xdg-open",
}

# Hôtes de shell / script : jamais lançables. Les autoriser reviendrait à ouvrir
# une porte vers l'exécution de commandes arbitraires (hors allowlist run_command).
_BLOCKED_APPS = {
    "cmd", "cmd.exe", "command", "command.com",
    "powershell", "powershell.exe", "pwsh", "pwsh.exe",
    "wt", "wt.exe", "bash", "bash.exe", "sh", "zsh", "wsl", "wsl.exe",
    "wscript", "wscript.exe", "cscript", "cscript.exe",
    "mshta", "mshta.exe", "rundll32", "rundll32.exe",
    "reg", "reg.exe", "regedit", "regedit.exe",
    "conhost", "conhost.exe", "regsvr32", "regsvr32.exe",
}

# Applications autorisées par défaut. Extensible via SOULBAH_ALLOWED_APPS
# (noms séparés par des virgules). Comparaison sur le nom sans extension, insensible à la casse.
_DEFAULT_ALLOWED_APPS = {
    "notepad", "wordpad", "write", "notepad++",
    "code", "chrome", "firefox", "msedge", "iexplore", "opera", "brave",
    "explorer", "calc", "calculator", "mspaint", "snippingtool",
    "vlc", "spotify", "obs", "obs64", "audacity",
    "winword", "excel", "powerpnt", "onenote", "outlook", "acrobat", "acrord32",
    "teams", "slack", "discord", "zoom", "telegram", "whatsapp",
    "resolve",  # DaVinci Resolve
}


def _allowed_apps() -> set[str]:
    extra = {
        a.strip().lower()
        for a in os.environ.get("SOULBAH_ALLOWED_APPS", "").split(",")
        if a.strip()
    }
    return _DEFAULT_ALLOWED_APPS | extra


def _app_key(app: str) -> str:
    """Nom normalisé pour la comparaison : basename sans extension, en minuscules."""
    return os.path.splitext(os.path.basename(str(app)))[0].strip().lower()


class OpenAppSkill(Skill):
    name = "open_app"
    step_types = ("open_app", "open_software", "launch")
    category = "app_launch"
    sensitive = True

    def _resolve(self, step: dict) -> str:
        raw = step.get("app") or step.get("software") or step.get("name") or ""
        return APP_ALIASES.get(str(raw).lower(), str(raw))

    def describe(self, step: dict) -> str:
        return f"ouvrir l'application : {self._resolve(step)}"

    def run(self, step: dict) -> SkillResult:
        app = self._resolve(step)
        if not app:
            return SkillResult(ok=False, detail="aucune application spécifiée")

        key = _app_key(app)
        if key in _BLOCKED_APPS:
            return SkillResult(
                ok=False,
                detail=f"application interdite : '{app}' (shell/hôte de script — risque d'exécution arbitraire)",
            )
        allowed = _allowed_apps()
        if key not in allowed:
            return SkillResult(
                ok=False,
                detail=(
                    f"application non autorisée : '{app}'. "
                    f"Ajoutez-la via SOULBAH_ALLOWED_APPS. "
                    f"Allowlist actuelle : {', '.join(sorted(allowed))}"
                ),
            )

        try:
            exe = shutil.which(app)
            if exe:
                subprocess.Popen([exe])
            elif sys.platform == "win32":
                # Fallback Windows : `start` résout l'app par son nom. Pas d'injection
                # possible (argv en liste, shell=False) et l'app est déjà allowlistée.
                subprocess.Popen(["cmd", "/c", "start", "", app], shell=False)
            elif sys.platform == "darwin":
                subprocess.Popen(["open", "-a", app])
            else:
                subprocess.Popen([app])
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec ouverture '{app}' : {e}")

        return SkillResult(ok=True, detail=f"application lancée : {app}")
