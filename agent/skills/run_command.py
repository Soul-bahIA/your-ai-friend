"""Skill : exécuter une commande de développement (Git, tests, scripts) — TRÈS sensible.

Sécurité (modèle « allowlist stricte par programme ») :
  - Programmes autorisés : git, npm, python/python3, node, pytest. Rien d'autre
    (pas de npx, pip, pnpm, yarn… qui permettent d'exécuter du code arbitraire).
  - Chaque programme n'accepte qu'un jeu fermé de sous-commandes/drapeaux :
      git    : status | diff | log | show | branch | add | commit | init
               (aucune option globale avant la sous-commande, jamais -c/--config…)
      npm    : test | ci | install (sans argument) | run <script>
      python : <script.py> [args…]   (aucune option d'interpréteur : -c/-m/-r…)
      node   : <script.js|.mjs|.cjs> [args…] (aucune option : -e/--eval/-r/--require/--import…)
      pytest : [chemins de tests] + options de lecture (-q -v -x -k …)
  - `cwd` OBLIGATOIRE, dans la liste blanche de dossiers.
  - Tout argument ressemblant à un chemin (absolu, contenant `..` ou un séparateur)
    doit se résoudre dans la liste blanche (relatif => résolu depuis `cwd`).
  - Arguments passés en liste (jamais de shell), exécutable résolu en chemin absolu.
  - Timeout borné, sortie tronquée.
  - Le gate exige TOUJOURS une confirmation interactive, même en mode auto.

Exemple : {"type": "run_command", "program": "git", "args": ["status"], "cwd": "C:/projets/app"}
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

from skills.base import PathCheck, Skill, SkillResult

ALLOWED_PROGRAMS = ("git", "npm", "python", "python3", "node", "pytest")

GIT_SUBCOMMANDS = frozenset({"status", "diff", "log", "show", "branch", "add", "commit", "init"})
# Options git refusées partout (préfixe) : config arbitraire (core.sshCommand,
# core.pager, alias…), changement de dépôt/exécutables, programmes distants.
_GIT_FORBIDDEN_PREFIXES = (
    "-c", "-C", "--config", "--exec-path", "--git-dir", "--work-tree", "--namespace",
    "--upload-pack", "--receive-pack", "--exec", "--super-prefix", "--attr-source",
)

NPM_SIMPLE = frozenset({"test", "ci", "install"})
_NPM_SCRIPT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._-]{0,63}$")

# Options d'interpréteur qui évaluent du code ou chargent des modules arbitraires.
# Refusées sous toutes leurs formes (exactes, collées `-cCODE`, avec `=`).
_INTERP_FORBIDDEN_PREFIXES = (
    "-c", "-e", "-m", "-r", "-p", "-i",
    "--eval", "--print", "--require", "--import", "--loader", "--experimental-loader",
    "--inspect", "--interactive",
)
_SCRIPT_EXT = {
    "python": (".py",),
    "python3": (".py",),
    "node": (".js", ".mjs", ".cjs"),
}

# pytest : options autorisées (exactes) et options à valeur.
_PYTEST_FLAGS = frozenset({
    "-q", "-qq", "-v", "-vv", "-x", "-s", "-l", "-rA", "-ra",
    "--lf", "--ff", "--co", "--collect-only", "--no-header", "--exitfirst",
    "--quiet", "--verbose", "--last-failed", "--failed-first",
})
_PYTEST_VALUE_FLAGS = frozenset({"-k", "--maxfail", "--tb", "--durations"})

# Caractères/opérateurs shell refusés dans tout argument (défense en profondeur :
# aucun shell n'est utilisé, mais npm passe par un .cmd sous Windows).
_SHELL_TOKENS = ("&&", "||", "|", ";", "`", "$(", ">", "<", "\n", "\r", "\x00")

_MAX_ARGS = 64
_MAX_ARG_LEN = 2000
_MAX_OUTPUT = 4000
_DEFAULT_TIMEOUT = 120
_MAX_TIMEOUT = 600

_DRIVE_RE = re.compile(r"^[A-Za-z]:")


def _looks_like_path(s: str) -> bool:
    return (
        os.path.isabs(s)
        or ".." in s
        or "/" in s
        or "\\" in s
        or bool(_DRIVE_RE.match(s))
        or s.startswith("~")
    )


def _path_candidates(arg: str) -> list[str]:
    """Valeurs de chemin potentielles portées par un argument : l'argument
    lui-même, la valeur après `=` (`--output=…`) et la valeur collée d'une option
    courte (`-F../x`)."""
    cands = [arg]
    if arg.startswith("-"):
        if "=" in arg:
            cands.append(arg.split("=", 1)[1])
        if not arg.startswith("--") and len(arg) > 2:
            cands.append(arg[2:])
    return [c for c in cands if c and _looks_like_path(c)]


def _check_path_arg(arg: str, cwd: str, path_allowed: PathCheck | None) -> str | None:
    for cand in _path_candidates(arg):
        if cand.startswith("~"):
            return f"chemin refusé (~ non autorisé) : {arg}"
        if path_allowed is None:
            continue
        resolved = os.path.join(cwd, cand)  # absolu => join retourne `cand`
        if not path_allowed(resolved):
            return f"chemin hors liste blanche dans les arguments : {arg}"
    return None


def _has_prefix(arg: str, prefixes: tuple[str, ...]) -> str | None:
    for p in prefixes:
        if arg.startswith(p):
            return p
    return None


def _check_git(args: list[str]) -> str | None:
    if not args:
        return "git : sous-commande requise"
    for a in args:
        p = _has_prefix(a, _GIT_FORBIDDEN_PREFIXES)
        if p:
            return f"option git refusée : '{a}'"
    sub = args[0]
    if sub not in GIT_SUBCOMMANDS:
        return (
            f"sous-commande git non autorisée : '{sub}' "
            f"(autorisées : {', '.join(sorted(GIT_SUBCOMMANDS))})"
        )
    return None


def _check_npm(args: list[str]) -> str | None:
    if not args:
        return "npm : sous-commande requise (test | ci | install | run <script>)"
    sub = args[0]
    if sub in NPM_SIMPLE:
        if len(args) != 1:
            return f"npm {sub} n'accepte aucun argument supplémentaire"
        return None
    if sub == "run":
        if len(args) != 2:
            return "npm run attend exactement un nom de script"
        if not _NPM_SCRIPT_RE.match(args[1]):
            return f"nom de script npm invalide : '{args[1]}'"
        return None
    return f"sous-commande npm non autorisée : '{sub}' (autorisées : test, ci, install, run <script>)"


def _check_interpreter(prog: str, args: list[str], cwd: str, path_allowed: PathCheck | None) -> str | None:
    for a in args:
        p = _has_prefix(a, _INTERP_FORBIDDEN_PREFIXES)
        if p:
            return f"drapeau refusé pour {prog} : '{a}' (évaluation/chargement de code arbitraire)"
    if not args:
        return f"{prog} : un fichier de script est requis"
    script = args[0]
    if script.startswith("-"):
        return f"{prog} : aucune option d'interpréteur autorisée (premier argument = script)"
    exts = _SCRIPT_EXT[prog]
    if not script.lower().endswith(exts):
        return f"{prog} : le script doit avoir l'extension {' / '.join(exts)}"
    if path_allowed is not None and not path_allowed(os.path.join(cwd, script)):
        return f"script hors liste blanche : {script}"
    return None


def _check_pytest(args: list[str], cwd: str, path_allowed: PathCheck | None) -> str | None:
    i = 0
    while i < len(args):
        a = args[i]
        if a.startswith("-"):
            if a in _PYTEST_FLAGS:
                i += 1
                continue
            name = a.split("=", 1)[0]
            if name in _PYTEST_VALUE_FLAGS:
                if "=" in a:
                    i += 1
                else:
                    if i + 1 >= len(args):
                        return f"pytest : valeur manquante pour {a}"
                    i += 2
                continue
            return f"option pytest non autorisée : '{a}'"
        # Argument positionnel = chemin de test, toujours vérifié contre la whitelist.
        if path_allowed is not None:
            target = a.split("::", 1)[0]
            if not path_allowed(os.path.join(cwd, target)):
                return f"chemin de test hors liste blanche : {a}"
        i += 1
    return None


def check_command(
    program: object,
    args: object,
    cwd: object,
    path_allowed: PathCheck | None = None,
) -> str | None:
    """Valide une commande. Retourne un message d'erreur (refus) ou None.

    `path_allowed` (fourni par le gate) active les contrôles de whitelist ;
    s'il vaut None, seuls les contrôles structurels sont faits."""
    prog = str(program or "").strip()
    if not prog:
        return "champ 'program' manquant"
    if prog not in ALLOWED_PROGRAMS:
        return f"programme non autorisé : '{prog}' (allowlist : {', '.join(ALLOWED_PROGRAMS)})"

    if args is None:
        args = []
    if not isinstance(args, list):
        return "'args' doit être une liste"
    if len(args) > _MAX_ARGS:
        return f"trop d'arguments (max {_MAX_ARGS})"
    str_args: list[str] = []
    for a in args:
        if isinstance(a, bool) or not isinstance(a, (str, int, float)):
            return f"argument invalide (texte attendu) : {a!r}"
        s = str(a)
        if len(s) > _MAX_ARG_LEN:
            return "argument trop long"
        str_args.append(s)

    if not isinstance(cwd, str) or not cwd.strip():
        return "champ 'cwd' obligatoire (dossier de travail dans la liste blanche)"
    if path_allowed is not None and not path_allowed(cwd):
        return f"cwd hors liste blanche : {cwd}"

    for a in str_args:
        if any(tok in a for tok in _SHELL_TOKENS):
            return f"argument suspect refusé : {a}"

    if prog == "git":
        err = _check_git(str_args)
    elif prog == "npm":
        err = _check_npm(str_args)
    elif prog in ("python", "python3", "node"):
        err = _check_interpreter(prog, str_args, cwd, path_allowed)
    else:  # pytest
        err = _check_pytest(str_args, cwd, path_allowed)
    if err:
        return err

    for a in str_args:
        err = _check_path_arg(a, cwd, path_allowed)
        if err:
            return err
    return None


