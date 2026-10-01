"""LOT 1 — corrections issues de la vérification adverse (agent).

- §14/S1 : deny-list contournée à la CRÉATION par les noms que Windows normalise
  (`a.env `, `a.env.`, `a.env::$DATA`, `.ssh.`, `.git::$INDEX_ALLOCATION`) et par
  les formes longues / alias (`\\\\?\\C:\\…`, partage UNC) ;
- whitelist revérifiée par les skills de fichiers au moment d'agir (TOCTOU) ;
- S21 : payload.requires_confirmation (posé par le serveur) respecté par l'agent ;
- C§2/§13 : un stop pendant une confirmation console en attente est honoré ;
- C§2/§8 : évènement terminal `task_failed` sur échec, refus et délai dépassé ;
- C§2 : un final `cancelled` rejeté reste non évaluable (drapeau `cancelled`).

Aucune action réelle hors des dossiers temporaires des tests."""
from __future__ import annotations

import os
import sys
import threading
import time

import pytest

import executor as ex
import pending as pending_mod
import permissions
import soulbah_agent
from client import OK, REJECTED
from executor import Executor
from pending import PendingUpdates, minimal_failed_result
from permissions import SERVER_CONFIRM_STEP_TYPES, PermissionGate, normalize_dir, path_inside
from skills import REGISTRY
from skills.base import Skill, SkillResult, bind_path_refusal, path_refusal_now, sleep_or_cancel
from skills.filesystem import FileOpsSkill
from skills.hotkey import HotkeySkill
from skills.move_file import MoveFileSkill
from skills.phone import PhoneSkill
from skills.safety import (
    AGENT_DIR,
    REPO_ROOT,
    denied_name,
    deny_reason,
    strip_ext_prefix,
    windows_name_variants,
    workspace_errors,
)

WIN = sys.platform == "win32"
BS = "\\"
EXECUTIONS = {"n": 0}


class _Count(Skill):
    name = "verif_count"
    step_types = ("verif_count",)
    category = "generic"
    sensitive = False

    def run(self, step):
        EXECUTIONS["n"] += 1
        return SkillResult(ok=True, detail="exécuté")


class _Sensitive(_Count):
    """Action sensible (catégorie fichiers) : confirmée en mode « confirm »."""
    name = "verif_sensitive"
    step_types = ("verif_sensitive",)
    category = "filesystem"
    sensitive = True

    def describe(self, step):
        return "action sensible de test"


class _Wait(Skill):
    name = "verif_wait"
    step_types = ("verif_wait",)
    category = "generic"
    sensitive = False

    def run(self, step):
        if not sleep_or_cancel(float(step.get("seconds", 30))):
            return SkillResult(ok=False, detail="interrompu")
        return SkillResult(ok=True, detail="fini")


@pytest.fixture(autouse=True)
def _registry(monkeypatch):
    REGISTRY["verif_count"] = _Count()
    REGISTRY["verif_sensitive"] = _Sensitive()
    REGISTRY["verif_wait"] = _Wait()
    EXECUTIONS["n"] = 0
    monkeypatch.setattr(soulbah_agent, "_running", True)
    monkeypatch.setattr(soulbah_agent, "_interrupts", 0)
    monkeypatch.setattr(soulbah_agent, "_current_token", None)
    monkeypatch.setattr(pending_mod, "_BASE_DELAY", 0.0)
    monkeypatch.setattr(pending_mod, "_MAX_DELAY", 0.0)
    yield
    for k in ("verif_count", "verif_sensitive", "verif_wait"):
        REGISTRY.pop(k, None)
    bind_path_refusal(None)


@pytest.fixture()
def ws(tmp_path):
    root = tmp_path / "workspace"
    root.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    return root, outside


def _asker(monkeypatch, answer="n"):
    calls = []

    def fake(prompt, timeout, should_stop=None):
        calls.append(prompt)
        return answer

    monkeypatch.setattr(permissions, "_timed_input", fake)
    return calls


class Client:
    """Client minimal (claim/event/control/update) pour handle_task."""

    def __init__(self, control=lambda: "none", updates=None):
        self.control = control
        self.update_outcomes = list(updates or [])
        self.events, self.updates = [], []
        self.last_detail = "HTTP 400 — status invalide"

    def claim(self, task_id, attempt):
        return OK, "ok", None

    def event(self, task_id, type, message=None, data=None, attempt=0):
        self.events.append((type, message, data))
        return OK

    def get_control(self, task_id):
        return self.control()

    def update(self, task_id, status, result=None, error_message=None, attempt=0):
        self.updates.append((status, result, error_message))
        return self.update_outcomes.pop(0) if self.update_outcomes else OK


