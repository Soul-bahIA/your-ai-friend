"""Gate de permissions : rien de sensible ne s'exécute sans autorisation."""
from __future__ import annotations

import logging
import os
import sys
import time
from typing import Any, Callable
from urllib.parse import urlsplit

from skills.base import Skill
from skills.manifests import confirm_step_types, get_manifest, path_param_names
from skills.safety import canonical_path, deny_reason, workspace_errors  # noqa: F401 - réexporté
import soulbah_settings as S

log = logging.getLogger("soulbah.permissions")

# Actions qui pilotent directement l'ordinateur ou le téléphone (souris, clavier,
# fenêtres, lancement d'application, ADB). Elles n'ont PAS de chemin à valider :
# leur portée est l'écran entier. Le mode "auto" seul ne les autorise donc pas —
# il faut soit une confirmation interactive, soit une pré-autorisation explicite
# (allow_input_control). Le téléphone est sous ce verrou depuis le LOT 1 (S6).
INPUT_CONTROL_CATEGORIES = frozenset({"mouse", "keyboard", "window", "app_launch", "phone"})

# Catégories qui exigent TOUJOURS une confirmation interactive, quel que soit le
# mode (auto inclus) et même avec allow_input_control : exécution de commandes.
ALWAYS_CONFIRM_CATEGORIES = frozenset({"shell"})

# S21 : étapes « à effet réel » — manifestes `requires_confirmation` (LOT 2 : même
# source que SENSITIVE_STEP_TYPES côté serveur, via shared/tools/catalog.json). Le
# serveur pose payload.requires_confirmation=true dès qu'une tâche en contient une (le
# client ne peut pas l'abaisser) : ces étapes sont alors TOUJOURS confirmées sur le PC,
# même en mode auto et même avec allow_input_control. Le drapeau n'ajoute que des
# confirmations : il ne dispense jamais d'une vérification locale.
SERVER_CONFIRM_STEP_TYPES = confirm_step_types()
SERVER_CONFIRM_REASON = "confirmation exigée par le serveur pour cette action à effet réel (requires_confirmation)"

# LOT 12 (audit §9.10) : une action de niveau L3 (suppression de branche, push…) est TOUJOURS
# confirmée au niveau 3 (« confirmer » sur la console, approbation L3 dans l'app), quel que soit le
# mode, allow_input_control ou un grant de session.
def manifest_level(step: dict) -> str | None:
    m = get_manifest(str(step.get("type", "")).strip())
    return m["security_level"] if m else None


def is_l3(skill: Skill, step: dict) -> bool:
    try:
        if skill.confirm_level(step) >= 3:
            return True
    except Exception:  # noqa: BLE001 - doute = niveau le plus strict
        return True
    return manifest_level(step) == "L3"


# Champs de chemin vérifiés (whitelist + deny-list) quelle que soit la catégorie : tous
# les paramètres `is_path` des manifestes (texte, ou liste de chemins comme `clips`).
_PATH_KEYS, _PATH_LIST_KEYS = path_param_names()

# V3 LOT 1 : étapes coupées par recording=false.
RECORDING_STEP_TYPES = frozenset({"record_screen", "start_recording", "start_recording_bg"})

DEFAULT_CONFIRM_TIMEOUT = 120.0
# Réponse exigée pour une action de niveau L3 (risquée / irréversible).
L3_ANSWER = "confirmer"

# LOT 6 : où la confirmation est demandée (config.approval_mode).
APPROVAL_CONSOLE = "console"  # sur le PC (historique)
APPROVAL_REMOTE = "remote"  # approbation HMAC dans l'app (approvals.RemoteApprover)
APPROVAL_BOTH = "both"  # remote d'abord ; repli console si la route n'existe pas (404)

EmitFn = Callable[[str, str, dict], None]


def normalize_dir(path: str) -> str:
    """normcase + realpath : comparaison insensible à la casse sous Windows et
    résolution des liens symboliques/jonctions (un lien dans un dossier autorisé
    ne doit pas permettre de sortir de la whitelist). Le préfixe long (`\\\\?\\`)
    est retiré, comme pour la deny-list (skills.safety.canonical_path)."""
    return canonical_path(path)


