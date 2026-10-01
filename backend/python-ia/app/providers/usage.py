"""Tarifs, estimation du coût et compteur de consommation des appels LLM (LOT 5).

Tarifs (USD par million de jetons, entrée / sortie) : source unique
`shared/models/pricing.json` (audit §11), dont `_BUILTIN_PRICING` est la copie intégrée
(l'image Docker de python-ia n'embarque pas `shared/`) ; un test de non-dérive compare
les deux. Recherche : fournisseur → modèle exact, sinon le plus long préfixe
(`claude-haiku-4-5-20251001` → `claude-haiku-4-5`, `mistral-large-latest` →
`mistral-large`), sinon `*` (modèle local = 0). Surcharge sans code : LLM_PRICING (JSON,
même forme que la clé `providers`). Modèle inconnu → coût None (jamais 0 : un coût
inconnu ne doit pas passer pour gratuit).

Compteur en mémoire par processus (`UsageMeter`) : totaux jetons / coût par fournisseur
et par rôle, coût cumulé du jour UTC, plafond quotidien LLM_DAILY_BUDGET_USD (vide =
illimité). Au-delà du plafond, `check_budget()` lève LLMError(402, kind="budget") AVANT
tout nouvel appel ; avertissement journalisé au franchissement de 80 %. Les coûts
inconnus ne comptent pas dans le budget (comptés dans `unknown_cost_calls`).
"""
from __future__ import annotations

import json
import logging
import os
import threading
import time
from datetime import datetime, timezone
from typing import Any, Callable

from .base import LLMError

logger = logging.getLogger("python-ia.llm")

PRICING_FILE_ENV = "LLM_PRICING_FILE"
PRICING_OVERRIDE_ENV = "LLM_PRICING"
DAILY_BUDGET_ENV = "LLM_DAILY_BUDGET_USD"
BUDGET_WARN_RATIO = 0.8

# Copie de shared/models/pricing.json["providers"] — modifier les deux ensemble.
_BUILTIN_PRICING: dict[str, dict[str, dict[str, float]]] = {
    "anthropic": {
        "claude-opus-5-5": {"input": 4.0, "output": 20.0},
        "claude-opus-5": {"input": 5.0, "output": 25.0},
        "claude-sonnet-5-5": {"input": 2.0, "output": 10.0},
        "claude-sonnet-5": {"input": 2.0, "output": 10.0},
        "claude-sonnet-4-6": {"input": 3.0, "output": 15.0},
        "claude-haiku-4-5": {"input": 1.0, "output": 5.0},
    },
    "openai": {
        "gpt-4o": {"input": 2.5, "output": 10.0},
        "gpt-4o-mini": {"input": 0.15, "output": 0.6},
        "gpt-4.1": {"input": 2.0, "output": 8.0},
        "gpt-4.1-mini": {"input": 0.4, "output": 1.6},
    },
    "gemini": {
        "gemini-2.0-flash": {"input": 0.1, "output": 0.4},
        "gemini-2.5-flash": {"input": 0.3, "output": 2.5},
        "gemini-2.5-pro": {"input": 1.25, "output": 10.0},
    },
    "mistral": {
        "mistral-large": {"input": 2.0, "output": 6.0},
        "mistral-small": {"input": 0.1, "output": 0.3},
    },
    "deepseek": {
        "deepseek-chat": {"input": 0.27, "output": 1.1},
        "deepseek-reasoner": {"input": 0.55, "output": 2.19},
    },
    "xai": {
        "grok-2": {"input": 2.0, "output": 10.0},
        "grok-3": {"input": 3.0, "output": 15.0},
        "grok-4": {"input": 3.0, "output": 15.0},
    },
    "qwen": {
        "qwen-max": {"input": 1.6, "output": 6.4},
        "qwen-plus": {"input": 0.4, "output": 1.2},
        "qwen-turbo": {"input": 0.05, "output": 0.2},
    },
    "local": {
        "*": {"input": 0.0, "output": 0.0},
    },
}

# Emplacement du JSON partagé dans le dépôt (absent sous Docker : copie intégrée).
SHARED_PRICING_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", "..", "..", "shared", "models", "pricing.json"
)