def _task(steps, **payload):
    return {"id": "task-verif", "task_type": "t", "requeue_count": 0, "payload": {"steps": steps, **payload}}


# =====================================================================================
# §14 / S1 — noms normalisés par Windows et formes longues
# =====================================================================================
@pytest.mark.parametrize("rel", [
    "planted.env ", "planted.env.", "planted.env. . ", "planted.env::$DATA", "planted.env:$DATA",
    "planted.env:flux", ".env.", ".env ", ".env::$DATA",
    ".ssh ", ".ssh.", ".ssh::$INDEX_ALLOCATION", ".gnupg.", ".ssh./config", ".ssh /authorized_keys",
    "id_rsa.", "cle.pem..", "cle.key ", "certs/serveur.pem::$DATA",
    ".git.", ".git ", "proj/.git./hooks/pre-commit", "proj/.git::$INDEX_ALLOCATION/hooks/pre-commit",
    "proj/.git:$I30:$INDEX_ALLOCATION/config",
])
def test_windows_normalized_names_are_denied_before_creation(ws, rel):
    root, _ = ws
    path = os.path.join(str(root), *rel.split("/"))
    assert not os.path.exists(path)
    assert deny_reason(path) is not None, rel
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    for t in ("write_file", "make_dir", "read_file"):
        ok, reason = gate.authorize(FileOpsSkill(), {"type": t, "path": path, "content": "x"})
        assert not ok, (rel, t, reason)
        res = FileOpsSkill().run({"type": t, "path": path, "content": "x"})
        assert not res.ok, (rel, t, res.detail)
    assert os.listdir(root) == [], "rien ne doit être créé dans le workspace"


@pytest.mark.parametrize("rel", ["notes.txt", "rapport final.docx", "env.txt", "environnement/a.md",
                                 "a.envoi.txt", "proj/gitignore.txt", "ok.txt:flux", "ssh_notes.txt"])
def test_ordinary_names_still_allowed(ws, rel):
    root, _ = ws
    assert deny_reason(os.path.join(str(root), *rel.split("/"))) is None


def test_name_variants_and_git_args():
    assert windows_name_variants("a.env::$data") >= {"a.env::$data", "a.env"}
    assert windows_name_variants("a.env. ") >= {"a.env"}
    assert windows_name_variants("notes.txt") == {"notes.txt"}
    assert windows_name_variants("..") == {".."}  # jamais vide
    # Les arguments git « nus » restent refusés (HEAD:.env, .env.).
    assert denied_name("HEAD:.env") and denied_name(".env.") and denied_name("sub/.git./config")
    assert denied_name("notes.txt") is None


def test_probe_write_planted_env_with_trailing_space_refused(ws, monkeypatch):
    """Reproduction du vérificateur : 'planted.env ' créait un vrai `planted.env`."""
    root, _ = ws
    calls = _asker(monkeypatch, "o")
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    for leaf in ("planted.env ", "planted.env::$DATA", "planted.env:x"):
        path = str(root) + os.sep + leaf
        ok, reason = gate.authorize(FileOpsSkill(), {"type": "write_file", "path": path, "content": "A=1"})
        assert not ok and "fichier .env" in reason
        # Le skill refuse aussi lui-même (défense en profondeur).
        res = FileOpsSkill().run({"type": "write_file", "path": path, "content": "A=1"})
        assert not res.ok and "interdit" in res.detail
    assert calls == []
    assert os.listdir(root) == [], "aucun fichier ne doit être créé"


def test_probe_make_dir_ssh_variants_refused(ws):
    root, _ = ws
    for leaf in (".ssh ", ".ssh.", ".gnupg::$INDEX_ALLOCATION"):
        res = FileOpsSkill().run({"type": "make_dir", "path": str(root) + os.sep + leaf})
        assert not res.ok and ".ssh/.gnupg" in res.detail
    assert os.listdir(root) == []


