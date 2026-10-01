"""Espaces de travail git pour le rôle codeur (LOT 12, audit §9.7, §9.10).

Chaque tâche de code travaille dans SA worktree, sur la branche `soulbah/<session>/<tâche>` ;
les fusions vont vers `soulbah/<session>/integration`, jamais vers une branche de l'utilisateur.

  git_worktree       (L1) crée / retire la worktree d'une tâche (idempotent)
  git_commit         (L1) git add -A puis commit dans la worktree (rien à valider = succès)
  git_merge          (L2) fusionne une branche de tâche dans la branche d'intégration, DANS la
                          worktree d'intégration, puis lance les tests : rouges → fusion annulée
                          (reset sur l'état d'avant), conflit → fusion abandonnée
  git_branch_delete  (L3) suppression d'une branche Soulbah (toujours confirmée, mot « confirmer »)
  git_push           (L3) push d'une branche Soulbah, jamais forcé (toujours confirmé)

Sécurité : git est toujours lancé SANS shell avec le durcissement de run_command (hooks
désactivés, fsmonitor coupé, dépôts nus refusés) ; noms de branches contraints aux espaces
Soulbah ; tout chemin (dépôt, worktree) dans les dossiers autorisés et hors deny-list (gate) ;
l'identité de commit par défaut est « SoulBah Agent » si le dépôt n'en a pas.
"""
from __future__ import annotations

import os
import re
import threading
import time
from typing import Any

from skills.base import PathCheck, Skill, SkillResult, current_token
from skills.manifests import declared_param_error
from skills.proctree import ProcResult, run_tree
from skills.run_command import GIT_HARDENING, _find_executable, check_command, effective_args

TASK_BRANCH_RE = re.compile(r"^soulbah/[a-z0-9][a-z0-9_-]{0,63}/[a-z0-9][a-z0-9_.-]{0,63}$")
INTEGRATION_RE = re.compile(r"^soulbah/[a-z0-9][a-z0-9_-]{0,63}/integration$")
REF_RE = re.compile(r"^(?!-)[A-Za-z0-9_./-]{1,200}$")
REMOTE_RE = re.compile(r"^(?!-)[A-Za-z0-9_.-]{1,64}$")
IDENTITY = ("-c", "user.name=SoulBah Agent", "-c", "user.email=agent@soulbah.local")
_GIT_TIMEOUT = 120.0
_TEST_TIMEOUT = 600.0
_MERGE_LOCK_WAIT = 120.0
_merge_locks: dict[str, threading.Lock] = {}
_merge_locks_guard = threading.Lock()


def git(args: list[str], cwd: str, timeout: float = _GIT_TIMEOUT, identity: bool = False) -> ProcResult | None:
    """Lance git durci (None si git est introuvable)."""
    exe = _find_executable("git")
    if not exe:
        return None
    argv = [exe, *GIT_HARDENING, *(IDENTITY if identity else ()), *args]
    return run_tree(argv, cwd=cwd, timeout=timeout, cancel=current_token())


def _out(p: ProcResult | None) -> str:
    return (p.stdout or "").strip() if p else ""


def _err(p: ProcResult | None, what: str) -> str:
    if p is None:
        return "git introuvable dans le PATH"
    msg = (p.stderr or p.stdout or "").strip().splitlines()
    return f"{what} : {msg[-1][:300] if msg else f'code {p.returncode}'}"


def head_sha(cwd: str) -> str | None:
    p = git(["rev-parse", "HEAD"], cwd)
    return _out(p) if p and p.returncode == 0 else None


def branch_exists(repo: str, branch: str) -> bool:
    p = git(["rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"], repo)
    return bool(p and p.returncode == 0)


def worktree_branch(path: str) -> str | None:
    """Branche extraite dans la worktree `path` (None si ce n'est pas une worktree git)."""
    if not os.path.isdir(path):
        return None
    p = git(["rev-parse", "--abbrev-ref", "HEAD"], path)
    return _out(p) if p and p.returncode == 0 else None


def _check_paths(step: dict, path_allowed: PathCheck, *keys: str) -> str | None:
    for k in keys:
        v = step.get(k)
        if not isinstance(v, str) or not v.strip():
            return f"champ '{k}' requis (chemin absolu)"
        if not os.path.isabs(v):
            return f"champ '{k}' : chemin absolu attendu"
        if not path_allowed(v):
            return f"champ '{k}' hors des dossiers autorisés : {v}"
    return None


