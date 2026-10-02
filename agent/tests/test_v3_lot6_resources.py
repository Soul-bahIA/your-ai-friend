"""V3 LOT 6 — Resource Manager côté PC : le superviseur ne lance de nouveaux workers que si la
mémoire libre le permet, et envoie l'état mémoire au plan de contrôle (lease et keepalive)."""
from __future__ import annotations

import pathlib

import soulbah_resources as R
from runtime import supervisor as sup_mod
from runtime.journal import Journal
from runtime.rtclient import RuntimeClient
from tests.test_lot8_runtime import rt_env  # noqa: F401 — fixture réutilisée

ROOT = pathlib.Path(__file__).resolve().parents[2]
POLICY = R.ResourcePolicy(reserve_mb=400, critical_mb=200, worker_mb=150)


def test_shared_copy_is_identical():
    src = (ROOT / "shared" / "config" / "soulbah_resources.py").read_bytes()
    assert (ROOT / "agent" / "soulbah_resources.py").read_bytes() == src, "copie modifiée : python scripts/sync_shared.py"


def _supervisor(plane, free_mb: int | None, max_slots: int = 6, mem: dict | None = None):
    from config import load_config

    cfg = load_config()
    journal = Journal()
    s = sup_mod.Supervisor(cfg, RuntimeClient(cfg, journal), journal, max_slots, tick_s=0.2,
                           memory=lambda: {"total_mb": 8000, "free_mb": (mem or {}).get("free_mb", free_mb), "load_percent": 90})
    s.policy = POLICY
    assert s.handshake() == "ok"
    s.reconciled = True
    spawned: list[str] = []
    s.spawn = lambda task, **_kw: spawned.append(task["id"]) or object()  # pas de vrai worker ici
    bodies: list[tuple[str, dict]] = []
    real = plane.handle

    def recording(method, path, body, headers):
        bodies.append((path, body if isinstance(body, dict) else {}))
        return real(method, path, body, headers)

    plane.handle = recording
    return s, spawned, bodies


def test_low_memory_limits_new_workers_and_reports_it(rt_env):  # noqa: F811
    for _ in range(6):
        rt_env.plane.add_task([{"type": "wait", "seconds": 1}])
    mem = {"free_mb": 700}
    s, spawned, bodies = _supervisor(rt_env.plane, free_mb=700, mem=mem)
    assert s.lease() == 2  # (700 − 400) ÷ 150 = 2 workers, pas 6
    assert len(spawned) == 2
    lease_body = next(b for p, b in bodies if p.endswith("/lease"))
    assert lease_body["slots"] == 2
    res = lease_body["resources"]
    assert res["free_mb"] == 700 and res["pressure"] == "ok" and res["allowed_new"] == 2 and res["throttled"] is True
    assert s.throttled is True
    # keepalive : l'état mémoire part aussi (2 workers lancés : la mémoire libre a baissé)
    mem["free_mb"] = 420
    s.keepalive()
    keep = next(b for p, b in bodies if p.endswith("/keepalive"))
    assert keep["resources"]["held"] == 2 and keep["resources"]["allowed_new"] == 0


def test_critical_memory_asks_for_no_lease_at_all(rt_env):  # noqa: F811
    rt_env.plane.add_task([{"type": "wait", "seconds": 1}])
    s, spawned, bodies = _supervisor(rt_env.plane, free_mb=150)
    assert s.lease() == 0 and spawned == []
    assert not any(p.endswith("/lease") for p, _ in bodies)
    assert s.last_resources["pressure"] == "critical"


def test_enough_memory_keeps_v2_behaviour(rt_env):  # noqa: F811
    for _ in range(4):
        rt_env.plane.add_task([{"type": "wait", "seconds": 1}])
    s, spawned, _bodies = _supervisor(rt_env.plane, free_mb=6000, max_slots=3)
    assert s.lease() == 3 and s.throttled is False


def test_unknown_memory_falls_back_to_slots(rt_env):  # noqa: F811
    for _ in range(2):
        rt_env.plane.add_task([{"type": "wait", "seconds": 1}])
    s, spawned, bodies = _supervisor(rt_env.plane, free_mb=None, max_slots=2)
    assert s.lease() == 2
    assert next(b for p, b in bodies if p.endswith("/lease"))["resources"]["pressure"] == "unknown"
