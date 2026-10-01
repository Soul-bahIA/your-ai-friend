r"""Journal local du runtime (audit §9.2, §9.9) : SQLite en mode WAL.

Fichier `<SOULBAH_RUNTIME_DIR>\journal.db` (défaut `%LOCALAPPDATA%\Soulbah\runtime`),
partagé entre le superviseur et ses workers (WAL : lecteurs et écrivain concurrents,
`busy_timeout` 10 s). Chaque écriture est une transaction `BEGIN IMMEDIATE … COMMIT`
avec `synchronous=FULL` : une ligne est entière ou absente, même après un kill ou une
coupure de courant.

Tables :
  - held_tasks  : baux détenus (task_id, attempt, lease_owner, spec_json, started_at,
                  state ∈ running | waiting | finalizing) — base de la réconciliation ;
  - actions     : état de chaque étape (planned → attempted → executed → verified ;
                  failed / skipped / simulated terminaux), monotone comme côté serveur ;
  - checkpoints : (seq, step_cursor, variables_json) après chaque étape ;
  - outbox      : écritures HTTP non acceptées (réseau, 5xx), rejouées en ordre avec
                  backoff ; `kind`/`task_id` permettent de maintenir le bail d'une tâche
                  dont le final attend (§9.9) et d'ignorer les écritures d'une tâche
                  abandonnée.
"""
from __future__ import annotations

import json
import logging
import os
import sqlite3
import threading
import time
from contextlib import contextmanager
from typing import Any, Iterator

from runtime.instance_lock import runtime_dir

log = logging.getLogger("soulbah.runtime.journal")

JOURNAL_FILE = "journal.db"
BUSY_TIMEOUT_S = 10.0

# États d'une action (identiques à backend/node-api/src/v2/runtime/actions.ts).
ACTION_RANK = {"planned": 0, "attempted": 1, "executed": 2, "verified": 3}
TERMINAL_ACTIONS = frozenset({"verified", "failed", "skipped", "simulated"})
ACTION_STATUSES = frozenset(ACTION_RANK) | TERMINAL_ACTIONS

STATE_RUNNING = "running"
STATE_WAITING = "waiting"  # QUESTION émise : un humain doit trancher (§9.9)
STATE_FINALIZING = "finalizing"  # final (result / ERROR) en outbox : bail maintenu, aucun nouveau bail
HELD_STATES = (STATE_RUNNING, STATE_WAITING, STATE_FINALIZING)

# Backoff de l'outbox (mêmes bornes que pending.py).
_BASE_DELAY = 2.0
_MAX_DELAY = 120.0
# Durée pendant laquelle une entrée réclamée par un processus (en cours d'envoi) n'est
# pas reprise par un autre : si l'envoyeur meurt, l'entrée redevient due ensuite.
_CLAIM_SECONDS = 30.0

_SCHEMA = (
    """CREATE TABLE IF NOT EXISTS held_tasks (
        task_id TEXT PRIMARY KEY,
        attempt INTEGER NOT NULL,
        lease_owner TEXT,
        spec_json TEXT NOT NULL,
        started_at REAL NOT NULL,
        state TEXT NOT NULL DEFAULT 'running',
        updated_at REAL NOT NULL
    )""",
    """CREATE TABLE IF NOT EXISTS actions (
        task_id TEXT NOT NULL,
        attempt INTEGER NOT NULL,
        step_index INTEGER NOT NULL,
        tool TEXT NOT NULL,
        status TEXT NOT NULL,
        idempotent INTEGER NOT NULL DEFAULT 0,
        updated_at REAL NOT NULL,
        PRIMARY KEY (task_id, attempt, step_index)
    )""",
    """CREATE TABLE IF NOT EXISTS checkpoints (
        task_id TEXT NOT NULL,
        attempt INTEGER NOT NULL,
        seq INTEGER NOT NULL,
        step_cursor INTEGER NOT NULL,
        variables_json TEXT NOT NULL,
        created_at REAL NOT NULL,
        PRIMARY KEY (task_id, attempt, seq)
    )""",
    """CREATE TABLE IF NOT EXISTS outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        method TEXT NOT NULL,
        path TEXT NOT NULL,
        body_json TEXT NOT NULL,
        created_at REAL NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_at REAL NOT NULL,
        kind TEXT NOT NULL DEFAULT '',
        task_id TEXT,
        attempt INTEGER
    )""",
    "CREATE INDEX IF NOT EXISTS outbox_due ON outbox (next_at, id)",
    "CREATE INDEX IF NOT EXISTS outbox_task ON outbox (task_id)",
)