class GitWorktreeSkill(Skill):
    name = "git_worktree"
    step_types = ("git_worktree",)
    category = "git"
    timeout_s = 120.0

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        declared = declared_param_error(step)
        if declared:
            return declared
        err = _check_paths(step, path_allowed, "repo", "path")
        if err:
            return err
        branch = step.get("branch")
        if not isinstance(branch, str) or not (TASK_BRANCH_RE.match(branch) or INTEGRATION_RE.match(branch)):
            return "champ 'branch' : branche soulbah/<session>/<tâche> attendue"
        action = step.get("action", "create")
        if action not in ("create", "remove"):
            return "champ 'action' : create | remove"
        base = step.get("base")
        if base is not None and (not isinstance(base, str) or not REF_RE.match(base)):
            return "champ 'base' : référence git invalide"
        return None

    def run(self, step: dict) -> SkillResult:
        repo, path, branch = str(step["repo"]), str(step["path"]), str(step["branch"])
        if not os.path.isdir(repo):
            return SkillResult(ok=False, detail=f"dépôt introuvable : {repo}")
        if step.get("action", "create") == "remove":
            if not os.path.isdir(path):
                return SkillResult(ok=True, detail=f"worktree déjà absente : {path}", data={"path": path, "branch": branch})
            p = git(["worktree", "remove", path], repo)
            if not p or p.returncode != 0:
                return SkillResult(ok=False, detail=_err(p, "retrait de la worktree refusé (modifications non validées ?)"))
            return SkillResult(ok=True, detail=f"worktree retirée : {path}", data={"path": path, "branch": branch})
        current = worktree_branch(path)
        if current == branch:
            return SkillResult(ok=True, detail=f"worktree déjà prête sur {branch}", data={"path": path, "branch": branch, "head": head_sha(path)})
        if os.path.exists(path) and os.listdir(path):
            return SkillResult(ok=False, detail=f"le dossier de worktree existe déjà et n'est pas vide : {path}")
        if branch_exists(repo, branch):
            p = git(["worktree", "add", path, branch], repo)
        else:
            p = git(["worktree", "add", "-b", branch, path, str(step.get("base") or "HEAD")], repo)
        if not p or p.returncode != 0:
            return SkillResult(ok=False, detail=_err(p, "création de la worktree impossible"))
        return SkillResult(ok=True, detail=f"worktree {branch} → {path}", data={"path": path, "branch": branch, "head": head_sha(path)})


class GitCommitSkill(Skill):
    name = "git_commit"
    step_types = ("git_commit",)
    category = "git"
    timeout_s = 120.0

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        declared = declared_param_error(step)
        if declared:
            return declared
        err = _check_paths(step, path_allowed, "cwd")
        if err:
            return err
        msg = step.get("message")
        if not isinstance(msg, str) or not msg.strip() or len(msg) > 500:
            return "champ 'message' requis (1–500 caractères)"
        return None

    def run(self, step: dict) -> SkillResult:
        cwd = str(step["cwd"])
        branch = worktree_branch(cwd)
        if branch is None:
            return SkillResult(ok=False, detail=f"pas une worktree git : {cwd}")
        if not (TASK_BRANCH_RE.match(branch) or INTEGRATION_RE.match(branch)):
            return SkillResult(ok=False, detail=f"commit refusé hors d'une branche Soulbah (branche courante : {branch})")
        if step.get("add_all", True):
            p = git(["add", "-A"], cwd)
            if not p or p.returncode != 0:
                return SkillResult(ok=False, detail=_err(p, "git add impossible"))
        status = git(["status", "--porcelain"], cwd)
        if status and status.returncode == 0 and not _out(status):
            return SkillResult(ok=True, detail="rien à valider", data={"returncode": 0, "stdout": "", "sha": head_sha(cwd), "branch": branch})
        p = git(["commit", "-q", "-m", str(step["message"]).strip()], cwd, identity=True)
        if not p or p.returncode != 0:
            return SkillResult(ok=False, detail=_err(p, "commit impossible"), data={"returncode": p.returncode if p else -1})
        sha = head_sha(cwd)
        # La sortie porte branche, commit et message : preuve du critère git_branch_contains.
        stdout = f"{branch} {sha} {str(step['message']).strip()[:500]}"
        return SkillResult(ok=True, detail=f"commit {str(sha)[:10]} sur {branch}",
                           data={"returncode": 0, "stdout": stdout, "sha": sha, "branch": branch})