def _find_executable(prog: str) -> str | None:
    """Résout le programme dans le PATH en chemin absolu, SANS chercher dans le
    dossier courant (contrairement à shutil.which sous Windows)."""
    if sys.platform == "win32":
        exts = (".cmd",) if prog == "npm" else (".exe",)
    else:
        exts = ("",)
    for d in os.environ.get("PATH", "").split(os.pathsep):
        d = d.strip().strip('"')
        if not d or not os.path.isabs(d):
            continue
        for ext in exts:
            candidate = os.path.join(d, prog + ext)
            if os.path.isfile(candidate):
                return candidate
    return None


class RunCommandSkill(Skill):
    name = "run_command"
    step_types = ("run_command", "run_script", "shell")
    category = "shell"
    sensitive = True
    timeout_s = _MAX_TIMEOUT + 30

    def describe(self, step: dict) -> str:
        prog = step.get("program", "?")
        args = step.get("args") or []
        cwd = step.get("cwd")
        line = f"{prog} {' '.join(map(str, args)) if isinstance(args, list) else args}".strip()
        return f"exécuter « {line} »" + (f" dans {cwd}" if cwd else " (cwd manquant)")

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        return check_command(step.get("program"), step.get("args"), step.get("cwd"), path_allowed)

    def run(self, step: dict) -> SkillResult:
        # Revalidation structurelle (la whitelist a été vérifiée par le gate).
        err = check_command(step.get("program"), step.get("args"), step.get("cwd"))
        if err:
            return SkillResult(ok=False, detail=err)

        prog = str(step.get("program")).strip()
        args = [str(a) for a in (step.get("args") or [])]
        cwd = str(step.get("cwd"))
        if not os.path.isdir(cwd):
            return SkillResult(ok=False, detail=f"dossier de travail introuvable : {cwd}")
        if prog in ("python", "python3", "node") and not os.path.isfile(os.path.join(cwd, args[0])):
            return SkillResult(ok=False, detail=f"script introuvable : {args[0]}")

        try:
            timeout = float(step.get("timeout", _DEFAULT_TIMEOUT))
        except (TypeError, ValueError):
            timeout = _DEFAULT_TIMEOUT
        timeout = max(1.0, min(timeout, _MAX_TIMEOUT))

        exe = _find_executable(prog)
        if not exe:
            return SkillResult(ok=False, detail=f"programme introuvable sur le système : {prog}")

        try:
            proc = subprocess.run(
                [exe, *args],
                cwd=cwd,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
                shell=False,
                stdin=subprocess.DEVNULL,
            )
        except FileNotFoundError:
            return SkillResult(ok=False, detail=f"programme introuvable sur le système : {prog}")
        except subprocess.TimeoutExpired:
            return SkillResult(ok=False, detail=f"délai dépassé ({timeout}s)")
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec exécution : {e}")

        out = (proc.stdout or "")[:_MAX_OUTPUT]
        err_out = (proc.stderr or "")[:_MAX_OUTPUT]
        ok = proc.returncode == 0
        detail = f"code={proc.returncode}"
        if out:
            detail += f" | stdout: {out.strip()[:500]}"
        if not ok and err_out:
            detail += f" | stderr: {err_out.strip()[:500]}"
        return SkillResult(ok=ok, detail=detail, data={"returncode": proc.returncode, "stdout": out, "stderr": err_out})
