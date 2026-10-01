"""SoulBah Agent — worker local.

Poll la file de tâches du backend Node (`/api/agent-tasks`), exécute les tâches
via des skills sûrs soumis à un gate de permissions, et remonte le résultat.

Usage :
    python soulbah_agent.py                            # boucle continue
    python soulbah_agent.py --once                     # un seul cycle de poll puis sort
    python soulbah_agent.py --dry-run --plan plan.json # simule un plan LOCAL (aucune tâche serveur)
"""
from __future__ import annotations

import argparse
import json
import logging
import logging.handlers
import os
import signal
import sys
import threading
import time
from dataclasses import dataclass
from typing import Any

from client import AUTH, AUTH_HINT, CONFLICT, CONTROL_GONE, GONE, OK, RETRY, TaskClient, task_attempt
from config import Config, default_workspace, load_config
from executor import Executor
from pending import PendingUpdates
from permissions import PermissionGate, workspace_errors
import skills
from skills.base import CancelToken

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
_interrupts = 0
# Jeton d'annulation de la tâche en cours : annulé par Ctrl+C (T40).
_current_token: CancelToken | None = None
_logging_ready = False

# Battement de cœur pendant l'exécution d'une tâche : le backend s'en sert
# comme signe de vie (updated_at) pour ne remettre en file que les tâches
# réellement orphelines. Doit rester nettement sous AGENT_TASK_STALE_SECONDS
# (180 s par défaut côté backend).
HEARTBEAT_SECONDS = 30.0
# Attente max de la fin du thread heartbeat avant d'envoyer le final (T51).
HEARTBEAT_JOIN_SECONDS = 15.0
# Backoff du poll quand le backend est injoignable (plafond).
MAX_POLL_BACKOFF = 60.0
# Refus d'authentification (401/403) consécutifs avant l'arrêt de l'agent (T41).
MAX_AUTH_FAILURES = 3

_TRUE = ("1", "true", "yes", "oui")


def _setup_logging() -> None:
    global _logging_ready
    if _logging_ready:
        return
    _logging_ready = True
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
    """Ctrl+C / SIGTERM : arrêt de la boucle ET interruption rapide de la tâche en
    cours (jeton annulé → étape interrompue → final `cancelled`). Un second Ctrl+C
    force l'arrêt immédiat."""
    global _running, _interrupts
    _interrupts += 1
    if _interrupts >= 2 and not _running:
        raise KeyboardInterrupt
    _running = False
    token = _current_token
    if token is not None and not token.is_cancelled():
        token.cancel("interruption locale (Ctrl+C)")
        log.warning("Arrêt demandé — interruption de la tâche en cours (statut « cancelled »)… "
                    "Ctrl+C à nouveau pour forcer.")
    else:
        log.info("Arrêt demandé — fin du cycle en cours…")


def _send_final(
    client: TaskClient,
    pending: PendingUpdates,
    task_id: str,
    status: str,
    attempt: int,
    result: dict | None = None,
    error_message: str | None = None,
) -> str:
    """Envoie la mise à jour finale. Si le backend est indisponible, elle est
    persistée et la tâche reste « en finalisation » (aucune nouvelle tâche n'est
    prise) ; si elle est rejetée, un final `failed` minimal la remplace ; si le
    serveur répond 409, le résultat est gardé pour être rejoué sans ré-exécution."""
    outcome = pending.deliver(client, task_id, status, attempt, result, error_message)
    if outcome in (RETRY, AUTH):
        log.warning("Mise à jour finale de %s mise en attente — renvoi automatique (backoff) ; "
                    "aucune nouvelle tâche ne sera prise d'ici là", str(task_id)[:8])
    return outcome


