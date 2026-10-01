"""Orchestrateur : choisit le fournisseur/modèle d'IA le plus adapté à chaque tâche.

Sélection du fournisseur principal :
  1. override explicite — UNIQUEMENT s'il figure dans LLM_ALLOWED_OVERRIDES
     (liste séparée par des virgules, vide par défaut) ; sinon 400 ;
  2. mapping tâche → fournisseur (défauts ci-dessous, surchargés par LLM_ROUTING) ;
  3. fournisseur par défaut disponible (LLM_DEFAULT_PROVIDER, sinon 1er configuré).

Modèle par rôle (profil) : planner / evaluator / vision / cheap, via
LLM_MODEL_<RÔLE>="[fournisseur:]modèle" et LLM_EFFORT_<RÔLE>. Le profil ne s'applique
que si le fournisseur retenu est celui du profil (défaut : anthropic).

Repli multi-sauts : sur panne du fournisseur (429, 5xx, délai, connexion, clé ou
crédits), on tente le suivant (LLM_FALLBACK_ORDER, au plus LLM_MAX_HOPS appels
RÉELLEMENT tentés : un fournisseur sauté car son disjoncteur est ouvert ne consomme
pas de saut). Un disjoncteur par fournisseur (LLM_CB_THRESHOLD échecs consécutifs →
ouvert pendant LLM_CB_COOLDOWN_S, puis UN seul appel d'essai) évite de marteler un
fournisseur en panne. Pas de repli sur un override explicite (le choix de l'appelant
est respecté).

Vision : une requête portant des images n'est JAMAIS envoyée à un modèle dont la
vision n'est pas déclarée (capabilities.py).

Délais : chaque saut est coupé (asyncio.wait_for) au plus tard à
min(délai de la tâche + marge SDK, temps restant avant l'échéance x-deadline-ms
− DEADLINE_MARGIN_S) ; le SDK reçoit un délai un peu plus court pour échouer
proprement avant la coupure. Sans en-tête, un budget implicite par tâche (aligné sur
les délais de node) borne l'ensemble des sauts.

Chaque appel est journalisé avec son usage (jetons entrée/sortie, raison d'arrêt,
coût estimé) ; une réponse tronquée (max_tokens) devient une erreur 502 « réponse
tronquée ».

Coûts et budgets (LOT 5, usage.py) : le coût de chaque appel est estimé d'après
shared/models/pricing.json (`cost_usd`, None si tarif inconnu) et cumulé en mémoire par
fournisseur et par rôle (`status()["usage"]`). LLM_MAX_OUTPUT_TOKENS_<RÔLE> plafonne
max_tokens des tâches à profil ; LLM_DAILY_BUDGET_USD (coût cumulé par jour UTC) refuse
tout nouvel appel par 402 kind="budget" une fois atteint, sans repli.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from dataclasses import dataclass
from typing import Any

from .. import request_context
from .base import CompletionResult, LLMError, LLMProvider
from .circuit import CircuitBreaker  # noqa: F401 — réexporté (compatibilité LOT 1)
from .. import network_guard, soulbah_settings
from ..config import soulbah_settings_now
from .registry import BLOCKED_BY_MODE, build_providers
from .usage import UsageMeter, estimate_cost, price_for

logger = logging.getLogger("python-ia.llm")

# Type de tâche -> fournisseur préféré. Ajustable sans code via LLM_ROUTING (JSON).
# Tant qu'un seul fournisseur est configuré, tout retombe dessus (voir plan_hops).
_DEFAULT_ROUTING: dict[str, str] = {
    "code": "deepseek",        # génération de code
    "reasoning": "anthropic",  # raisonnement complexe
    "routing": "anthropic",    # classification de la demande (cerveau central)
    "writing": "openai",       # rédaction
    "doc_analysis": "anthropic",
    "translation": "openai",
    "formation": "anthropic",
    "application": "anthropic",
    "vision": "anthropic",
    "automation": "anthropic",  # planification de l'agent
    "evaluation": "anthropic",  # évaluation d'une exécution (sans image)
    "optimization": "anthropic",
    "chat": "openai",
    "general": "anthropic",
}

_PREFERRED_DEFAULTS = ["anthropic", "openai", "gemini", "mistral", "deepseek", "xai", "qwen", "local"]

# Profils par rôle : (variable modèle, modèle par défaut, variable effort, effort par défaut).
PROFILES: dict[str, tuple[str, str, str, str]] = {
    "planner": ("LLM_MODEL_PLANNER", "claude-opus-5-5", "LLM_EFFORT_PLANNER", "high"),
    "evaluator": ("LLM_MODEL_EVALUATOR", "claude-opus-5-5", "LLM_EFFORT_EVALUATOR", "high"),
    "vision": ("LLM_MODEL_VISION", "claude-opus-5-5", "LLM_EFFORT_VISION", "high"),
    "cheap": ("LLM_MODEL_CHEAP", "claude-haiku-4-5-20251001", "LLM_EFFORT_CHEAP", "low"),
}
TASK_PROFILES: dict[str, str] = {
    "automation": "planner",
    "evaluation": "evaluator",
    "vision": "vision",
    "routing": "cheap",
}

# Tâches longues (génération de contenu) : node attend jusqu'à 900 s.
LONG_TASKS = {"formation", "application", "code", "writing"}


def _env_float(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, "") or default)
    except ValueError:
        return default


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, "") or default)
    except ValueError:
        return default


def _csv_env(name: str) -> list[str]:
    return [p.strip() for p in os.getenv(name, "").split(",") if p.strip()]


MIN_HOP_S = 1.0             # en dessous, on ne lance pas de nouvel appel
DEADLINE_MARGIN_S = 0.5     # temps laissé pour répondre à l'appelant (jamais consommé par un saut)
SDK_TIMEOUT_GRACE_S = 0.25  # le délai du SDK expire un peu AVANT la coupure wait_for

# Plafond de max_tokens par profil (LOT 5) : vide = valeur demandée par l'appelant.
OUTPUT_TOKEN_CAPS: dict[str, str] = {
    "planner": "LLM_MAX_OUTPUT_TOKENS_PLANNER",
    "evaluator": "LLM_MAX_OUTPUT_TOKENS_EVALUATOR",
    "vision": "LLM_MAX_OUTPUT_TOKENS_VISION",
    "cheap": "LLM_MAX_OUTPUT_TOKENS_CHEAP",
}


@dataclass
class Hop:
    provider: LLMProvider
    model: str
    effort: str | None


class Orchestrator:
    def __init__(self, providers: dict[str, LLMProvider] | None = None) -> None:
        self._providers: dict[str, LLMProvider] | None = providers
        self._routing: dict[str, str] = dict(_DEFAULT_ROUTING)
        try:
            override = json.loads(os.getenv("LLM_ROUTING", "") or "{}")
            if isinstance(override, dict):
                self._routing.update({str(k): str(v) for k, v in override.items()})
        except json.JSONDecodeError:
            logger.warning("LLM_ROUTING n'est pas un JSON valide : ignoré")
        self.breaker = CircuitBreaker(
            threshold=_env_int("LLM_CB_THRESHOLD", 3),
            cooldown_s=_env_float("LLM_CB_COOLDOWN_S", 30.0),
        )
        # Consommation (jetons, coût) cumulée par processus ; survit à set_providers().
        self.meter = UsageMeter()

    # ------------------------------------------------------------------ config
    def set_providers(self, providers: dict[str, LLMProvider] | None) -> None:
        """Remplace les fournisseurs (tests / rechargement) et réinitialise le disjoncteur."""
        self._providers = providers
        self.breaker.reset()

    def _providers_map(self) -> dict[str, LLMProvider]:
        if self._providers is None:
            self._providers = build_providers()
        return self._providers

    def _default_provider_id(self) -> str | None:
        provs = self._providers_map()
        wanted = os.getenv("LLM_DEFAULT_PROVIDER", "")
        if wanted and wanted in provs:
            return wanted
        for pid in _PREFERRED_DEFAULTS:
            if pid in provs:
                return pid
        return next(iter(provs), None)

    @staticmethod
    def allowed_overrides() -> list[str]:
        """Même variable et même sémantique que node (LLM_ALLOWED_OVERRIDES, vide = aucun)."""
        return [p.lower() for p in _csv_env("LLM_ALLOWED_OVERRIDES")]

    def _fallback_order(self) -> list[str]:
        order = _csv_env("LLM_FALLBACK_ORDER") or list(_PREFERRED_DEFAULTS)
        rest = [p for p in self._providers_map() if p not in order]
        return order + rest

    @staticmethod
    def profile_for(task: str) -> tuple[str, str, str | None] | None:
        """(fournisseur, modèle, effort) du profil associé à la tâche, ou None."""
        name = TASK_PROFILES.get(task)
        if not name:
            return None
        model_env, model_default, effort_env, effort_default = PROFILES[name]
        raw = (os.getenv(model_env, "") or model_default).strip()
        pid, model = raw.split(":", 1) if ":" in raw else ("anthropic", raw)
        effort = (os.getenv(effort_env, "") or effort_default).strip().lower() or None
        return pid.strip(), model.strip(), effort

    @staticmethod
    def role_for(task: str) -> str:
        """Rôle sous lequel la consommation est comptée : nom du profil (planner,
        evaluator, vision, cheap) si la tâche en a un, sinon la tâche elle-même."""
        return TASK_PROFILES.get(task, task)

    @staticmethod
    def output_token_cap(role: str) -> int | None:
        """Plafond LLM_MAX_OUTPUT_TOKENS_<RÔLE> (entier > 0), None = aucun."""
        env = OUTPUT_TOKEN_CAPS.get(role)
        if not env:
            return None
        raw = (os.getenv(env, "") or "").strip()
        if not raw:
            return None
        try:
            cap = int(raw)
        except ValueError:
            logger.warning("%s=%r invalide (entier > 0 attendu) : ignoré", env, raw[:20])
            return None
        return cap if cap > 0 else None

    @classmethod
    def cap_output_tokens(cls, task: str, max_tokens: int) -> int:
        """max_tokens effectif : min(demandé, plafond du profil de la tâche)."""
        cap = cls.output_token_cap(cls.role_for(task))
        if cap is not None and max_tokens > cap:
            logger.info("max_tokens %d plafonné à %d (profil %s)", max_tokens, cap, cls.role_for(task))
            return cap
        return max_tokens

    @staticmethod
    def _task_timeout_s(task: str) -> float:
        if task in LONG_TASKS:
            return _env_float("LLM_LONG_TIMEOUT_S", 600.0)
        return _env_float("LLM_TIMEOUT_S", 100.0)

    @staticmethod
    def _task_budget_s(task: str) -> float:
        """Budget total implicite (tous sauts) sans x-deadline-ms : sous les délais
        de node (120 s / 900 s) pour ne jamais travailler après son abandon."""
        if task in LONG_TASKS:
            return _env_float("LLM_LONG_BUDGET_S", 840.0)
        return _env_float("LLM_BUDGET_S", 110.0)

    # ---------------------------------------------------------------- routing
    @staticmethod
    def local_role_for(task: str) -> str | None:
        """Rôle local d'une tâche : profil (planner, evaluator, vision, cheap) ou code."""
        if task in TASK_PROFILES:
            return TASK_PROFILES[task]
        return "code" if task == "code" else None

    def local_chain(self, task: str) -> list[str]:
        """Serveurs locaux pour une tâche, du plus adapté au plus petit (repli Grand → Petit) :
        spécialisé du rôle, général (LOCAL_LLM_URL), petit modèle (LOCAL_LLM_URL_SMALL)."""
        provs = self._providers_map()
        role = self.local_role_for(task)
        chain = [f"local_{role}"] if role else []
        chain += ["local", "local_small"]
        out: list[str] = []
        for pid in chain:
            if pid in provs and pid not in out:
                out.append(pid)
        return out

    def plan_hops(self, task: str, override: str | None, needs_vision: bool) -> list[Hop]:
        provs = self._providers_map()
        if not provs and BLOCKED_BY_MODE:
            mode = soulbah_settings_now()["mode"]
            raise LLMError(
                503,
                f"Aucun modèle local disponible en mode {mode} : les fournisseurs cloud sont "
                "refusés. Configurez un serveur de modèle local (LOCAL_LLM_URL).",
                kind="no_local_model",
            )
        if not provs:
            raise LLMError(
                500,
                "Aucun fournisseur d'IA configuré. Renseignez au moins une clé "
                "(ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, …).",
                kind="no_provider",
            )
        override = (override or "").strip().lower() or None
        if override:
            if override not in self.allowed_overrides():
                raise LLMError(400, "Fournisseur d'IA imposé non autorisé.", kind="override_forbidden")
            if override not in provs:
                raise LLMError(400, "Fournisseur d'IA imposé non configuré.", kind="override_unavailable")
            order = [override]
        else:
            primary = self._routing.get(task)
            if not primary or primary not in provs:
                primary = self._default_provider_id()
            cloud_order = [p for p in [primary] + self._fallback_order()
                           if p in provs and not p.startswith("local")]
            cloud_order = list(dict.fromkeys(cloud_order))
            local = self.local_chain(task)
            policy = str(soulbah_settings_now().get("model_policy") or "auto").strip()
            if policy == "cloud-first":
                order = cloud_order + local  # comportement V2 : cloud d'abord, local en repli
            elif policy == "local-only":
                order = local  # jamais de cloud, même en HYBRID
            elif policy != "auto" and policy.split(":", 1)[0] in provs:
                pinned = policy.split(":", 1)[0]  # « fournisseur » ou « fournisseur:modèle »
                order = [pinned] + [p for p in local + cloud_order if p != pinned]
            else:
                order = local + cloud_order  # V3 : local prioritaire (mission §8, mode HYBRID)
            if not order:
                order = [p for p in [primary] if p]

        profile = self.profile_for(task)
        default_effort = (os.getenv("LLM_EFFORT_DEFAULT", "") or "").strip().lower() or None
        hops: list[Hop] = []
        policy_now = str(soulbah_settings_now().get("model_policy") or "auto").strip()
        pinned_pid, _, pinned_model = policy_now.partition(":")
        for pid in order:
            prov = provs[pid]
            model, effort = prov.model, default_effort
            if profile and profile[0] == pid:
                model, effort = profile[1], profile[2]
            if not override and pid == pinned_pid and pinned_model:
                model = pinned_model  # model_policy « fournisseur:modèle »
            if needs_vision and not prov.capabilities(model).vision:
                if override:
                    raise LLMError(400, "Le fournisseur imposé ne prend pas en charge les images.", kind="no_vision")
                logger.info("Saut %s:%s ignoré : vision non déclarée", pid, model)
                continue
            hops.append(Hop(prov, model, effort))
        if not hops:
            raise LLMError(503, "Aucun modèle d'IA compatible vision n'est configuré.", kind="no_vision")
        # Pas de troncature ici : LLM_MAX_HOPS borne les appels TENTÉS (generate), pour
        # qu'un fournisseur au disjoncteur ouvert ne consomme pas un saut.
        return hops

    @staticmethod
    def _hop_timeouts(task_timeout: float, remaining: float) -> tuple[float, float]:
        """(délai transmis au SDK, coupure wait_for) d'un saut. La coupure ne dépasse
        jamais `remaining - DEADLINE_MARGIN_S` : la marge reste disponible pour répondre
        à l'appelant ; le SDK expire un peu avant la coupure (erreur propre)."""
        budget = remaining - DEADLINE_MARGIN_S
        sdk_timeout = max(0.1, min(task_timeout, budget - SDK_TIMEOUT_GRACE_S))
        return sdk_timeout, max(sdk_timeout, min(sdk_timeout + SDK_TIMEOUT_GRACE_S, budget))

    # ------------------------------------------------------------- execution
    async def generate(
        self,
        task: str,
        system: str,
        messages: list[dict[str, Any]],
        max_tokens: int,
        json_schema: dict | None = None,
        images: list[str] | None = None,
        provider: str | None = None,
        effort: str | None = None,
    ) -> CompletionResult:
        """`effort` (LOT 5, relais /v2/models/complete) : impose le niveau d'effort à
        tous les sauts ; None = effort du profil / LLM_EFFORT_DEFAULT."""
        hops = self.plan_hops(task, provider, bool(images))
        # Budget quotidien : refus AVANT tout appel, sans repli (402 kind="budget").
        self.meter.check_budget()
        max_tokens = self.cap_output_tokens(task, max_tokens)
        effort = (effort or "").strip().lower() or None
        started = time.monotonic()
        local_deadline = started + self._task_budget_s(task)
        task_timeout = self._task_timeout_s(task)
        max_hops = max(1, _env_int("LLM_MAX_HOPS", 3))
        attempts = 0
        tried: list[str] = []
        first_error: LLMError | None = None

        for hop in hops:
            pid = hop.provider.id
            if attempts >= max_hops:
                break
            remaining = request_context.remaining_s()
            if remaining is None:
                remaining = local_deadline - time.monotonic()
            if remaining < MIN_HOP_S:
                if first_error is not None:
                    logger.warning("Échéance atteinte après échec de %s", tried)
                raise LLMError(504, "Délai de la requête dépassé avant la réponse de l'IA.", kind="deadline")
            token = self.breaker.acquire(pid)
            if token is None:
                logger.warning("Fournisseur %s ignoré : disjoncteur ouvert (ou essai déjà en cours)", pid)
                continue
            attempts += 1
            sdk_timeout, hard_timeout = self._hop_timeouts(task_timeout, remaining)

            t0 = time.monotonic()
            try:
                result = await asyncio.wait_for(
                    hop.provider.generate(
                        system, messages, max_tokens, json_schema, images,
                        model=hop.model, timeout_s=sdk_timeout, effort=effort or hop.effort,
                    ),
                    timeout=hard_timeout,
                )
            except asyncio.TimeoutError:
                err = LLMError(504, f"Le fournisseur {pid} n'a pas répondu à temps.", fallback=True, kind="timeout")
            except LLMError as e:
                if not e.fallback:
                    # Le fournisseur a répondu (requête rejetée…) : pas de verdict de panne.
                    self.breaker.release(pid, token)
                    self._log_failure(task, hop, e, t0)
                    raise
                err = e
            except asyncio.CancelledError:
                self.breaker.release(pid, token)  # requête abandonnée : sonde rendue
                raise
            except Exception:  # noqa: BLE001 — bug/erreur inattendue d'un fournisseur
                logger.exception("Erreur inattendue du fournisseur %s", pid)
                err = LLMError(502, f"Erreur du fournisseur {pid}", fallback=True, kind="internal")
            else:
                self.breaker.success(pid)
                result.fallback_from = list(tried)
                if not result.provider:
                    result.provider = pid
                if not result.model:
                    result.model = hop.model
                if not result.latency_ms:
                    result.latency_ms = int((time.monotonic() - t0) * 1000)
                if result.cost_usd is None:
                    result.cost_usd = estimate_cost(result.provider, result.model,
                                                    result.input_tokens, result.output_tokens)
                self.meter.record(result.provider, result.model, self.role_for(task),
                                  result.input_tokens, result.output_tokens, result.cost_usd)
                self._log_success(task, result)
                if result.truncated:
                    raise LLMError(
                        502,
                        "Réponse IA tronquée (limite de jetons atteinte). Réessayez avec une demande plus courte.",
                        kind="truncated",
                    )
                return result

            # Panne propre au fournisseur : disjoncteur + saut suivant.
            self.breaker.failure(pid)
            self._log_failure(task, hop, err, t0)
            tried.append(pid)
            if first_error is None:
                first_error = err

        if first_error is not None:
            raise first_error
        raise LLMError(503, "Fournisseurs d'IA temporairement indisponibles. Réessayez plus tard.",
                       kind="circuit_open")

    async def complete(
        self,
        task: str,
        system: str,
        messages: list[dict[str, Any]],
        max_tokens: int,
        json_schema: dict | None = None,
        images: list[str] | None = None,
        provider: str | None = None,
    ) -> str:
        """Compatibilité : renvoie le texte seul (l'usage est journalisé et compté)."""
        result = await self.generate(task, system, messages, max_tokens, json_schema, images, provider)
        return result.text

    # ----------------------------------------------------------------- logs
    @staticmethod
    def _log_success(task: str, result: CompletionResult) -> None:
        entry = {"task": task, **result.usage()}
        request_context.record_usage(entry)
        logger.info("llm_call %s", json.dumps({"ok": True, **entry}, ensure_ascii=False))

    @staticmethod
    def _log_failure(task: str, hop: Hop, err: LLMError, t0: float) -> None:
        logger.warning("llm_call %s", json.dumps({
            "ok": False, "task": task, "provider": hop.provider.id, "model": hop.model,
            "status": err.status, "kind": err.kind,
            "latency_ms": int((time.monotonic() - t0) * 1000),
        }, ensure_ascii=False))

    def status(self) -> dict[str, Any]:
        provs = self._providers_map()
        profiles = {}
        for task, name in TASK_PROFILES.items():
            prof = self.profile_for(task)
            if prof:
                profiles[name] = {
                    "provider": prof[0], "model": prof[1], "effort": prof[2], "task": task,
                    "max_output_tokens_cap": self.output_token_cap(name),
                    "pricing_usd_per_mtok": price_for(prof[0], prof[1]),
                }
        # Tarifs connus (USD / 1M jetons) des modèles effectivement en jeu : modèle par
        # défaut de chaque fournisseur configuré + modèles des profils. None = inconnu.
        pricing: dict[str, dict[str, float] | None] = {}
        for pid, prov in provs.items():
            pricing[f"{pid}:{prov.model}"] = price_for(pid, prov.model)
        for prof in profiles.values():
            pricing.setdefault(f"{prof['provider']}:{prof['model']}", prof["pricing_usd_per_mtok"])
        settings = soulbah_settings_now()
        vision = any(p.capabilities(p.model).vision for p in provs.values())
        return {
            "mode": settings["mode"],
            "mode_label": soulbah_settings.mode_label(settings),
            "cloud_models_allowed": soulbah_settings.cloud_models_allowed(settings),
            "blocked_by_mode": dict(BLOCKED_BY_MODE),
            "reasoning_available": bool(provs),
            "vision_available": vision,
            "local_configured": any(p.startswith("local") for p in provs),
            "model_policy": settings.get("model_policy"),
            "local_chains": {t: self.local_chain(t) for t in ("automation", "evaluation", "vision", "routing", "code", "general")},
            "network_guard": {k: v for k, v in network_guard.status().items() if k != "recent"},
            "providers": [p.describe() for p in provs.values()],
            "configured": list(provs.keys()),
            "default": self._default_provider_id(),
            "routing": self._routing,
            "profiles": profiles,
            "allowed_overrides": self.allowed_overrides(),
            "circuit_breakers": self.breaker.snapshot(),
            "pricing": pricing,
            "usage": self.meter.snapshot(),
        }


orchestrator = Orchestrator()
