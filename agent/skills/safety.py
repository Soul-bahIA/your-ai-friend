r"""Deny-list permanente et contrôle du workspace (S1, S2, contrat §14).

Indépendant du gate (aucun import de permissions.py) pour être utilisable par les
skills eux-mêmes (revalidation au moment de l'exécution).

Toujours refusé, même si le chemin est dans un dossier autorisé :
  - le code et la configuration de l'agent, et tout le dépôt SoulBah ;
  - les fichiers `.env` (`.env`, `*.env`, `.env.*`) ;
  - les dossiers `.ssh` / `.gnupg` et les clés privées (id_rsa*, *.pem, *.key…) ;
  - tout dossier `.git` (hooks inclus) et tout dossier qui EST un dépôt git
    (HEAD + objects/ + refs/ : dépôt nu, `--separate-git-dir`…).

Les noms sont comparés tels que Windows les CRÉERA : realpath ne canonicalise
pas un chemin qui n'existe pas encore, or Windows retire les points et espaces
finaux (`a.env.`, `a.env ` → `a.env`) et un flux NTFS désigne le fichier ou le
dossier de base (`a.env::$DATA`, `a.env:flux`, `.git::$INDEX_ALLOCATION`).
Les formes longues (préfixes `\\?\` et `\\.\`) et les autres alias d'un même
dossier (partage UNC `\\localhost\c$\…`) ne contournent pas non plus la
protection de l'agent et du dépôt : elle compare aussi l'identité disque
(volume + numéro de fichier) des dossiers existants.
"""
from __future__ import annotations

import fnmatch
import os
from typing import Iterator

AGENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_KEY_PATTERNS = (
    "id_rsa*", "id_dsa*", "id_ecdsa*", "id_ed25519*",
    "*.pem", "*.key", "*.ppk", "*.p12", "*.pfx",
)
_SECRET_DIRS = frozenset({".ssh", ".gnupg"})

_BS = "\\"
_UNC_EXT_PREFIX = _BS * 2 + "?" + _BS + "UNC" + _BS  # \\?\UNC\
_EXT_PREFIXES = (_BS * 2 + "?" + _BS, _BS * 2 + "." + _BS)  # \\?\  \\.\


def strip_ext_prefix(path: str) -> str:
    r"""`\\?\C:\x` ou `\\.\C:\x` → `C:\x` ; `\\?\UNC\srv\x` → `\\srv\x` (Windows).

    realpath conserve le préfixe long qu'on lui donne : sans ce retrait, une
    comparaison de préfixes ne reconnaîtrait plus le dossier de l'agent."""
    if os.name != "nt" or not isinstance(path, str):
        return path
    if path[:8].upper() == _UNC_EXT_PREFIX:
        return _BS * 2 + path[8:]
    for prefix in _EXT_PREFIXES:
        if path.startswith(prefix):
            rest = path[len(prefix):]
            if len(rest) >= 2 and rest[1] == ":":
                return rest
    return path


def canonical_path(path: str) -> str:
    """Forme de comparaison d'un chemin : realpath (liens, jonctions, noms courts
    des chemins existants), préfixe long retiré, casse normalisée sous Windows."""
    return os.path.normcase(strip_ext_prefix(os.path.realpath(path)))


def _norm(path: str) -> str:
    return canonical_path(path)


def _identity(path: str | None) -> tuple[int, int] | None:
    """(volume, numéro de fichier) d'un chemin existant : identique quel que soit
    l'alias employé (UNC, préfixe long, nom court) ; None si indisponible."""
    if not path:
        return None
    try:
        st = os.stat(path)
    except (OSError, ValueError):
        return None
    if not st.st_ino:
        return None
    return (st.st_dev, st.st_ino)


def _self_and_parents(path: str) -> Iterator[str]:
    d = path
    while True:
        yield d
        parent = os.path.dirname(d)
        if not parent or parent == d:
            return
        d = parent