def test_move_to_planted_env_refused(ws):
    root, _ = ws
    src = root / "a.txt"
    src.write_text("A=1")
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    step = {"type": "move_file", "src": str(src), "dest": str(root) + os.sep + "b.env."}
    assert not gate.authorize(MoveFileSkill(), step)[0]
    assert not MoveFileSkill().run(step).ok
    assert sorted(os.listdir(root)) == ["a.txt"]


@pytest.mark.skipif(not WIN, reason="préfixes de chemins Windows")
def test_extended_prefix_does_not_bypass_protected_roots():
    for prefix in (BS * 2 + "?" + BS, BS * 2 + "." + BS):
        for name in ("permissions.py", "nouveau.py", os.path.join("skills", "safety.py")):
            p = prefix + os.path.join(AGENT_DIR, name)
            assert deny_reason(p) == "code/configuration de l'agent ou dépôt SoulBah", p
    assert strip_ext_prefix(BS * 2 + "?" + BS + "C:" + BS + "x") == "C:" + BS + "x"
    assert strip_ext_prefix(BS * 2 + "?" + BS + "UNC" + BS + "srv" + BS + "x") == BS * 2 + "srv" + BS + "x"


@pytest.mark.skipif(not WIN, reason="préfixes de chemins Windows")
def test_extended_prefix_workspace_containing_agent_refused():
    home = os.path.dirname(AGENT_DIR)
    assert workspace_errors([BS * 2 + "?" + BS + home])
    if REPO_ROOT:
        assert workspace_errors([BS * 2 + "?" + BS + os.path.join(REPO_ROOT, "frontend")])


@pytest.mark.skipif(not WIN, reason="préfixes de chemins Windows")
def test_whitelist_accepts_extended_prefix_of_allowed_path(ws):
    root, outside = ws
    dirs = [normalize_dir(str(root))]
    assert path_inside(BS * 2 + "?" + BS + str(root / "f.txt"), dirs)
    assert not path_inside(BS * 2 + "?" + BS + str(outside / "f.txt"), dirs)


def _unc(path: str) -> str | None:
    if not WIN or len(path) < 3 or path[1] != ":":
        return None
    unc = BS * 2 + "localhost" + BS + path[0].lower() + "$" + path[2:]
    try:
        return unc if os.path.isdir(unc) else None
    except OSError:
        return None


def test_unc_alias_of_agent_dir_is_protected():
    unc_agent = _unc(AGENT_DIR)
    if unc_agent is None:
        pytest.skip("partage administratif \\\\localhost\\c$ indisponible")
    assert deny_reason(os.path.join(unc_agent, "permissions.py")) is not None
    assert deny_reason(os.path.join(unc_agent, "nouveau.py")) is not None
    assert workspace_errors([os.path.dirname(unc_agent)])


# =====================================================================================
# NEW — whitelist revérifiée par le skill au moment d'agir
# =====================================================================================
def test_skill_rechecks_bound_whitelist(ws):
    root, outside = ws
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    bind_path_refusal(gate.path_refusal)
    try:
        assert path_refusal_now(str(root / "ok.txt")) is None
        res = FileOpsSkill().run({"type": "write_file", "path": str(outside / "x.txt"), "content": "x"})
        assert not res.ok and "hors liste blanche" in res.detail
        src = root / "a.txt"
        src.write_text("x")
        res = MoveFileSkill().run({"type": "move_file", "src": str(src), "dest": str(outside / "a.txt")})
        assert not res.ok and "hors liste blanche" in res.detail
        assert FileOpsSkill().run({"type": "write_file", "path": str(root / "ok.txt"), "content": "x"}).ok
    finally:
        bind_path_refusal(None)
    assert os.listdir(outside) == []
    # Hors executor (aucun gate lié) : pas de whitelist imposée par le skill lui-même.
    assert path_refusal_now(str(outside / "x.txt")) is None


class _LaxGate(PermissionGate):
    """Simule un échange de lien APRÈS la dernière revalidation du gate : le gate
    a tout accepté, seul le contrôle du skill au moment d'agir peut refuser."""

    def authorize(self, skill, step, context=None):
        return True, "test"

    def recheck(self, skill, step):
        return None