def journal_path() -> str:
    return os.path.join(runtime_dir(), JOURNAL_FILE)


def action_transition_ok(previous: str | None, new: str) -> bool:
    """True si `new` peut succéder à `previous` (identique = idempotent, accepté)."""
    if new not in ACTION_STATUSES:
        return False
    if previous is None or previous == new:
        return True
    if previous in TERMINAL_ACTIONS:
        return False
    if new in TERMINAL_ACTIONS:
        return True
    return ACTION_RANK[new] > ACTION_RANK[previous]


def outbox_delay(attempts: int) -> float:
    return min(_BASE_DELAY * (2 ** max(0, attempts - 1)), _MAX_DELAY)


def _dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, default=str)


def _loads(text: str | None, default: Any) -> Any:
    if not text:
        return default
    try:
        return json.loads(text)
    except ValueError:
        return default


class Journal:
    def __init__(self, path: str | None = None):
        self.path = path or journal_path()
        directory = os.path.dirname(self.path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(self.path, timeout=BUSY_TIMEOUT_S, isolation_level=None,
                                     check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute(f"PRAGMA busy_timeout = {int(BUSY_TIMEOUT_S * 1000)}")
        mode = self._conn.execute("PRAGMA journal_mode = WAL").fetchone()[0]
        if str(mode).lower() != "wal":
            log.warning("Journal %s : mode WAL indisponible (%s)", self.path, mode)
        self._conn.execute("PRAGMA synchronous = FULL")
        with self._tx():
            for stmt in _SCHEMA:
                self._conn.execute(stmt)

    # --- infrastructure ------------------------------------------------------------------
    @contextmanager
    def _tx(self) -> Iterator[sqlite3.Connection]:
        """Transaction exclusive d'écriture : tout ou rien."""
        with self._lock:
            self._conn.execute("BEGIN IMMEDIATE")
            try:
                yield self._conn
            except BaseException:
                self._conn.execute("ROLLBACK")
                raise
            self._conn.execute("COMMIT")

    def _query(self, sql: str, params: tuple = ()) -> list[sqlite3.Row]:
        with self._lock:
            return self._conn.execute(sql, params).fetchall()

    def journal_mode(self) -> str:
        return str(self._query("PRAGMA journal_mode")[0][0])

    def close(self) -> None:
        with self._lock:
            try:
                self._conn.close()
            except sqlite3.Error:
                pass

    # --- baux détenus --------------------------------------------------------------------
    def hold(self, task: dict[str, Any], state: str = STATE_RUNNING) -> None:
        """Enregistre (ou remplace) une tâche détenue : son bail et sa spécification complète."""
        now = time.time()
        with self._tx() as c:
            c.execute(
                "INSERT INTO held_tasks (task_id, attempt, lease_owner, spec_json, started_at, state, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(task_id) DO UPDATE SET attempt = excluded.attempt, "
                "lease_owner = excluded.lease_owner, spec_json = excluded.spec_json, state = excluded.state, "
                "updated_at = excluded.updated_at",
                (str(task["id"]), int(task.get("attempt") or 0), task.get("lease_owner"), _dumps(task), now, state, now),
            )

    def set_state(self, task_id: str, state: str) -> None:
        if state not in HELD_STATES:
            raise ValueError(f"état inconnu : {state}")
        with self._tx() as c:
            c.execute("UPDATE held_tasks SET state = ?, updated_at = ? WHERE task_id = ?", (state, time.time(), task_id))

    def release(self, task_id: str) -> None:
        """La tâche n'est plus détenue : bail, actions et checkpoints sont oubliés
        (les écritures d'outbox éventuelles sont conservées : elles peuvent encore aboutir)."""
        with self._tx() as c:
            c.execute("DELETE FROM held_tasks WHERE task_id = ?", (task_id,))
            c.execute("DELETE FROM actions WHERE task_id = ?", (task_id,))
            c.execute("DELETE FROM checkpoints WHERE task_id = ?", (task_id,))

    def purge(self, task_id: str) -> None:
        """Abandon / annulation : tout ce qui concerne la tâche disparaît, outbox comprise."""
        with self._tx() as c:
            c.execute("DELETE FROM held_tasks WHERE task_id = ?", (task_id,))
            c.execute("DELETE FROM actions WHERE task_id = ?", (task_id,))
            c.execute("DELETE FROM checkpoints WHERE task_id = ?", (task_id,))
            c.execute("DELETE FROM outbox WHERE task_id = ?", (task_id,))

    @staticmethod
    def _held_row(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "task_id": row["task_id"], "attempt": int(row["attempt"]), "lease_owner": row["lease_owner"],
            "spec": _loads(row["spec_json"], {}), "started_at": float(row["started_at"]),
            "state": row["state"], "updated_at": float(row["updated_at"]),
        }

    def held(self) -> list[dict[str, Any]]:
        return [self._held_row(r) for r in self._query("SELECT * FROM held_tasks ORDER BY started_at, task_id")]

    def get_held(self, task_id: str) -> dict[str, Any] | None:
        rows = self._query("SELECT * FROM held_tasks WHERE task_id = ?", (task_id,))
        return self._held_row(rows[0]) if rows else None

    # --- actions ------------------------------------------------------------------------
    def record_action(self, task_id: str, attempt: int, step_index: int, tool: str, status: str,
                      idempotent: bool) -> bool:
        """Pose l'état d'une étape. False (rien d'écrit) si la transition régresse."""
        with self._tx() as c:
            row = c.execute("SELECT status FROM actions WHERE task_id = ? AND attempt = ? AND step_index = ?",
                            (task_id, attempt, step_index)).fetchone()
            previous = row["status"] if row else None
            if not action_transition_ok(previous, status):
                log.warning("Action %s/%d étape %d : transition %s → %s refusée", str(task_id)[:8], attempt,
                            step_index, previous, status)
                return False
            c.execute(
                "INSERT INTO actions (task_id, attempt, step_index, tool, status, idempotent, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(task_id, attempt, step_index) DO UPDATE SET "
                "tool = excluded.tool, status = excluded.status, idempotent = excluded.idempotent, "
                "updated_at = excluded.updated_at",
                (task_id, int(attempt), int(step_index), tool, status, 1 if idempotent else 0, time.time()),
            )
        return True

    def actions(self, task_id: str, attempt: int | None = None) -> list[dict[str, Any]]:
        if attempt is None:
            rows = self._query("SELECT * FROM actions WHERE task_id = ? ORDER BY attempt, step_index", (task_id,))
        else:
            rows = self._query("SELECT * FROM actions WHERE task_id = ? AND attempt = ? ORDER BY step_index",
                               (task_id, attempt))
        return [{"task_id": r["task_id"], "attempt": int(r["attempt"]), "step_index": int(r["step_index"]),
                 "tool": r["tool"], "status": r["status"], "idempotent": bool(r["idempotent"]),
                 "updated_at": float(r["updated_at"])} for r in rows]

    def last_activity(self, task_id: str) -> float | None:
        """Dernier horodatage d'écriture (action, checkpoint ou bail) pour la tâche."""
        rows = self._query(
            "SELECT MAX(t) AS t FROM (SELECT MAX(updated_at) AS t FROM actions WHERE task_id = ? "
            "UNION ALL SELECT MAX(created_at) FROM checkpoints WHERE task_id = ? "
            "UNION ALL SELECT MAX(updated_at) FROM held_tasks WHERE task_id = ?)",
            (task_id, task_id, task_id))
        value = rows[0]["t"] if rows else None
        return float(value) if value is not None else None

    # --- checkpoints ----------------------------------------------------------------------
    def checkpoint(self, task_id: str, attempt: int, seq: int, step_cursor: int, variables: dict[str, Any]) -> None:
        with self._tx() as c:
            c.execute(
                "INSERT OR REPLACE INTO checkpoints (task_id, attempt, seq, step_cursor, variables_json, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (task_id, int(attempt), int(seq), int(step_cursor), _dumps(variables or {}), time.time()),
            )

    def last_checkpoint(self, task_id: str, attempt: int) -> dict[str, Any] | None:
        rows = self._query("SELECT * FROM checkpoints WHERE task_id = ? AND attempt = ? ORDER BY seq DESC LIMIT 1",
                           (task_id, attempt))
        if not rows:
            return None
        r = rows[0]
        return {"seq": int(r["seq"]), "step_cursor": int(r["step_cursor"]),
                "variables": _loads(r["variables_json"], {}), "created_at": float(r["created_at"])}

    # --- outbox ----------------------------------------------------------------------------
    def enqueue(self, method: str, path: str, body: dict[str, Any], kind: str = "",
                task_id: str | None = None, attempt: int | None = None, attempts: int = 0) -> int:
        """Met une écriture en attente ; elle est due immédiatement (attempts = 0) ou après
        le backoff correspondant au nombre d'essais déjà faits."""
        now = time.time()
        next_at = now + (outbox_delay(attempts) if attempts > 0 else 0.0)
        with self._tx() as c:
            cur = c.execute(
                "INSERT INTO outbox (method, path, body_json, created_at, attempts, next_at, kind, task_id, attempt) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (method, path, _dumps(body), now, int(attempts), next_at, kind, task_id, attempt),
            )
            return int(cur.lastrowid)

    @staticmethod
    def _outbox_row(r: sqlite3.Row) -> dict[str, Any]:
        return {"id": int(r["id"]), "method": r["method"], "path": r["path"], "body": _loads(r["body_json"], {}),
                "created_at": float(r["created_at"]), "attempts": int(r["attempts"]), "next_at": float(r["next_at"]),
                "kind": r["kind"], "task_id": r["task_id"],
                "attempt": int(r["attempt"]) if r["attempt"] is not None else None}

    def outbox_count(self, task_id: str | None = None) -> int:
        if task_id is None:
            return int(self._query("SELECT COUNT(*) AS n FROM outbox")[0]["n"])
        return int(self._query("SELECT COUNT(*) AS n FROM outbox WHERE task_id = ?", (task_id,))[0]["n"])

    def outbox_has(self, task_id: str, kind: str | None = None) -> bool:
        if kind is None:
            return self.outbox_count(task_id) > 0
        return int(self._query("SELECT COUNT(*) AS n FROM outbox WHERE task_id = ? AND kind = ?",
                               (task_id, kind))[0]["n"]) > 0

    def outbox_task_ids(self) -> list[str]:
        return [r["task_id"] for r in self._query("SELECT DISTINCT task_id FROM outbox WHERE task_id IS NOT NULL")]

    def outbox_all(self) -> list[dict[str, Any]]:
        return [self._outbox_row(r) for r in self._query("SELECT * FROM outbox ORDER BY id")]

    def outbox_claim_due(self, now: float | None = None, limit: int = 50) -> list[dict[str, Any]]:
        """Réclame atomiquement les entrées dues (ordre d'insertion) : leur `next_at` est
        repoussé de _CLAIM_SECONDS pour qu'un autre processus ne les envoie pas en même
        temps. L'appelant termine par outbox_done / outbox_retry / outbox_release."""
        now = time.time() if now is None else now
        claimed: list[dict[str, Any]] = []
        with self._tx() as c:
            # Ordre strict PAR TÂCHE : une écriture n'est due que si aucune écriture plus ancienne
            # de la même tâche n'attend encore (backoff plus long, ou réclamée par un autre
            # processus) — sinon un résultat pourrait partir avant les actions qui le précèdent,
            # et ces actions seraient ensuite refusées (tâche déjà terminée).
            rows = c.execute(
                "SELECT * FROM outbox o WHERE o.next_at <= ? AND NOT EXISTS ("
                "  SELECT 1 FROM outbox p WHERE p.task_id IS NOT NULL AND p.task_id = o.task_id"
                "  AND p.id < o.id AND p.next_at > ?) ORDER BY o.id LIMIT ?",
                (now, now, limit)).fetchall()
            for r in rows:
                c.execute("UPDATE outbox SET next_at = ? WHERE id = ?", (now + _CLAIM_SECONDS, r["id"]))
                claimed.append(self._outbox_row(r))
        return claimed

    def outbox_done(self, entry_id: int) -> None:
        with self._tx() as c:
            c.execute("DELETE FROM outbox WHERE id = ?", (entry_id,))

    def outbox_retry(self, entry_id: int, now: float | None = None) -> float:
        """Nouvel échec réessayable : attempts + 1, prochain essai après backoff."""
        now = time.time() if now is None else now
        with self._tx() as c:
            row = c.execute("SELECT attempts FROM outbox WHERE id = ?", (entry_id,)).fetchone()
            attempts = (int(row["attempts"]) if row else 0) + 1
            next_at = now + outbox_delay(attempts)
            c.execute("UPDATE outbox SET attempts = ?, next_at = ? WHERE id = ?", (attempts, next_at, entry_id))
        return next_at

    def outbox_release(self, entry_id: int, now: float | None = None) -> None:
        """Entrée réclamée mais non envoyée (ordre à préserver) : redevient due tout de suite."""
        now = time.time() if now is None else now
        with self._tx() as c:
            c.execute("UPDATE outbox SET next_at = ? WHERE id = ?", (now, entry_id))
