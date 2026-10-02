"""File d'inférence des modèles locaux — Resource Manager V3 (LOT 6).

Problème : six agents logiques peuvent demander une inférence au même instant, alors qu'un
serveur llama.cpp sur CPU ne sert qu'un ou deux contextes à la fois. Sans file, les requêtes
s'empilent dans le serveur, chacune consomme son délai en attendant, et les dernières échouent
par dépassement de délai sans que personne ne voie pourquoi.

Ici, chaque serveur local (une URL) a une porte :
  - capacité = slots du serveur (GET /props → total_slots), réduite à 1 sous pression mémoire
    critique (soulbah_resources.inference_capacity) ; SOULBAH_INFERENCE_SLOTS l'impose ;
  - priorité : conversation (chat, routing) > agents (automation, evaluation, vision) > fond
    (code, rédaction, formation) ; ordre d'arrivée à priorité égale ;
  - occupation réelle : avant de libérer une requête, la porte consulte GET /slots (llama.cpp)
    — le chat de node-api appelle le serveur directement, sans passer par ici : ses inférences
    comptent quand même ;
  - attente bornée : au-delà du temps restant de la requête (ou SOULBAH_INFERENCE_QUEUE_MAX_S),
    erreur 503 kind="local_busy" avec la file en cause (repli vers le saut suivant s'il existe).
Le temps passé en file n'est PAS imputé au délai de l'appel au modèle (le routeur recalcule
le temps restant après l'entrée), seulement à l'échéance globale de la requête.

État visible : snapshot() → GET /v2/resources (capacité, en cours, en attente, attentes max et
moyenne, refus).
"""
from __future__ import annotations

import asyncio
import heapq
import itertools
import json
import logging
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any

from . import soulbah_resources as R

logger = logging.getLogger("python-ia.inference")

PRIORITY_INTERACTIVE = 0
PRIORITY_AGENT = 1
PRIORITY_BACKGROUND = 2
_TASK_PRIORITY = {
    "chat": PRIORITY_INTERACTIVE, "routing": PRIORITY_INTERACTIVE, "general": PRIORITY_INTERACTIVE,
    "automation": PRIORITY_AGENT, "evaluation": PRIORITY_AGENT, "vision": PRIORITY_AGENT,
    "reasoning": PRIORITY_AGENT, "optimization": PRIORITY_AGENT, "doc_analysis": PRIORITY_AGENT,
}
PRIORITY_NAMES = {PRIORITY_INTERACTIVE: "interactive", PRIORITY_AGENT: "agent", PRIORITY_BACKGROUND: "background"}

PROPS_TTL_S = 60.0
SLOTS_TTL_S = 0.4
PROBE_FAILURE_TTL_S = 30.0  # serveur sans /slots (Ollama, LM Studio…) : pas de nouvel essai avant
POLL_S = 0.5
HTTP_TIMEOUT_S = 2.0


def priority_for(task: str) -> int:
    return _TASK_PRIORITY.get(task, PRIORITY_BACKGROUND)


def _env_float(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, "") or default)
    except ValueError:
        return default


def _server_root(base_url: str) -> str:
    root = base_url.rstrip("/")
    return root[:-3] if root.endswith("/v1") else root


def _get_json(url: str) -> Any:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:  # noqa: S310 — URL locale validée par le registre
        return json.loads(resp.read().decode("utf-8"))


class GateBusy(Exception):
    """Aucune place dans le délai imparti."""

    def __init__(self, message: str, snapshot: dict[str, Any]):
        super().__init__(message)
        self.snapshot = snapshot


@dataclass(order=True)
class _Waiter:
    priority: int
    seq: int
    task: str = field(compare=False)
    enqueued: float = field(compare=False)
    future: asyncio.Future = field(compare=False, repr=False)


