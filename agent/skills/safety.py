"""Deny-list permanente et contrôle du workspace (S1, S2, contrat §14).

Indépendant du gate (aucun import de permissions.py) pour être utilisable par les
skills eux-mêmes (revalidation au moment de l'exécution).

Toujours refusé, même si le chemin est dans un dossier autorisé :
  - le code et la configuration de l'agent, et tout le dépôt SoulBah ;
  - les fichiers `.env` (`.env`, `*.env`, `.env.*`) ;
  - les dossiers `.ssh` / `.gnupg` et les clés privées (id_rsa*, *.pem, *.key…) ;
  - tout dossier `.git` (hooks inclus) et tout dossier qui EST un dépôt git
    (HEAD + objects/ + refs/ : dépôt nu, `--separate-git-dir`…).
"""
from __future__ import annotations

import fnmatch
import os

AGENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_KEY_PATTERNS = (
    "id_rsa*", "id_dsa*", "id_ecdsa*", "id_ed25519*",
    "*.pem", "*.key", "*.ppk", "*.p12", "*.pfx",
)
_SECRET_DIRS = frozenset({".ssh", ".gnupg"})


def _norm(path: str) -> str:
    return os.path.normcase(os.path.realpath(path))


def find_repo_root(start: str) -> str | None:
    """Premier dossier ancêtre (inclus) contenant un `.git` (dossier ou fichier)."""
    d = os.path.abspath(start)
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


REPO_ROOT = find_repo_root(AGENT_DIR)


def protected_roots() -> list[str]:
    """Dossiers protégés (normalisés) : l'agent et le dépôt SoulBah qui le contient."""
    roots = [_norm(AGENT_DIR)]
    if REPO_ROOT:
        roots.append(_norm(REPO_ROOT))
    return roots


def _inside(target: str, base: str) -> bool:
    return target == base or target.startswith(base.rstrip(os.sep) + os.sep)


def _is_git_dir(d: str) -> bool:
    try:
        return (
            os.path.isfile(os.path.join(d, "HEAD"))
            and os.path.isdir(os.path.join(d, "objects"))
            and os.path.isdir(os.path.join(d, "refs"))
        )
    except (OSError, ValueError):
        return False


def is_git_internal(path: str) -> bool:
    """True si le chemin (résolu) passe par un dossier `.git` ou se trouve dans un
    dossier qui est lui-même un dépôt git (dépôt nu, `--separate-git-dir`).
    Y écrire permettrait de planter un hook exécuté par un `git commit` autorisé."""
    try:
        resolved = os.path.realpath(path)
    except (OSError, ValueError):
        return True
    parts = os.path.normcase(resolved).replace("\\", "/").split("/")
    if ".git" in parts:
        return True
    d = resolved
    while True:
        if _is_git_dir(d):
            return True
        parent = os.path.dirname(d)
        if parent == d:
            return False
        d = parent


def denied_name(name: str) -> str | None:
    """Contrôle par NOM (sans accès disque) : composant `.git`/`.ssh`/`.gnupg`,
    fichier `.env`, clé privée. Sert aussi pour les arguments git « nus »
    (`git add .env`, `git show HEAD:.env`)."""
    lowered = [p for p in str(name).replace("\\", "/").lower().split("/") if p]
    if not lowered:
        return None
    if ".git" in lowered:
        return "dossier .git"
    if _SECRET_DIRS.intersection(lowered):
        return "dossier de clés (.ssh/.gnupg)"
    last = lowered[-1]
    if last == ".env" or last.endswith(".env") or last.startswith(".env."):
        return "fichier .env (secrets)"
    if any(fnmatch.fnmatchcase(last, pat) for pat in _KEY_PATTERNS):
        return "clé privée"
    return None


def deny_reason(path: str) -> str | None:
    """Raison du refus permanent d'un chemin, ou None s'il n'est pas dans la deny-list."""
    if not isinstance(path, str) or not path.strip() or "\x00" in path:
        return "chemin invalide"
    try:
        target = _norm(path)
    except (OSError, ValueError):
        return "chemin invalide"
    for root in protected_roots():
        if _inside(target, root):
            return "code/configuration de l'agent ou dépôt SoulBah"
    reason = denied_name(target)
    if reason:
        return reason
    if is_git_internal(path):
        return "données internes d'un dépôt git"
    return None


def workspace_errors(dirs: list[str]) -> list[str]:
    """Dossiers autorisés interdits : ceux qui contiennent le dossier de l'agent ou
    le dépôt SoulBah, ou qui se trouvent à l'intérieur du dépôt. Retourne la liste
    des erreurs (vide = configuration acceptable)."""
    errors: list[str] = []
    roots = [("le dossier de l'agent", _norm(AGENT_DIR))]
    if REPO_ROOT:
        roots.append(("le dépôt SoulBah", _norm(REPO_ROOT)))
    for d in dirs:
        try:
            n = _norm(d)
        except (OSError, ValueError):
            errors.append(f"dossier autorisé invalide : {d}")
            continue
        for label, root in roots:
            if _inside(root, n):
                errors.append(f"le dossier autorisé « {d} » contient {label} ({root})")
                break
            if _inside(n, root):
                errors.append(f"le dossier autorisé « {d} » est à l'intérieur de {label} ({root})")
                break
    return errors
