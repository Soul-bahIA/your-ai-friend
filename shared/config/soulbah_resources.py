"""Resource Manager V3 (LOT 6) — politique commune de l'agent et de python-ia.

Source unique : shared/config/soulbah_resources.py, copiée à l'identique par
scripts/sync_shared.py (agent/soulbah_resources.py, backend/python-ia/app/soulbah_resources.py).

Principe (mission V3 : « agents ≠ instances de modèle ») : 6 agents logiques peuvent exister,
mais la machine ne lance de nouveaux workers et n'envoie d'inférences au modèle local que si
la mémoire libre le permet. Aucune dépendance : lecture de la RAM par l'API Windows
(GlobalMemoryStatusEx) ou /proc/meminfo.

Variables (Mo) :
  SOULBAH_RAM_RESERVE_MB   mémoire toujours laissée libre au système (défaut 400)
  SOULBAH_RAM_CRITICAL_MB  en dessous : aucun nouveau worker, une seule inférence (défaut 200)
  SOULBAH_WORKER_RAM_MB    coût estimé d'un worker (processus Python + outils, défaut 150)
"""
from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from typing import Any

MB = 1024 * 1024

PRESSURE_OK = "ok"
PRESSURE_HIGH = "high"
PRESSURE_CRITICAL = "critical"
PRESSURE_UNKNOWN = "unknown"


def _env_int(name: str, default: int, low: int = 0, high: int = 1 << 20) -> int:
    raw = os.environ.get(name, "").strip()
    try:
        value = int(raw) if raw else default
    except ValueError:
        value = default
    return max(low, min(high, value))


@dataclass(frozen=True)
class ResourcePolicy:
    reserve_mb: int = 400
    critical_mb: int = 200
    worker_mb: int = 150

    @classmethod
    def from_env(cls) -> "ResourcePolicy":
        critical = _env_int("SOULBAH_RAM_CRITICAL_MB", 200, 0, 64_000)
        reserve = max(critical, _env_int("SOULBAH_RAM_RESERVE_MB", 400, 0, 64_000))
        return cls(reserve_mb=reserve, critical_mb=critical,
                   worker_mb=_env_int("SOULBAH_WORKER_RAM_MB", 150, 10, 64_000))

    def as_dict(self) -> dict[str, int]:
        return {"reserve_mb": self.reserve_mb, "critical_mb": self.critical_mb, "worker_mb": self.worker_mb}


def memory() -> dict[str, Any]:
    """{total_mb, free_mb, load_percent} ; valeurs None si la lecture est impossible."""
    if sys.platform == "win32":
        try:
            import ctypes
            from ctypes import wintypes

            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [("dwLength", wintypes.DWORD), ("dwMemoryLoad", wintypes.DWORD),
                            ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]

            st = MEMORYSTATUSEX()
            st.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
                return {"total_mb": int(st.ullTotalPhys // MB), "free_mb": int(st.ullAvailPhys // MB),
                        "load_percent": int(st.dwMemoryLoad)}
        except (OSError, AttributeError, ValueError):
            pass
        return {"total_mb": None, "free_mb": None, "load_percent": None}
    info: dict[str, int] = {}
    try:
        with open("/proc/meminfo", encoding="ascii") as f:
            for line in f:
                key, value = line.split(":", 1)
                info[key] = int(value.strip().split()[0]) * 1024
    except (OSError, ValueError, IndexError):
        return {"total_mb": None, "free_mb": None, "load_percent": None}
    total = info.get("MemTotal")
    free = info.get("MemAvailable")
    if not total or free is None:
        return {"total_mb": None, "free_mb": None, "load_percent": None}
    return {"total_mb": total // MB, "free_mb": free // MB, "load_percent": int(round(100 * (1 - free / total)))}


def pressure(free_mb: int | None, policy: ResourcePolicy | None = None) -> str:
    policy = policy or ResourcePolicy.from_env()
    if free_mb is None:
        return PRESSURE_UNKNOWN
    if free_mb < policy.critical_mb:
        return PRESSURE_CRITICAL
    if free_mb < policy.reserve_mb + policy.worker_mb:
        return PRESSURE_HIGH
    return PRESSURE_OK


def worker_slots_allowed(free_mb: int | None, running: int, max_slots: int,
                         policy: ResourcePolicy | None = None) -> int:
    """Nouveaux workers lançables maintenant (≥ 0).

    Budget = (mémoire libre − réserve) ÷ coût d'un worker, borné par les slots libres. Garantie de
    progression : si rien ne tourne et que la mémoire n'est pas critique, un worker est permis.
    Mémoire inconnue : seuls les slots comptent (comportement V2)."""
    policy = policy or ResourcePolicy.from_env()
    free_slots = max(0, int(max_slots) - max(0, int(running)))
    if free_mb is None:
        return free_slots
    if free_mb < policy.critical_mb:
        return 0
    budget = max(0, (int(free_mb) - policy.reserve_mb) // max(1, policy.worker_mb))
    allowed = min(free_slots, budget)
    if allowed == 0 and running <= 0 and free_slots > 0:
        allowed = 1
    return allowed


def inference_capacity(server_slots: int | None, free_mb: int | None,
                       policy: ResourcePolicy | None = None) -> int:
    """Inférences simultanées envoyées à un serveur local : ses slots (contextes préalloués par
    llama-server, donc sans RAM supplémentaire), réduits à 1 sous pression mémoire critique."""
    policy = policy or ResourcePolicy.from_env()
    slots = max(1, int(server_slots or 1))
    if free_mb is not None and free_mb < policy.critical_mb:
        return 1
    return slots


def snapshot(policy: ResourcePolicy | None = None) -> dict[str, Any]:
    policy = policy or ResourcePolicy.from_env()
    mem = memory()
    return {**mem, "pressure": pressure(mem.get("free_mb"), policy), "policy": policy.as_dict()}


__all__ = ["ResourcePolicy", "memory", "pressure", "worker_slots_allowed", "inference_capacity", "snapshot",
           "PRESSURE_OK", "PRESSURE_HIGH", "PRESSURE_CRITICAL", "PRESSURE_UNKNOWN"]
