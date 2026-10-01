"""Configuration du service python-ia (lue dans l'environnement)."""
from __future__ import annotations

import os

# URL du service Rust (calculs intensifs), fournie par docker-compose.
RUST_SERVICE_URL = os.getenv("RUST_SERVICE_URL", "http://rust-compute:8080")

# ---------------------------------------------------------------------------
# Environnement d'exécution (contrat LOT 1 §1) : dev | test | staging | production.
# Hors dev/test, le service REFUSE de démarrer sans IA_SERVICE_TOKEN.
# Une valeur inconnue est traitée comme stricte (jamais comme dev).
# ---------------------------------------------------------------------------
VALID_ENVS = ("dev", "test", "staging", "production")
_LAX_ENVS = ("dev", "test")


def soulbah_env() -> str:
    return (os.getenv("SOULBAH_ENV", "dev") or "dev").strip().lower()


def is_lax_env() -> bool:
    """True uniquement pour dev/test (authentification inter-services optionnelle)."""
    return soulbah_env() in _LAX_ENVS


def service_token() -> str:
    return os.getenv("IA_SERVICE_TOKEN", "")


def check_startup_config() -> list[str]:
    """Valide la configuration au démarrage.

    Lève RuntimeError si la configuration est dangereuse (token absent hors dev/test) ;
    renvoie la liste des avertissements non bloquants sinon.
    """
    env = soulbah_env()
    warnings: list[str] = []
    if env not in VALID_ENVS:
        warnings.append(
            f"SOULBAH_ENV={env!r} inconnu (attendu : {', '.join(VALID_ENVS)}) : traité comme production."
        )
    if not service_token():
        if not is_lax_env():
            raise RuntimeError(
                f"IA_SERVICE_TOKEN est obligatoire quand SOULBAH_ENV={env!r} "
                "(seuls dev et test acceptent un service sans authentification)."
            )
        warnings.append(
            "IA_SERVICE_TOKEN non défini : le service python-ia accepte les requêtes "
            "SANS authentification (acceptable uniquement en développement local)."
        )
    return warnings
