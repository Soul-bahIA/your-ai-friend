r"""Superviseur du runtime V2 (LOT 8 — audit §9.2 P3, §9.6, §9.9, §14).

    python -m runtime.supervisor            (depuis agent/, ou Lancer_Runtime.bat)

Rôle : un processus principal par PC qui
  1. prend la **garde d'instance unique** (jamais en même temps que l'agent V1) ;
  2. fait la **poignée de main** `register` : 426 (version / protocole refusés) → sortie 4 ;
     404 (serveur sans V2) ou SOULBAH_RUNTIME_LEGACY=1 → `legacy_adapter` (boucle V1) ;
  3. **réconcilie** au démarrage les tâches de son journal (`POST reconcile`) : `resume` →
     worker relancé avec `--resume` (§9.9 : verified sautée, executed actée, attempted
     rejouée seulement si l'outil est idempotent, sinon QUESTION) ; `abandon` / `cancel` →
     journal purgé. Aucun nouveau bail tant que la réconciliation n'a pas abouti ;
  4. boucle : outbox rejouée ; **keepalive** des baux (`stop` → arbre du worker tué en
     < 10 s, journal purgé ; réponse humaine à une QUESTION → worker relancé) ; détection
     des workers bloqués (aucune activité au-delà de SOULBAH_STEP_TIMEOUT + marge → arbre
     tué, ERROR timeout) ; **lease** avec `slots = max_slots − tâches détenues` (0 tant
     qu'une écriture attend dans l'outbox : base injoignable ou final non accepté) ;
  5. un **worker = un sous-processus dans son propre Job Object** (KILL_ON_JOB_CLOSE,
     BREAKAWAY_OK pour open_app) : si le superviseur meurt, ses workers meurent avec lui ;
     un worker mort sans final est relancé en reprise (même tentative, même bail) au plus
     MAX_LOCAL_RESTARTS fois, puis ERROR crash ;
  6. arrêt (Ctrl+C / SIGTERM) : plus de bail, fichiers d'arrêt posés, workers interrompus
     (aucun final : la prochaine réconciliation reprendra), arbres restants tués.

Codes de sortie : 0 arrêt normal · 2 configuration refusée · 3 clé agent refusée ·
4 runtime incompatible (426) · 5 un autre exécutant local tourne déjà.
"""
from __future__ import annotations

import argparse
import json
import logging
import logging.handlers
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable

from client import AUTH, OK
from config import Config, load_config
from redaction import RedactingFormatter
from runtime import legacy_adapter
from runtime.instance_lock import KIND_RUNTIME, InstanceLock, describe, runtime_dir
from runtime.journal import STATE_FINALIZING, STATE_RUNNING, STATE_WAITING, Journal
from runtime.rtclient import NOT_FOUND, QUEUED, UPGRADE_REQUIRED, RuntimeClient
from runtime.version import PROTOCOL, RUNTIME_VERSION
from skills.proctree import kill_tree, popen_in_job

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass

log = logging.getLogger("soulbah.runtime.supervisor")

AGENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

EXIT_OK = 0
EXIT_CONFIG = 2
EXIT_AUTH = 3
EXIT_UPGRADE = 4
EXIT_LOCKED = 5
RUN_LEGACY = -1  # interne : basculer sur la boucle V1

# Codes de sortie du worker (runtime/worker.py)
W_OK, W_USAGE, W_CONFIG, W_WAITING, W_INTERRUPTED, W_CRASH = 0, 2, 3, 5, 6, 7

MAX_LOCAL_RESTARTS = 2
HANG_MARGIN_S = 60.0
SHUTDOWN_GRACE_S = 8.0
DEFAULT_LEASE_SECONDS = 90.0
MAX_REGISTER_DELAY_S = 60.0


def max_slots_from_env() -> int:
    raw = os.environ.get("SOULBAH_MAX_SLOTS", "").strip()
    try:
        value = int(raw) if raw else 6
    except ValueError:
        value = 6
    return max(1, min(32, value))