def _merge_lock(key: str) -> threading.Lock:
    with _merge_locks_guard:
        return _merge_locks.setdefault(os.path.normcase(os.path.abspath(key)), threading.Lock())


class _FileLock:
    """Verrou inter-processus (O_EXCL) de la worktree d'intégration : deux workers ne fusionnent
    jamais en même temps dans la même branche (le plan déclare aussi la ressource repo:…:ref)."""

    def __init__(self, path: str, wait_s: float):
        self.path = path
        self.wait_s = wait_s
        self.held = False

    def __enter__(self) -> "_FileLock":
        deadline = time.monotonic() + self.wait_s
        while True:
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(fd, str(os.getpid()).encode())
                os.close(fd)
                self.held = True
                return self
            except FileExistsError:
                try:
                    if time.time() - os.path.getmtime(self.path) > 3 * self.wait_s:
                        os.remove(self.path)  # verrou orphelin d'un processus tué
                        continue
                except OSError:
                    pass
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"fusion déjà en cours ({self.path})")
                time.sleep(0.1)

    def __exit__(self, *_exc: Any) -> None:
        if self.held:
            try:
                os.remove(self.path)
            except OSError:
                pass


class GitMergeSkill(Skill):
    name = "git_merge"
    step_types = ("git_merge",)
    category = "git"
    timeout_s = 900.0
    # Les tests lancés après la fusion exécutent le code du dépôt : comme run_command, la
    # fusion est TOUJOURS confirmée (console ou approbation dans l'app), même en mode auto.
    always_confirm = True

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        declared = declared_param_error(step)
        if declared:
            return declared
        err = _check_paths(step, path_allowed, "repo", "path")
        if err:
            return err
        if not isinstance(step.get("source"), str) or not TASK_BRANCH_RE.match(step["source"]) or INTEGRATION_RE.match(step["source"]):
            return "champ 'source' : branche de tâche soulbah/<session>/<tâche> attendue"
        if not isinstance(step.get("target"), str) or not INTEGRATION_RE.match(step["target"]):
            return "champ 'target' : branche d'intégration soulbah/<session>/integration attendue"
        if step["source"].rsplit("/", 1)[0] != step["target"].rsplit("/", 1)[0]:
            return "source et target doivent appartenir à la même session"
        prog = step.get("test_program")
        if prog is not None:
            err = check_command(prog, step.get("test_args") or [], step.get("path"), path_allowed)
            if err:
                return f"commande de tests refusée : {err}"
        return None

    def run(self, step: dict) -> SkillResult:
        repo, path = str(step["repo"]), str(step["path"])
        source, target = str(step["source"]), str(step["target"])
        if not branch_exists(repo, source):
            return SkillResult(ok=False, detail=f"branche source inconnue : {source}")
        if not branch_exists(repo, target):
            p = git(["branch", target, str(step.get("base") or "HEAD")], repo)
            if not p or p.returncode != 0:
                return SkillResult(ok=False, detail=_err(p, "création de la branche d'intégration impossible"))
        with _merge_lock(path):
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
            try:
                with _FileLock(os.path.abspath(path).rstrip("\\/") + ".soulbah-merge.lock", _MERGE_LOCK_WAIT):
                    return self._merge_locked(repo, path, source, target, step)
            except TimeoutError as e:
                return SkillResult(ok=False, detail=str(e))

    def _merge_locked(self, repo: str, path: str, source: str, target: str, step: dict) -> SkillResult:
        current = worktree_branch(path)
        if current is None:
            if os.path.exists(path) and os.listdir(path):
                return SkillResult(ok=False, detail=f"le dossier d'intégration existe et n'est pas une worktree : {path}")
            p = git(["worktree", "add", path, target], repo)
            if not p or p.returncode != 0:
                return SkillResult(ok=False, detail=_err(p, "worktree d'intégration impossible"))
        elif current != target:
            return SkillResult(ok=False, detail=f"la worktree d'intégration est sur {current}, pas sur {target}")
        dirty = git(["status", "--porcelain"], path)
        if dirty and _out(dirty):
            return SkillResult(ok=False, detail="worktree d'intégration modifiée hors fusion : fusion refusée")
        before = head_sha(path)
        p = git(["merge", "--no-ff", "--no-edit", source], path, identity=True)
        if not p or p.returncode != 0:
            git(["merge", "--abort"], path)
            return SkillResult(ok=False, detail=f"conflit de fusion {source} → {target} : fusion abandonnée",
                               data={"returncode": p.returncode if p else -1, "stdout": _out(p)[:2000], "conflict": True})
        merged = head_sha(path)
        data: dict[str, Any] = {"merge_sha": merged, "before_sha": before, "path": path, "source": source,
                                "target": target, "summary": f"{target} {merged} ← {source}"}
        prog = step.get("test_program")
        if prog:
            exe = _find_executable(str(prog))
            if not exe:
                self._undo(path, before)
                return SkillResult(ok=False, detail=f"programme de tests introuvable : {prog} — fusion annulée", data=data)
            t = run_tree([exe, *effective_args({"program": prog, "args": step.get("test_args") or []})], cwd=path,
                         timeout=min(max(float(step.get("test_timeout") or _TEST_TIMEOUT), 1.0), _TEST_TIMEOUT), cancel=current_token())
            passed = t.returncode == 0 and not t.timed_out and not t.cancelled
            data.update(returncode=t.returncode, stdout=(t.stdout or "")[-4000:], stderr=(t.stderr or "")[-4000:],
                        test_report={"passed": passed, "returncode": t.returncode, "program": str(prog),
                                     "args": [str(a) for a in step.get("test_args") or []], "merge_sha": merged})
            if not passed:
                self._undo(path, before)
                why = "délai dépassé" if t.timed_out else ("interrompus" if t.cancelled else f"code {t.returncode}")
                return SkillResult(ok=False, detail=f"tests rouges après fusion ({why}) : {target} remise à {str(before)[:10]}", data=data)
        else:
            data.update(returncode=0, stdout="")
        return SkillResult(ok=True, detail=f"{source} fusionnée dans {target} ({str(merged)[:10]}){', tests verts' if prog else ''}", data=data)

    @staticmethod
    def _undo(path: str, before: str | None) -> None:
        if before:
            git(["reset", "--hard", "-q", before], path)


