"""Doubles de test. FakeProvider vit dans app/providers/fake.py (LOT 3 : il sert aussi à la
pile de développement locale, LLM_FAKE_PROVIDER=1) ; ce module le réexporte et ajoute les
erreurs amont factices."""
from __future__ import annotations

from app.providers.base import LLMError
from app.providers.fake import FakeProvider, skeleton_from_schema

__all__ = ["FakeProvider", "skeleton_from_schema", "rate_limited", "server_error"]


def rate_limited(pid: str = "x") -> LLMError:
    return LLMError(429, f"Trop de requêtes ({pid}).", fallback=True, kind="rate_limit")


def server_error(pid: str = "x") -> LLMError:
    return LLMError(502, f"Erreur du fournisseur {pid} (503)", fallback=True, kind="server")