def test_executor_binds_gate_whitelist_for_skills(ws):
    root, outside = ws
    executor = Executor(_LaxGate("auto", [str(root)], dry_run=False), step_timeout=30)
    events = []
    report = executor.run_task(
        {"steps": [{"type": "write_file", "path": str(outside / "x.txt"), "content": "x"}]},
        on_event=lambda t, m, d: events.append(t))
    assert not report["ok"] and "au moment d'agir" in report["steps"][0]["detail"]
    assert os.listdir(outside) == []
    assert events[-1] == "task_failed"
    # Le contrôle est détaché après l'étape (thread de travail terminé).
    assert path_refusal_now(str(outside / "x.txt")) is None


@pytest.mark.skipif(not WIN, reason="jonctions NTFS")
def test_junction_swapped_after_recheck_is_refused_by_skill(ws):
    _winapi = pytest.importorskip("_winapi")
    if not hasattr(_winapi, "CreateJunction"):
        pytest.skip("CreateJunction indisponible")
    root, outside = ws
    real = root / "real"
    real.mkdir()
    link = root / "link"
    _winapi.CreateJunction(str(real), str(link))

    class SwapGate(PermissionGate):
        def recheck(self, skill, step):
            err = super().recheck(skill, step)
            # L'attaquant remplace la jonction juste après la revalidation du gate.
            os.rmdir(link)
            _winapi.CreateJunction(str(outside), str(link))
            return err

    try:
        executor = Executor(SwapGate("auto", [str(root)], dry_run=False), step_timeout=30)
        report = executor.run_task({"steps": [{"type": "write_file", "path": str(link / "f.txt"), "content": "x"}]})
        assert not report["ok"] and "hors liste blanche" in report["steps"][0]["detail"]
        assert os.listdir(outside) == [] and os.listdir(real) == []
    finally:
        if os.path.lexists(link):
            os.rmdir(link)


# =====================================================================================
# S21 — payload.requires_confirmation respecté
# =====================================================================================
def test_requires_confirmation_overrides_auto_mode_for_writes(ws, monkeypatch):
    root, _ = ws
    calls = _asker(monkeypatch, "n")
    gate = PermissionGate("auto", [str(root)], dry_run=False)
    step = {"type": "write_file", "path": str(root / "a.txt"), "content": "x"}
    # Sans le drapeau : comportement inchangé (mode auto, aucune question).
    assert gate.authorize(FileOpsSkill(), step) == (True, "mode auto")
    assert calls == []
    ok, reason = gate.authorize(FileOpsSkill(), step, {"requires_confirmation": True})
    assert not ok and reason == "refusé par l'utilisateur" and len(calls) == 1
    mv = {"type": "move_file", "src": str(root / "a.txt"), "dest": str(root / "b.txt")}
    assert not gate.authorize(MoveFileSkill(), mv, {"requires_confirmation": True})[0] and len(calls) == 2
    # Actions sans effet réel de la même tâche : mode auto inchangé.
    for t in ("read_file", "list_dir", "make_dir"):
        assert gate.authorize(FileOpsSkill(), {"type": t, "path": str(root)}, {"requires_confirmation": True})[0]
    assert len(calls) == 2
    # Seul un vrai booléen compte (le serveur pose true).
    assert gate.authorize(FileOpsSkill(), step, {"requires_confirmation": "false"})[0] and len(calls) == 2


def test_requires_confirmation_overrides_input_preauthorization(ws, monkeypatch):
    root, _ = ws
    calls = _asker(monkeypatch, "o")
    monkeypatch.setattr(HotkeySkill, "input_risk", lambda self, step: None)
    monkeypatch.setattr(PhoneSkill, "input_risk", lambda self, step: None)
    gate = PermissionGate("auto", [str(root)], dry_run=False, allow_input_control=True)
    hk = {"type": "hotkey", "keys": ["ctrl", "s"]}
    assert gate.authorize(HotkeySkill(), hk) == (True, "contrôle d'entrée pré-autorisé")
    assert calls == []
    assert gate.authorize(HotkeySkill(), hk, {"requires_confirmation": True}) == (True, "validé par l'utilisateur")
    assert gate.authorize(PhoneSkill(), {"type": "phone_tap", "x": 1, "y": 2}, {"requires_confirmation": True})[0]
    assert len(calls) == 2


def test_requires_confirmation_server_list_matches_agent_skills():
    for t in SERVER_CONFIRM_STEP_TYPES:
        assert t in REGISTRY, f"type serveur inconnu de l'agent : {t}"


