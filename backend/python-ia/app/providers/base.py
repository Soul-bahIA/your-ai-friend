"""Contrat commun à tous les fournisseurs de modèles d'IA.

SoulBah AI ne dépend d'aucun fournisseur unique : chaque fournisseur (Anthropic,
OpenAI, Gemini, Mistral, DeepSeek, xAI, Qwen, modèle local…) implémente cette
interface. Le routeur choisit le fournisseur selon le type de tâche, ou selon un
override explicite (liste blanche). Changer de fournisseur = configuration.

Règle de sécurité (S23) : le `message` d'une LLMError est renvoyé tel quel au client.
Il ne doit JAMAIS contenir le texte d'une exception interne ni un corps de réponse
amont (qui peut contenir un extrait de clé) : ces détails vont dans les logs.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger("python-ia.llm")


class LLMError(Exception):
    """Erreur LLM portant un code HTTP à propager tel quel (429/402/502…).

    - `fallback` : True si la panne est propre au fournisseur (429, 5xx, délai,
      connexion, clé/crédits) : le routeur peut alors tenter le fournisseur suivant
      et compte l'échec dans le disjoncteur.
    - `kind` : catégorie stable pour les logs et les tests.
    """

    def __init__(self, status: int, message: str, *, fallback: bool = False, kind: str = "error"):
        super().__init__(message)
        self.status = status
        self.message = message
        self.fallback = fallback
        self.kind = kind


def upstream_error(provider: str, status: int, detail: str = "") -> LLMError:
    """Traduit un code HTTP d'un fournisseur amont en erreur pour NOTRE appelant.

    Un 401/403 du fournisseur signifie que NOTRE clé API est mauvaise : ce n'est pas
    une erreur d'authentification du client, on renvoie donc 502 (jamais 401, qui
    ferait croire au front que la session utilisateur a expiré).
    `detail` (corps amont) est seulement journalisé, jamais renvoyé au client.
    """
    if detail and status not in (401, 403):
        logger.warning("Fournisseur %s : HTTP %s : %s", provider, status, detail[:500])
    elif status in (401, 403):
        logger.error("Fournisseur %s : HTTP %s (clé API refusée)", provider, status)
    if status in (401, 403):
        return LLMError(502, f"Clé API du fournisseur invalide ({provider}).", fallback=True, kind="auth")
    if status == 429:
        return LLMError(429, f"Trop de requêtes ({provider}). Réessayez dans quelques instants.",
                        fallback=True, kind="rate_limit")
    if status == 402:
        return LLMError(402, f"Crédits épuisés pour {provider}.", fallback=True, kind="credits")
    if status in (408, 504):
        return LLMError(504, f"Le fournisseur {provider} n'a pas répondu à temps.", fallback=True, kind="timeout")
    if status == 404:
        # Modèle/endpoint inconnu : configuration de CE fournisseur -> on peut tenter le suivant.
        return LLMError(502, f"Erreur du fournisseur {provider} ({status})", fallback=True, kind="not_found")
    if status >= 500:
        return LLMError(502, f"Erreur du fournisseur {provider} ({status})", fallback=True, kind="server")
    return LLMError(502, f"Erreur du fournisseur {provider} ({status})", fallback=False, kind="bad_request")


@dataclass(frozen=True)
class ModelCapabilities:
    """Capacités EXPLICITES d'un couple fournisseur/modèle (rien n'est supposé)."""

    vision: bool = False
    json_schema: bool = False
    # Le modèle « réfléchit » par défaut (thinking adaptatif toujours actif) : les
    # jetons de réflexion consomment max_tokens -> plancher appliqué par le fournisseur.
    thinking: bool = False
    # Accepte output_config.effort.
    effort: bool = False
    max_output_tokens: int = 8192

    def as_dict(self) -> dict[str, Any]:
        return {
            "vision": self.vision,
            "json_schema": self.json_schema,
            "thinking": self.thinking,
            "effort": self.effort,
            "max_output_tokens": self.max_output_tokens,
        }


@dataclass
class CompletionResult:
    """Résultat d'un appel LLM : texte + métrage (usage) + raison d'arrêt."""

    text: str
    provider: str = ""
    model: str = ""
    input_tokens: int | None = None
    output_tokens: int | None = None
    stop_reason: str | None = None
    truncated: bool = False
    latency_ms: int = 0
    # Fournisseurs essayés AVANT celui qui a répondu (repli), dans l'ordre.
    fallback_from: list[str] = field(default_factory=list)

    def usage(self) -> dict[str, Any]:
        return {
            "provider": self.provider,
            "model": self.model,
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "stop_reason": self.stop_reason,
            "truncated": self.truncated,
            "latency_ms": self.latency_ms,
            "fallback_from": list(self.fallback_from),
        }


class LLMProvider:
    """Un fournisseur de modèle. `generate` unifie texte, JSON structuré et vision."""

    id: str = "base"
    family: str = "base"
    model: str = ""

    def capabilities(self, model: str | None = None) -> ModelCapabilities:
        return ModelCapabilities()

    # Compatibilité : anciens attributs lus par les appelants/tests.
    @property
    def supports_vision(self) -> bool:
        return self.capabilities().vision

    @property
    def supports_json_schema(self) -> bool:
        return self.capabilities().json_schema

    async def generate(
        self,
        system: str,
        messages: list[dict[str, Any]],
        max_tokens: int,
        json_schema: dict | None = None,
        images: list[str] | None = None,
        *,
        model: str | None = None,
        timeout_s: float | None = None,
        effort: str | None = None,
    ) -> CompletionResult:
        """Appelle le modèle et renvoie un CompletionResult.

        - `messages` : [{role, content:str}] ; les images (base64 JPEG) sont
          attachées au dernier message utilisateur si `images` est fourni.
        - `json_schema` : si fourni, on demande une sortie JSON conforme (nativement
          si le modèle le supporte, sinon via consigne + response_format JSON).
        - `model` : modèle à utiliser (profil) ; défaut = modèle du fournisseur.
        - `timeout_s` : délai de CET appel (aligné sur l'échéance de la requête).
        - `effort` : niveau d'effort (ignoré si le modèle ne le supporte pas).
        """
        raise NotImplementedError

    async def complete(
        self,
        system: str,
        messages: list[dict[str, Any]],
        max_tokens: int,
        json_schema: dict | None = None,
        images: list[str] | None = None,
    ) -> str:
        """Compatibilité : texte seul."""
        return (await self.generate(system, messages, max_tokens, json_schema, images)).text

    def describe(self) -> dict[str, Any]:
        caps = self.capabilities()
        return {
            "id": self.id,
            "family": self.family,
            "model": self.model,
            "supports_vision": caps.vision,
            "supports_json_schema": caps.json_schema,
            "capabilities": caps.as_dict(),
        }


def attach_images_last_user(
    messages: list[dict[str, Any]], images: list[str], make_block
) -> list[dict[str, Any]]:
    """Copie `messages` en attachant les images (blocs construits par `make_block`)
    au dernier message, suivies de son texte."""
    msgs: list[dict[str, Any]] = [dict(m) for m in messages]
    last = msgs[-1] if msgs else {"role": "user", "content": ""}
    text = last.get("content", "") if isinstance(last.get("content"), str) else ""
    blocks: list[dict[str, Any]] = [make_block(b) for b in images]
    blocks.append({"type": "text", "text": text})
    last["content"] = blocks
    if msgs:
        msgs[-1] = last
    else:
        msgs = [{"role": "user", "content": blocks}]
    return msgs
