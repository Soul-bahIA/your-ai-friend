"""Contrat commun à tous les skills de l'agent."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any


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
    category: str = "generic"  # app_launch | keyboard | filesystem | screen
    sensitive: bool = True  # True => nécessite une validation en mode "confirm"

    def describe(self, step: dict) -> str:
        """Phrase lisible décrivant l'action (affichée à l'utilisateur)."""
        return f"{self.name}: {step}"

    def run(self, step: dict) -> SkillResult:  # pragma: no cover - implémenté par les sous-classes
        raise NotImplementedError