def path_inside(path: str, normalized_dirs: list[str]) -> bool:
    """True si `path` (résolu) est égal à, ou contenu dans, l'un des dossiers
    normalisés (cf. normalize_dir)."""
    if not normalized_dirs or not isinstance(path, str) or not path.strip():
        return False
    if "\x00" in path:
        return False
    try:
        target = normalize_dir(path)
    except (OSError, ValueError):
        return False
    return any(
        target == base or target.startswith(base.rstrip(os.sep) + os.sep)
        for base in normalized_dirs
    )


def _timed_input(prompt: str, timeout: float, should_stop: Callable[[], bool] | None = None) -> str | None:
    """Lit une ligne au clavier avec délai. Retourne None si le délai expire ou si
    `should_stop()` devient vrai (Ctrl+C, tâche annulée/reprise par le serveur).

    Lève EOFError s'il n'y a pas de console interactive."""
    stdin = sys.stdin
    if stdin is None or not stdin.isatty():
        raise EOFError("pas de console interactive")
    stop = should_stop or (lambda: False)

    if sys.platform == "win32":
        import msvcrt

        sys.stdout.write(prompt)
        sys.stdout.flush()
        deadline = time.monotonic() + timeout
        chars: list[str] = []
        while time.monotonic() < deadline and not stop():
            if msvcrt.kbhit():
                ch = msvcrt.getwch()
                if ch in ("\r", "\n"):
                    sys.stdout.write("\n")
                    sys.stdout.flush()
                    return "".join(chars)
                if ch in ("\x03", "\x1b"):  # Ctrl+C / Échap : refus immédiat
                    sys.stdout.write("\n")
                    sys.stdout.flush()
                    return ""
                if ch == "\x08":  # retour arrière
                    if chars:
                        chars.pop()
                        sys.stdout.write("\b \b")
                elif ch in ("\x00", "\xe0"):  # touche spéciale (flèches…) : ignorée
                    msvcrt.getwch()
                else:
                    chars.append(ch)
                    sys.stdout.write(ch)
                sys.stdout.flush()
            else:
                time.sleep(0.05)
        sys.stdout.write("\n")
        sys.stdout.flush()
        return None

    import select

    sys.stdout.write(prompt)
    sys.stdout.flush()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and not stop():
        ready, _, _ = select.select([stdin], [], [], min(0.25, max(0.0, deadline - time.monotonic())))
        if ready:
            line = stdin.readline()
            if not line:
                raise EOFError("fin de l'entrée standard")
            return line.rstrip("\r\n")
    sys.stdout.write("\n")
    return None


