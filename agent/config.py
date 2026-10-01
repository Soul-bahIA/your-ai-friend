"""Configuration de SoulBah Agent, chargée depuis l'environnement / .env."""
from __future__ import annotations

import os
from dataclasses import dataclass, field

try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:  # dotenv est optionnel
    pass


@dataclass
class Config:
    api_url: str  # backend Node (ex : http://localhost:3000)
    agent_key: str  # x-agent-key : le backend en déduit le user_id
    poll_interval: float = 5.0
    # confirm = demande une validation avant chaque action sensible
    # auto    = exécute sans demander (à n'utiliser qu'en connaissance de cause)
    permission_mode: str = "confirm"
    # dry_run = l'agent décrit ce qu'il ferait sans rien exécuter
    dry_run: bool = False
    # Dossiers dans lesquels les opérations sur fichiers sont autorisées
    allowed_dirs: list[str] = field(default_factory=list)
    # Pré-autorise les actions d'entrée (souris/clavier/fenêtre/app) sans confirmation.
    # Sans ce drapeau, elles restent soumises à validation — même en mode auto.
    allow_input_control: bool = False
    # Délai max d'exécution d'une étape (s). Au-delà, l'étape échoue et la tâche s'arrête.
    step_timeout: float = 900.0
    # Délai de réponse à une confirmation (s). Sans réponse : refus par défaut.
    confirm_timeout: float = 120.0


def _float_env(name: str, default: float, minimum: float) -> float:
    raw = os.environ.get(name, "")
    try:
        value = float(raw) if raw.strip() else default
    except ValueError:
        value = default
    return max(minimum, value)


def load_config() -> Config:
    # Après migration, l'agent parle au backend Node (et non plus à l'edge function).
    api_url = os.environ.get("SOULBAH_API_URL", "http://localhost:3000").rstrip("/")
    agent_key = os.environ.get("SOULBAH_AGENT_KEY", "")

    if not agent_key:
        raise SystemExit(
            "Variable d'environnement manquante : SOULBAH_AGENT_KEY\n"
            "Générez une clé depuis la page Sécurité de l'app, puis copiez-la dans .env."
        )

    allowed = [
        d.strip()
        for d in os.environ.get("SOULBAH_ALLOWED_DIRS", "").split(os.pathsep)
        if d.strip()
    ]

    return Config(
        api_url=api_url,
        agent_key=agent_key,
        poll_interval=_float_env("SOULBAH_POLL_INTERVAL", 5.0, 0.5),
        permission_mode=os.environ.get("SOULBAH_PERMISSION_MODE", "confirm"),
        dry_run=os.environ.get("SOULBAH_DRY_RUN", "").lower() in ("1", "true", "yes"),
        allowed_dirs=allowed,
        allow_input_control=os.environ.get("SOULBAH_ALLOW_INPUT_CONTROL", "").lower()
        in ("1", "true", "yes"),
        step_timeout=_float_env("SOULBAH_STEP_TIMEOUT", 900.0, 5.0),
        confirm_timeout=_float_env("SOULBAH_CONFIRM_TIMEOUT", 120.0, 5.0),
    )
