"""LOT 10 — chaos côté runtime : plan de contrôle (ou sa base) injoignable pendant l'exécution.

Attendu (audit §9.9, §13 « PG coupé → 0 doublon ») : le worker termine son étape, ses écritures
(actions, checkpoints, résultat) partent dans l'outbox du journal ; le superviseur ne prend
AUCUN nouveau bail tant que l'outbox n'est pas vide ; au retour du serveur l'outbox est rejouée
dans l'ordre, un seul résultat est accepté, et la tâche en attente n'est servie qu'ensuite.
"""
from __future__ import annotations

import sys
import time
from types import SimpleNamespace

import pytest

from runtime import supervisor as sup_mod
from runtime.journal import STATE_FINALIZING, Journal
from runtime.rtclient import RuntimeClient

from fake_control_plane import FakeControlPlane

pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="Job Objects : Windows uniquement")


@pytest.fixture
def rt_env(tmp_path, monkeypatch):
    ws = tmp_path / "workspace"
    ws.mkdir()
    plane = FakeControlPlane(lease_seconds=6).start()
    for k, v in {
        "SOULBAH_API_URL": plane.url,
        "SOULBAH_AGENT_KEY": "sbk_" + "c" * 64,
        "SOULBAH_ALLOWED_DIRS": str(ws),
        "SOULBAH_PERMISSION_MODE": "auto",
        "SOULBAH_APPROVAL_MODE": "console",
        "SOULBAH_RUNTIME_DIR": str(tmp_path / "runtime"),
        "SOULBAH_POLL_INTERVAL": "0.5",
        "SOULBAH_NO_DOTENV": "1",
        "PYTHONUTF8": "1",
    }.items():
        monkeypatch.setenv(k, v)
    yield SimpleNamespace(plane=plane, ws=ws)
    plane.stop()


def drive(s, until, timeout: float = 120.0) -> bool:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        s.tick()
        if until():
            return True
        time.sleep(0.2)
    return False


def test_control_plane_outage_no_duplicate(rt_env):
    from config import load_config

    plane = rt_env.plane
    a, b = rt_env.ws / "a.txt", rt_env.ws / "b.txt"
    a.write_text("x", encoding="utf-8")
    first = plane.add_task([{"type": "wait", "seconds": 1.5}, {"type": "move_file", "src": str(a), "dest": str(b)}])
    cfg = load_config()
    journal = Journal()
    s = sup_mod.Supervisor(cfg, RuntimeClient(cfg, journal), journal, 2, tick_s=0.2)
    assert s.handshake() == "ok"
    s.reconcile()
    try:
        assert drive(s, lambda: first in s.workers), "aucun bail pris"
        plane.down = True  # coupure pendant l'étape 0
        second = plane.add_task([{"type": "wait", "seconds": 0.1}])
        # Le worker termine sans serveur : tout est en outbox, la tâche est « en finalisation ».
        assert drive(s, lambda: first not in s.workers and journal.outbox_count() > 0, timeout=60)
        assert journal.get_held(first)["state"] == STATE_FINALIZING
        assert b.exists() and not a.exists()
        t_end = time.monotonic() + 4
        while time.monotonic() < t_end:  # panne prolongée : aucun nouveau bail
            s.tick()
            time.sleep(0.2)
        assert plane.leases[second] == 0
        assert plane.results == []
        assert plane.refused_while_down > 0

        plane.down = False  # retour du serveur
        assert drive(s, lambda: plane.status(first) == "COMPLETED")
        assert drive(s, lambda: plane.status(second) == "COMPLETED")
    finally:
        s.shutdown()
        journal.close()
    assert [r[0] for r in plane.results].count(first) == 1   # un seul résultat
    assert plane.leases[first] == 1 and plane.leases[second] == 1
    assert plane.posted(first, 1, "attempted") == 1           # move_file jamais rejoué
    # ordre préservé : pour chaque étape, les états arrivent planned → attempted → executed → verified
    for step in (0, 1):
        seq = [st for (t, _a, i, st) in plane.action_log if t == first and i == step]
        assert seq == sorted(seq, key=["planned", "attempted", "executed", "verified"].index), seq