_warned: set[str] = set()


def _warn_once(message: str) -> None:
    if message not in _warned:
        _warned.add(message)
        logger.warning(message)


def _price(value: Any) -> dict[str, float] | None:
    """{"input": x, "output": y} avec des nombres >= 0, sinon None."""
    if not isinstance(value, dict):
        return None
    try:
        inp, out = float(value.get("input")), float(value.get("output"))
    except (TypeError, ValueError):
        return None
    if inp < 0 or out < 0:
        return None
    return {"input": inp, "output": out}


def _clean_table(data: Any, source: str) -> dict[str, dict[str, dict[str, float]]]:
    table: dict[str, dict[str, dict[str, float]]] = {}
    if not isinstance(data, dict):
        _warn_once(f"{source} : objet JSON attendu, ignoré")
        return table
    for pid, models in data.items():
        if not isinstance(models, dict):
            continue
        clean: dict[str, dict[str, float]] = {}
        for model, price in models.items():
            p = _price(price)
            if p is None:
                _warn_once(f"{source}[{str(pid)[:30]!r}][{str(model)[:60]!r}] : tarif invalide, ignoré")
                continue
            clean[str(model).lower()] = p
        if clean:
            table[str(pid).lower()] = clean
    return table


def load_shared_pricing(path: str | None = None) -> dict[str, dict[str, dict[str, float]]] | None:
    """Table `providers` de shared/models/pricing.json (ou LLM_PRICING_FILE), None si absent."""
    path = path or os.getenv(PRICING_FILE_ENV, "") or SHARED_PRICING_PATH
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError):
        _warn_once(f"Tarifs {path} illisibles : copie intégrée utilisée")
        return None
    return _clean_table(data.get("providers") if isinstance(data, dict) else None, path)


def pricing_table() -> dict[str, dict[str, dict[str, float]]]:
    """Table effective : copie intégrée (ou fichier LLM_PRICING_FILE si imposé) + surcharge
    LLM_PRICING. Lue à chaque appel (bon marché, et les tests changent l'environnement)."""
    table = {pid: dict(models) for pid, models in _BUILTIN_PRICING.items()}
    if os.getenv(PRICING_FILE_ENV, ""):
        loaded = load_shared_pricing()
        if loaded:
            for pid, models in loaded.items():
                table.setdefault(pid, {}).update(models)
    raw = os.getenv(PRICING_OVERRIDE_ENV, "")
    if raw:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            _warn_once(f"{PRICING_OVERRIDE_ENV} n'est pas un JSON valide : ignoré")
        else:
            for pid, models in _clean_table(data, PRICING_OVERRIDE_ENV).items():
                table.setdefault(pid, {}).update(models)
    return table


def price_for(provider: str, model: str) -> dict[str, float] | None:
    """Tarif (USD / 1M jetons) d'un couple fournisseur/modèle, None si inconnu."""
    models = pricing_table().get((provider or "").lower())
    if not models:
        return None
    m = (model or "").lower()
    if m in models:
        return models[m]
    best = None
    for key in models:
        if key != "*" and m.startswith(key) and (best is None or len(key) > len(best)):
            best = key
    if best is not None:
        return models[best]
    return models.get("*")


def estimate_cost(provider: str, model: str, input_tokens: int | None, output_tokens: int | None) -> float | None:
    """Coût estimé en USD ; None si le tarif est inconnu. Jetons absents = 0."""
    price = price_for(provider, model)
    if price is None:
        return None
    cost = (int(input_tokens or 0) * price["input"] + int(output_tokens or 0) * price["output"]) / 1_000_000
    return round(cost, 8)


def daily_budget_usd() -> float | None:
    """Plafond quotidien (USD) ; None = illimité (vide, invalide ou <= 0)."""
    raw = (os.getenv(DAILY_BUDGET_ENV, "") or "").strip()
    if not raw:
        return None
    try:
        value = float(raw)
    except ValueError:
        _warn_once(f"{DAILY_BUDGET_ENV}={raw[:20]!r} invalide : budget illimité")
        return None
    return value if value > 0 else None


