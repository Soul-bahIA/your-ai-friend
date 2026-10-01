"""Skill : ouvrir une application installée (sensible).

Sécurité :
  - Allowlist d'applications (par défaut + SOULBAH_ALLOWED_APPS). Lancer un
    shell/hôte de script (cmd, powershell, wscript…) permettrait de taper ensuite
    des commandes arbitraires via type_text/hotkey — ce qui contournerait
    l'allowlist stricte de run_command. Ces hôtes sont donc explicitement interdits.
  - Le nom demandé est un NOM, jamais un chemin : tout séparateur, guillemet ou
    métacaractère shell (& | < > ^ % ! ( ) ; , retour à la ligne…) est refusé.
  - L'exécutable est résolu uniquement via une table nom → .exe connue, le PATH
    (nom exact + « .exe », sans le dossier courant) ou le registre « App Paths ».
    Le chemin résolu doit être absolu et finir par .exe (pas de .bat/.cmd).
  - Lancement direct de l'exe en liste d'arguments, shell=False, sans `cmd /c start`.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

from skills.base import PathCheck, Skill, SkillResult

# Alias courants → nom canonique de l'allowlist
APP_ALIASES = {
    "vscode": "code",
    "vs code": "code",
    "visual studio code": "code",
    "navigateur": "chrome",
    "google chrome": "chrome",
    "edge": "msedge",
    "explorateur": "explorer",
    "bloc-notes": "notepad",
    "calculatrice": "calc",
    "paint": "mspaint",
    "davinci resolve": "resolve",
    "davinci": "resolve",
    "word": "winword",
    "powerpoint": "powerpnt",
}

# Hôtes de shell / script : jamais lançables. Les autoriser reviendrait à ouvrir
# une porte vers l'exécution de commandes arbitraires (hors allowlist run_command).
_BLOCKED_APPS = frozenset({
    "cmd", "command", "powershell", "powershell_ise", "pwsh",
    "wt", "windowsterminal", "bash", "sh", "zsh", "wsl", "wslhost",
    "wscript", "cscript", "mshta", "rundll32", "reg", "regedit", "regsvr32",
    "conhost", "msiexec", "schtasks", "at", "certutil", "bitsadmin", "msbuild",
    "installutil", "forfiles", "pcalua", "hh", "control", "mmc", "cmstp",
    "python", "pythonw", "py", "node", "java", "javaw",
})

# Applications autorisées par défaut. Extensible via SOULBAH_ALLOWED_APPS
# (noms séparés par des virgules, sans chemin ni extension autre que .exe).
_DEFAULT_ALLOWED_APPS = frozenset({
    "notepad", "wordpad", "write", "notepad++",
    "code", "chrome", "firefox", "msedge", "iexplore", "opera", "brave",
    "explorer", "calc", "calculator", "mspaint", "snippingtool",
    "vlc", "spotify", "obs", "obs64", "audacity",
    "winword", "excel", "powerpnt", "onenote", "outlook", "acrobat", "acrord32",
    "teams", "slack", "discord", "zoom", "telegram", "whatsapp",
    "resolve",  # DaVinci Resolve
})

# Nom canonique : lettres/chiffres puis + . _ - uniquement.
_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9+._-]{0,63}$")
# Valeur brute : refuse séparateurs, guillemets, métacaractères shell et contrôles.
_FORBIDDEN_CHARS = set('\\/:"\'`&|<>^%!();,*?$[]{}=@#~') | {"\n", "\r", "\t", "\x00"}


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def _known_locations(key: str) -> list[str]:
    """Emplacements d'installation connus (Windows) pour les applis courantes,
    hors PATH (VS Code installe un `code.cmd` dans le PATH : on vise Code.exe)."""
    pf = _env("ProgramFiles", r"C:\Program Files")
    pf86 = _env("ProgramFiles(x86)", r"C:\Program Files (x86)")
    local = _env("LOCALAPPDATA")
    windir = _env("SystemRoot", r"C:\Windows")
    sys32 = os.path.join(windir, "System32")
    table: dict[str, list[str]] = {
        "code": [
            os.path.join(local, "Programs", "Microsoft VS Code", "Code.exe") if local else "",
            os.path.join(pf, "Microsoft VS Code", "Code.exe"),
        ],
        "chrome": [
            os.path.join(pf, "Google", "Chrome", "Application", "chrome.exe"),
            os.path.join(pf86, "Google", "Chrome", "Application", "chrome.exe"),
            os.path.join(local, "Google", "Chrome", "Application", "chrome.exe") if local else "",
        ],
        "firefox": [
            os.path.join(pf, "Mozilla Firefox", "firefox.exe"),
            os.path.join(pf86, "Mozilla Firefox", "firefox.exe"),
        ],
        "msedge": [
            os.path.join(pf86, "Microsoft", "Edge", "Application", "msedge.exe"),
            os.path.join(pf, "Microsoft", "Edge", "Application", "msedge.exe"),
        ],
        "explorer": [os.path.join(windir, "explorer.exe")],
        "notepad": [os.path.join(sys32, "notepad.exe")],
        "calc": [os.path.join(sys32, "calc.exe")],
        "calculator": [os.path.join(sys32, "calc.exe")],
        "mspaint": [os.path.join(sys32, "mspaint.exe")],
        "snippingtool": [os.path.join(sys32, "SnippingTool.exe")],
        "write": [os.path.join(sys32, "write.exe")],
        "wordpad": [os.path.join(pf, "Windows NT", "Accessories", "wordpad.exe")],
        "notepad++": [os.path.join(pf, "Notepad++", "notepad++.exe"), os.path.join(pf86, "Notepad++", "notepad++.exe")],
        "vlc": [os.path.join(pf, "VideoLAN", "VLC", "vlc.exe"), os.path.join(pf86, "VideoLAN", "VLC", "vlc.exe")],
        "obs": [os.path.join(pf, "obs-studio", "bin", "64bit", "obs64.exe")],
        "obs64": [os.path.join(pf, "obs-studio", "bin", "64bit", "obs64.exe")],
        "audacity": [os.path.join(pf, "Audacity", "Audacity.exe")],
        "resolve": [os.path.join(pf, "Blackmagic Design", "DaVinci Resolve", "Resolve.exe")],
    }
    return [p for p in table.get(key, []) if p]


def _allowed_apps() -> set[str]:
    extra = set()
    for a in _env("SOULBAH_ALLOWED_APPS").split(","):
        name = a.strip().lower()
        if name.endswith(".exe"):
            name = name[:-4]
        if name and _NAME_RE.match(name) and name not in _BLOCKED_APPS:
            extra.add(name)
    return set(_DEFAULT_ALLOWED_APPS) | extra


def validate_app_name(raw: object) -> tuple[str | None, str | None]:
    """Valide le nom demandé. Retourne (nom_canonique, None) ou (None, erreur)."""
    if not isinstance(raw, str) or not raw.strip():
        return None, "aucune application spécifiée"
    value = raw.strip()
    if len(value) > 64:
        return None, "nom d'application trop long"
    bad = sorted({c for c in value if c in _FORBIDDEN_CHARS or ord(c) < 32})
    if bad:
        return None, (
            f"nom d'application refusé : '{value}' — indiquez un nom simple "
            f"(ni chemin, ni guillemet, ni métacaractère)"
        )
    key = APP_ALIASES.get(value.lower(), value.lower())
    if key.endswith(".exe"):
        key = key[:-4]
    if not _NAME_RE.match(key):
        return None, f"nom d'application invalide : '{value}'"
    if key in _BLOCKED_APPS:
        return None, f"application interdite : '{value}' (shell/hôte de script — risque d'exécution arbitraire)"
    allowed = _allowed_apps()
    if key not in allowed:
        return None, (
            f"application non autorisée : '{value}'. Ajoutez-la via SOULBAH_ALLOWED_APPS. "
            f"Allowlist actuelle : {', '.join(sorted(allowed))}"
        )
    return key, None


def _from_path(key: str) -> str | None:
    """Recherche « <nom>.exe » dans le PATH (dossiers absolus uniquement, jamais le
    dossier courant ; extension .exe imposée : pas de .bat/.cmd via PATHEXT)."""
    filename = key + ".exe" if sys.platform == "win32" else key
    for d in _env("PATH").split(os.pathsep):
        d = d.strip().strip('"')
        if not d or not os.path.isabs(d):
            continue
        candidate = os.path.join(d, filename)
        if os.path.isfile(candidate):
            return candidate
    return None


def _from_app_paths(key: str) -> str | None:
    """Registre Windows « App Paths » (ce qu'utilise `start`), lu sans shell."""
    if sys.platform != "win32":
        return None
    try:
        import winreg
    except ImportError:
        return None
    sub = rf"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\{key}.exe"
    for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        try:
            with winreg.OpenKey(hive, sub) as k:
                value, _ = winreg.QueryValueEx(k, "")
        except OSError:
            continue
        if isinstance(value, str):
            value = os.path.expandvars(value.strip().strip('"'))
            if value:
                return value
    return None


def resolve_executable(key: str) -> str | None:
    """Résout le nom canonique (déjà validé) en chemin absolu vers un .exe."""
    candidates: list[str | None] = []
    if sys.platform == "win32":
        candidates.extend(_known_locations(key))
    candidates.append(_from_path(key))
    candidates.append(_from_app_paths(key))
    for c in candidates:
        if not c or not os.path.isabs(c) or not os.path.isfile(c):
            continue
        if sys.platform == "win32" and not c.lower().endswith(".exe"):
            continue
        stem = os.path.splitext(os.path.basename(c))[0].lower()
        if stem in _BLOCKED_APPS:
            continue
        return c
    return None


class OpenAppSkill(Skill):
    name = "open_app"
    step_types = ("open_app", "open_software", "launch")
    category = "app_launch"
    sensitive = True

    def _raw(self, step: dict) -> object:
        return step.get("app") or step.get("software") or step.get("name") or ""

    def describe(self, step: dict) -> str:
        return f"ouvrir l'application : {self._raw(step)}"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        _, err = validate_app_name(self._raw(step))
        return err

    def run(self, step: dict) -> SkillResult:
        key, err = validate_app_name(self._raw(step))
        if err or not key:
            return SkillResult(ok=False, detail=err or "aucune application spécifiée")

        exe = resolve_executable(key)
        try:
            if exe:
                subprocess.Popen([exe], shell=False, close_fds=True)
            elif sys.platform == "darwin":
                # Nom validé (aucun métacaractère), argv en liste : pas d'injection.
                subprocess.Popen(["open", "-a", key], shell=False)
            else:
                return SkillResult(ok=False, detail=f"application introuvable sur ce poste : '{key}'")
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec ouverture '{key}' : {e}")

        return SkillResult(ok=True, detail=f"application lancée : {key}", data={"exe": exe} if exe else None)
