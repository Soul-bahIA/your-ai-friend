import httpx

from .config import RUST_SERVICE_URL


async def heavy_compute(values: list[float]) -> dict:
    """Délègue les calculs numériques intensifs au service Rust."""
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(
            f"{RUST_SERVICE_URL}/compute",
            json={"values": values},
        )
        resp.raise_for_status()
        return resp.json()
