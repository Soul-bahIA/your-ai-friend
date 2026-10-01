"""Contexte par requête : échéance (x-deadline-ms) et métrage des appels LLM.

Les valeurs sont portées par des ContextVar posées par le middleware de main.py :
elles sont visibles dans la tâche de la requête et copiées dans le threadpool
(endpoints `def`). La liste d'usage est un objet mutable partagé : les appels LLM
faits dans un thread y sont donc bien comptés.
"""
from __future__ import annotations

import time
from contextvars import ContextVar, Token
from typing import Any

DEADLINE_HEADER = "x-deadline-ms"
USAGE_HEADER = "x-llm-usage"
MAX_DEADLINE_MS = 3_600_000  # 1 h : au-delà, on borne

_deadline: ContextVar[float | None] = ContextVar("soulbah_deadline", default=None)
_usage: ContextVar[list[dict[str, Any]] | None] = ContextVar("soulbah_llm_usage", default=None)


def parse_deadline_ms(raw: str | None) -> int | None:
    """Valeur de l'en-tête x-deadline-ms = budget RESTANT en millisecondes (relatif,
    insensible au décalage d'horloge entre node et python). None si absent ;
    ValueError si invalide (non entier ou <= 0) ; borné à MAX_DEADLINE_MS."""
    if raw is None or raw.strip() == "":
        return None
    value = int(raw.strip())  # ValueError si non entier
    if value <= 0:
        raise ValueError("x-deadline-ms doit être > 0")
    return min(value, MAX_DEADLINE_MS)


def begin_request(deadline_ms: int | None) -> tuple[Token, Token]:
    deadline = time.monotonic() + deadline_ms / 1000.0 if deadline_ms else None
    return _deadline.set(deadline), _usage.set([])


def end_request(tokens: tuple[Token, Token]) -> None:
    _deadline.reset(tokens[0])
    _usage.reset(tokens[1])


def set_deadline_in(seconds: float | None) -> Token:
    """Pose une échéance relative (tests, appels internes)."""
    return _deadline.set(time.monotonic() + seconds if seconds is not None else None)


def reset_deadline(token: Token) -> None:
    _deadline.reset(token)


def remaining_s() -> float | None:
    """Secondes restantes avant l'échéance de la requête (None = pas d'échéance)."""
    deadline = _deadline.get()
    if deadline is None:
        return None
    return deadline - time.monotonic()


def deadline_exceeded() -> bool:
    rem = remaining_s()
    return rem is not None and rem <= 0


def record_usage(entry: dict[str, Any]) -> None:
    usage = _usage.get()
    if usage is not None:
        usage.append(entry)


def usage_summary() -> dict[str, Any] | None:
    """Agrégat des appels LLM de la requête courante (None si aucun)."""
    usage = _usage.get()
    if not usage:
        return None
    return {
        "calls": len(usage),
        "input_tokens": sum(int(u.get("input_tokens") or 0) for u in usage),
        "output_tokens": sum(int(u.get("output_tokens") or 0) for u in usage),
        "models": sorted({f"{u.get('provider')}:{u.get('model')}" for u in usage}),
    }
