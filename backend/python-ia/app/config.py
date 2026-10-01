"""Configuration du service python-ia (lue dans l'environnement)."""
from __future__ import annotations

import os
from functools import lru_cache
from typing import Any

from . import soulbah_settings

# URL du service Rust (calculs intensifs), fournie par docker-compose.
RUST_SERVICE_URL = os.getenv("RUST_SERVICE_URL", "http://rust-compute:8080")

# ---------------------------------------------------------------------------
# Environnement d'exécution (contrat LOT 1 §1) : dev | test | staging | production.
# Hors dev/test, le service REFUSE de démarrer sans IA_SERVICE_TOKEN.
# Une valeur inconnue (faute de frappe : "prod"…) REFUSE le démarrage, comme node
# (envChecks.ts) : jamais un côté démarré et l'autre arrêté pour la même config.
# Elle reste traitée comme stricte (jamais comme dev) par is_lax_env().
# ---------------------------------------------------------------------------
VALID_ENVS = ("dev", "test", "staging", "production")
_LAX_ENVS = ("dev", "test")


def soulbah_env() -> str:
    # Absent, vide ou blanc -> dev (même normalisation que node : trim().toLowerCase() || "dev").
    return (os.getenv("SOULBAH_ENV") or "").strip().lower() or "dev"


def is_lax_env() -> bool:
    """True uniquement pour dev/test (authentification inter-services optionnelle)."""
    return soulbah_env() in _LAX_ENVS


def service_token() -> str:
    return os.getenv("IA_SERVICE_TOKEN", "")


def fake_provider_enabled() -> bool:
    """LLM_FAKE_PROVIDER=1 (LOT 3) : le registre ne contient QUE le fournisseur factice
    (app/providers/fake.py) — pile de développement sans clé, sans réseau, sans coût.
    Refusé hors dev/test (check_startup_config et registry.build_providers)."""
    return (os.getenv("LLM_FAKE_PROVIDER") or "").strip().lower() in ("1", "true", "yes", "on")


def check_startup_config() -> list[str]:
    """Valide la configuration au démarrage.

    Lève RuntimeError si la configuration est invalide (SOULBAH_ENV inconnu) ou
    dangereuse (token absent hors dev/test) ; renvoie la liste des avertissements non
    bloquants sinon.
    """
    env = soulbah_env()
    warnings: list[str] = []
    central = settings_resolution()
    if central["errors"]:
        raise RuntimeError("Configuration Soulbah invalide : " + " ; ".join(central["errors"]))
    if env not in VALID_ENVS:
        raise RuntimeError(
            f"SOULBAH_ENV invalide « {env[:40]} » (attendu : {' | '.join(VALID_ENVS)})."
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
    if fake_provider_enabled():
        if not is_lax_env():
            raise RuntimeError(
                f"LLM_FAKE_PROVIDER=1 est interdit quand SOULBAH_ENV={env!r} : fournisseur "
                "factice réservé au développement et aux tests."
            )
        warnings.append(
            "LLM_FAKE_PROVIDER=1 : fournisseur d'IA FACTICE (réponses déterministes, aucun "
            "appel réel) — toutes les clés fournisseur sont ignorées."
        )
    return warnings


# ---------------------------------------------------------------------------
# V3 LOT 1 : configuration centrale (shared/config/soulbah_settings.py, copiée ici).
# Racine du dépôt : app/ → python-ia/ → backend/ → racine (absente en conteneur : env seul).
# ---------------------------------------------------------------------------
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


@lru_cache(maxsize=1)
def settings_resolution() -> dict[str, Any]:
    return soulbah_settings.load(REPO_ROOT)


def soulbah_settings_now() -> dict[str, Any]:
    """Configuration résolue du processus (lue une fois ; settings_resolution.cache_clear())."""
    return settings_resolution()["settings"]
