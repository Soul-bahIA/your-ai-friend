"""Faux plan de contrôle (node-api) pour les tests du runtime V2 (LOT 8) : serveur HTTP local
sur 127.0.0.1 (port libre), routes /api/v2/runtime/* et PUT /api/v2/artifacts/<sha>,
mêmes règles de clôture que le vrai serveur (bail détenu = tentative + propriétaire ;
actions monotones ; résultat accepté une seule fois). Tout est compté pour les assertions
« 0 doublon » : baux accordés, résultats, actions postées par (tâche, étape, statut).
"""
from __future__ import annotations

import json
import threading
import uuid
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

RANK = {"planned": 0, "attempted": 1, "executed": 2, "verified": 3}
TERMINAL = {"verified", "failed", "skipped", "simulated"}
LEASED = {"RUNNING", "WAITING"}


def can_advance(prev: str | None, new: str) -> bool:
    if prev is None or prev == new:
        return True
    if prev in TERMINAL:
        return False
    if new in TERMINAL:
        return True
    return RANK[new] > RANK[prev]


class FakeControlPlane:
    def __init__(self, register_status: int = 200, lease_seconds: int = 30):
        self.lock = threading.RLock()
        self.register_status = register_status
        self.lease_seconds = lease_seconds
        self.runtime_id = str(uuid.uuid4())
        self.tasks: dict[str, dict[str, Any]] = {}
        self.queue: list[str] = []
        self.leases = Counter()
        self.results: list[tuple[str, int, dict]] = []
        self.messages: list[tuple[str, int, str, dict]] = []
        self.action_log: list[tuple[str, int, int, str]] = []
        self.actions: dict[tuple[str, int, int], dict[str, Any]] = {}
        self.reconciles: list[list[dict]] = []
        self.registers = 0
        self.artifacts: dict[str, bytes] = {}
        # Panne simulée (LOT 10 chaos) : toute route répond 503 ; requêtes refusées comptées.
        self.down = False
        self.refused_while_down = 0
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    # --- cycle de vie --------------------------------------------------------------------
    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def start(self) -> "FakeControlPlane":
        self.thread.start()
        return self

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    # --- données ---------------------------------------------------------------------------
    def add_task(self, steps: list[dict], simulated: bool = False, idempotent: dict[str, bool] | None = None) -> str:
        tid = str(uuid.uuid4())
        with self.lock:
            self.tasks[tid] = {"id": tid, "status": "READY", "attempt": 0, "lease_owner": None, "answers": [],
                               "spec": {"steps": steps}, "simulated": simulated, "idempotent": idempotent or {}}
            self.queue.append(tid)
        return tid

    def lease_dict(self, t: dict[str, Any]) -> dict[str, Any]:
        return {"id": t["id"], "session_id": str(uuid.uuid4()), "node_key": "n", "title": "test", "role": "coder",
                "security_level": "L1", "attempt": t["attempt"], "spec": t["spec"], "resources": [],
                "acceptance_criteria": [], "simulated": t["simulated"], "lease_owner": t["lease_owner"],
                "lease_expires_at": "2099-01-01T00:00:00Z", "max_security_level": "L2"}

    def posted(self, task_id: str, step_index: int, status: str) -> int:
        with self.lock:
            return sum(1 for (t, _a, i, s) in self.action_log if t == task_id and i == step_index and s == status)

    def status(self, task_id: str) -> str:
        with self.lock:
            return self.tasks[task_id]["status"]

    def answer(self, task_id: str, text: str) -> None:
        with self.lock:
            t = self.tasks[task_id]
            t["answers"].append({"question": "q", "answer": text, "attempt": t["attempt"]})
            if t["status"] == "WAITING":
                t["status"] = "RUNNING"

    # --- routes ------------------------------------------------------------------------------
    def handle(self, method: str, path: str, body: Any, headers: Any) -> tuple[int, Any]:
        if not headers.get("x-agent-key"):
            return 401, {"error": "x-agent-key requis"}
        with self.lock:
            if self.down:
                self.refused_while_down += 1
                return 503, {"error": "Service temporairement indisponible"}
            if method == "PUT" and path.startswith("/api/v2/artifacts/"):
                sha = path.rsplit("/", 1)[1].split("?")[0]
                self.artifacts[sha] = body
                return 201, {"artifact": {"id": str(uuid.uuid4()), "sha256": sha}, "created": True}
            if not path.startswith("/api/v2/runtime/"):
                return 404, {"error": "inconnu"}
            route = path[len("/api/v2/runtime/"):].split("?")[0]
            owner = f"runtime:{self.runtime_id}"
            if route == "register":
                self.registers += 1
                if self.register_status != 200:
                    return self.register_status, {"error": "runtime refusé : test", "min_version": "9.0.0", "protocol": 1}
                return 200, {"runtime_id": self.runtime_id, "max_slots": body.get("max_slots", 6), "protocol": 1,
                             "lease_seconds": self.lease_seconds, "max_parallel": 6}
            if route == "lease":
                granted = []
                for _ in range(int(body.get("slots") or 0)):
                    if not self.queue:
                        break
                    t = self.tasks[self.queue.pop(0)]
                    t["status"], t["attempt"], t["lease_owner"] = "RUNNING", t["attempt"] + 1, owner
                    self.leases[t["id"]] += 1
                    granted.append(self.lease_dict(t))
                running = sum(1 for t in self.tasks.values() if t["status"] in LEASED)
                return 200, {"tasks": granted, "running": running, "max_parallel": 6, "lease_seconds": self.lease_seconds}
            if route == "keepalive":
                out = []
                for item in body.get("tasks") or []:
                    t = self.tasks.get(item["task_id"])
                    ok = t is not None and t["status"] in LEASED and t["attempt"] == item["attempt"] \
                        and t["lease_owner"] == owner
                    out.append({"task_id": item["task_id"], "status": t["status"] if t else "unknown",
                                "control": "continue" if ok else "stop", "lease_expires_at": None,
                                "answers": list(t["answers"]) if t else [], "messages": []})
                return 200, {"tasks": out, "lease_seconds": self.lease_seconds}
            if route == "reconcile":
                self.reconciles.append(list(body.get("tasks") or []))
                decisions = []
                for item in body.get("tasks") or []:
                    t = self.tasks.get(item["task_id"])
                    if t is None or t["status"] == "CANCELLED":
                        decisions.append({"task_id": item["task_id"], "attempt": item["attempt"], "decision": "cancel",
                                          "status": "gone", "actions": []})
                        continue
                    resume = t["status"] in LEASED and t["attempt"] == item["attempt"] and t["lease_owner"] == owner
                    acts = [{"step_index": i, "tool": a["tool"], "status": a["status"],
                             "idempotent": t["idempotent"].get(a["tool"], a["tool"] == "wait")}
                            for (tid, att, i), a in sorted(self.actions.items()) if tid == t["id"] and att == t["attempt"]]
                    decisions.append({"task_id": t["id"], "attempt": item["attempt"],
                                      "decision": "resume" if resume else "abandon", "status": t["status"],
                                      "actions": acts if resume else []})
                return 200, {"decisions": decisions, "lease_seconds": self.lease_seconds}
            if route.startswith("messages/"):
                return 200, {"acked": True}
            parts = route.split("/")
            if len(parts) >= 3 and parts[0] == "tasks":
                tid, what = parts[1], parts[2]
                t = self.tasks.get(tid)
                if t is None:
                    return 410, {"error": "gone"}
                if method == "GET":
                    acts = [{"step_index": i, "tool": a["tool"], "status": a["status"]}
                            for (x, att, i), a in sorted(self.actions.items()) if x == tid and att == t["attempt"]]
                    return 200, {"task_id": tid, "attempt": t["attempt"], "status": t["status"], "actions": acts}
                held = t["status"] in LEASED and t["attempt"] == body.get("attempt") and t["lease_owner"] == owner
                if not held:
                    return 409, {"error": "bail non détenu pour cette tentative", "status": t["status"]}
                if what == "actions":
                    key = (tid, t["attempt"], int(body["step_index"]))
                    prev = self.actions.get(key, {}).get("status")
                    if not can_advance(prev, body["status"]):
                        return 409, {"error": f"{prev} → {body['status']} refusé"}
                    self.actions[key] = {"tool": body["tool"], "status": body["status"],
                                         "evidence": body.get("evidence")}
                    self.action_log.append((tid, t["attempt"], int(body["step_index"]), body["status"]))
                    return 200, {"action_id": str(uuid.uuid4()), "status": body["status"], "previous": prev}
                if what == "checkpoint":
                    return 200, {"task_id": tid, "checkpoint_id": str(uuid.uuid4()), "duplicate": False}
                if what == "result":
                    t["status"] = "COMPLETED"
                    self.results.append((tid, t["attempt"], body.get("result") or {}))
                    return 200, {"task_id": tid, "status": "COMPLETED", "effect": "VALIDATING → COMPLETED"}
                if what == "message":
                    self.messages.append((tid, t["attempt"], body.get("type"), body.get("payload") or {}))
                    if body.get("type") == "QUESTION":
                        t["status"] = "WAITING"
                    elif body.get("type") == "ERROR":
                        t["status"] = "FAILED"
                    return 200, {"task_id": tid, "status": t["status"], "effect": "ok", "message_id": str(uuid.uuid4())}
            return 404, {"error": "route inconnue"}

    def _handler(self):
        plane = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):  # silencieux
                pass

            def _do(self, method: str) -> None:
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length) if length else b""
                if method == "PUT":
                    body: Any = raw
                else:
                    try:
                        body = json.loads(raw.decode("utf-8")) if raw else {}
                    except ValueError:
                        body = {}
                status, payload = plane.handle(method, self.path, body, self.headers)
                data = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):  # noqa: N802
                self._do("GET")

            def do_POST(self):  # noqa: N802
                self._do("POST")

            def do_PUT(self):  # noqa: N802
                self._do("PUT")

        return Handler