def _empty_total() -> dict[str, Any]:
    return {"calls": 0, "input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0, "unknown_cost_calls": 0}


class UsageMeter:
    """Compteur de consommation en mémoire (par processus, partagé entre threads)."""

    def __init__(self, clock: Callable[[], float] = time.time):
        self._clock = clock
        self._lock = threading.Lock()
        self._by_provider: dict[str, dict[str, Any]] = {}
        self._by_role: dict[str, dict[str, Any]] = {}
        self._total = _empty_total()
        self._day: str = self._utc_day()
        self._day_total = _empty_total()
        self._warned_80 = False
        self._warned_over = False

    def _utc_day(self) -> str:
        return datetime.fromtimestamp(self._clock(), tz=timezone.utc).date().isoformat()

    def _roll_day_locked(self) -> None:
        day = self._utc_day()
        if day != self._day:
            self._day = day
            self._day_total = _empty_total()
            self._warned_80 = False
            self._warned_over = False

    @staticmethod
    def _add(total: dict[str, Any], input_tokens: int, output_tokens: int, cost: float | None) -> None:
        total["calls"] += 1
        total["input_tokens"] += input_tokens
        total["output_tokens"] += output_tokens
        if cost is None:
            total["unknown_cost_calls"] += 1
        else:
            total["cost_usd"] = round(total["cost_usd"] + cost, 8)

    def record(self, provider: str, model: str, role: str, input_tokens: int | None,
               output_tokens: int | None, cost_usd: float | None) -> None:
        inp, out = int(input_tokens or 0), int(output_tokens or 0)
        with self._lock:
            self._roll_day_locked()
            self._add(self._total, inp, out, cost_usd)
            self._add(self._day_total, inp, out, cost_usd)
            self._add(self._by_provider.setdefault(provider or "?", _empty_total()), inp, out, cost_usd)
            self._add(self._by_role.setdefault(role or "?", _empty_total()), inp, out, cost_usd)
            limit = daily_budget_usd()
            spent = self._day_total["cost_usd"]
        if limit is None:
            return
        if spent >= limit and not self._warned_over:
            self._warned_over = True
            logger.warning("Budget quotidien LLM ATTEINT : %.4f / %.2f USD (jour UTC %s) : "
                           "les prochains appels seront refusés (402)", spent, limit, self._day)
        elif spent >= BUDGET_WARN_RATIO * limit and not self._warned_80:
            self._warned_80 = True
            logger.warning("Budget quotidien LLM à %.0f %% : %.4f / %.2f USD (jour UTC %s)",
                           100 * spent / limit, spent, limit, self._day)

    def spent_today(self) -> float:
        with self._lock:
            self._roll_day_locked()
            return self._day_total["cost_usd"]

    def check_budget(self) -> None:
        """Lève LLMError(402, kind="budget") si le plafond quotidien est atteint."""
        limit = daily_budget_usd()
        if limit is None:
            return
        spent = self.spent_today()
        if spent >= limit:
            raise LLMError(
                402,
                "Budget quotidien d'IA épuisé. Les appels reprendront demain (UTC) ou après "
                "relèvement de LLM_DAILY_BUDGET_USD.",
                kind="budget",
            )

    def reset(self) -> None:
        with self._lock:
            self._by_provider.clear()
            self._by_role.clear()
            self._total = _empty_total()
            self._day = self._utc_day()
            self._day_total = _empty_total()
            self._warned_80 = False
            self._warned_over = False

    def snapshot(self) -> dict[str, Any]:
        limit = daily_budget_usd()
        with self._lock:
            self._roll_day_locked()
            spent = self._day_total["cost_usd"]
            return {
                "total": dict(self._total),
                "by_provider": {k: dict(v) for k, v in sorted(self._by_provider.items())},
                "by_role": {k: dict(v) for k, v in sorted(self._by_role.items())},
                "today": {"day": self._day, **self._day_total},
                "daily_budget_usd": limit,
                "budget_remaining_usd": None if limit is None else round(max(0.0, limit - spent), 8),
                "budget_exhausted": limit is not None and spent >= limit,
            }
