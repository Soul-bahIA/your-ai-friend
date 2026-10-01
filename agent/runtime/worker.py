"""Worker du runtime V2 : UN processus par tâche, lancé par le superviseur dans son
propre Job Object (`python -m runtime.worker --task <fichier.json> [--resume <décisions.json>]`).

Déroulement (audit §9.2, §9.9) :
  1. charge la tâche (bail reçu par `lease`), la configuration existante (clé, workspace,
     modes), construit `Executor` + `PermissionGate` via `soulbah_agent.build_executor`
     (mêmes règles qu'en V1 : catalogue cohérent, workspace hors dépôt) ; en mode
     `remote` / `both`, le gate LOT 6 passe par `RemoteApprover` branché sur le client
     runtime (routes `/api/v2/approvals/*`) ;
  2. exécute `spec.steps` avec l'executor existant (délais, jetons d'annulation, gate), en
     journalisant l'**état des actions** à chaque étape : `planned` (avant autorisation)
     → `attempted` (juste avant l'exécution) → `executed` (preuve brute : résultat du skill)
     → `verified` si le skill répond ok (post-condition minimale ; la vérification fine est
     le LOT 9), sinon `failed` ; `simulated` en dry-run. Chaque état est écrit dans le
     journal SQLite PUIS envoyé (`POST actions`), et un checkpoint (`step_cursor = i + 1`)
     suit chaque étape ;
  3. reprise (`--resume`) d'après les décisions du serveur : `verified` → sautée ;
     `executed` → marquée vérifiée sans ré-exécution ; `attempted` → rejouée seulement si
     le manifeste de l'outil est `idempotent`, sinon message QUESTION (« rejouer l'étape N
     (type) ? ») et sortie « en attente » (code 5) — avec `--answer`, la réponse humaine
     tranche ; `planned` / absente → exécutée ;
  4. fin : succès → `POST result` ; refus de politique / délai / échec d'étape / exception
     → message `ERROR {kind: policy_refused | timeout | error | crash, message, result}`.
     Une interruption demandée (fichier d'arrêt du superviseur, SIGINT/SIGTERM) ne produit
     AUCUN final : l'étape reste `attempted` dans le journal et la réconciliation
     appliquera §9.9 (code 6).

Codes de sortie : 0 final envoyé (ou en outbox) · 2 arguments / fichier illisible ·
3 configuration refusée · 5 en attente d'une réponse humaine · 6 interrompu · 7 crash.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import sys
import time
from typing import Any

# Lancé depuis agent/ (python -m runtime.worker) : agent/ est déjà en tête de sys.path.
from approvals import RemoteApprover
from client import CONFLICT, GONE, OK, REJECTED
from config import load_config
from redaction import RedactingFormatter
from runtime.evidence import build_evidence, self_report
from runtime.journal import (STATE_FINALIZING, STATE_WAITING, Journal)
from runtime.rtclient import QUEUED, RuntimeClient
from skills.base import CancelToken, SkillResult
from skills.manifests import get_manifest

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass

log = logging.getLogger("soulbah.runtime.worker")

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_CONFIG = 3
EXIT_WAITING = 5
EXIT_INTERRUPTED = 6
EXIT_CRASH = 7

QUESTION_YES = ("o", "oui", "y", "yes", "rejouer", "replay", "retry", "ok")
_STOP_POLL_SECONDS = 1.0


def is_idempotent(step_type: str, fallback: bool | None = None) -> bool:
    """Idempotence d'un type d'étape d'après son manifeste (source de vérité LOT 2) ;
    `fallback` (valeur annoncée par le serveur) si le type est inconnu localement."""
    m = get_manifest(step_type)
    if m is not None:
        return bool(m.get("idempotent"))
    return bool(fallback)


def setup_logging(level: int = logging.INFO) -> None:
    root = logging.getLogger()
    if root.handlers:
        return
    root.setLevel(level)
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(RedactingFormatter("%(asctime)s  %(levelname)-7s %(name)s  %(message)s", datefmt="%H:%M:%S"))
    root.addHandler(handler)


class TaskRun:
    """Exécution d'une tâche avec journal d'actions, checkpoints et reprise."""

    def __init__(self, task: dict[str, Any], executor: Any, client: RuntimeClient, journal: Journal,
                 stop_file: str | None = None):
        self.task = task
        self.task_id = str(task["id"])
        self.attempt = int(task.get("attempt") or 0)
        self.spec = task.get("spec") if isinstance(task.get("spec"), dict) else {}
        self.steps: list[Any] = list(self.spec.get("steps") or [])
        self.simulated = bool(task.get("simulated"))
        self.executor = executor
        self.client = client
        self.journal = journal
        self.stop_file = stop_file
        self.token = CancelToken()
        self.interrupted = False  # arrêt demandé (fichier d'arrêt / signal) : aucun final
        self.start = 0  # index de la première étape réellement exécutée
        self.pre_report: list[dict[str, Any]] = []
        self.seq = 0
        self.short = self.task_id[:8]

    # --- journal + serveur ----------------------------------------------------------------------
    def _params(self, step: Any) -> dict[str, Any]:
        if not isinstance(step, dict):
            return {}
        return {k: v for k, v in step.items() if k != "type"}

    def record(self, index: int, step: Any, status: str, evidence: list[Any] | None = None,
               error: str | None = None) -> None:
        tool = str(step.get("type", "")).strip() if isinstance(step, dict) else "unknown"
        if not tool:
            tool = "unknown"
        idem = is_idempotent(tool)
        if not self.journal.record_action(self.task_id, self.attempt, index, tool, status, idem):
            return  # régression : rien n'est envoyé (le serveur répondrait 409)
        outcome, _ = self.client.post_action(self.task_id, self.attempt, index, tool, self._params(step), status,
                                             evidence=evidence, error=error, simulated=self.simulated)
        if outcome not in (OK, QUEUED):
            log.warning("Action %s étape %d (%s) non acceptée : %s", self.short, index, status, outcome)

    def _upload(self, content: bytes, mime: str, kind: str) -> tuple[str | None, str] | None:
        put = getattr(self.client, "put_artifact", None)
        return put(content, mime, kind, task_id=self.task_id) if put else None

    def checkpoint(self, step_cursor: int, variables: dict[str, Any] | None = None) -> None:
        self.seq += 1
        self.journal.checkpoint(self.task_id, self.attempt, self.seq, step_cursor, variables or {})
        self.client.post_checkpoint(self.task_id, self.attempt, self.seq, step_cursor, variables or {})

    def message(self, type_: str, payload: dict[str, Any], final: bool = False) -> str:
        return self.client.post_message(self.task_id, self.attempt, type_, payload, final=final)

    # --- reprise (§9.9) ----------------------------------------------------------------------
    def plan_resume(self, decisions: list[dict[str, Any]] | None, answer: str | None) -> tuple[str, dict[str, Any]]:
        """Détermine la première étape à exécuter. Retourne ("run", {}) ; ("waiting",
        {question}) si une étape attempted non idempotente exige une réponse humaine ;
        ("failed", {summary, step}) si une étape est déjà en échec ou si l'humain a refusé."""
        if not decisions:
            return "run", {}
        by_index = {int(a.get("step_index", -1)): a for a in decisions if isinstance(a, dict)}
        last_seq = self.journal.last_checkpoint(self.task_id, self.attempt)
        if last_seq:
            self.seq = int(last_seq.get("seq", 0))
        for i, step in enumerate(self.steps):
            a = by_index.get(i)
            if a is None:
                self.start = i
                return "run", {}
            status = str(a.get("status") or "")
            step_type = str(step.get("type", "")).strip() if isinstance(step, dict) else "?"
            if status in ("verified", "skipped", "simulated"):
                self.pre_report.append({"index": i, "type": step_type, "ok": True,
                                        "detail": f"déjà {status} avant la reprise — sautée", "resumed": True})
                continue
            if status == "executed":
                # La preuve brute a été enregistrée avant le crash : on acte le résultat
                # déjà obtenu sans ré-exécuter (jamais de double effet).
                log.info("Reprise %s : étape %d (%s) exécutée avant le crash — marquée vérifiée sans ré-exécution",
                         self.short, i, step_type)
                self.record(i, step, "verified", evidence=self_report("reprise : exécutée avant le crash", i))
                self.pre_report.append({"index": i, "type": step_type, "ok": True,
                                        "detail": "exécutée avant la reprise — vérifiée sans ré-exécution",
                                        "resumed": True})
                continue
            if status == "attempted":
                if is_idempotent(step_type, a.get("idempotent")):
                    log.info("Reprise %s : étape %d (%s) interrompue — outil idempotent, rejouée", self.short, i,
                             step_type)
                    self.start = i
                    return "run", {}
                if answer is not None:
                    if answer.strip().lower() in QUESTION_YES:
                        log.warning("Reprise %s : étape %d (%s) rejouée sur décision humaine", self.short, i,
                                    step_type)
                        self.start = i
                        return "run", {}
                    self.record(i, step, "failed", error="rejeu refusé par l'utilisateur après interruption")
                    return "failed", {"summary": f"étape {i} ({step_type}) interrompue et non rejouée "
                                                 f"(refus de l'utilisateur)", "step": i}
                question = (f"L'étape {i} ({step_type}) a été interrompue avant la fin et l'outil n'est pas "
                            f"idempotent : la rejouer ? (oui / non)")
                return "waiting", {"question": question, "step_index": i, "tool": step_type,
                                   "options": ["oui", "non"], "kind": "replay_step"}
            if status == "failed":
                return "failed", {"summary": f"étape {i} ({step_type}) déjà en échec avant la reprise", "step": i}
            # planned (ou statut inconnu) : exécutée
            self.start = i
            return "run", {}
        self.start = len(self.steps)
        return "run", {}

    # --- exécution ----------------------------------------------------------------------------
    def _check_control(self) -> str:
        if self.stop_file and os.path.exists(self.stop_file):
            if not self.interrupted:
                log.warning("Arrêt demandé par le superviseur — interruption de l'étape en cours")
            self.interrupted = True
            self.token.cancel("arrêt demandé par le superviseur")
            return "stop"
        return "none"

    def interrupt(self, reason: str) -> None:
        self.interrupted = True
        self.token.cancel(reason)

    def _on_step(self, phase: str, rel_index: int, step: dict, result: SkillResult | None) -> None:
        i = self.start + rel_index
        if phase == "planned":
            self.record(i, step, "planned")
        elif phase == "attempted":
            self.record(i, step, "attempted")
        elif phase == "done":
            if result is None:
                return
            if self.interrupted or self.token.is_cancelled():
                # Interruption : l'étape reste `attempted` — la réconciliation décidera (§9.9).
                return
            if self.simulated:
                self.record(i, step, "simulated", evidence=self_report(result.detail, i))
            elif result.ok:
                # LOT 9 : preuves typées d'après le manifeste (captures → artefacts sha256).
                step_type = str(step.get("type", "")).strip()
                evidence = build_evidence(step_type, True, result.detail, result.data, step_index=i,
                                          upload=self._upload)
                self.record(i, step, "executed", evidence=evidence)
                self.record(i, step, "verified")
            else:
                self.record(i, step, "failed", error=result.detail)
            self.checkpoint(i + 1 if result.ok else i, {"last_step": i, "ok": bool(result.ok)})

    def _on_event(self, etype: str, message: str, data: dict) -> None:
        if etype in ("heartbeat",):
            return
        if etype == "screenshot":
            log.info("[%s] capture d'écran (étape %s)", self.short, data.get("index"))
            return
        log.info("[%s] %-18s %s", self.short, etype, message or "")

    def run(self, decisions: list[dict[str, Any]] | None = None, answer: str | None = None) -> int:
        mode, info = self.plan_resume(decisions, answer)
        if mode == "waiting":
            outcome = self.message("QUESTION", info)
            self.journal.set_state(self.task_id, STATE_WAITING)
            log.warning("Tâche %s en attente d'une décision humaine : %s (%s)", self.short, info["question"], outcome)
            return EXIT_WAITING
        if mode == "failed":
            return self._final_error("error", info["summary"], {"ok": False, "steps": self.pre_report,
                                                                 "summary": info["summary"]})

        payload = dict(self.spec)
        payload["steps"] = self.steps[self.start:]
        if not payload["steps"] and self.pre_report:
            report = {"ok": True, "steps": self.pre_report, "summary": "toutes les étapes déjà vérifiées (reprise)",
                      "stopped": False, "cancelled": False, "aborted": False, "timed_out": False}
            if self.simulated:
                report["simulated"] = True
            return self._final_ok(report)

        if self.start:
            log.info("Tâche %s : reprise à l'étape %d / %d", self.short, self.start, len(self.steps))
        self._check_control()
        report = self.executor.run_task(
            payload, on_event=self._on_event, check_control=self._check_control, cancel=self.token,
            task_id=self.task_id, attempt=self.attempt, on_step=self._on_step,
        )
        if self.interrupted:
            log.warning("Tâche %s interrompue — aucun final envoyé (reprise par réconciliation)", self.short)
            return EXIT_INTERRUPTED

        steps = list(self.pre_report)
        for entry in report.get("steps") or []:
            e = dict(entry)
            e["index"] = self.start + int(e.get("index", 0))
            steps.append(e)
        report["steps"] = steps
        if report.get("ok"):
            return self._final_ok(report)
        if report.get("cancelled"):
            # Un stop venu du serveur a déjà changé l'état de la tâche : le final serait refusé (409).
            log.warning("Tâche %s annulée : %s", self.short, report.get("summary"))
            return EXIT_INTERRUPTED
        last = steps[-1] if steps else {}
        detail = str(last.get("detail") or "")
        if report.get("timed_out"):
            kind = "timeout"
        elif detail.startswith("non autorisé"):
            kind = "policy_refused"
        else:
            kind = "error"
        return self._final_error(kind, f"{report.get('summary')} — {detail}"[:2000], report)

    # --- finals -------------------------------------------------------------------------------
    def _settle(self, outcome: str, what: str) -> int:
        if outcome == OK:
            self.journal.release(self.task_id)
            log.info("✔ %s de %s accepté", what, self.short)
        elif outcome == QUEUED:
            self.journal.set_state(self.task_id, STATE_FINALIZING)
            log.warning("⏳ %s de %s en outbox — bail maintenu par le superviseur jusqu'à acceptation", what,
                        self.short)
        elif outcome in (CONFLICT, GONE, REJECTED):
            self.journal.release(self.task_id)
            log.error("✖ %s de %s refusé définitivement (%s) — tâche oubliée", what, self.short, outcome)
        else:
            self.journal.release(self.task_id)
            log.error("✖ %s de %s non transmis (%s)", what, self.short, outcome)
        return EXIT_OK

    def _final_ok(self, report: dict[str, Any]) -> int:
        outcome = self.client.post_result(self.task_id, self.attempt, report, simulated=self.simulated)
        return self._settle(outcome, "résultat")

    def _final_error(self, kind: str, message: str, report: dict[str, Any] | None) -> int:
        payload: dict[str, Any] = {"kind": kind, "message": message[:2000]}
        if report is not None:
            payload["result"] = report
        outcome = self.message("ERROR", payload, final=True)
        return self._settle(outcome, f"ERROR {kind}")


