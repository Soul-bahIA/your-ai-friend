"""Fixtures communes : MEDIA_DIR isolé, aucun appel réseau réel vers un fournisseur."""
from __future__ import annotations

import os
import sys
import tempfile

import pytest

# MEDIA_DIR doit être défini AVANT l'import de app.main (lu à l'import).
_MEDIA = tempfile.mkdtemp(prefix="soulbah_test_media_")
os.environ["MEDIA_DIR"] = _MEDIA
# Aucune clé réelle : l'orchestrateur ne doit jamais joindre un vrai fournisseur.
for _k in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "MISTRAL_API_KEY",
           "DEEPSEEK_API_KEY", "XAI_API_KEY", "QWEN_API_KEY", "LOCAL_LLM_URL", "IA_SERVICE_TOKEN",
           "RUST_SERVICE_URL", "VIDEO_TTS_CONCURRENCY"):
    os.environ.pop(_k, None)
# Tests hermétiques : aucune configuration de routage/modèles héritée du shell.
for _k in [k for k in os.environ if k.startswith("LLM_") or k.endswith("_MODEL")]:
    os.environ.pop(_k, None)
# Environnement de test (contrat LOT 1 §1) : token inter-services optionnel.
os.environ["SOULBAH_ENV"] = "test"

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi.testclient import TestClient  # noqa: E402

from app import main  # noqa: E402
from app.providers import orchestrator  # noqa: E402


@pytest.fixture
def media_dir() -> str:
    return main.MEDIA_DIR


@pytest.fixture
def client(monkeypatch):
    monkeypatch.delenv("IA_SERVICE_TOKEN", raising=False)
    with TestClient(main.app) as c:
        yield c


@pytest.fixture
def fake_llm(monkeypatch):
    """Remplace orchestrator.complete : renvoie `fake_llm.reply` et mémorise les appels."""

    class _Fake:
        reply: str = "{}"
        calls: list[dict] = []

        async def complete(self, task, system, messages, max_tokens, json_schema=None,
                           images=None, provider=None):
            self.calls.append({"task": task, "system": system, "messages": messages,
                               "images": images})
            return self.reply

    fake = _Fake()
    fake.calls = []
    monkeypatch.setattr(orchestrator, "complete", fake.complete)
    return fake


@pytest.fixture
def use_providers():
    """Installe des fournisseurs factices (FakeProvider) dans l'orchestrateur global
    pour la durée d'un test, puis restaure l'état (aucun fournisseur réel)."""
    def _install(providers: dict):
        orchestrator.set_providers(dict(providers))
        return orchestrator

    yield _install
    orchestrator.set_providers(None)
