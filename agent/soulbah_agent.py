"""SoulBah Agent — worker local.

Poll la file `agent_tasks` (Supabase), exécute les tâches via des skills sûrs
soumis à un gate de permissions, et remonte le résultat.

Usage :
    python soulbah_agent.py            # boucle continue
    python soulbah_agent.py --once     # un seul cycle de poll puis sort
    python soulbah_agent.py --dry-run  # décrit les actions sans les exécuter
"""
from __future__ import annotations

import argparse
import logging
import signal
import sys
import threading
import time
from typing import Any

from client import TaskClient
from config import load_config
from executor import Executor
from permissions import PermissionGate

# Console Windows : force l'UTF-8 pour que les symboles des logs (▶ ✔ →)
# ne déclenchent pas d'erreurs d'encodage (cp1252 par défaut).
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s %(name)s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("soulbah.agent")

_running = True

# Battement de cœur pendant l'exécution d'une tâche : le backend s'en sert
# comme signe de vie (updated_at) pour ne remettre en file que les tâches
# réellement orphelines. Doit rester nettement sous AGENT_TASK_STALE_SECONDS
# (180 s par défaut côté backend).
HEARTBEAT_SECONDS = 30.0


def _stop(_signum, _frame):
    global _running
    _running = False
    log.info("Arrêt demandé — fin du cycle en cours…")


def handle_task(task: dict[str, Any], client: TaskClient, executor: Executor) -> None:
    task_id = task.get("id")
    task_type = task.get("task_type", "?")
    payload = task.get("payload") or {}
    title = payload.get("title", task_type)

    log.info("▶ Tâche %s « %s » (%s)", str(task_id)[:8], title, task_type)
    # Claim atomique : le backend n'accepte in_progress que si la tâche est encore
    # 'pending'. Si un autre agent l'a déjà prise, on passe à la suivante.
    if not client.update(task_id, "in_progress"):
        log.info("↷ Tâche %s déjà prise par un autre agent — ignorée", str(task_id)[:8])
        return

    # Streaming temps réel vers le poste de pilotage : évènements + contrôle.
    def on_event(etype: str, message: str, data: dict) -> None:
        client.event(task_id, etype, message, data)

    def check_control() -> str:
        return client.get_control(task_id)

    # Heartbeat : signe de vie périodique tant que la tâche s'exécute, pour
    # que le backend ne la considère jamais orpheline pendant une étape longue.
    hb_stop = threading.Event()

    def _heartbeat() -> None:
        while not hb_stop.wait(HEARTBEAT_SECONDS):
            client.event(task_id, "heartbeat", None, {})

    hb_thread = threading.Thread(target=_heartbeat, daemon=True, name="heartbeat")
    hb_thread.start()

    try:
        report = executor.run_task(payload, on_event=on_event, check_control=check_control)
    except Exception as e:  # noqa: BLE001 - une tâche ne doit jamais tuer l'agent
        log.exception("Exception non gérée sur la tâche %s", task_id)
        client.event(task_id, "task_failed", f"Erreur : {e}", {})
        client.update(task_id, "failed", error_message=str(e))
        return
    finally:
        hb_stop.set()

    if report["ok"]:
        client.update(task_id, "completed", result=report)
        log.info("✔ Tâche %s terminée", str(task_id)[:8])
    else:
        client.update(task_id, "failed", result=report, error_message=report["summary"])
        log.warning("✖ Tâche %s en échec : %s", str(task_id)[:8], report["summary"])


def main() -> int:
    parser = argparse.ArgumentParser(description="SoulBah Agent — worker local")
    parser.add_argument("--once", action="store_true", help="un seul cycle de poll")
    parser.add_argument("--dry-run", action="store_true", help="ne rien exécuter réellement")
    parser.add_argument("--auto", action="store_true", help="mode auto (pas de confirmation) — à vos risques")
    parser.add_argument(
        "--allow-input-control",
        action="store_true",
        help="pré-autorise souris/clavier/fenêtre/app sans confirmation (consentement explicite)",
    )
    args = parser.parse_args()

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
        cfg.permission_mode, cfg.allowed_dirs, cfg.dry_run, cfg.allow_input_control
    )
    executor = Executor(gate)

    mode = "DRY-RUN" if cfg.dry_run else cfg.permission_mode.upper()
    input_ctrl = "pré-autorisé" if cfg.allow_input_control else "sur confirmation"
    log.info("SoulBah Agent démarré · mode=%s · entrée(souris/clavier)=%s · poll=%ss · api=%s",
             mode, input_ctrl, cfg.poll_interval, cfg.api_url)
    # Annonce la whitelist au backend pour que le planificateur génère des
    # chemins valides. Non bloquant : en cas d'échec, l'agent fonctionne quand même.
    if client.announce(cfg.allowed_dirs):
        log.info("Whitelist annoncée au backend : %s",
                 "; ".join(cfg.allowed_dirs) or "(aucun dossier)")
    if cfg.dry_run:
        log.info("Aucune action réelle ne sera exécutée (dry-run).")

    while _running:
        tasks = client.poll()
        if tasks:
            log.info("%d tâche(s) en attente", len(tasks))
        for task in tasks:
            if not _running:
                break
            handle_task(task, client, executor)

        if args.once:
            break

        # Attente fractionnée pour réagir vite à Ctrl+C
        waited = 0.0
        while _running and waited < cfg.poll_interval:
            time.sleep(0.25)
            waited += 0.25

    log.info("Agent arrêté.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