def handle_task(
    task: dict[str, Any],
    client: TaskClient,
    executor: Executor,
    pending: PendingUpdates,
    confirm_timeout: float = 120.0,
) -> str:
    """Traite une tâche reçue par poll. Retourne l'issue : skipped | conflict |
    claim_failed | gone | aborted | replayed | completed | failed | cancelled."""
    global _current_token
    task_id = task.get("id")
    if not task_id:
        log.warning("Tâche sans identifiant ignorée")
        return "skipped"
    task_type = task.get("task_type", "?")
    payload = task.get("payload") or {}
    title = payload.get("title", task_type) if isinstance(payload, dict) else task_type
    short = str(task_id)[:8]
    attempt = task_attempt(task)

    if pending.has(task_id):
        log.info("↷ Tâche %s : résultat déjà obtenu, en attente de synchronisation — ignorée", short)
        return "skipped"
    replay = pending.replay_entry(task_id)

    log.info("▶ Tâche %s « %s » (%s) · tentative %d", short, title, task_type, attempt)
    # Claim atomique : le backend n'accepte in_progress que si la tâche est encore
    # 'pending'. Si un autre agent l'a déjà prise, on passe à la suivante.
    outcome, detail, server_attempt = client.claim(task_id, attempt)
    if outcome == CONFLICT:
        log.info("↷ Tâche %s déjà prise par un autre agent (409) — ignorée", short)
        return "conflict"
    if outcome == GONE:
        log.warning("↷ Tâche %s supprimée côté serveur (410) — ignorée", short)
        pending.discard(task_id)
        return "gone"
    if outcome == AUTH:
        log.error("✖ Claim de la tâche %s refusé : %s", short, detail)
        return "claim_failed"
    if outcome == RETRY:
        log.warning("✖ Claim de la tâche %s impossible — backend injoignable ou en erreur (%s) ; "
                    "nouvel essai au prochain cycle", short, detail)
        return "claim_failed"
    if outcome != OK:
        log.error("✖ Claim de la tâche %s refusé par le backend (%s) — ignorée", short, detail)
        return "claim_failed"
    if server_attempt is not None:
        attempt = server_attempt

    # T9 : tâche déjà exécutée par cet agent puis remise en file par le serveur
    # (final perdu/rejeté) → on renvoie le résultat obtenu, SANS ré-exécuter.
    if replay is not None:
        log.warning("↺ Tâche %s déjà exécutée par cet agent — résultat renvoyé sans ré-exécution "
                    "(tentative %d)", short, attempt)
        result = replay.get("result")
        if isinstance(result, dict):
            result = dict(result, final_replayed=True)
        _send_final(client, pending, task_id, str(replay.get("status") or "failed"), attempt,
                    result=result, error_message=replay.get("error_message"))
        return "replayed"

    # Posé quand le backend répond 409/410 à un évènement/heartbeat/contrôle : la
    # tâche a été remise en file, n'est plus in_progress ou a été supprimée.
    abort = threading.Event()
    gone = threading.Event()
    token = CancelToken()
    last_progress = [time.monotonic()]

    def _lost(source: str, why: str) -> None:
        if why == GONE:
            gone.set()
        if not abort.is_set():
            abort.set()
            if why == GONE:
                log.warning("⚠ Tâche %s supprimée côté serveur (410 sur %s) — abandon immédiat", short, source)
            else:
                log.warning("⚠ Tâche %s : le serveur ne la considère plus comme la nôtre (409 sur %s) — "
                            "exécution interrompue après l'étape en cours", short, source)

    # Streaming temps réel vers le poste de pilotage : évènements + contrôle.
    def on_event(etype: str, message: str, data: dict) -> None:
        last_progress[0] = time.monotonic()
        if abort.is_set():
            return
        out = client.event(task_id, etype, message, data, attempt=attempt)
        if out in (CONFLICT, GONE):
            _lost(f"l'évènement {etype}", out)

    def check_control() -> str:
        ctrl = client.get_control(task_id)
        if ctrl == CONTROL_GONE:
            _lost("le contrôle", GONE)
        return ctrl

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
            out = client.event(task_id, "heartbeat", None, {}, attempt=attempt)
            if out in (CONFLICT, GONE):
                _lost("le heartbeat", out)
                return

    hb_thread = threading.Thread(target=_heartbeat, daemon=True, name="heartbeat")
    hb_thread.start()

    _current_token = token
    if not _running:  # Ctrl+C reçu entre le poll et le démarrage
        token.cancel("interruption locale (Ctrl+C)")
    report: dict[str, Any] | None = None
    crash: Exception | None = None
    try:
        report = executor.run_task(payload, on_event=on_event, check_control=check_control,
                                   abort=abort, cancel=token)
    except Exception as e:  # noqa: BLE001 - une tâche ne doit jamais tuer l'agent
        log.exception("Exception non gérée sur la tâche %s", task_id)
        crash = e
    finally:
        # T51 : le heartbeat est arrêté ET terminé avant le final (sinon 409 parasite).
        hb_stop.set()
        hb_thread.join(HEARTBEAT_JOIN_SECONDS)
        if hb_thread.is_alive():
            log.warning("Thread heartbeat de %s toujours actif après %d s", short, int(HEARTBEAT_JOIN_SECONDS))
        _current_token = None

    if gone.is_set():
        pending.discard(task_id)
        log.warning("✖ Tâche %s supprimée côté serveur (410) — abandonnée, aucun statut final", short)
        return "gone"
    if abort.is_set() or (report is not None and report.get("aborted")):
        log.warning("✖ Tâche %s abandonnée (409) — aucun statut final envoyé", short)
        return "aborted"

    if report is None:
        on_event("task_failed", f"Erreur : {crash}", {})
        _send_final(client, pending, task_id, "failed", attempt,
                    result={"ok": False, "steps": [], "summary": f"erreur interne : {crash}"},
                    error_message=str(crash))
        return "failed"

    if report["ok"]:
        status = "completed"
    elif report.get("cancelled"):
        status = "cancelled"  # T4 : un stop n'est pas un échec (jamais évalué côté serveur)
    else:
        status = "failed"
    _send_final(client, pending, task_id, status, attempt, result=report,
                error_message=None if report["ok"] else report["summary"])
    if status == "completed":
        log.info("✔ Tâche %s terminée", short)
    elif status == "cancelled":
        log.warning("■ Tâche %s annulée : %s", short, report["summary"])
    else:
        log.warning("✖ Tâche %s en échec : %s", short, report["summary"])
    return status


