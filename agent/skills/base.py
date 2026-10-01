"""Contrat commun à tous les skills de l'agent."""
from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from typing import Any, Callable

# Vérificateur de chemin fourni par le gate : True si le chemin est dans la whitelist.
PathCheck = Callable[[str], bool]


class CancelToken:
    """Jeton d'annulation propre à UNE tâche (ou à une étape).

    Remplace l'ancien drapeau global `cancel_event` (T15) : un thread zombie d'une
    tâche précédente garde SON jeton, définitivement annulé. Il ne peut ni être
    « ré-armé » par la tâche suivante, ni annuler celle-ci. Un jeton enfant
    (`child()`) est annulé en même temps que son parent : l'executor crée un enfant
    par étape, l'agent annule le jeton de la tâche (Ctrl+C)."""

    def __init__(self, parent: "CancelToken | None" = None):
        self._event = threading.Event()
        self._lock = threading.Lock()
        self._children: list[CancelToken] = []
        self.reason: str | None = None
        if parent is not None:
            parent._attach(self)

    def _attach(self, child: "CancelToken") -> None:
        with self._lock:
            cancelled = self._event.is_set()
            if not cancelled:
                self._children.append(child)
        if cancelled:
            child.cancel(self.reason or "annulé")

    def child(self) -> "CancelToken":
        return CancelToken(parent=self)

    def cancel(self, reason: str = "annulé") -> None:
        with self._lock:
            if self._event.is_set():
                return
            self.reason = reason
            self._event.set()
            children, self._children = self._children, []
        for c in children:
            c.cancel(reason)

    def is_cancelled(self) -> bool:
        return self._event.is_set()

    def wait(self, timeout: float | None = None) -> bool:
        """Attend l'annulation au plus `timeout` s. True si le jeton est annulé."""
        return self._event.wait(timeout)


# Jeton courant du thread : posé par l'executor dans le thread de travail d'une
# étape. Les skills longs (wait, enregistrements, rendu…) le consultent via
# current_token() pour s'interrompre proprement.
_local = threading.local()


def current_token() -> CancelToken:
    """Jeton d'annulation du thread courant. Hors executor (appel direct d'un
    skill, outil, test), un jeton neuf jamais annulé est renvoyé."""
    token = getattr(_local, "token", None)
    return token if token is not None else CancelToken()


def bind_token(token: CancelToken | None) -> None:
    """Associe `token` au thread courant (None = détache)."""
    _local.token = token


def sleep_or_cancel(seconds: float, step: float = 0.25, token: CancelToken | None = None) -> bool:
    """Attend `seconds` en surveillant le jeton d'annulation (courant par défaut).

    Retourne True si l'attente est allée à son terme, False si elle a été annulée."""
    token = token or current_token()
    deadline = time.monotonic() + max(0.0, seconds)
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return True
        if token.wait(min(step, remaining)):
            return False


# --- Masquage des textes saisis (S8 / contrat §12) ---------------------------
# Les paramètres de texte libre (texte tapé, contenu écrit) ne doivent apparaître
# ni dans les journaux, ni dans les évènements, ni dans les résultats.
MASKED_KEYS = ("text", "content")


def mask_text(value: object) -> str:
    n = len(value) if isinstance(value, str) else len(str(value or ""))
    return f"[texte masqué : {n} car.]"


def mask_step(step: object) -> object:
    """Copie de l'étape où les champs de texte libre sont masqués."""
    if not isinstance(step, dict):
        return step
    masked = dict(step)
    for key in MASKED_KEYS:
        if key in masked and masked[key] not in (None, ""):
            masked[key] = mask_text(masked[key])
    return masked


def is_number(value: object) -> bool:
    """Nombre réel fini (int/float, jamais bool ni chaîne)."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    return value == value and value not in (float("inf"), float("-inf"))


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
        """Phrase lisible décrivant l'action (affichée à l'utilisateur, journalisée et
        envoyée au backend) : ne doit JAMAIS contenir de texte saisi en clair."""
        return f"{self.name}: {mask_step(step)}"

    def confirm_details(self, step: dict) -> str | None:
        """Contenu COMPLET affiché uniquement sur la console locale au moment de la
        confirmation (texte à taper, contenu à écrire, commande et script…).
        Jamais journalisé ni transmis au backend."""
        return None

    def confirm_level(self, step: dict) -> int:
        """Niveau de l'action : 2 = confirmation simple [o/N] ; 3 = action risquée
        ou irréversible, il faut taper « confirmer »."""
        return 2

    def input_risk(self, step: dict) -> str | None:
        """Raison d'exiger une confirmation MÊME si le contrôle d'entrée est
        pré-autorisé (S3 : raccourci ouvrant un terminal, saisie dans une fenêtre
        inconnue…). None = aucun risque particulier."""
        return None

    def validate(self, step: dict, path_allowed: PathCheck) -> str | None:
        """Validation de sécurité propre au skill, appelée par le gate AVANT toute
        confirmation/exécution. Retourne un message d'erreur (refus) ou None."""
        return None

    def run(self, step: dict) -> SkillResult:  # pragma: no cover - implémenté par les sous-classes
        raise NotImplementedError
