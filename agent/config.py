"""Configuration de SoulBah Agent, chargée depuis l'environnement / agent/.env.

SOULBAH_NO_DOTENV=1 désactive le chargement de agent/.env (tests hermétiques, T53).
"""
from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field

AGENT_DIR = os.path.dirname(os.path.abspath(__file__))
log = logging.getLogger("soulbah.config")
_TRUE = ("1", "true", "yes", "oui")


def dotenv_disabled() -> bool:
    return os.environ.get("SOULBAH_NO_DOTENV", "").strip().lower() in _TRUE


if not dotenv_disabled():
    try:
        from dotenv import load_dotenv

        # Chemin explicite : le .env de l'agent, jamais celui du dossier courant.
        load_dotenv(os.path.join(AGENT_DIR, ".env"))
    except ImportError:  # dotenv est optionnel
        pass


def default_workspace() -> str:
    """%USERPROFILE%\\SoulbahWorkspace (créé au démarrage si besoin) — hors du dépôt."""
    home = os.environ.get("USERPROFILE") or os.path.expanduser("~")
    return os.path.join(home, "SoulbahWorkspace")


@dataclass
class Config:
    api_url: str  # backend Node (ex : http://localhost:3000)
    agent_key: str  # x-agent-key : le backend en déduit le user_id
    poll_interval: float = 5.0
    # confirm = demande une validation avant chaque action sensible
    # auto    = exécute sans demander (à n'utiliser qu'en connaissance de cause)
    permission_mode: str = "confirm"
    # dry_run = simulation d'un plan LOCAL (--plan) : aucune tâche n'est réclamée au serveur
    dry_run: bool = False
    # Dossiers dans lesquels les opérations sur fichiers sont autorisées
    allowed_dirs: list[str] = field(default_factory=list)
    # True si allowed_dirs est le workspace par défaut (SOULBAH_ALLOWED_DIRS vide)
    default_workspace: bool = False
    # Pré-autorise les actions d'entrée (souris/clavier/fenêtre/app/téléphone) sans
    # confirmation, sauf actions à risque. Sans ce drapeau, elles restent soumises à
    # validation — même en mode auto.
    allow_input_control: bool = False
    # Délai max d'exécution d'une étape (s). Au-delà, l'étape échoue et la tâche s'arrête.
    step_timeout: float = 900.0
    # Délai de réponse à une confirmation (s). Sans réponse : refus par défaut.
    confirm_timeout: float = 120.0
    # LOT 6 : où les confirmations L2/L3 sont demandées.
    #   console = sur le PC (comportement historique) ; remote = approbation HMAC dans
    #   l'app (/api/v2/approvals) ; both = remote d'abord, repli console si la route
    #   n'existe pas (serveur V1, 404).
    approval_mode: str = "console"
    # Origine de la clé agent : "env" (SOULBAH_AGENT_KEY / agent/.env), "dpapi"
    # (fichier chiffré, voir secrets.py) ou "" (aucune, dry-run).
    key_source: str = ""


APPROVAL_MODES = ("console", "remote", "both")


def _approval_mode() -> str:
    raw = os.environ.get("SOULBAH_APPROVAL_MODE", "console").strip().lower() or "console"
    if raw not in APPROVAL_MODES:
        log.warning(
            "SOULBAH_APPROVAL_MODE=%r inconnu (console | remote | both) — « console » utilisé", raw)
        return "console"
    return raw


def _dpapi_agent_key() -> str | None:
    """Clé agent du coffre DPAPI (secrets.py), None si absente, illisible ou hors Windows."""
    try:
        import secrets as agent_secrets  # agent/secrets.py (voir sa docstring)

        return agent_secrets.load_agent_key()
    except NotImplementedError as e:
        log.warning("Clé DPAPI ignorée : %s", e)
        return None
    except Exception:  # noqa: BLE001 - un coffre en erreur ne doit pas empêcher le diagnostic
        log.warning("Lecture de la clé DPAPI impossible", exc_info=True)
        return None


def _float_env(name: str, default: float, minimum: float) -> float:
    raw = os.environ.get(name, "")
    try:
        value = float(raw) if raw.strip() else default
    except ValueError:
        value = default
    return max(minimum, value)


def load_config(require_key: bool = True) -> Config:
    # Après migration, l'agent parle au backend Node (et non plus à l'edge function).
    api_url = os.environ.get("SOULBAH_API_URL", "http://localhost:3000").rstrip("/")
    agent_key = os.environ.get("SOULBAH_AGENT_KEY", "").strip()
    key_source = "env" if agent_key else ""
    if not agent_key:
        # LOT 6 : clé chiffrée par DPAPI (`python soulbah_agent.py --store-key`).
        agent_key = _dpapi_agent_key() or ""
        key_source = "dpapi" if agent_key else ""

    if require_key and not agent_key:
        raise SystemExit(
            "Clé agent introuvable : ni SOULBAH_AGENT_KEY (environnement / agent/.env), "
            "ni coffre DPAPI (python soulbah_agent.py --store-key).\n"
            "Générez une clé depuis la page Sécurité de l'app, puis enregistrez-la avec --store-key."
        )

    allowed = [
        d.strip()
        for d in os.environ.get("SOULBAH_ALLOWED_DIRS", "").split(os.pathsep)
        if d.strip()
    ]
    use_default = not allowed
    if use_default:
        allowed = [default_workspace()]

    return Config(
        api_url=api_url,
        agent_key=agent_key,
        poll_interval=_float_env("SOULBAH_POLL_INTERVAL", 5.0, 0.5),
        permission_mode=os.environ.get("SOULBAH_PERMISSION_MODE", "confirm"),
        dry_run=os.environ.get("SOULBAH_DRY_RUN", "").lower() in _TRUE,
        allowed_dirs=allowed,
        default_workspace=use_default,
        allow_input_control=os.environ.get("SOULBAH_ALLOW_INPUT_CONTROL", "").lower() in _TRUE,
        step_timeout=_float_env("SOULBAH_STEP_TIMEOUT", 900.0, 5.0),
        confirm_timeout=_float_env("SOULBAH_CONFIRM_TIMEOUT", 120.0, 5.0),
        approval_mode=_approval_mode(),
        key_source=key_source,
    )
