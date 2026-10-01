"""SoulBah Agent — worker local.

Poll la file de tâches du backend Node (`/api/agent-tasks`), exécute les tâches
via des skills sûrs soumis à un gate de permissions, et remonte le résultat.

Usage :
    python soulbah_agent.py            # boucle continue
    python soulbah_agent.py --once     # un seul cycle de poll puis sort
    python soulbah_agent.py --dry-run  # décrit les actions sans les exécuter
"""
from __future__ import annotations

import argparse
import logging
import logging.handlers
import os
import signal
import sys
import threading
import time
from typing import Any

from client import CONFLICT, OK, RETRY, TaskClient, task_attempt
from config import load_config
from executor import Executor
from pending import PendingUpdates
from permissions import PermissionGate

# Console Windows : force l'UTF-8 pour que les symboles des logs (▶ ✔ →)
# ne déclenchent pas d'erreurs d'encodage (cp1252 par défaut).
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass

AGENT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.join(AGENT_DIR, "logs")

log = logging.getLogger("soulbah.agent")

_running = True

# Battement de cœur pendant l'exécution d'une tâche : le backend s'en sert
# comme signe de vie (updated_at) pour ne remettre en file que les tâches
# réellement orphelines. Doit rester nettement sous AGENT_TASK_STALE_SECONDS
# (180 s par défaut côté backend).
HEARTBEAT_SECONDS = 30.0
# Backoff du poll quand le backend est injoignable (plafond).
MAX_POLL_BACKOFF = 60.0


