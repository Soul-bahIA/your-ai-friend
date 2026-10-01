"""Gate de permissions : rien de sensible ne s'exécute sans autorisation."""
from __future__ import annotations

import logging
import os

from skills.base import Skill

log = logging.getLogger("soulbah.permissions")

# Actions qui pilotent directement l'ordinateur (souris, clavier, fenêtres,
# lancement d'application). Elles n'ont PAS de chemin à valider : leur portée est
# l'écran entier. Le mode "auto" seul ne les autorise donc pas — il faut soit une
# confirmation interactive, soit une pré-autorisation explicite (allow_input_control).
INPUT_CONTROL_CATEGORIES = frozenset({"mouse", "keyboard", "window", "app_launch"})


class PermissionGate:
    def __init__(
        self,
        mode: str,
        allowed_dirs: list[str],
        dry_run: bool,
        allow_input_control: bool = False,
    ):
        self.mode = mode  # "confirm" | "auto"
        # normcase : sous Windows le système de fichiers est insensible à la casse,
        # la comparaison doit l'être aussi (sinon des chemins légitimes sont refusés).
        # realpath : résout les liens symboliques/jonctions pour éviter qu'un lien
        # situé dans un dossier autorisé ne pointe en dehors.
        self.allowed_dirs = [os.path.normcase(os.path.realpath(d)) for d in allowed_dirs]
        self.dry_run = dry_run
        # Verrou dédié aux actions d'entrée (souris/clavier/fenêtre/app) : pré-autorise
        # leur exécution sans confirmation. À n'activer que si l'utilisateur a
        # explicitement consenti à laisser l'agent piloter son écran.
        self.allow_input_control = allow_input_control

    def path_allowed(self, path: str) -> bool:
        """Un chemin est autorisé s'il est contenu dans un dossier de la liste blanche."""
        if not self.allowed_dirs:
            return False
        target = os.path.normcase(os.path.realpath(path))
        return any(
            target == base or target.startswith(base + os.sep)
            for base in self.allowed_dirs
        )

    def _confirm(self, skill: Skill, step: dict) -> tuple[bool, str]:
        """Confirmation interactive. Sans console (stdin non interactif), on REFUSE
        par sécurité plutôt que de laisser passer une action sensible."""
        try:
            print(f"\n  ⚠  Action sensible [{skill.category}] : {skill.describe(step)}")
            answer = input("     Autoriser ? [o/N] ").strip().lower()
        except EOFError:
            return False, "confirmation impossible (pas de console) — refusé"
        if answer in ("o", "oui", "y", "yes"):
            return True, "validé par l'utilisateur"
        return False, "refusé par l'utilisateur"

    def authorize(self, skill: Skill, step: dict) -> tuple[bool, str]:
        """Retourne (autorisé, raison). Applique whitelist, verrou d'entrée, confirmation."""
        # 1. Contrôle des chemins : fichiers, répertoire de commandes (cwd), vidéo, téléphone (path/output/clips)
        if skill.category in ("filesystem", "shell", "video", "phone"):
            for key in ("src", "dest", "path", "cwd", "output", "audio"):
                p = step.get(key)
                if p and not self.path_allowed(p):
                    return False, f"chemin hors liste blanche : {p}"
            clips = step.get("clips")
            if isinstance(clips, list):
                for p in clips:
                    if p and not self.path_allowed(p):
                        return False, f"chemin hors liste blanche : {p}"

        # 2. En dry-run, on autorise (l'exécuteur simulera sans agir)
        if self.dry_run:
            return True, "dry-run"

        # 3. Actions non sensibles : autorisées directement
        if not skill.sensitive:
            return True, "action non sensible"

        # 4. Verrou des actions d'entrée (souris/clavier/fenêtre/app) : le mode "auto"
        #    NE suffit PAS. Sans pré-autorisation explicite, on exige une confirmation
        #    interactive — même en auto — car ces actions échappent à la whitelist.
        if skill.category in INPUT_CONTROL_CATEGORIES:
            if self.allow_input_control:
                return True, "contrôle d'entrée pré-autorisé"
            return self._confirm(skill, step)

        # 5. Autres actions sensibles (run_command, fichiers, vidéo, téléphone) :
        #    en mode auto, autorisées sans demander (elles restent bornées par la whitelist).
        if self.mode == "auto":
            return True, "mode auto"

        # 6. Mode confirm : validation interactive explicite
        return self._confirm(skill, step)