def test_requires_confirmation_dry_run_still_simulates(ws, monkeypatch):
    root, _ = ws
    monkeypatch.setattr(permissions, "_timed_input", lambda *a, **k: pytest.fail("aucune question en dry-run"))
    gate = PermissionGate("auto", [str(root)], dry_run=True)
    step = {"type": "write_file", "path": str(root / "a.txt"), "content": "x"}
    assert gate.authorize(FileOpsSkill(), step, {"requires_confirmation": True}) == (True, "dry-run")


@pytest.mark.parametrize("answer,written", [("n", False), ("o", True)])
def test_executor_honours_server_requires_confirmation(ws, monkeypatch, answer, written):
    root, _ = ws
    calls = _asker(monkeypatch, answer)
    executor = Executor(PermissionGate("auto", [str(root)], dry_run=False), step_timeout=30)
    events = []
    target = root / "a.txt"
    report = executor.run_task(
        {"requires_confirmation": True, "steps": [{"type": "write_file", "path": str(target), "content": "x"}]},
        on_event=lambda t, m, d: events.append((t, d)))
    assert len(calls) == 1 and report["ok"] is written and target.exists() is written
    types = [t for t, _ in events]
    assert "approval_required" in types
    res = dict(events)["approval_result"]  # LOT 6 : + reason / remote / approval_id
    assert res["step_index"] == 0 and res["approved"] is written
    # Tâche sans le drapeau : le mode auto s'applique comme avant.
    target2 = root / "b.txt"
    report = executor.run_task({"steps": [{"type": "write_file", "path": str(target2), "content": "x"}]})
    assert report["ok"] and target2.exists() and len(calls) == 1


# =====================================================================================
# C§2 / §13 — stop pendant une confirmation console
# =====================================================================================
def _seq_control(seq, default="none"):
    reads = {"n": 0}

    def control():
        i = reads["n"]
        reads["n"] += 1
        return seq[i] if i < len(seq) else default

    return control, reads


def test_stop_while_confirmation_pending_refuses_and_cancels(tmp_path, monkeypatch):
    """Reproduction du vérificateur : l'utilisateur clique Arrêter puis approuve sur le
    PC 1 s plus tard. Avant : l'action s'exécutait. Maintenant : refus + cancelled."""
    monkeypatch.setattr(ex, "_CONFIRM_CONTROL_POLL_SECONDS", 0.05)
    polled = {"n": 0}

    def fake_input(prompt, timeout, should_stop=None):
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            polled["n"] += 1
            if should_stop is not None and should_stop():
                return None
            time.sleep(0.01)
        return "o"  # approbation tardive sur le PC

    monkeypatch.setattr(permissions, "_timed_input", fake_input)
    control, reads = _seq_control(["none"], default="stop")
    executor = Executor(PermissionGate("confirm", [str(tmp_path)], dry_run=False))
    events = []
    report = executor.run_task({"steps": [{"type": "verif_sensitive"}, {"type": "verif_count"}]},
                               on_event=lambda t, m, d: events.append((t, d)), check_control=control)
    assert EXECUTIONS["n"] == 0
    assert report["cancelled"] and report["stopped"] and not report["ok"] and report["steps"] == []
    assert [t for t, _ in events] == ["task_started", "approval_required", "approval_result", "task_cancelled"]
    res = dict(events)["approval_result"]  # LOT 6 : + reason / remote / approval_id
    assert res["step_index"] == 0 and res["approved"] is False
    assert reads["n"] <= 3 < polled["n"], "lecture du contrôle limitée pendant la confirmation"


def test_stop_received_right_after_approval_is_honoured(tmp_path, monkeypatch):
    """Approbation immédiate, mais l'ordre stop est arrivé pendant la question :
    le contrôle est relu avant d'agir."""
    _asker(monkeypatch, "o")
    control, reads = _seq_control(["none", "stop"])
    executor = Executor(PermissionGate("confirm", [str(tmp_path)], dry_run=False))
    events = []
    report = executor.run_task({"steps": [{"type": "verif_sensitive"}]},
                               on_event=lambda t, m, d: events.append(t), check_control=control)
    assert EXECUTIONS["n"] == 0 and report["cancelled"]
    assert "step_started" not in events and events[-1] == "task_cancelled"


