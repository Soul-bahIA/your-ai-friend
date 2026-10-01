"""Contrat commun à tous les skills de l'agent."""
from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from typing import Any, Callable

# Vérificateur de chemin fourni par le gate : True si le chemin est dans la whitelist.
PathCheck = Callable[[str], bool]

# Drapeau d'annulation global : posé par l'executor quand l'utilisateur demande
# l'arrêt, quand le backend signale que la tâche n'est plus à nous (409) ou quand
# une étape dépasse son délai. Les skills longs (wait, enregistrements…) le
# consultent périodiquement pour s'interrompre proprement.
cancel_event = threading.Event()


def sleep_or_cancel(seconds: float, step: float = 0.25) -> bool:
    """Attend `seconds` en surveillant le drapeau d'annulation.

    Retourne True si l'attente est allée à son terme, False si elle a été annulée."""
    deadline = time.monotonic() + max(0.0, seconds)
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return True
        if cancel_event.wait(min(step, remaining)):
            return False


@dataclass
class SkillResult:
    ok: bool
    detail: str
    data: dict[str, Any] | None = None


class Skill:
    """Un skill exécute une action atomique décrite par un `step` (dict JSON)."""

    # Identifiant + types d'étapes que ce skill prend en charge
    name: str = "base"
    step_types: tuple[str, ...] = ()

    # Métadonnées de sécurité utilisées par le gate de permissions
    category: str = "generic"  # app_launch | keyboard | filesystem | screen | shell | video | phone
    sensitive: bool = True  # True => nécessite une validation en mode "confirm"

    # Délai max d'exécution (secondes). None = délai global (SOULBAH_STEP_TIMEOUT).
    timeout_s: float | None = None

    def describe(self, step: dict) -> str:
        """Phrase lisible décrivant l'action (affichée à l'utilisateur)."""
        return f"{self.name}: {step}"

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        """Validation de sécurité propre au skill, appelée par le gate AVANT toute
        confirmation/exécution. Retourne un message d'erreur (refus) ou None."""
        return None

    def run(self, step: dict) -> SkillResult:  # pragma: no cover - implémenté par les sous-classes
        raise NotImplementedError