def _has_ancestor_identity(path: str, identities: set[tuple[int, int]]) -> bool:
    """True si `path` ou l'un de ses dossiers parents EXISTANTS a l'une des identités."""
    if not identities:
        return False
    for d in _self_and_parents(path):
        ident = _identity(d)
        if ident is not None and ident in identities:
            return True
    return False


def windows_name_variants(part: str) -> set[str]:
    """Un composant de chemin tel qu'écrit ET tel que Windows le créera : flux
    NTFS retiré (`nom:flux`, `nom::$DATA` → `nom`), points et espaces finaux
    supprimés (`nom.env. ` → `nom.env`). Comparer toutes les variantes ne fait
    qu'ajouter des refus : un nom ordinaire n'a qu'une variante, lui-même."""
    variants = {part}
    for v in (part, part.split(":", 1)[0]):
        variants.add(v)
        variants.add(v.rstrip(". "))
    return {v for v in variants if v}


def _components(path: str) -> list[set[str]]:
    parts = [p for p in str(path).replace(_BS, "/").lower().split("/") if p]
    return [windows_name_variants(p) for p in parts]


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


def _protected_identities() -> set[tuple[int, int]]:
    ids: set[tuple[int, int]] = set()
    for root in (AGENT_DIR, REPO_ROOT):
        ident = _identity(root)
        if ident is not None:
            ids.add(ident)
    return ids


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
    """True si le chemin (résolu) passe par un dossier `.git` (variantes Windows
    comprises : `.git.`, `.git::$INDEX_ALLOCATION`) ou se trouve dans un dossier
    qui est lui-même un dépôt git (dépôt nu, `--separate-git-dir`).
    Y écrire permettrait de planter un hook exécuté par un `git commit` autorisé."""
    try:
        resolved = os.path.realpath(path)
    except (OSError, ValueError):
        return True
    if any(".git" in names for names in _components(resolved)):
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
    (`git add .env`, `git show HEAD:.env`).

    Chaque composant est comparé sous toutes ses variantes Windows
    (windows_name_variants) : `a.env `, `a.env.`, `a.env::$DATA`, `.ssh.` ou
    `.git::$INDEX_ALLOCATION` créeraient `a.env`, `.ssh` ou `.git`."""
    components = _components(name)
    if not components:
        return None
    if any(".git" in names for names in components):
        return "dossier .git"
    if any(_SECRET_DIRS & names for names in components):
        return "dossier de clés (.ssh/.gnupg)"
    last_names = components[-1]
    if any(last == ".env" or last.endswith(".env") or last.startswith(".env.") for last in last_names):
        return "fichier .env (secrets)"
    if any(fnmatch.fnmatchcase(last, pat) for last in last_names for pat in _KEY_PATTERNS):
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
    # Autre écriture du même dossier (partage UNC…) : comparaison par identité disque.
    if _has_ancestor_identity(target, _protected_identities()):
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
    des erreurs (vide = configuration acceptable). Les comparaisons sont textuelles
    (chemins canoniques) ET par identité disque (alias UNC, préfixe long…)."""
    errors: list[str] = []
    roots = [("le dossier de l'agent", AGENT_DIR)]
    if REPO_ROOT:
        roots.append(("le dépôt SoulBah", REPO_ROOT))
    for d in dirs:
        try:
            n = _norm(d)
        except (OSError, ValueError):
            errors.append(f"dossier autorisé invalide : {d}")
            continue
        own_id = _identity(n)
        for label, raw_root in roots:
            root = _norm(raw_root)
            root_id = _identity(raw_root)
            if _inside(root, n) or (own_id is not None and _has_ancestor_identity(root, {own_id})):
                errors.append(f"le dossier autorisé « {d} » contient {label} ({root})")
                break
            if _inside(n, root) or (root_id is not None and _has_ancestor_identity(n, {root_id})):
                errors.append(f"le dossier autorisé « {d} » est à l'intérieur de {label} ({root})")
                break
    return errors