def test_pause_during_confirmation_waits_before_acting(tmp_path, monkeypatch):
    monkeypatch.setattr(ex, "_PAUSE_POLL_SECONDS", 0.01)
    _asker(monkeypatch, "o")
    control, reads = _seq_control(["none", "pause", "pause", "none"])
    executor = Executor(PermissionGate("confirm", [str(tmp_path)], dry_run=False))
    events = []
    report = executor.run_task({"steps": [{"type": "verif_sensitive"}]},
                               on_event=lambda t, m, d: events.append((t, d)), check_control=control)
    assert report["ok"] and EXECUTIONS["n"] == 1
    types = [t for t, _ in events]
    paused_at = types.index("info")
    assert types.index("approval_result") < paused_at < types.index("step_started")
    assert reads["n"] >= 4


def test_no_extra_control_read_without_confirmation(tmp_path):
    control, reads = _seq_control([])
    executor = Executor(PermissionGate("auto", [str(tmp_path)], dry_run=False))
    report = executor.run_task({"steps": [{"type": "verif_count"}, {"type": "verif_count"}]}, check_control=control)
    assert report["ok"] and reads["n"] == 2  # une lecture avant chaque étape, comme avant


def test_handle_task_stop_during_confirmation_sends_cancelled(tmp_path, monkeypatch):
    monkeypatch.setattr(ex, "_CONFIRM_CONTROL_POLL_SECONDS", 0.05)

    def fake_input(prompt, timeout, should_stop=None):
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            if should_stop is not None and should_stop():
                return None
            time.sleep(0.01)
        return "o"

    monkeypatch.setattr(permissions, "_timed_input", fake_input)
    control, _ = _seq_control(["none"], default="stop")
    c = Client(control=control)
    executor = Executor(PermissionGate("confirm", [str(tmp_path)], dry_run=False))
    pending = PendingUpdates(str(tmp_path / "p.json"))
    out = soulbah_agent.handle_task(_task([{"type": "verif_sensitive"}]), c, executor, pending)
    assert out == "cancelled" and EXECUTIONS["n"] == 0
    status, result, _ = c.updates[-1]
    assert status == "cancelled" and result["cancelled"] is True


# =====================================================================================
# C§2 / §8 — évènement terminal task_failed
# =====================================================================================
def _terminal(events):
    return [(t, d) for t, d in events if t in ("task_completed", "task_failed", "task_cancelled")]


def test_failed_step_emits_task_failed(tmp_path):
    executor = Executor(PermissionGate("auto", [str(tmp_path)], dry_run=False))
    events = []
    report = executor.run_task({"steps": [{"type": "read_file", "path": str(tmp_path / "absent.txt")}]},
                               on_event=lambda t, m, d: events.append((t, d)))
    assert not report["ok"]
    assert [t for t, _ in events] == ["task_started", "step_started", "step_failed", "task_failed"]
    assert _terminal(events) == [("task_failed", {"index": 1, "timed_out": False})]


def test_refused_step_emits_task_failed(ws):
    root, outside = ws
    executor = Executor(PermissionGate("auto", [str(root)], dry_run=False))
    events = []
    executor.run_task({"steps": [{"type": "write_file", "path": str(outside / "x.txt"), "content": "x"}]},
                      on_event=lambda t, m, d: events.append((t, d)))
    assert _terminal(events) == [("task_failed", {"index": 1, "timed_out": False})]


def test_unknown_skill_emits_task_failed(tmp_path):
    executor = Executor(PermissionGate("auto", [str(tmp_path)], dry_run=False))
    events = []
    executor.run_task({"steps": [{"type": "inconnu"}]}, on_event=lambda t, m, d: events.append(t))
    assert events[-1] == "task_failed"


def test_timed_out_step_emits_task_failed(tmp_path):
    executor = Executor(PermissionGate("auto", [str(tmp_path)], dry_run=False), step_timeout=0.3)
    events = []
    report = executor.run_task({"steps": [{"type": "verif_wait", "seconds": 30}]},
                               on_event=lambda t, m, d: events.append((t, d)))
    assert report["timed_out"] and not report["ok"]
    assert _terminal(events) == [("task_failed", {"index": 1, "timed_out": True})]


@pytest.mark.parametrize("payload", [["pas", "un", "objet"], {"steps": "pas une liste"}])
def test_invalid_payload_emits_task_failed(tmp_path, payload):
    executor = Executor(PermissionGate("auto", [str(tmp_path)], dry_run=False))
    events = []
    report = executor.run_task(payload, on_event=lambda t, m, d: events.append(t))
    assert not report["ok"] and events == ["task_failed"]


