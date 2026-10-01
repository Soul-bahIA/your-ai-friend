"""Contrat commun à tous les fournisseurs de modèles d'IA.

SoulBah AI ne dépend d'aucun fournisseur unique : chaque fournisseur (Anthropic,
OpenAI, Gemini, Mistral, DeepSeek, xAI, Qwen, modèle local…) implémente cette
interface. Le routeur choisit le fournisseur selon le type de tâche, ou selon un
override explicite. Changer de fournisseur = configuration, pas de code métier.
"""
from __future__ import annotations

from typing import Any


class LLMError(Exception):
    """Erreur LLM portant un code HTTP à propager tel quel (429/402/502…)."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


class LLMProvider:
    """Un fournisseur de modèle. `complete` unifie texte, JSON structuré et vision."""

    id: str = "base"
    family: str = "base"
    model: str = ""
    supports_vision: bool = False
    supports_json_schema: bool = False

    async def complete(
        self,
        system: str,
        messages: list[dict[str, Any]],
        max_tokens: int,
        json_schema: dict | None = None,
        images: list[str] | None = None,
    ) -> str:
        """Retourne le texte généré.

        - `messages` : [{role, content:str}] ; les images (base64 JPEG) sont
          attachées au dernier message utilisateur si `images` est fourni.
        - `json_schema` : si fourni, on demande une sortie JSON conforme (nativement
          si le fournisseur le supporte, sinon via consigne + response_format JSON).
        """
        raise NotImplementedError

    def describe(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "family": self.family,
            "model": self.model,
            "supports_vision": self.supports_vision,
            "supports_json_schema": self.supports_json_schema,
        }