def load_json(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="SoulBah runtime — worker d'une tâche")
    parser.add_argument("--task", required=True, metavar="FICHIER.json",
                        help='{"runtime_id": …, "task": {bail reçu par lease}}')
    parser.add_argument("--resume", metavar="FICHIER.json", help="décision de réconciliation {decision, actions}")
    parser.add_argument("--answer", metavar="TEXTE", help="réponse humaine à la QUESTION de reprise")
    parser.add_argument("--stop-file", metavar="CHEMIN", help="fichier dont l'apparition demande l'arrêt")
    parser.add_argument("--journal", metavar="CHEMIN", help="journal SQLite (défaut : SOULBAH_RUNTIME_DIR)")
    args = parser.parse_args(argv)
    setup_logging()

    try:
        bundle = load_json(args.task)
        task = bundle["task"] if isinstance(bundle, dict) and "task" in bundle else bundle
        runtime_id = bundle.get("runtime_id") if isinstance(bundle, dict) else None
        if not isinstance(task, dict) or not task.get("id"):
            raise ValueError("tâche sans identifiant")
        decisions = None
        if args.resume:
            resume = load_json(args.resume)
            decisions = resume.get("actions") if isinstance(resume, dict) else resume
            if not isinstance(decisions, list):
                raise ValueError("décisions de reprise invalides")
    except (OSError, ValueError, KeyError, TypeError) as e:
        log.error("Fichier de tâche illisible : %s", e)
        return EXIT_USAGE

    import soulbah_agent  # import tardif : évite de charger l'agent V1 quand on affiche l'aide

    try:
        cfg = load_config(require_key=True)
    except SystemExit as e:
        log.error("%s", e)
        return EXIT_CONFIG
    cfg.dry_run = bool(task.get("simulated"))
    executor, code = soulbah_agent.build_executor(cfg)
    if executor is None:
        return EXIT_CONFIG

    journal = Journal(args.journal) if args.journal else Journal()
    client = RuntimeClient(cfg, journal, runtime_id=str(runtime_id) if runtime_id else None)
    if cfg.approval_mode in ("remote", "both"):
        executor.gate.approver = RemoteApprover(client, timeout_s=cfg.confirm_timeout)

    run = TaskRun(task, executor, client, journal, stop_file=args.stop_file)

    def _stop(_signum, _frame):
        run.interrupt("interruption locale (signal)")

    old_int = signal.signal(signal.SIGINT, _stop)
    old_term = signal.signal(signal.SIGTERM, _stop)
    log.info("Worker %s · tentative %d · %d étape(s) · simulé=%s · approbations=%s", run.short, run.attempt,
             len(run.steps), run.simulated, cfg.approval_mode)
    try:
        return run.run(decisions, args.answer)
    except Exception as e:  # noqa: BLE001 - toute exception devient un message ERROR crash
        log.exception("Exception non gérée dans le worker %s", run.short)
        try:
            run._final_error("crash", f"{e.__class__.__name__}: {e}", None)
        except Exception:  # noqa: BLE001
            log.exception("Envoi du message ERROR crash impossible")
        return EXIT_CRASH
    finally:
        signal.signal(signal.SIGINT, old_int)
        signal.signal(signal.SIGTERM, old_term)
        journal.close()


if __name__ == "__main__":
    sys.exit(main())