def test_success_and_abort_emit_no_task_failed(tmp_path):
    executor = Executor(PermissionGate("auto", [str(tmp_path)], dry_run=False))
    events = []
    executor.run_task({"steps": [{"type": "verif_count"}]}, on_event=lambda t, m, d: events.append(t))
    assert events[-1] == "task_completed" and "task_failed" not in events
    events.clear()
    abort = threading.Event()
    abort.set()  # 409/410 : la tâche n'est plus la nôtre → rien n'est émis
    report = executor.run_task({"steps": [{"type": "verif_count"}]}, on_event=lambda t, m, d: events.append(t),
                               abort=abort)
    assert report["aborted"] and "task_failed" not in events and "task_cancelled" not in events


def test_handle_task_failure_reaches_cockpit(tmp_path):
    executor = Executor(PermissionGate("auto", [str(tmp_path)], dry_run=False))
    pending = PendingUpdates(str(tmp_path / "p.json"))
    c = Client()
    task = _task([{"type": "read_file", "path": str(tmp_path / "absent.txt")}])
    assert soulbah_agent.handle_task(task, c, executor, pending) == "failed"
    assert [e[0] for e in c.events if e[0].startswith("task_")][-1] == "task_failed"
    assert c.updates[-1][0] == "failed"


# =====================================================================================
# C§2 — final cancelled rejeté → minimal non évaluable
# =====================================================================================
def _node_skip_reason(status, result):
    """Règles de non-évaluation de node (agentGoal.ts evaluationSkipReason) utiles ici."""
    if status == "cancelled":
        return "cancelled"
    if result.get("cancelled") is True or result.get("status") == "cancelled":
        return "cancelled"
    if result.get("simulated") is True:
        return "simulated"
    if result.get("empty_plan") is True:
        return "empty_plan"
    return None


def test_minimal_result_keeps_cancelled_flags():
    m = minimal_failed_result("cancelled", {"ok": False, "cancelled": True, "stopped": True,
                                            "steps": [{"index": 0, "ok": False, "detail": "x"}]})
    assert m["cancelled"] is True and m["stopped"] is True and m["original_status"] == "cancelled"
    assert _node_skip_reason("failed", m) == "cancelled"
    # Même sans drapeau dans le rapport, le statut d'origine suffit.
    assert minimal_failed_result("cancelled", {})["cancelled"] is True
    assert minimal_failed_result("cancelled", None)["cancelled"] is True
    # Un final completed/failed rejeté ne devient pas « annulé ».
    m = minimal_failed_result("completed", {"ok": True, "steps": []})
    assert "cancelled" not in m and "stopped" not in m
    m = minimal_failed_result("failed", {"ok": False, "timed_out": True, "steps": []})
    assert m["timed_out"] is True and "cancelled" not in m


def test_rejected_cancelled_final_replaced_by_non_evaluable_minimal(tmp_path):
    executor = Executor(PermissionGate("auto", [str(tmp_path)], dry_run=False))
    pending = PendingUpdates(str(tmp_path / "p.json"))
    c = Client(control=lambda: "stop", updates=[REJECTED, OK])
    out = soulbah_agent.handle_task(_task([{"type": "verif_count"}]), c, executor, pending)
    assert out == "cancelled" and EXECUTIONS["n"] == 0
    assert [u[0] for u in c.updates] == ["cancelled", "failed"]
    minimal = c.updates[-1][1]
    assert minimal["final_rejected"] is True and minimal["cancelled"] is True
    assert _node_skip_reason("failed", minimal) == "cancelled"


# =====================================================================================
# C§2 — un stop pendant une étape longue l'interrompt (comportement retenu, documenté)
# =====================================================================================
def test_stop_during_long_step_interrupts_it(tmp_path, monkeypatch):
    monkeypatch.setattr(ex, "_CONTROL_POLL_SECONDS", 0.1)
    control, _ = _seq_control(["none"], default="stop")
    executor = Executor(PermissionGate("auto", [str(tmp_path)], dry_run=False), step_timeout=60)
    t0 = time.monotonic()
    report = executor.run_task({"steps": [{"type": "verif_wait", "seconds": 30}]}, check_control=control)
    assert time.monotonic() - t0 < 5
    assert report["cancelled"] and report["steps"][0]["detail"] in ("interrompu", "étape interrompue (arrêt demandé)")