# --- Simulation d'un plan local (T10) -----------------------------------------
def load_plan(path: str) -> dict[str, Any]:
    """Plan local : liste d'étapes, payload {"steps": [...]} ou tâche {"payload": {...}}."""
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, list):
        return {"steps": data}
    if isinstance(data, dict):
        if isinstance(data.get("payload"), dict):
            return data["payload"]
        return data
    raise ValueError('plan invalide : liste d\'étapes ou objet {"steps": [...]} attendu')


def run_local_plan(plan_path: str, executor: Executor) -> int:
    """Simule un plan local : aucune tâche n'est réclamée au serveur, aucune action
    n'est exécutée, le rapport porte `simulated: true`. Code 0 si toutes les étapes
    passent les validations, 1 sinon, 2 si le plan est illisible."""
    global _current_token
    try:
        payload = load_plan(plan_path)
    except (OSError, ValueError) as e:
        log.error("Plan local illisible (%s) : %s", plan_path, e)
        return 2

    def on_event(etype: str, message: str, _data: dict) -> None:
        log.info("[simulation] %-16s %s", etype, message or "")

    token = CancelToken()
    _current_token = token
    try:
        report = executor.run_task(payload, on_event=on_event, cancel=token)
    finally:
        _current_token = None
    report["simulated"] = True
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report.get("ok") else 1


# --- Boucle principale ---------------------------------------------------------
@dataclass
class LoopState:
    failures: int = 0
    auth_failures: int = 0
    finalizing_logged: bool = False
    exit_code: int | None = None


