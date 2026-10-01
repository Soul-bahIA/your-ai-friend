"""Gate de permissions : rien de sensible ne s'exécute sans autorisation."""
from __future__ import annotations

import logging
import os
import sys
import time

from skills.base import Skill

log = logging.getLogger("soulbah.permissions")

# Actions qui pilotent directement l'ordinateur (souris, clavier, fenêtres,
# lancement d'application). Elles n'ont PAS de chemin à valider : leur portée est
# l'écran entier. Le mode "auto" seul ne les autorise donc pas — il faut soit une
# confirmation interactive, soit une pré-autorisation explicite (allow_input_control).
INPUT_CONTROL_CATEGORIES = frozenset({"mouse", "keyboard", "window", "app_launch"})

# Catégories qui exigent TOUJOURS une confirmation interactive, quel que soit le
# mode (auto inclus) et même avec allow_input_control : exécution de commandes.
ALWAYS_CONFIRM_CATEGORIES = frozenset({"shell"})

# Catégories dont les champs de chemin sont vérifiés contre la whitelist.
_PATH_CATEGORIES = frozenset({"filesystem", "shell", "video", "phone", "screen"})
_PATH_KEYS = ("src", "dest", "path", "cwd", "output", "audio")

DEFAULT_CONFIRM_TIMEOUT = 120.0


def normalize_dir(path: str) -> str:
    """normcase + realpath : comparaison insensible à la casse sous Windows et
    résolution des liens symboliques/jonctions (un lien dans un dossier autorisé
    ne doit pas permettre de sortir de la whitelist)."""
    return os.path.normcase(os.path.realpath(path))


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


def _timed_input(prompt: str, timeout: float) -> str | None:
    """Lit une ligne au clavier avec délai. Retourne None si le délai expire.

    Lève EOFError s'il n'y a pas de console interactive."""
    stdin = sys.stdin
    if stdin is None or not stdin.isatty():
        raise EOFError("pas de console interactive")

    if sys.platform == "win32":
        import msvcrt

        sys.stdout.write(prompt)
        sys.stdout.flush()
        deadline = time.monotonic() + timeout
        chars: list[str] = []
        while time.monotonic() < deadline:
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
    ready, _, _ = select.select([stdin], [], [], timeout)
    if not ready:
        sys.stdout.write("\n")
        return None
    line = stdin.readline()
    if not line:
        raise EOFError("fin de l'entrée standard")
    return line.rstrip("\r\n")


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
        # Verrou dédié aux actions d'entrée (souris/clavier/fenêtre/app) : pré-autorise
        # leur exécution sans confirmation. À n'activer que si l'utilisateur a
        # explicitement consenti à laisser l'agent piloter son écran.
        self.allow_input_control = allow_input_control
        # Sans réponse dans ce délai, la confirmation est REFUSÉE par défaut.
        self.confirm_timeout = max(1.0, float(confirm_timeout))

    def path_allowed(self, path: str) -> bool:
        """Un chemin est autorisé s'il est contenu dans un dossier de la liste blanche."""
        return path_inside(path, self.allowed_dirs)

    def _confirm(self, skill: Skill, step: dict) -> tuple[bool, str]:
        """Confirmation interactive avec délai. Sans console (stdin non interactif)
        ou sans réponse à temps, on REFUSE par sécurité."""
        try:
            print(f"\n  ⚠  Action sensible [{skill.category}] : {skill.describe(step)}")
            answer = _timed_input(
                f"     Autoriser ? [o/N] (refus auto dans {int(self.confirm_timeout)} s) ",
                self.confirm_timeout,
            )
        except EOFError:
            return False, "confirmation impossible (pas de console) — refusé"
        if answer is None:
            log.warning("Pas de réponse en %d s — action refusée par défaut", int(self.confirm_timeout))
            return False, f"pas de réponse en {int(self.confirm_timeout)} s — refusé par défaut"
        if answer.strip().lower() in ("o", "oui", "y", "yes"):
            return True, "validé par l'utilisateur"
        return False, "refusé par l'utilisateur"

    def _check_paths(self, skill: Skill, step: dict) -> str | None:
        if skill.category not in _PATH_CATEGORIES:
            return None
        for key in _PATH_KEYS:
            p = step.get(key)
            if p is None or p == "":
                continue
            if not isinstance(p, str) or not self.path_allowed(p):
                return f"chemin hors liste blanche : {p}"
        clips = step.get("clips")
        if clips is not None:
            if not isinstance(clips, list):
                return "champ 'clips' invalide (liste de chemins attendue)"
            for p in clips:
                if not isinstance(p, str) or not self.path_allowed(p):
                    return f"chemin hors liste blanche : {p}"
        return None

    def authorize(self, skill: Skill, step: dict) -> tuple[bool, str]:
        """Retourne (autorisé, raison). Applique whitelist, validation propre au
        skill, verrou d'entrée et confirmation."""
        # 1. Contrôle des chemins : fichiers, répertoire de commandes (cwd), vidéo,
        #    téléphone, capture d'écran (path/output/audio/clips)
        err = self._check_paths(skill, step)
        if err:
            return False, err

        # 2. Validation spécifique au skill (allowlist de commandes, d'applis…)
        try:
            err = skill.validate(step, self.path_allowed)
        except Exception as e:  # noqa: BLE001 - une validation qui plante = refus
            log.exception("Validation du skill %s en erreur", skill.name)
            err = f"validation impossible : {e}"
        if err:
            return False, err

        # 3. En dry-run, on autorise (l'exécuteur simulera sans agir)
        if self.dry_run:
            return True, "dry-run"

        # 4. Commandes : confirmation interactive TOUJOURS exigée, même en mode auto.
        if skill.category in ALWAYS_CONFIRM_CATEGORIES:
            return self._confirm(skill, step)

        # 5. Actions non sensibles : autorisées directement
        if not skill.sensitive:
            return True, "action non sensible"

        # 6. Verrou des actions d'entrée (souris/clavier/fenêtre/app) : le mode "auto"
        #    NE suffit PAS. Sans pré-autorisation explicite, on exige une confirmation
        #    interactive — même en auto — car ces actions échappent à la whitelist.
        if skill.category in INPUT_CONTROL_CATEGORIES:
            if self.allow_input_control:
                return True, "contrôle d'entrée pré-autorisé"
            return self._confirm(skill, step)

        # 7. Autres actions sensibles (fichiers, vidéo, téléphone) : en mode auto,
        #    autorisées sans demander (elles restent bornées par la whitelist).
        if self.mode == "auto":
            return True, "mode auto"

        # 8. Mode confirm : validation interactive explicite
        return self._confirm(skill, step)