class PermissionGate:
    def __init__(
        self,
        mode: str,
        allowed_dirs: list[str],
        dry_run: bool,
        allow_input_control: bool = False,
        confirm_timeout: float = DEFAULT_CONFIRM_TIMEOUT,
        approval_mode: str = APPROVAL_CONSOLE,
        approver: Any | None = None,
        settings: dict[str, Any] | None = None,
    ):
        self.mode = mode  # "confirm" | "auto"
        # V3 LOT 1 : configuration centrale (mode OFFLINE / LOCAL_INTERNET / HYBRID, contrôle de
        # l'ordinateur, enregistrement). Défaut : HYBRID, comportement V2 inchangé.
        self.settings = settings if settings is not None else S.resolve({})["settings"]
        # LOT 6 : console | remote | both ; `approver` = approvals.RemoteApprover (posé par
        # l'agent une fois le client HTTP créé ; None = aucune approbation distante possible).
        self.approval_mode = approval_mode if approval_mode in (APPROVAL_CONSOLE, APPROVAL_REMOTE, APPROVAL_BOTH) \
            else APPROVAL_CONSOLE
        self.approver = approver
        self.allowed_dirs = [normalize_dir(d) for d in allowed_dirs]
        self.dry_run = dry_run
        # Verrou dédié aux actions d'entrée (souris/clavier/fenêtre/app/téléphone) :
        # pré-autorise leur exécution sans confirmation, SAUF actions à risque
        # (Skill.input_risk : raccourci ouvrant un terminal, saisie dans une
        # fenêtre inconnue…). À n'activer qu'avec le consentement de l'utilisateur.
        self.allow_input_control = allow_input_control
        # Sans réponse dans ce délai, la confirmation est REFUSÉE par défaut.
        self.confirm_timeout = max(1.0, float(confirm_timeout))

    # --- chemins -----------------------------------------------------------
    def path_refusal(self, path: object) -> str | None:
        """Raison du refus d'un chemin (hors whitelist ou deny-list), ou None."""
        if not isinstance(path, str) or not path.strip():
            return f"chemin invalide : {path!r}"
        if not path_inside(path, self.allowed_dirs):
            return f"chemin hors liste blanche : {path}"
        reason = deny_reason(path)
        if reason:
            return f"chemin interdit ({reason}) : {path}"
        return None

    def path_allowed(self, path: str) -> bool:
        """Un chemin est autorisé s'il est dans la liste blanche ET hors deny-list."""
        return self.path_refusal(path) is None

    def _check_paths(self, skill: Skill, step: dict) -> str | None:
        for key in _PATH_KEYS:
            p = step.get(key)
            if p is None or p == "":
                continue
            err = self.path_refusal(p)
            if err:
                return err
        for key in _PATH_LIST_KEYS:
            items = step.get(key)
            if items is None:
                continue
            if not isinstance(items, list):
                return f"champ '{key}' invalide (liste de chemins attendue)"
            for p in items:
                err = self.path_refusal(p)
                if err:
                    return err
        return None

    def _validate(self, skill: Skill, step: dict) -> str | None:
        err = self._check_paths(skill, step)
        if err:
            return err
        try:
            return skill.validate(step, self.path_allowed)
        except Exception as e:  # noqa: BLE001 - une validation qui plante = refus
            log.exception("Validation du skill %s en erreur", skill.name)
            return f"validation impossible : {e}"

    def recheck(self, skill: Skill, step: dict) -> str | None:
        """Revalidation juste avant l'exécution (S28) : un lien symbolique remplacé
        pendant la confirmation ne doit pas faire sortir de la whitelist."""
        err = self._validate(skill, step)
        return f"revalidation avant exécution : {err}" if err else None

    # --- confirmation --------------------------------------------------------
    def _confirm(self, skill: Skill, step: dict, ctx: dict[str, Any], why: str | None = None) -> tuple[bool, str]:
        """Confirmation interactive avec délai. Sans console (stdin non interactif)
        ou sans réponse à temps, on REFUSE par sécurité.

        Évènements (contrat §13) : `approval_required` avant de demander,
        `approval_result` après. Le résumé envoyé est masqué (S8) ; le contenu
        complet n'est affiché que sur la console locale (S7).

        LOT 6 : selon `approval_mode`, la décision est prise sur la console (historique),
        dans l'app (approbation HMAC liée au payload — approvals.RemoteApprover) ou dans
        l'app avec repli console si le serveur n'a pas la route (404, serveur V1). Le jeton
        obtenu est posé dans ctx["approval_token"] (jamais émis dans un évènement) et
        l'identifiant dans ctx["approval_id"] (repris par step_started)."""
        emit: EmitFn | None = ctx.get("emit")
        index = ctx.get("step_index")
        summary = skill.describe(step)
        level = 3 if is_l3(skill, step) else 2
        action = str(step.get("type", skill.name))

        def _emit(etype: str, message: str, data: dict) -> None:
            if emit is None:
                return
            try:
                emit(etype, message, data)
            except Exception:  # noqa: BLE001 - un évènement ne doit pas bloquer le gate
                log.debug("Évènement %s non émis", etype, exc_info=True)

        def _required(approval_id: str | None, where: str) -> None:
            _emit("approval_required", f"En attente de confirmation {where} : {summary}", {
                "step_index": index, "action": action, "summary": summary,
                "level": f"L{level}", "approval_id": approval_id,
            })

        remote = False
        approval_id: str | None = None
        use_remote = self.approval_mode in (APPROVAL_REMOTE, APPROVAL_BOTH)
        if use_remote and self.approver is None and self.approval_mode == APPROVAL_REMOTE:
            approved, reason = False, "approbation distante exigée (SOULBAH_APPROVAL_MODE=remote) mais aucun client"
            remote = True
            _required(None, "dans l'app")
        elif use_remote and self.approver is not None:
            requested: dict[str, str | None] = {"id": None}

            def _on_requested(new_id: str) -> None:
                requested["id"] = new_id
                _required(new_id, "dans l'app")

            decision = self.approver.request(step, skill, level, summary, ctx, on_requested=_on_requested)
            approval_id = getattr(decision, "approval_id", None) or requested["id"]
            if getattr(decision, "unavailable", False) and self.approval_mode == APPROVAL_BOTH:
                log.warning("Approbations distantes indisponibles (route absente : serveur V1) — "
                            "repli sur la confirmation console pour cette action")
                _required(None, "sur le PC")
                approved, reason = self._ask(skill, step, summary, level, why, ctx.get("stop_check"))
            else:
                remote = True
                if requested["id"] is None:
                    _required(approval_id, "dans l'app")
                approved, reason, token = decision
                if approved and token:
                    ctx["approval_token"] = token
        else:
            _required(None, "sur le PC")
            approved, reason = self._ask(skill, step, summary, level, why, ctx.get("stop_check"))
        if approval_id:
            ctx["approval_id"] = approval_id
        _emit("approval_result", "Action approuvée" if approved else f"Action refusée ({reason})", {
            "step_index": index, "approved": approved, "reason": reason, "remote": remote,
            "approval_id": approval_id,
        })
        return approved, reason

    def _ask(self, skill: Skill, step: dict, summary: str, level: int, why: str | None,
             stop_check: Callable[[], bool] | None) -> tuple[bool, str]:
        try:
            print(f"\n  ⚠  Action sensible [{skill.category}] : {summary}")
            if why:
                print(f"     Pourquoi une confirmation : {why}")
            details = None
            try:
                details = skill.confirm_details(step)
            except Exception as e:  # noqa: BLE001
                details = f"(détails indisponibles : {e})"
            if details:
                print("     ─── Contenu complet (affiché sur ce PC uniquement) ───")
                for line in str(details).splitlines() or [""]:
                    print(f"     │ {line}")
                print("     ──────────────────────────────────────────────────────")
            if level >= 3:
                prompt = (f"     Action L3 (risquée/irréversible) : tapez « {L3_ANSWER} » pour autoriser "
                          f"(refus auto dans {int(self.confirm_timeout)} s) ")
            else:
                prompt = f"     Autoriser ? [o/N] (refus auto dans {int(self.confirm_timeout)} s) "
            if stop_check is None:
                answer = _timed_input(prompt, self.confirm_timeout)
            else:
                answer = _timed_input(prompt, self.confirm_timeout, should_stop=stop_check)
        except EOFError:
            return False, "confirmation impossible (pas de console) — refusé"
        if stop_check is not None and stop_check():
            return False, "confirmation interrompue (arrêt demandé)"
        if answer is None:
            log.warning("Pas de réponse en %d s — action refusée par défaut", int(self.confirm_timeout))
            return False, f"pas de réponse en {int(self.confirm_timeout)} s — refusé par défaut"
        value = answer.strip().lower()
        if level >= 3:
            if value == L3_ANSWER:
                return True, "validé par l'utilisateur (L3)"
            return False, f"refusé (action L3 : « {L3_ANSWER} » attendu)"
        if value in ("o", "oui", "y", "yes"):
            return True, "validé par l'utilisateur"
        return False, "refusé par l'utilisateur"

    # --- configuration centrale (V3 LOT 1) ------------------------------------------
    def settings_refusal(self, skill: Skill, step: dict) -> str | None:
        """Refus imposé par la configuration centrale, AVANT toute confirmation : ni le mode
        auto, ni allow_input_control, ni une approbation ne le lèvent."""
        st = self.settings
        stype = str(step.get("type", "")).strip()
        if not st.get("computer_control", True) and skill.category in INPUT_CONTROL_CATEGORIES:
            return "contrôle de l'ordinateur désactivé par la configuration (computer_control=false)"
        if not st.get("recording", True) and stype in RECORDING_STEP_TYPES:
            return "enregistrement de l'écran désactivé par la configuration (recording=false)"
        if not S.internet_allowed(st):
            mode = st.get("mode")
            if skill.name == "browser_get":
                host = (urlsplit(str(step.get("url") or "")).hostname or "")
                if not S.is_local_endpoint(st, host):
                    return f"mode {mode} : lecture web refusée (hôte {host or '?'} hors des machines locales déclarées)"
            if skill.name == "git_push":
                return f"mode {mode} : envoi vers un dépôt distant refusé"
            if skill.name == "run_command" and str(step.get("program") or "").strip() == "npm":
                args = step.get("args") if isinstance(step.get("args"), list) else []
                if args and str(args[0]) in ("ci", "install", "i", "add", "update"):
                    return f"mode {mode} : installation de paquets npm refusée (réseau requis ; cache hors ligne : LOT 10 V3)"
        return None

    # --- décision ------------------------------------------------------------
    def authorize(self, skill: Skill, step: dict, context: dict[str, Any] | None = None) -> tuple[bool, str]:
        """Retourne (autorisé, raison). Applique whitelist + deny-list, validation
        propre au skill, verrou d'entrée et confirmation.

        `context` (facultatif, fourni par l'executor) : `emit` (évènements
        d'approbation), `step_index`, `goal_meta` (tâche planifiée par le serveur),
        `requires_confirmation` (payload.requires_confirmation posé par le serveur),
        `stop_check` (interrompt une confirmation en attente)."""
        ctx = context or {}

        # 1-2. Chemins (whitelist + deny-list permanente) puis validation du skill
        err = self._validate(skill, step)
        if err:
            return False, err

        # 2 bis. Configuration centrale (V3 LOT 1) : mode et interrupteurs, même en dry-run
        #        (un plan simulé doit montrer qu'il serait refusé).
        refusal = self.settings_refusal(skill, step)
        if refusal:
            return False, refusal

        # 3. En dry-run, on autorise (l'exécuteur simulera sans agir)
        if self.dry_run:
            return True, "dry-run"

        # 4. Commandes (et skills qui exécutent du code, ex. git_merge) : confirmation TOUJOURS
        #    exigée, même en mode auto. Actions L3 : idem, au niveau 3 (LOT 12).
        if (skill.category in ALWAYS_CONFIRM_CATEGORIES or getattr(skill, "always_confirm", False)
                or is_l3(skill, step)):
            return self._confirm(skill, step, ctx)

        # 4 bis. S21 : le serveur exige une confirmation pour les actions à effet réel
        #        de cette tâche — ni le mode auto ni allow_input_control n'en dispensent.
        if ctx.get("requires_confirmation") is True and \
                str(step.get("type", "")).strip() in SERVER_CONFIRM_STEP_TYPES:
            why = SERVER_CONFIRM_REASON
            if skill.category in INPUT_CONTROL_CATEGORIES:
                try:
                    risk = skill.input_risk(step)
                except Exception as e:  # noqa: BLE001
                    risk = f"analyse du risque impossible : {e}"
                if risk:
                    why = f"{why} ; {risk}"
            return self._confirm(skill, step, ctx, why=why)

        # 5. Actions non sensibles (wait, liste des téléphones) : autorisées directement
        if not skill.sensitive:
            return True, "action non sensible"

        # 6. Captures d'écran (S17) : sans confirmation seulement pour une tâche
        #    planifiée par le serveur à partir d'un objectif (payload.goal_meta).
        if skill.category == "screen" and ctx.get("goal_meta"):
            return True, "capture planifiée par le serveur (goal_meta)"

        # 7. Verrou des actions d'entrée (souris/clavier/fenêtre/app/téléphone) : le
        #    mode "auto" NE suffit PAS. Même pré-autorisées, les actions à risque
        #    (S3) restent confirmées.
        if skill.category in INPUT_CONTROL_CATEGORIES:
            if self.allow_input_control:
                try:
                    risk = skill.input_risk(step)
                except Exception as e:  # noqa: BLE001
                    risk = f"analyse du risque impossible : {e}"
                if not risk:
                    return True, "contrôle d'entrée pré-autorisé"
                return self._confirm(skill, step, ctx, why=risk)
            return self._confirm(skill, step, ctx)

        # 8. Autres actions sensibles (fichiers, vidéo, captures) : en mode auto,
        #    autorisées sans demander (bornées par la whitelist et la deny-list).
        if self.mode == "auto":
            return True, "mode auto"

        # 9. Mode confirm : validation interactive explicite
        return self._confirm(skill, step, ctx)
