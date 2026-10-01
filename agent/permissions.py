"""Gate de permissions : rien de sensible ne s'exécute sans autorisation."""
from __future__ import annotations

import logging
import os
import sys
import time
from typing import Any, Callable

from skills.base import Skill
from skills.manifests import confirm_step_types, path_param_names
from skills.safety import canonical_path, deny_reason, workspace_errors  # noqa: F401 - réexporté

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

# Champs de chemin vérifiés (whitelist + deny-list) quelle que soit la catégorie : tous
# les paramètres `is_path` des manifestes (texte, ou liste de chemins comme `clips`).
_PATH_KEYS, _PATH_LIST_KEYS = path_param_names()

DEFAULT_CONFIRM_TIMEOUT = 120.0
# Réponse exigée pour une action de niveau L3 (risquée / irréversible).
L3_ANSWER = "confirmer"

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
    ):
        self.mode = mode  # "confirm" | "auto"
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
        complet n'est affiché que sur la console locale (S7)."""
        emit: EmitFn | None = ctx.get("emit")
        index = ctx.get("step_index")
        summary = skill.describe(step)
        level = 3 if skill.confirm_level(step) >= 3 else 2

        def _emit(etype: str, message: str, data: dict) -> None:
            if emit is None:
                return
            try:
                emit(etype, message, data)
            except Exception:  # noqa: BLE001 - un évènement ne doit pas bloquer le gate
                log.debug("Évènement %s non émis", etype, exc_info=True)

        _emit("approval_required", f"En attente de confirmation sur le PC : {summary}", {
            "step_index": index, "action": str(step.get("type", skill.name)), "summary": summary,
            "level": level,
        })
        approved, reason = self._ask(skill, step, summary, level, why, ctx.get("stop_check"))
        _emit("approval_result", "Action approuvée" if approved else f"Action refusée ({reason})", {
            "step_index": index, "approved": approved,
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

        # 3. En dry-run, on autorise (l'exécuteur simulera sans agir)
        if self.dry_run:
            return True, "dry-run"

        # 4. Commandes : confirmation interactive TOUJOURS exigée, même en mode auto.
        if skill.category in ALWAYS_CONFIRM_CATEGORIES:
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
