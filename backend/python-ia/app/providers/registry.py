"""Registre des fournisseurs d'IA — construit à partir de l'environnement.

Un fournisseur est activé s'il est configuré (clé présente, ou URL locale pour un
modèle auto-hébergé). Ajouter un fournisseur futur = ajouter une entrée SPECS.
Les capacités (vision, JSON natif, réflexion…) sont déclarées dans capabilities.py
(vision=False par défaut ; surcharge : LLM_CAPABILITIES). Les modèles par rôle
(planner/evaluator/vision/cheap) sont choisis par le routeur (LLM_MODEL_<RÔLE>).
"""
from __future__ import annotations

import os

from .anthropic_provider import AnthropicProvider
from .base import LLMProvider
from .openai_compat import OpenAICompatProvider

# id -> (famille, url de base, variable d'env de la clé, variable d'env du modèle, modèle par défaut)
# Les fournisseurs "openai-compat" partagent le même code, seule la config change.
SPECS: dict[str, dict[str, str]] = {
    "anthropic": {
        "family": "anthropic",
        "key_env": "ANTHROPIC_API_KEY",
        "model_env": "ANTHROPIC_MODEL",
        "default_model": "claude-opus-5-5",
    },
    "openai": {
        "family": "openai-compat",
        "base_url": "https://api.openai.com/v1",
        "key_env": "OPENAI_API_KEY",
        "model_env": "OPENAI_MODEL",
        "default_model": "gpt-4o",
    },
    "gemini": {
        "family": "openai-compat",
        "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
        "key_env": "GEMINI_API_KEY",
        "model_env": "GEMINI_MODEL",
        "default_model": "gemini-2.0-flash",
    },
    "mistral": {
        "family": "openai-compat",
        "base_url": "https://api.mistral.ai/v1",
        "key_env": "MISTRAL_API_KEY",
        "model_env": "MISTRAL_MODEL",
        "default_model": "mistral-large-latest",
    },
    "deepseek": {
        "family": "openai-compat",
        "base_url": "https://api.deepseek.com/v1",
        "key_env": "DEEPSEEK_API_KEY",
        "model_env": "DEEPSEEK_MODEL",
        "default_model": "deepseek-chat",
    },
    "xai": {
        "family": "openai-compat",
        "base_url": "https://api.x.ai/v1",
        "key_env": "XAI_API_KEY",
        "model_env": "XAI_MODEL",
        "default_model": "grok-2-latest",
    },
    "qwen": {
        "family": "openai-compat",
        "base_url": "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        "key_env": "QWEN_API_KEY",
        "model_env": "QWEN_MODEL",
        "default_model": "qwen-max",
    },
}

# Modèle local (Ollama / LM Studio / vLLM) : activé si LOCAL_LLM_URL est défini.
LOCAL_URL_ENV = "LOCAL_LLM_URL"
LOCAL_MODEL_ENV = "LOCAL_LLM_MODEL"
LOCAL_KEY_ENV = "LOCAL_LLM_KEY"


def build_providers() -> dict[str, LLMProvider]:
    providers: dict[str, LLMProvider] = {}

    for pid, spec in SPECS.items():
        key = os.getenv(spec["key_env"], "")
        if not key:
            continue
        model = os.getenv(spec["model_env"], spec["default_model"])
        if spec["family"] == "anthropic":
            providers[pid] = AnthropicProvider(pid, model, key)
        else:
            providers[pid] = OpenAICompatProvider(
                pid, spec["base_url"], key, model, family="openai-compat"
            )

    # Modèle local (clé optionnelle)
    local_url = os.getenv(LOCAL_URL_ENV, "")
    if local_url:
        providers["local"] = OpenAICompatProvider(
            "local",
            local_url,
            os.getenv(LOCAL_KEY_ENV, ""),
            os.getenv(LOCAL_MODEL_ENV, "llama3.1"),
            family="local",
        )

    return providers