def run_cycle(client: TaskClient, executor: Executor, pending: PendingUpdates, cfg: Config,
              state: LoopState) -> float:
    """Un cycle : renvoi des finals en attente, puis poll si aucune tâche n'est en
    finalisation. Retourne le délai avant le prochain cycle ; `state.exit_code` est
    posé quand l'agent doit s'arrêter (clé révoquée)."""
    pending.flush(client)
    if len(pending):
        # T9 : un final n'est pas encore accepté. La tâche reste « en finalisation »
        # (heartbeat) et AUCUNE nouvelle tâche n'est prise : pas de poll, donc pas
        # de remise en file déclenchée par cet agent.
        pending.keepalive(client)
        if not state.finalizing_logged:
            log.warning("⏳ %d mise(s) à jour finale(s) en attente — aucune nouvelle tâche n'est prise "
                        "tant qu'elle(s) n'est (ne sont) pas acceptée(s)", len(pending))
            state.finalizing_logged = True
        return cfg.poll_interval
    if state.finalizing_logged:
        log.info("Finalisation terminée — reprise du poll")
        state.finalizing_logged = False

    tasks = client.poll()
    if tasks is None:
        if getattr(client, "last_error", None) == AUTH:
            state.auth_failures += 1
            status = getattr(client, "last_status", None) or "401/403"
            if state.auth_failures >= MAX_AUTH_FAILURES:
                log.error("✖ %d refus d'authentification consécutifs (HTTP %s) : %s. "
                          "Poll arrêté — corrigez la clé puis relancez l'agent.",
                          state.auth_failures, status, AUTH_HINT)
                state.exit_code = 3
                return 0.0
            log.error("Clé agent refusée par le backend (HTTP %s, %d/%d) : %s",
                      status, state.auth_failures, MAX_AUTH_FAILURES, AUTH_HINT)
            return cfg.poll_interval
        state.failures += 1
        delay = min(cfg.poll_interval * (2 ** state.failures), MAX_POLL_BACKOFF)
        log.warning("Backend injoignable ou en erreur — nouvel essai dans %.0f s", delay)
        return delay

    if state.failures:
        log.info("Connexion au backend rétablie")
    state.failures = 0
    state.auth_failures = 0
    if tasks:
        log.info("%d tâche(s) en attente", len(tasks))
    for task in tasks:
        if not _running:
            break
        handle_task(task, client, executor, pending, confirm_timeout=cfg.confirm_timeout)
        if len(pending):
            break  # un final est en attente : ne pas prendre d'autre tâche
    return cfg.poll_interval


def _interruptible_sleep(delay: float) -> None:
    """Attente fractionnée pour réagir vite à Ctrl+C."""
    waited = 0.0
    while _running and waited < delay:
        time.sleep(0.25)
        waited += 0.25


def _serve(cfg: Config, executor: Executor, once: bool) -> int:
    client = TaskClient(cfg)
    pending = PendingUpdates()
    state = LoopState()

    input_ctrl = "pré-autorisé (actions à risque confirmées)" if cfg.allow_input_control else "sur confirmation"
    log.info("SoulBah Agent démarré · mode=%s · entrée(souris/clavier/téléphone)=%s · poll=%ss · étape≤%ss · api=%s",
             cfg.permission_mode.upper(), input_ctrl, cfg.poll_interval, int(cfg.step_timeout), cfg.api_url)
    log.info("Workspace autorisé : %s", "; ".join(cfg.allowed_dirs))
    # Annonce la whitelist au backend pour que le planificateur génère des
    # chemins valides. Non bloquant : en cas d'échec, l'agent fonctionne quand même.
    if client.announce(cfg.allowed_dirs):
        log.info("Whitelist annoncée au backend")
    elif getattr(client, "last_error", None) == AUTH:
        state.auth_failures = 1

    # Mises à jour finales restées en attente lors d'une session précédente.
    if len(pending):
        log.info("%d mise(s) à jour finale(s) en attente — renvoi…", len(pending))
        pending.flush(client, force=True)

    while _running:
        delay = run_cycle(client, executor, pending, cfg, state)
        if state.exit_code is not None or once:
            break
        _interruptible_sleep(delay)

    if len(pending):
        pending.flush(client, force=True)
        if len(pending):
            log.warning("%d mise(s) à jour finale(s) toujours en attente — renvoyée(s) au prochain démarrage",
                        len(pending))
    log.info("Agent arrêté.")
    return state.exit_code or 0


