"""Skill : exécuter une commande de développement (Git, tests, scripts) — TRÈS sensible.

Sécurité (modèle « allowlist stricte par programme ») :
  - Programmes autorisés : git, npm, python/python3, node, pytest. Rien d'autre
    (pas de npx, pip, pnpm, yarn… qui permettent d'exécuter du code arbitraire).
  - Chaque programme n'accepte qu'un jeu fermé de sous-commandes/drapeaux :
      git    : status | diff | log | show | branch | add | commit | init
               (aucune option globale avant la sous-commande, jamais -c/--config…,
               ni --separate-git-dir / --template / --output, même abrégées ;
               `branch -D` / `--force` refusés ; `branch -d` = action L3 ;
               `init` : -q / -b <branche> / un dossier dans la whitelist)
      npm    : test | ci | install (sans argument) | run <script>
               (ci/install : --ignore-scripts ajouté d'office, sauf
               "allow_scripts": true → confirmation L3)
      python : <script.py> [args…]   (aucune option d'interpréteur : -c/-m/-r…)
      node   : <script.js|.mjs|.cjs> [args…] (aucune option : -e/--eval/-r/--require/--import…)
      pytest : [chemins de tests] + options de lecture (-q -v -x -k …)
  - `cwd` OBLIGATOIRE, dans la liste blanche de dossiers (hors deny-list).
  - Tout argument ressemblant à un chemin (absolu, contenant `..` ou un séparateur)
    doit se résoudre dans la liste blanche (relatif => résolu depuis `cwd`), et
    aucun argument ne peut viser un .env, une clé ou un dossier .git.
  - git est TOUJOURS lancé avec `-c core.hooksPath=/dev/null -c core.fsmonitor=false
    -c safe.bareRepository=explicit` : aucun hook (même planté auparavant), aucun
    fsmonitor, aucun dépôt nu implicite ne peut exécuter de code.
  - Arguments passés en liste (jamais de shell), exécutable résolu en chemin absolu
    (jamais le raccourci Microsoft Store « WindowsApps » de python/python3).
  - Délai borné : au-delà (ou sur stop / Ctrl+C), TOUT l'arbre de processus est
    tué (Job Object Windows + taskkill /T). Sortie tronquée.
  - Le gate exige TOUJOURS une confirmation interactive, même en mode auto ; elle
    affiche la commande complète, le cwd et le contenu exécuté (script npm,
    début du fichier python/node, conftest.py de pytest).

Exemple : {"type": "run_command", "program": "git", "args": ["status"], "cwd": "C:/projets/app"}
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys

from skills.base import PathCheck, Skill, SkillResult, current_token
from skills.proctree import run_tree
from skills.safety import denied_name

ALLOWED_PROGRAMS = ("git", "npm", "python", "python3", "node", "pytest")

GIT_SUBCOMMANDS = frozenset({"status", "diff", "log", "show", "branch", "add", "commit", "init"})
# Options git refusées partout (préfixe) : config arbitraire (core.sshCommand,
# core.pager, alias…), changement de dépôt/exécutables, programmes distants.
_GIT_FORBIDDEN_PREFIXES = (
    "-c", "-C", "--config", "--exec-path", "--git-dir", "--work-tree", "--namespace",
    "--upload-pack", "--receive-pack", "--exec", "--super-prefix", "--attr-source",
)
# Options longues refusées y compris ABRÉGÉES (git accepte tout préfixe non ambigu :
# `--sep=x` vaut `--separate-git-dir=x`).
_GIT_FORBIDDEN_LONG = (
    "--separate-git-dir", "--template", "--output", "--exec-path", "--git-dir", "--work-tree",
    "--upload-pack", "--receive-pack", "--exec", "--config-env", "--namespace", "--super-prefix",
    "--attr-source",
)
# Options de git init acceptées (le reste — --bare, --shared, --template… — est refusé).
_GIT_INIT_FLAGS = frozenset({"-q", "--quiet"})
_GIT_INIT_VALUE_FLAGS = frozenset({"-b", "--initial-branch"})
# Valeurs d'options git qui ne sont PAS des chemins (messages, formats…).
_GIT_VALUE_FLAGS = frozenset({
    "-m", "--message", "-n", "--max-count", "--author", "--date", "--format", "--pretty",
    "-b", "--initial-branch", "--since", "--until", "--grep",
})
# Durcissement appliqué à CHAQUE commande git lancée par l'agent (S2).
GIT_HARDENING = (
    "-c", "core.hooksPath=/dev/null",
    "-c", "core.fsmonitor=false",
    "-c", "safe.bareRepository=explicit",
)

NPM_SIMPLE = frozenset({"test", "ci", "install"})
_NPM_INSTALLS = frozenset({"ci", "install"})
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
_HEAD_LINES = 20
_HEAD_CHARS = 1500

_DRIVE_RE = re.compile(r"^[A-Za-z]:")
_IS_WIN = sys.platform == "win32"


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
            return f"chemin hors liste blanche ou interdit dans les arguments : {arg}"
    return None


def _has_prefix(arg: str, prefixes: tuple[str, ...]) -> str | None:
    for p in prefixes:
        if arg.startswith(p):
            return p
    return None


def _forbidden_long(arg: str) -> str | None:
    """Option longue interdite, y compris sous forme abrégée (`--sep`, `--templ=`)."""
    if not arg.startswith("--"):
        return None
    name = arg.split("=", 1)[0]
    if len(name) < 4:
        return None
    for opt in _GIT_FORBIDDEN_LONG:
        if name == opt or opt.startswith(name):
            return opt
    return None


def _git_positionals(args: list[str]) -> list[str]:
    """Arguments positionnels git (hors valeurs d'options comme le message -m)."""
    out: list[str] = []
    skip = False
    for a in args[1:]:
        if skip:
            skip = False
            continue
        if a == "--":
            continue
        if a.startswith("-"):
            if "=" not in a and a in _GIT_VALUE_FLAGS:
                skip = True
            continue
        out.append(a)
    return out


def _check_git_branch(args: list[str]) -> str | None:
    for a in args[1:]:
        if a in ("--force", "-D", "-M") or (a.startswith("--") and len(a) >= 5 and "--force".startswith(a)):
            return f"git branch : option refusée '{a}' (suppression/écrasement forcé interdit)"
        if re.fullmatch(r"-[A-Za-z]{2,}", a) and set(a[1:]) & {"D", "M", "f"}:
            return f"git branch : option refusée '{a}' (suppression/écrasement forcé interdit)"
        if a == "-f":
            return "git branch : option refusée '-f' (écrasement forcé interdit)"
    return None


def _check_git_init(args: list[str]) -> str | None:
    positional = 0
    i = 1
    while i < len(args):
        a = args[i]
        name = a.split("=", 1)[0]
        if a in _GIT_INIT_FLAGS:
            i += 1
            continue
        if name in _GIT_INIT_VALUE_FLAGS:
            if "=" in a:
                i += 1
            else:
                if i + 1 >= len(args):
                    return f"git init : valeur manquante pour {a}"
                i += 2
            continue
        if a.startswith("-"):
            return f"git init : option refusée '{a}' (autorisées : -q, -b <branche>, <dossier>)"
        positional += 1
        i += 1
    if positional > 1:
        return "git init : un seul dossier accepté"
    return None


def _check_git(args: list[str]) -> str | None:
    if not args:
        return "git : sous-commande requise"
    for a in args:
        if _has_prefix(a, _GIT_FORBIDDEN_PREFIXES) or _forbidden_long(a):
            return f"option git refusée : '{a}'"
    sub = args[0]
    if sub not in GIT_SUBCOMMANDS:
        return (
            f"sous-commande git non autorisée : '{sub}' "
            f"(autorisées : {', '.join(sorted(GIT_SUBCOMMANDS))})"
        )
    if sub == "branch":
        err = _check_git_branch(args)
        if err:
            return err
    if sub == "init":
        err = _check_git_init(args)
        if err:
            return err
    for a in _git_positionals(args):
        reason = denied_name(a.rsplit(":", 1)[-1])
        if reason:
            return f"argument git interdit ({reason}) : '{a}'"
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
        return f"cwd hors liste blanche ou interdit : {cwd}"

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


# --- Résolution de l'exécutable (T42) ---------------------------------------------
def is_store_stub(path: str) -> bool:
    """Raccourci « App Execution Alias » du Microsoft Store (WindowsApps) : ce n'est
    pas un interpréteur (il ouvre le Store ou échoue silencieusement)."""
    if not _IS_WIN:
        return False
    norm = os.path.normcase(os.path.abspath(path))
    if os.path.normcase(os.sep + os.path.join("microsoft", "windowsapps") + os.sep) in norm:
        return True
    try:
        return os.path.getsize(path) == 0
    except OSError:
        return True


def _candidates_for(prog: str) -> tuple[str, ...]:
    # python3 n'existe souvent que sous forme de raccourci Store sous Windows :
    # on accepte le vrai python.exe (et inversement).
    if prog == "python3":
        return ("python3", "python")
    if prog == "python":
        return ("python", "python3")
    return (prog,)


def _find_executable(prog: str) -> str | None:
    """Résout le programme dans le PATH en chemin absolu, SANS chercher dans le
    dossier courant (contrairement à shutil.which sous Windows) et sans jamais
    retenir le raccourci Microsoft Store (WindowsApps)."""
    if _IS_WIN:
        exts = (".cmd",) if prog == "npm" else (".exe",)
    else:
        exts = ("",)
    for name in _candidates_for(prog):
        for d in os.environ.get("PATH", "").split(os.pathsep):
            d = d.strip().strip('"')
            if not d or not os.path.isabs(d):
                continue
            for ext in exts:
                candidate = os.path.join(d, name + ext)
                if os.path.isfile(candidate) and not is_store_stub(candidate):
                    return candidate
    return None


def _missing_message(prog: str) -> str:
    if _IS_WIN and prog in ("python", "python3"):
        for d in os.environ.get("PATH", "").split(os.pathsep):
            d = d.strip().strip('"')
            for name in ("python.exe", "python3.exe"):
                c = os.path.join(d, name) if d else ""
                if c and os.path.isfile(c) and is_store_stub(c):
                    return (f"interpréteur Python introuvable : seul le raccourci Microsoft Store "
                            f"(WindowsApps) répond à « {prog} ». Installez Python depuis python.org "
                            f"ou désactivez l'alias d'exécution d'application.")
    return f"programme introuvable sur le système : {prog}"


# --- Ligne de commande effective et contenu affiché à la confirmation (S5) ---------
def _wants_scripts(step: dict) -> bool:
    return step.get("allow_scripts") is True


def effective_args(step: dict) -> list[str]:
    """Arguments réellement passés au programme (durcissements inclus)."""
    prog = str(step.get("program") or "").strip()
    args = [str(a) for a in (step.get("args") or [])]
    if prog == "git":
        return [*GIT_HARDENING, *args]
    if prog == "npm" and args and args[0] in _NPM_INSTALLS and not _wants_scripts(step):
        return [*args, "--ignore-scripts"]
    return args


def _file_head(path: str) -> str:
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as e:
        return f"(lecture impossible : {e})"
    digest = hashlib.sha256(raw).hexdigest()
    text = raw.decode("utf-8", errors="replace")
    lines = text.splitlines()
    shown = "\n".join(lines[:_HEAD_LINES])
    head = shown[:_HEAD_CHARS]
    more = "\n[… suite non affichée]" if len(lines) > _HEAD_LINES or len(shown) > _HEAD_CHARS else ""
    return f"{path} — {len(raw)} octets, sha256 {digest[:16]}…\n{head}{more}"


def _npm_context(step: dict, cwd: str, args: list[str]) -> list[str]:
    out: list[str] = []
    pkg = os.path.join(cwd, "package.json")
    try:
        with open(pkg, "r", encoding="utf-8") as f:
            scripts = json.load(f).get("scripts") or {}
    except (OSError, ValueError, AttributeError) as e:
        return [f"package.json illisible ou absent ({e.__class__.__name__}) dans {cwd}"]
    if not isinstance(scripts, dict):
        scripts = {}
    sub = args[0] if args else ""
    if sub in _NPM_INSTALLS:
        names = ("preinstall", "install", "postinstall", "prepare")
        if _wants_scripts(step):
            out.append("⚠ SCRIPTS D'INSTALLATION AUTORISÉS (action L3) : le code des dépendances "
                       "et les scripts ci-dessous s'exécuteront.")
        else:
            out.append("Scripts d'installation désactivés (--ignore-scripts ajouté).")
    else:
        target = "test" if sub == "test" else (args[1] if len(args) > 1 else "")
        names = (f"pre{target}", target, f"post{target}")
    for name in names:
        if name in scripts:
            out.append(f'  "{name}": {json.dumps(scripts[name], ensure_ascii=False)}')
    if sub not in _NPM_INSTALLS and not any(n in scripts for n in names):
        out.append("  (script introuvable dans package.json)")
    return out


def _pytest_context(cwd: str) -> list[str]:
    out: list[str] = []
    found: list[str] = []
    skip = {".git", "node_modules", ".venv", "venv", "__pycache__", ".tox"}
    base_depth = cwd.rstrip(os.sep).count(os.sep)
    for root, dirs, files in os.walk(cwd):
        dirs[:] = [d for d in dirs if d not in skip]
        if root.count(os.sep) - base_depth >= 4:
            dirs[:] = []
        if "conftest.py" in files:
            found.append(os.path.join(root, "conftest.py"))
        if len(found) >= 10:
            break
    for name in ("pytest.ini", "pyproject.toml", "setup.cfg", "tox.ini"):
        cfg = os.path.join(cwd, name)
        if os.path.isfile(cfg):
            try:
                with open(cfg, "r", encoding="utf-8", errors="replace") as f:
                    lines = [ln.rstrip() for ln in f if "addopts" in ln or "plugins" in ln or "-p " in ln]
            except OSError:
                lines = []
            out.append(f"Config pytest : {name}" + (f" — {'; '.join(lines[:5])}" if lines else ""))
    if found:
        out.append(f"{len(found)} conftest.py (code exécuté par pytest) :")
        for c in found:
            out.append(_file_head(c))
    else:
        out.append("Aucun conftest.py trouvé.")
    return out


def describe_command(step: dict) -> str:
    """Contenu complet affiché à la confirmation (console locale)."""
    prog = str(step.get("program") or "").strip()
    args = [str(a) for a in (step.get("args") or [])] if isinstance(step.get("args"), list) else []
    cwd = str(step.get("cwd") or "")
    exe = _find_executable(prog) if prog in ALLOWED_PROGRAMS else None
    argv = [exe or prog, *effective_args(step)]
    lines = [
        f"Commande complète : {json.dumps(argv, ensure_ascii=False)}",
        f"Dossier de travail (cwd) : {cwd}",
    ]
    if not exe:
        lines.append(f"⚠ {_missing_message(prog)}")
    try:
        if prog == "npm":
            lines.extend(_npm_context(step, cwd, args))
        elif prog in ("python", "python3", "node") and args:
            lines.append("Script exécuté :")
            lines.append(_file_head(os.path.join(cwd, args[0])))
        elif prog == "pytest":
            lines.extend(_pytest_context(cwd))
        elif prog == "git":
            lines.append("Hooks git, fsmonitor et dépôts nus implicites désactivés pour cette commande.")
            if args and args[0] == "branch" and any(a in ("-d", "--delete") for a in args):
                lines.append("⚠ Suppression de branche (action L3).")
    except Exception as e:  # noqa: BLE001
        lines.append(f"(contexte indisponible : {e})")
    return "\n".join(lines)


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

    def confirm_details(self, step: dict) -> str | None:
        return describe_command(step)

    def confirm_level(self, step: dict) -> int:
        prog = str(step.get("program") or "").strip()
        args = [str(a) for a in (step.get("args") or [])] if isinstance(step.get("args"), list) else []
        if prog == "npm" and args and args[0] in _NPM_INSTALLS and _wants_scripts(step):
            return 3
        if prog == "git" and args and args[0] == "branch" and any(a in ("-d", "--delete") for a in args[1:]):
            return 3
        return 2

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        allow = step.get("allow_scripts")
        if allow is not None and not isinstance(allow, bool):
            return "champ 'allow_scripts' invalide (booléen attendu)"
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
            return SkillResult(ok=False, detail=_missing_message(prog))

        try:
            proc = run_tree([exe, *effective_args(step)], cwd=cwd, timeout=timeout, cancel=current_token())
        except FileNotFoundError:
            return SkillResult(ok=False, detail=_missing_message(prog))
        except Exception as e:  # noqa: BLE001
            return SkillResult(ok=False, detail=f"échec exécution : {e}")

        out = proc.stdout[:_MAX_OUTPUT]
        err_out = proc.stderr[:_MAX_OUTPUT]
        data = {"returncode": proc.returncode, "stdout": out, "stderr": err_out}
        if proc.timed_out:
            return SkillResult(ok=False, detail=f"délai dépassé ({timeout:g} s) — arbre de processus arrêté",
                               data={**data, "timed_out": True})
        if proc.cancelled:
            return SkillResult(ok=False, detail="commande interrompue (arrêt demandé) — arbre de processus arrêté",
                               data={**data, "cancelled": True})
        ok = proc.returncode == 0
        detail = f"code={proc.returncode}"
        if out:
            detail += f" | stdout: {out.strip()[:500]}"
        if not ok and err_out:
            detail += f" | stderr: {err_out.strip()[:500]}"
        return SkillResult(ok=ok, detail=detail, data=data)