@dataclass
class WorkerHandle:
    task_id: str
    attempt: int
    proc: subprocess.Popen
    job: Any
    started_wall: float
    stop_file: str
    log_handle: Any
    stop_requested: bool = False  # stop venu du serveur (annulation, bail perdu)
    hung: bool = False


class Supervisor:
    def __init__(self, cfg: Config, client: RuntimeClient, journal: Journal, max_slots: int, *,
                 python: str | None = None, tick_s: float = 1.0, hang_margin_s: float = HANG_MARGIN_S,
                 now: Callable[[], float] = time.monotonic):
        self.cfg = cfg
        self.client = client
        self.journal = journal
        self.max_slots = max(1, min(32, int(max_slots)))
        self.python = python or sys.executable
        self.tick_s = tick_s
        self.hang_margin_s = hang_margin_s
        self._now = now
        self.workers: dict[str, WorkerHandle] = {}
        self.restarts: dict[str, int] = {}
        self.consumed_answers: dict[str, int] = {}
        self.lease_seconds = DEFAULT_LEASE_SECONDS
        self.reconciled = False
        self.next_keepalive = 0.0
        self.next_lease = 0.0
        self._stop = threading.Event()
        self.tasks_dir = os.path.join(runtime_dir(), "tasks")
        self.logs_dir = os.path.join(runtime_dir(), "logs")

    # --- arrêt ---------------------------------------------------------------------------
    @property
    def stopping(self) -> bool:
        return self._stop.is_set()

    def request_stop(self, *_args: Any) -> None:
        if not self._stop.is_set():
            log.warning("Arrêt demandé — plus de nouveau bail, interruption des workers…")
        self._stop.set()

    # --- poignée de main ---------------------------------------------------------------------
    def handshake(self) -> str:
        """"ok" | "legacy" | "upgrade" | "auth" | "retry"."""
        caps = {"platform": sys.platform, "slots": self.max_slots, "runtime_version": RUNTIME_VERSION,
                "protocol": PROTOCOL, "desktop": sys.platform == "win32"}
        outcome, detail, data, _status = self.client.register(self.max_slots, caps, hostname=socket.gethostname())
        if outcome == OK:
            self.lease_seconds = float((data or {}).get("lease_seconds") or DEFAULT_LEASE_SECONDS)
            log.info("Runtime %s enregistré (v%s, protocole %d) · %d slot(s) · plafond effectif %s · bail %ss",
                     str(self.client.runtime_id)[:8], RUNTIME_VERSION, PROTOCOL, self.max_slots,
                     (data or {}).get("max_parallel"), int(self.lease_seconds))
            return "ok"
        if outcome == UPGRADE_REQUIRED:
            info = data if isinstance(data, dict) else {}
            log.error("✖ Runtime refusé par le serveur : %s (version minimale %s, protocole %s). "
                      "Mettez à jour l'agent.", info.get("error") or detail, info.get("min_version"), info.get("protocol"))
            return "upgrade"
        if outcome == NOT_FOUND:
            log.warning("Serveur sans API runtime V2 (404) — bascule sur la boucle de l'agent V1")
            return "legacy"
        if outcome == AUTH:
            log.error("✖ Clé agent refusée par le serveur (%s)", detail)
            return "auth"
        log.warning("Enregistrement impossible (%s) — nouvel essai", detail)
        return "retry"

    # --- workers ---------------------------------------------------------------------------
    def _write_json(self, path: str, data: Any) -> None:
        tmp = f"{path}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, default=str)
        os.replace(tmp, path)

    def spawn(self, task: dict[str, Any], resume_actions: list[dict[str, Any]] | None = None,
              answer: str | None = None) -> WorkerHandle | None:
        tid = str(task["id"])
        os.makedirs(self.tasks_dir, exist_ok=True)
        os.makedirs(self.logs_dir, exist_ok=True)
        task_file = os.path.join(self.tasks_dir, f"{tid}.json")
        stop_file = os.path.join(self.tasks_dir, f"{tid}.stop")
        self._write_json(task_file, {"runtime_id": self.client.runtime_id, "task": task})
        try:
            os.remove(stop_file)
        except OSError:
            pass
        argv = [self.python, "-m", "runtime.worker", "--task", task_file, "--stop-file", stop_file,
                "--journal", self.journal.path]
        if resume_actions is not None:
            resume_file = os.path.join(self.tasks_dir, f"{tid}.resume.json")
            self._write_json(resume_file, {"decision": "resume", "actions": resume_actions})
            argv += ["--resume", resume_file]
        if answer is not None:
            argv += ["--answer", str(answer)[:500]]
        env = dict(os.environ)
        env["SOULBAH_RUNTIME_DIR"] = runtime_dir()
        env["PYTHONUTF8"] = "1"
        log_handle = open(os.path.join(self.logs_dir, f"{tid}.log"), "a", encoding="utf-8")
        try:
            proc, job = popen_in_job(argv, AGENT_DIR, env=env, use_job=True, breakaway_ok=True,
                                     stdout=log_handle, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        except OSError as e:
            log_handle.close()
            log.error("Lancement du worker de %s impossible : %s", tid[:8], e)
            return None
        handle = WorkerHandle(tid, int(task.get("attempt") or 0), proc, job, time.time(), stop_file, log_handle)
        self.workers[tid] = handle
        self.journal.set_state(tid, STATE_RUNNING)
        log.info("▶ Worker %s lancé (PID %s, tentative %d%s%s) · job=%s", tid[:8], proc.pid, handle.attempt,
                 ", reprise" if resume_actions is not None else "", ", avec réponse" if answer is not None else "",
                 "oui" if job is not None else "non")
        return handle

    def _close(self, w: WorkerHandle) -> None:
        if w.job is not None:
            try:
                w.job.close()  # KILL_ON_JOB_CLOSE : aucun descendant ne survit
            except Exception:  # noqa: BLE001
                pass
            w.job = None
        try:
            w.log_handle.close()
        except Exception:  # noqa: BLE001
            pass

    def kill(self, w: WorkerHandle, reason: str) -> None:
        """Tue l'arbre du worker (Job Object puis taskkill /T en repli)."""
        log.warning("✖ Worker %s tué (%s)", w.task_id[:8], reason)
        kill_tree(w.proc, w.job)
        try:
            w.proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            log.error("Worker %s toujours vivant après kill_tree", w.task_id[:8])

    def _send_final_error(self, task_id: str, attempt: int, kind: str, message: str) -> None:
        outcome = self.client.post_message(task_id, attempt, "ERROR", {"kind": kind, "message": message[:2000]},
                                           final=True)
        if outcome == QUEUED:
            if self.journal.get_held(task_id):
                self.journal.set_state(task_id, STATE_FINALIZING)
        else:
            self.journal.release(task_id)
        log.warning("ERROR %s envoyé pour %s (%s)", kind, task_id[:8], outcome)

    def _resume_actions(self, task_id: str, attempt: int) -> list[dict[str, Any]]:
        return [{"step_index": a["step_index"], "tool": a["tool"], "status": a["status"],
                 "idempotent": a["idempotent"]} for a in self.journal.actions(task_id, attempt)]

    def reap(self) -> None:
        for tid, w in list(self.workers.items()):
            rc = w.proc.poll()
            if rc is None:
                continue
            self._close(w)
            del self.workers[tid]
            self._after_exit(w, rc)

    def _after_exit(self, w: WorkerHandle, rc: int) -> None:
        tid = w.task_id
        held = self.journal.get_held(tid)
        if w.stop_requested:
            self.journal.purge(tid)
            self.restarts.pop(tid, None)
            log.info("Worker %s arrêté à la demande du serveur — tâche oubliée", tid[:8])
            return
        if self.stopping:
            log.info("Worker %s interrompu par l'arrêt du runtime (code %s) — reprise au prochain démarrage", tid[:8], rc)
            return
        if held is None or held["state"] == STATE_FINALIZING:
            self.restarts.pop(tid, None)
            log.info("Worker %s terminé (code %s)", tid[:8], rc)
            return
        if rc == W_WAITING:
            log.info("Worker %s en attente d'une réponse humaine", tid[:8])
            return
        if w.hung:
            self._send_final_error(tid, held["attempt"], "timeout",
                                   f"aucune activité depuis plus de {int(self.cfg.step_timeout + self.hang_margin_s)} s "
                                   f"— arbre du worker tué")
            return
        if rc in (W_USAGE, W_CONFIG):
            self._send_final_error(tid, held["attempt"], "crash", f"worker refusé au démarrage (code {rc})")
            return
        count = self.restarts.get(tid, 0)
        if count < MAX_LOCAL_RESTARTS:
            self.restarts[tid] = count + 1
            log.warning("Worker %s mort sans final (code %s) — reprise locale %d/%d depuis le journal", tid[:8], rc,
                        count + 1, MAX_LOCAL_RESTARTS)
            self.spawn(held["spec"], resume_actions=self._resume_actions(tid, held["attempt"]))
            return
        self.restarts.pop(tid, None)
        self._send_final_error(tid, held["attempt"], "crash",
                               f"worker mort sans final {count + 1} fois (dernier code {rc})")

    def check_hangs(self) -> None:
        limit = float(self.cfg.step_timeout) + self.hang_margin_s
        now = time.time()
        for w in list(self.workers.values()):
            if w.hung or w.proc.poll() is not None:
                continue
            last = self.journal.last_activity(w.task_id) or w.started_wall
            if now - max(last, w.started_wall) > limit:
                w.hung = True
                self.kill(w, f"bloqué : aucune activité depuis {int(now - last)} s")

    # --- protocole ---------------------------------------------------------------------------
    def reconcile(self) -> bool:
        held = self.journal.held()
        if not held:
            self.reconciled = True
            return True
        outcome, detail, data, _status = self.client.reconcile(
            [{"task_id": h["task_id"], "attempt": h["attempt"]} for h in held])
        if outcome != OK or not isinstance(data, dict):
            log.warning("Réconciliation impossible (%s) — aucun nouveau bail en attendant", detail)
            return False
        by_id = {h["task_id"]: h for h in held}
        for d in data.get("decisions") or []:
            tid = str(d.get("task_id"))
            h = by_id.get(tid)
            if h is None:
                continue
            decision = d.get("decision")
            if decision == "resume":
                if h["state"] in (STATE_FINALIZING, STATE_WAITING):
                    log.info("Réconciliation %s : reprise (%s) — rien à relancer", tid[:8], h["state"])
                    continue
                if tid in self.workers:
                    continue
                local = self._resume_actions(tid, h["attempt"])
                actions = local or [a for a in (d.get("actions") or []) if isinstance(a, dict)]
                log.info("Réconciliation %s : reprise de la tentative %d (%d action(s) connues)", tid[:8], h["attempt"],
                         len(actions))
                self.spawn(h["spec"], resume_actions=actions)
            else:
                log.warning("Réconciliation %s : %s (statut serveur %s) — tâche oubliée", tid[:8], decision, d.get("status"))
                w = self.workers.get(tid)
                if w is not None:
                    w.stop_requested = True
                    self.kill(w, f"réconciliation : {decision}")
                else:
                    self.journal.purge(tid)
        self.reconciled = True
        return True

    def keepalive(self) -> None:
        held = self.journal.held()
        if not held:
            return
        outcome, detail, data, _status = self.client.keepalive(
            [{"task_id": h["task_id"], "attempt": h["attempt"]} for h in held])
        if outcome != OK or not isinstance(data, dict):
            log.warning("Keepalive impossible (%s)", detail)
            return
        if data.get("lease_seconds"):
            self.lease_seconds = float(data["lease_seconds"])
        by_id = {h["task_id"]: h for h in held}
        for item in data.get("tasks") or []:
            tid = str(item.get("task_id"))
            h = by_id.get(tid)
            if h is None:
                continue
            if item.get("control") == "stop":
                w = self.workers.get(tid)
                log.warning("Serveur : arrêt de %s (statut %s)", tid[:8], item.get("status"))
                if w is not None and w.proc.poll() is None:
                    w.stop_requested = True
                    self.kill(w, f"stop serveur (statut {item.get('status')})")
                else:
                    self.journal.purge(tid)
                continue
            for m in item.get("messages") or []:
                if isinstance(m, dict) and m.get("id"):
                    log.info("Message %s pour %s : %s", m.get("type"), tid[:8], str(m.get("payload"))[:200])
                    self.client.ack_message(str(m["id"]), tid)
            if h["state"] == STATE_WAITING and tid not in self.workers:
                answers = [a for a in (item.get("answers") or []) if isinstance(a, dict)]
                fresh = answers[self.consumed_answers.get(tid, 0):]
                fresh = [a for a in fresh if a.get("attempt") in (None, h["attempt"]) and a.get("answer")]
                if fresh:
                    self.consumed_answers[tid] = len(answers)
                    log.info("Réponse humaine reçue pour %s — reprise", tid[:8])
                    self.spawn(h["spec"], resume_actions=self._resume_actions(tid, h["attempt"]),
                               answer=str(fresh[-1]["answer"]))

    def lease(self) -> int:
        if self.stopping or not self.reconciled:
            return 0
        if self.journal.outbox_count() > 0:
            return 0  # §9.9 : une écriture attend (base injoignable / final non accepté)
        slots = self.max_slots - len(self.journal.held())
        if slots <= 0:
            return 0
        outcome, detail, data, _status = self.client.lease(slots)
        if outcome != OK or not isinstance(data, dict):
            log.warning("Bail impossible (%s)", detail)
            return 0
        if data.get("lease_seconds"):
            self.lease_seconds = float(data["lease_seconds"])
        n = 0
        for task in data.get("tasks") or []:
            if not isinstance(task, dict) or not task.get("id"):
                continue
            tid = str(task["id"])
            if tid in self.workers or self.journal.get_held(tid):
                log.error("Bail reçu pour %s déjà détenue — ignoré", tid[:8])
                continue
            self.journal.hold(task)
            self.restarts.pop(tid, None)
            self.consumed_answers.pop(tid, None)
            if self.spawn(task) is not None:
                n += 1
        if n:
            log.info("%d tâche(s) reçue(s) (%d en cours / plafond %s)", n, data.get("running"), data.get("max_parallel"))
        return n

    def tick(self) -> None:
        now = self._now()
        self.client.flush_outbox()
        self.reap()
        if not self.reconciled:
            self.reconcile()
        if now >= self.next_keepalive:
            self.keepalive()
            self.next_keepalive = now + max(2.0, self.lease_seconds / 3.0)
        self.check_hangs()
        if self.reconciled and now >= self.next_lease:
            self.lease()
            self.next_lease = now + float(self.cfg.poll_interval)

    def shutdown(self) -> None:
        for w in self.workers.values():
            try:
                with open(w.stop_file, "w", encoding="utf-8") as f:
                    f.write("stop")
            except OSError:
                pass
        deadline = time.monotonic() + SHUTDOWN_GRACE_S
        while self.workers and time.monotonic() < deadline:
            for tid, w in list(self.workers.items()):
                if w.proc.poll() is not None:
                    self._close(w)
                    del self.workers[tid]
            time.sleep(0.2)
        for w in list(self.workers.values()):
            self.kill(w, "arrêt du runtime")
            self._close(w)
        self.workers.clear()
        try:
            self.client.flush_outbox()
        except Exception:  # noqa: BLE001
            pass

    def run(self) -> int:
        delay = 1.0
        while not self.stopping:
            result = self.handshake()
            if result == "ok":
                break
            if result == "upgrade":
                return EXIT_UPGRADE
            if result == "auth":
                return EXIT_AUTH
            if result == "legacy":
                return RUN_LEGACY
            self._stop.wait(delay)
            delay = min(delay * 2, MAX_REGISTER_DELAY_S)
        if self.stopping:
            return EXIT_OK
        self.reconcile()
        try:
            while not self.stopping:
                self.tick()
                self._stop.wait(self.tick_s)
        finally:
            self.shutdown()
        log.info("Runtime arrêté.")
        return EXIT_OK


def setup_logging() -> None:
    root = logging.getLogger()
    if root.handlers:
        return
    root.setLevel(logging.INFO)
    fmt = RedactingFormatter("%(asctime)s  %(levelname)-7s %(name)s  %(message)s", datefmt="%H:%M:%S")
    console = logging.StreamHandler()
    console.setFormatter(fmt)
    root.addHandler(console)
    try:
        logs = os.path.join(runtime_dir(), "logs")
        os.makedirs(logs, exist_ok=True)
        fh = logging.handlers.RotatingFileHandler(os.path.join(logs, "supervisor.log"), maxBytes=1_000_000,
                                                  backupCount=5, encoding="utf-8")
        fh.setFormatter(RedactingFormatter("%(asctime)s  %(levelname)-7s %(name)s  %(message)s",
                                           datefmt="%Y-%m-%d %H:%M:%S"))
        root.addHandler(fh)
    except OSError as e:
        log.warning("Journal fichier du runtime indisponible (%s)", e)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="SoulBah runtime V2 — superviseur")
    parser.add_argument("--max-slots", type=int, help="slots de ce PC (défaut SOULBAH_MAX_SLOTS ou 6, 1–32)")
    parser.add_argument("--legacy", action="store_true", help="forcer la boucle de l'agent V1 (serveur sans V2)")
    parser.add_argument("--tick", type=float, default=1.0, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    setup_logging()

    try:
        cfg = load_config(require_key=True)
    except SystemExit as e:
        log.error("%s", e)
        return EXIT_CONFIG
    import soulbah_agent  # import tardif : contrôles de démarrage partagés avec l'agent V1

    executor, code = soulbah_agent.build_executor(cfg)
    if executor is None:
        return code or EXIT_CONFIG

    lock = InstanceLock(KIND_RUNTIME)
    acquired, holder = lock.acquire()
    if not acquired:
        log.error("✖ Un autre exécutant local tourne déjà : %s (verrou %s)", describe(holder), lock.path)
        return EXIT_LOCKED
    journal = Journal()
    try:
        legacy = args.legacy or os.environ.get("SOULBAH_RUNTIME_LEGACY", "").strip().lower() in ("1", "true", "yes")
        if legacy:
            return legacy_adapter.run(cfg, executor)
        client = RuntimeClient(cfg, journal)
        sup = Supervisor(cfg, client, journal, args.max_slots or max_slots_from_env(), tick_s=args.tick)
        old_int = signal.signal(signal.SIGINT, sup.request_stop)
        old_term = signal.signal(signal.SIGTERM, sup.request_stop)
        log.info("SoulBah runtime v%s · %d slot(s) · api=%s · dossier %s", RUNTIME_VERSION, sup.max_slots, cfg.api_url,
                 runtime_dir())
        try:
            rc = sup.run()
        finally:
            signal.signal(signal.SIGINT, old_int)
            signal.signal(signal.SIGTERM, old_term)
        if rc == RUN_LEGACY:
            return legacy_adapter.run(cfg, executor)
        return rc
    finally:
        journal.close()
        lock.release()


if __name__ == "__main__":
    sys.exit(main())