def main(argv: list[str] | None = None) -> int:
    global _running, _interrupts
    parser = argparse.ArgumentParser(description="SoulBah Agent — worker local")
    parser.add_argument("--once", action="store_true", help="un seul cycle de poll")
    parser.add_argument("--dry-run", action="store_true",
                        help="simulation d'un plan local (--plan) : aucune tâche serveur, aucune action réelle")
    parser.add_argument("--plan", metavar="FICHIER.json",
                        help="plan local à simuler (implique --dry-run)")
    parser.add_argument("--auto", action="store_true",
                        help="mode auto (pas de confirmation pour fichiers/vidéo, sauf run_command) — à vos risques")
    parser.add_argument(
        "--allow-input-control",
        action="store_true",
        help="pré-autorise souris/clavier/fenêtre/app/téléphone (les actions à risque restent confirmées)",
    )
    args = parser.parse_args(argv)

    _setup_logging()
    # LOT 2 : contrat d'outils unique — registre des skills et manifestes cohérents.
    problems = skills.manifest_errors()
    if problems:
        for problem in problems:
            log.error("✖ Catalogue d'outils : %s", problem)
        log.error("Démarrage refusé : le registre des skills et agent/skills/manifests.py divergent "
                  "(voir docs/CATALOGUE_OUTILS.md).")
        return 2
    env_dry = os.environ.get("SOULBAH_DRY_RUN", "").strip().lower() in _TRUE
    dry = bool(args.dry_run or args.plan or env_dry)
    cfg = load_config(require_key=not dry)
    cfg.dry_run = dry
    if args.auto:
        cfg.permission_mode = "auto"
    if args.allow_input_control:
        cfg.allow_input_control = True

    # S1 / contrat §14 : workspace hors du dépôt, jamais le dossier de l'agent.
    errors = workspace_errors(cfg.allowed_dirs)
    if errors:
        for err in errors:
            log.error("✖ %s", err)
        log.error("Démarrage refusé : utilisez un workspace dédié hors du dépôt SoulBah, par exemple %s "
                  "(laissez SOULBAH_ALLOWED_DIRS vide pour l'utiliser).", default_workspace())
        return 2
    if cfg.default_workspace:
        try:
            os.makedirs(cfg.allowed_dirs[0], exist_ok=True)
        except OSError as e:
            log.error("Impossible de créer le workspace %s : %s", cfg.allowed_dirs[0], e)
            return 2

    gate = PermissionGate(
        cfg.permission_mode, cfg.allowed_dirs, cfg.dry_run, cfg.allow_input_control,
        confirm_timeout=cfg.confirm_timeout,
    )
    executor = Executor(gate, step_timeout=cfg.step_timeout)

    _running = True
    _interrupts = 0
    old_int = signal.signal(signal.SIGINT, _stop)
    old_term = signal.signal(signal.SIGTERM, _stop)
    try:
        if cfg.dry_run:
            # T10 : la simulation ne réclame JAMAIS de tâche au serveur.
            if not args.plan:
                log.error("Le dry-run simule un plan LOCAL : python soulbah_agent.py --dry-run --plan plan.json "
                          "(aucune tâche n'est réclamée au serveur en simulation).")
                return 2
            log.info("SIMULATION du plan local %s — aucune action réelle, aucune tâche serveur", args.plan)
            return run_local_plan(args.plan, executor)
        return _serve(cfg, executor, once=args.once)
    except KeyboardInterrupt:
        log.warning("Arrêt forcé (second Ctrl+C) — les finals en attente seront renvoyés au prochain démarrage.")
        return 130
    finally:
        signal.signal(signal.SIGINT, old_int)
        signal.signal(signal.SIGTERM, old_term)


if __name__ == "__main__":
    sys.exit(main())