class GitBranchDeleteSkill(Skill):
    name = "git_branch_delete"
    step_types = ("git_branch_delete",)
    category = "git"
    timeout_s = 60.0

    def confirm_level(self, step: dict) -> int:
        return 3

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        declared = declared_param_error(step)
        if declared:
            return declared
        err = _check_paths(step, path_allowed, "repo")
        if err:
            return err
        b = step.get("branch")
        if not isinstance(b, str) or not (TASK_BRANCH_RE.match(b) or INTEGRATION_RE.match(b)):
            return "champ 'branch' : seules les branches soulbah/… peuvent être supprimées"
        return None

    def describe(self, step: dict) -> str:
        return f"git_branch_delete: {step.get('branch')} ({'forcée' if step.get('force') else 'fusionnée seulement'})"

    def run(self, step: dict) -> SkillResult:
        p = git(["branch", "-D" if step.get("force") else "-d", str(step["branch"])], str(step["repo"]))
        if not p or p.returncode != 0:
            return SkillResult(ok=False, detail=_err(p, "suppression de branche refusée"))
        return SkillResult(ok=True, detail=f"branche supprimée : {step['branch']}", data={"returncode": 0, "stdout": _out(p)})


class GitPushSkill(Skill):
    name = "git_push"
    step_types = ("git_push",)
    category = "git"
    timeout_s = 300.0

    def confirm_level(self, step: dict) -> int:
        return 3

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        declared = declared_param_error(step)
        if declared:
            return declared
        err = _check_paths(step, path_allowed, "repo")
        if err:
            return err
        b = step.get("branch")
        if not isinstance(b, str) or not (TASK_BRANCH_RE.match(b) or INTEGRATION_RE.match(b)):
            return "champ 'branch' : seules les branches soulbah/… peuvent être poussées"
        remote = step.get("remote", "origin")
        if not isinstance(remote, str) or not REMOTE_RE.match(remote):
            return "champ 'remote' invalide"
        return None

    def describe(self, step: dict) -> str:
        return f"git_push: {step.get('branch')} → {step.get('remote', 'origin')} (jamais forcé)"

    def run(self, step: dict) -> SkillResult:
        p = git(["push", str(step.get("remote", "origin")), f"{step['branch']}:{step['branch']}"], str(step["repo"]), timeout=300)
        if not p or p.returncode != 0:
            return SkillResult(ok=False, detail=_err(p, "push refusé"), data={"returncode": p.returncode if p else -1})
        return SkillResult(ok=True, detail=f"poussée : {step['branch']}", data={"returncode": 0, "stdout": (p.stderr or "")[-2000:]})