class Gate:
    """Porte d'un serveur local (une URL)."""

    def __init__(self, key: str, base_url: str | None, *, probe: bool | None = None):
        self.key = key
        self.base_url = base_url
        if probe is None:  # SOULBAH_INFERENCE_PROBE=0 : jamais de lecture de /props ni /slots
            probe = os.getenv("SOULBAH_INFERENCE_PROBE", "1").strip() != "0"
        self.probe = probe and bool(base_url)
        self._loop: asyncio.AbstractEventLoop | None = None
        self.active = 0
        self._heap: list[_Waiter] = []
        self._seq = itertools.count()
        self._wake: asyncio.Event | None = None
        self._pump: asyncio.Task | None = None
        self._props: tuple[float, dict[str, Any] | None] = (0.0, None)
        self._slots: tuple[float, int | None] = (0.0, None)
        self.served = 0
        self.rejected = 0
        self.max_wait_s = 0.0
        self.total_wait_s = 0.0
        self.last_wait_s = 0.0
        self.max_active = 0
        self.max_waiting = 0

    # --- informations du serveur ------------------------------------------------------------
    def _server_props(self) -> dict[str, Any] | None:
        if not self.probe:
            return None
        at, props = self._props
        if time.monotonic() - at < PROPS_TTL_S:
            return props
        try:
            data = _get_json(_server_root(self.base_url or "") + "/props")
            props = data if isinstance(data, dict) else None
        except (OSError, ValueError, urllib.error.URLError):
            props = None
        self._props = (time.monotonic() + (0.0 if props else PROBE_FAILURE_TTL_S - PROPS_TTL_S), props)
        return props

    def server_slots(self) -> int | None:
        props = self._server_props()
        try:
            return int(props["total_slots"]) if props and props.get("total_slots") else None
        except (TypeError, ValueError):
            return None

    def idle_server_slots(self) -> int | None:
        """Slots inoccupés selon le serveur (GET /slots de llama.cpp) ; None = inconnu."""
        if not self.probe:
            return None
        at, idle = self._slots
        if time.monotonic() - at < SLOTS_TTL_S:
            return idle
        try:
            data = _get_json(_server_root(self.base_url or "") + "/slots")
            idle = sum(1 for s in data if isinstance(s, dict) and not s.get("is_processing")) if isinstance(data, list) else None
        except (OSError, ValueError, urllib.error.URLError):
            idle = None
        self._slots = (time.monotonic() + (0.0 if idle is not None else PROBE_FAILURE_TTL_S - SLOTS_TTL_S), idle)
        return idle

    def capacity(self, free_mb: int | None = None) -> int:
        forced = os.getenv("SOULBAH_INFERENCE_SLOTS", "").strip()
        if forced.isdigit() and int(forced) > 0:
            base = int(forced)
        else:
            base = self.server_slots() or 1
        if free_mb is None:
            free_mb = R.memory().get("free_mb")
        return R.inference_capacity(base, free_mb)

    # --- file --------------------------------------------------------------------------------
    def _bind_loop(self) -> None:
        """Une file par boucle asyncio (uvicorn : une seule ; tests : une par asyncio.run)."""
        loop = asyncio.get_running_loop()
        if self._loop is not loop:
            self._loop = loop
            self._heap = []
            self._wake = asyncio.Event()
            self._pump = None

    def _ensure_pump(self) -> None:
        if self._wake is None:
            self._wake = asyncio.Event()
        if self._pump is None or self._pump.done():
            self._pump = asyncio.get_running_loop().create_task(self._run_pump())

    async def _run_pump(self) -> None:
        """Libère les requêtes en tête de file dès qu'une place existe (porte ET serveur)."""
        assert self._wake is not None
        while self._heap:
            # Requêtes abandonnées (délai, annulation) : retirées de la tête.
            while self._heap and self._heap[0].future.done():
                heapq.heappop(self._heap)
            if not self._heap:
                break
            cap = await asyncio.to_thread(self.capacity)
            idle = await asyncio.to_thread(self.idle_server_slots) if self.active < cap else 0
            if self.active < cap and (idle is None or idle > 0):
                w = heapq.heappop(self._heap)
                if not w.future.done():
                    self.active += 1
                    self.max_active = max(self.max_active, self.active)
                    w.future.set_result(True)
                self._note_dispatch(idle)
                continue
            self._wake.clear()
            try:
                await asyncio.wait_for(self._wake.wait(), timeout=POLL_S)
            except asyncio.TimeoutError:
                pass

    def _note_dispatch(self, idle: int | None) -> None:
        """Le serveur n'a pas encore vu la requête libérée : un slot de moins dans la lecture en
        cache, conservée un peu plus longtemps."""
        if isinstance(idle, int):
            self._slots = (time.monotonic() + 0.6, max(0, idle - 1))

    async def acquire(self, task: str, timeout_s: float) -> float:
        """Attend une place ; renvoie le temps d'attente (s). GateBusy si le délai est dépassé."""
        self._bind_loop()
        loop = asyncio.get_running_loop()
        started = time.monotonic()
        waiter = _Waiter(priority_for(task), next(self._seq), task, started, loop.create_future())
        # Chemin rapide : rien en file, place libre (porte), serveur non saturé. Les lectures (qui
        # cèdent la main) précèdent la vérification ; vérification et prise de place se suivent
        # sans point d'attente : deux requêtes simultanées ne peuvent pas prendre la même place.
        if not self.waiting():
            cap = await asyncio.to_thread(self.capacity)
            idle = await asyncio.to_thread(self.idle_server_slots) if self.active < cap else 0
            if not self.waiting() and self.active < cap and (idle is None or idle > 0):
                self.active += 1
                self.max_active = max(self.max_active, self.active)
                self._note_dispatch(idle)
                self._account(0.0)
                return 0.0
        heapq.heappush(self._heap, waiter)
        self.max_waiting = max(self.max_waiting, self.waiting())
        self._ensure_pump()
        assert self._wake is not None
        self._wake.set()
        try:
            await asyncio.wait_for(asyncio.shield(waiter.future), timeout=max(0.0, timeout_s))
        except asyncio.TimeoutError:
            if waiter.future.done() and not waiter.future.cancelled():
                # Place obtenue au moment exact de l'expiration : on la garde.
                pass
            else:
                waiter.future.cancel()
                self.rejected += 1
                raise GateBusy(
                    f"Modèle local occupé : {self.active} inférence(s) en cours, {self.waiting()} en attente "
                    f"(attente de {time.monotonic() - started:.0f} s sans place libre).",
                    self.snapshot(),
                ) from None
        except asyncio.CancelledError:
            if waiter.future.done() and not waiter.future.cancelled():
                self.release()  # place obtenue mais requête abandonnée : rendue
            else:
                waiter.future.cancel()
            raise
        waited = time.monotonic() - started
        self._account(waited)
        return waited

    def _account(self, waited: float) -> None:
        self.served += 1
        self.last_wait_s = waited
        self.total_wait_s += waited
        self.max_wait_s = max(self.max_wait_s, waited)

    def release(self) -> None:
        self.active = max(0, self.active - 1)
        if self._wake is not None and self._loop is not None and not self._loop.is_closed():
            self._wake.set()

    def waiting(self) -> int:
        return sum(1 for w in self._heap if not w.future.done())

    def snapshot(self) -> dict[str, Any]:
        queue = sorted(w for w in self._heap if not w.future.done())
        now = time.monotonic()
        return {
            "key": self.key,
            "url": self.base_url,
            "capacity": self.capacity(),
            "server_slots": self.server_slots(),
            "active": self.active,
            "waiting": len(queue),
            "queue": [{"task": w.task, "priority": PRIORITY_NAMES[w.priority], "waiting_s": round(now - w.enqueued, 1)}
                      for w in queue[:20]],
            "served": self.served,
            "rejected_busy": self.rejected,
            "max_active": self.max_active,
            "max_waiting": self.max_waiting,
            "wait_s": {"last": round(self.last_wait_s, 2), "max": round(self.max_wait_s, 2),
                       "avg": round(self.total_wait_s / self.served, 2) if self.served else 0.0},
        }


class InferenceGates:
    """Une porte par serveur local (clé = URL du serveur, sinon identifiant du fournisseur)."""

    def __init__(self) -> None:
        self._gates: dict[str, Gate] = {}

    def gate_for(self, provider: Any) -> Gate | None:
        family = getattr(provider, "family", "")
        pid = str(getattr(provider, "id", ""))
        if family != "local" and not pid.startswith("local"):
            return None
        base = getattr(provider, "base_url", None)
        key = str(base or pid)
        gate = self._gates.get(key)
        if gate is None:
            gate = self._gates[key] = Gate(key, base, probe=None if base and pid != "fake" else False)
        return gate

    def queue_max_s(self) -> float:
        return max(1.0, _env_float("SOULBAH_INFERENCE_QUEUE_MAX_S", 600.0))

    def snapshot(self) -> list[dict[str, Any]]:
        return [g.snapshot() for g in self._gates.values()]

    def reset(self) -> None:
        self._gates.clear()


gates = InferenceGates()

__all__ = ["Gate", "GateBusy", "InferenceGates", "gates", "priority_for", "PRIORITY_INTERACTIVE",
           "PRIORITY_AGENT", "PRIORITY_BACKGROUND"]