def _setup_logging() -> None:
    fmt = logging.Formatter("%(asctime)s  %(levelname)-7s %(name)s  %(message)s", datefmt="%H:%M:%S")
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    console = logging.StreamHandler()
    console.setFormatter(fmt)
    root.addHandler(console)
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        file_handler = logging.handlers.RotatingFileHandler(
            os.path.join(LOG_DIR, "agent.log"), maxBytes=1_000_000, backupCount=5, encoding="utf-8"
        )
        file_handler.setFormatter(
            logging.Formatter("%(asctime)s  %(levelname)-7s %(name)s  %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
        )
        root.addHandler(file_handler)
    except OSError as e:
        log.warning("Journal fichier indisponible (%s) — console uniquement", e)


def _stop(_signum, _frame):
    global _running
    _running = False
    log.info("Arrêt demandé — fin du cycle en cours…")


def _send_final(
    client: TaskClient,
    pending: PendingUpdates,
    task_id: str,
    status: str,
    attempt: int,
    result: dict | None = None,
    error_message: str | None = None,
) -> None:
    """Envoie la mise à jour finale ; si le backend est indisponible, elle est
    persistée localement et renvoyée avec backoff (évite une double exécution)."""
    outcome = client.update(task_id, status, result=result, error_message=error_message, attempt=attempt)
    short = str(task_id)[:8]
    if outcome == OK:
        return
    if outcome == CONFLICT:
        log.warning("Mise à jour finale de %s refusée (409) : la tâche n'est plus à cet agent — ignorée", short)
        return
    if outcome == RETRY:
        pending.add(task_id, status, attempt, result=result, error_message=error_message)
        log.warning("Mise à jour finale de %s mise en attente — nouvel envoi automatique (backoff)", short)
        return
    log.error("Mise à jour finale de %s rejetée par le backend — non renvoyée", short)


def handle_task(
    task: dict[str, Any],
    client: TaskClient,
    executor: Executor,
    pending: PendingUpdates,
    confirm_timeout: float = 120.0,
) -> None:
    task_id = task.get("id")
    if not task_id:
        log.warning("Tâche sans identifiant ignorée")
        return
    task_type = task.get("task_type", "?")
    payload = task.get("payload") or {}
    title = payload.get("title", task_type) if isinstance(payload, dict) else task_type
    short = str(task_id)[:8]
    attempt = task_attempt(task)

    if pending.has(task_id):
        log.info("↷ Tâche %s : résultat déjà obtenu, en attente de synchronisation — ignorée", short)
        return

    log.info("▶ Tâche %s « %s » (%s) · tentative %d", short, title, task_type, attempt)
    # Claim atomique : le backend n'accepte in_progress que si la tâche est encore
    # 'pending'. Si un autre agent l'a déjà prise, on passe à la suivante.
    outcome, detail, server_attempt = client.claim(task_id, attempt)
    if outcome == CONFLICT:
        log.info("↷ Tâche %s déjà prise par un autre agent (409) — ignorée", short)
        return
    if outcome == RETRY:
        log.warning("✖ Claim de la tâche %s impossible — backend injoignable ou en erreur (%s) ; "
                    "nouvel essai au prochain cycle", short, detail)
        return
    if outcome != OK:
        log.error("✖ Claim de la tâche %s refusé par le backend (%s) — ignorée", short, detail)
        return
    if server_attempt is not None:
        attempt = server_attempt

    # Posé quand le backend répond 409 à un évènement/heartbeat : la tâche a été
    # remise en file ou n'est plus in_progress => on arrête d'agir pour elle.
    abort = threading.Event()
    last_progress = [time.monotonic()]

    def _conflict(source: str) -> None:
        if not abort.is_set():
            abort.set()
            log.warning("⚠ Tâche %s : le serveur ne la considère plus comme la nôtre (409 sur %s) — "
                        "exécution interrompue après l'étape en cours", short, source)

    # Streaming temps réel vers le poste de pilotage : évènements + contrôle.
    def on_event(etype: str, message: str, data: dict) -> None:
        last_progress[0] = time.monotonic()
        if abort.is_set():
            return
        if client.event(task_id, etype, message, data, attempt=attempt) == CONFLICT:
            _conflict(f"l'évènement {etype}")

    def check_control() -> str:
        return client.get_control(task_id)

    # Heartbeat : signe de vie périodique tant que la tâche progresse. S'il n'y a
    # plus aucune progression au-delà du délai max d'une étape (+ confirmation),
    # on cesse d'émettre : une tâche bloquée ne doit pas rester vivante pour toujours.
    stall_limit = executor.max_step_timeout() + confirm_timeout + 120.0
    hb_stop = threading.Event()

    def _heartbeat() -> None:
        while not hb_stop.wait(HEARTBEAT_SECONDS):
            if time.monotonic() - last_progress[0] > stall_limit:
                log.error("Tâche %s sans progression depuis %d s — heartbeat arrêté", short, int(stall_limit))
                return
            if client.event(task_id, "heartbeat", None, {}, attempt=attempt) == CONFLICT:
                _conflict("le heartbeat")
                return

    hb_thread = threading.Thread(target=_heartbeat, daemon=True, name="heartbeat")
    hb_thread.start()

    try:
        report = executor.run_task(payload, on_event=on_event, check_control=check_control, abort=abort)
    except Exception as e:  # noqa: BLE001 - une tâche ne doit jamais tuer l'agent
        log.exception("Exception non gérée sur la tâche %s", task_id)
        if not abort.is_set():
            on_event("task_failed", f"Erreur : {e}", {})
            _send_final(client, pending, task_id, "failed", attempt, error_message=str(e))
        return
    finally:
        hb_stop.set()

    if abort.is_set() or report.get("aborted"):
        log.warning("✖ Tâche %s abandonnée (409) — aucun statut final envoyé", short)
        return

    if report["ok"]:
        _send_final(client, pending, task_id, "completed", attempt, result=report)
        log.info("✔ Tâche %s terminée", short)
    else:
        _send_final(client, pending, task_id, "failed", attempt, result=report, error_message=report["summary"])
        log.warning("✖ Tâche %s en échec : %s", short, report["summary"])


def main() -> int:
    parser = argparse.ArgumentParser(description="SoulBah Agent — worker local")
    parser.add_argument("--once", action="store_true", help="un seul cycle de poll")
    parser.add_argument("--dry-run", action="store_true", help="ne rien exécuter réellement")
    parser.add_argument("--auto", action="store_true",
                        help="mode auto (pas de confirmation, sauf run_command) — à vos risques")
    parser.add_argument(
        "--allow-input-control",
        action="store_true",
        help="pré-autorise souris/clavier/fenêtre/app sans confirmation (consentement explicite)",
    )
    args = parser.parse_args()

    _setup_logging()
    cfg = load_config()
    if args.dry_run:
        cfg.dry_run = True
    if args.auto:
        cfg.permission_mode = "auto"
    if args.allow_input_control:
        cfg.allow_input_control = True

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    client = TaskClient(cfg)
    gate = PermissionGate(
        cfg.permission_mode, cfg.allowed_dirs, cfg.dry_run, cfg.allow_input_control,
        confirm_timeout=cfg.confirm_timeout,
    )
    executor = Executor(gate, step_timeout=cfg.step_timeout)
    pending = PendingUpdates()

    mode = "DRY-RUN" if cfg.dry_run else cfg.permission_mode.upper()
    input_ctrl = "pré-autorisé" if cfg.allow_input_control else "sur confirmation"
    log.info("SoulBah Agent démarré · mode=%s · entrée(souris/clavier)=%s · poll=%ss · étape≤%ss · api=%s",
             mode, input_ctrl, cfg.poll_interval, int(cfg.step_timeout), cfg.api_url)
    # Annonce la whitelist au backend pour que le planificateur génère des
    # chemins valides. Non bloquant : en cas d'échec, l'agent fonctionne quand même.
    if client.announce(cfg.allowed_dirs):
        log.info("Whitelist annoncée au backend : %s",
                 "; ".join(cfg.allowed_dirs) or "(aucun dossier)")
    if cfg.dry_run:
        log.info("Aucune action réelle ne sera exécutée (dry-run).")

    # Mises à jour finales restées en attente lors d'une session précédente.
    if len(pending):
        log.info("%d mise(s) à jour finale(s) en attente — renvoi…", len(pending))
        pending.flush(client, force=True)

    failures = 0
    while _running:
        pending.flush(client)
        tasks = client.poll()
        if tasks is None:
            failures += 1
            delay = min(cfg.poll_interval * (2 ** failures), MAX_POLL_BACKOFF)
            log.warning("Backend injoignable — nouvel essai dans %.0f s", delay)
        else:
            if failures:
                log.info("Connexion au backend rétablie")
            failures = 0
            delay = cfg.poll_interval
            if tasks:
                log.info("%d tâche(s) en attente", len(tasks))
            for task in tasks:
                if not _running:
                    break
                handle_task(task, client, executor, pending, confirm_timeout=cfg.confirm_timeout)

        if args.once:
            break

        # Attente fractionnée pour réagir vite à Ctrl+C
        waited = 0.0
        while _running and waited < delay:
            time.sleep(0.25)
            waited += 0.25

    if len(pending):
        pending.flush(client, force=True)
        if len(pending):
            log.warning("%d mise(s) à jour finale(s) toujours en attente — renvoyée(s) au prochain démarrage",
                        len(pending))
    log.info("Agent arrêté.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
