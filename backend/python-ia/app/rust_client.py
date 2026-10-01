"""Client du service de calcul Rust (rust-compute)."""
from __future__ import annotations

import logging

import httpx

from .config import RUST_SERVICE_URL

logger = logging.getLogger("python-ia")

COMPUTE_TIMEOUT_S = 30.0


class ComputeUnavailable(Exception):
    """rust-compute injoignable ou en erreur : l'API répond 503 (jamais 500)."""

    status = 503
    message = "Service de calcul indisponible"


async def heavy_compute(values: list[float]) -> dict:
    """Délègue les calculs numériques intensifs au service Rust.

    Toute panne (connexion refusée, délai, 5xx, réponse illisible) devient
    ComputeUnavailable ; le détail est journalisé, jamais renvoyé au client.
    """
    try:
        async with httpx.AsyncClient(timeout=COMPUTE_TIMEOUT_S) as client:
            resp = await client.post(f"{RUST_SERVICE_URL}/compute", json={"values": values})
        resp.raise_for_status()
        data = resp.json()
    except (httpx.HTTPError, ValueError) as e:
        logger.warning("rust-compute indisponible (%s) : %s", type(e).__name__, e)
        raise ComputeUnavailable() from e
    if not isinstance(data, dict):
        logger.warning("rust-compute : réponse inattendue (%s)", type(data).__name__)
        raise ComputeUnavailable()
    return data
