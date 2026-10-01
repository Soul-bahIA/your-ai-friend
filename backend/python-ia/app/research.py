"""Synthèse documentaire — compare des sources et produit une connaissance ORIGINALE.

Ne recopie jamais un extrait mot pour mot : compare, élimine les contradictions et
reformule en une synthèse propre à SoulBah AI, en citant les sources en référence.
Passe par l'orchestrateur multi-fournisseurs (tâche « doc_analysis »).
"""
from __future__ import annotations

import json

from .llm import structured_generate

SYNTHESIS_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "title": {"type": "string"},
        "summary": {"type": "string"},
        "content": {"type": "string"},
        "keywords": {"type": "array", "items": {"type": "string"}},
        "domain": {"type": "string"},
        "confidence": {"type": "number"},
        "sources": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"title": {"type": "string"}, "url": {"type": "string"}},
                "required": ["title", "url"],
            },
        },
    },
    "required": ["title", "summary", "content", "keywords", "domain", "confidence", "sources"],
}

_SYNTHESIS_SYSTEM = (
    "Tu es l'analyste documentaire de SoulBah AI. À partir d'extraits de sources et de "
    "connaissances déjà acquises, tu produis une SYNTHÈSE ORIGINALE en français.\n"
    "RÈGLES :\n"
    "- Compare les sources, garde ce qui est fiable et cohérent, élimine les contradictions.\n"
    "- Ne recopie JAMAIS un extrait mot pour mot : reformule intégralement.\n"
    "- Cite les sources utilisées dans le champ sources (référence uniquement).\n"
    "- confidence (0 à 1) reflète la fiabilité globale (nombre et concordance des sources).\n"
    "- domain : un domaine court en minuscules-avec-tirets (ex. marketing-digital, "
    "developpement-web, cybersecurite).\n"
    "- content : une synthèse structurée et réutilisable ; summary : 2-3 phrases."
)


async def synthesize(
    query: str,
    sources: list[dict],
    known: list[dict] | None = None,
    domain: str | None = None,
    provider: str | None = None,
) -> dict:
    parts = [f"SUJET / QUESTION :\n{query}"]
    if domain:
        parts.append(f"DOMAINE SUGGÉRÉ : {domain}")
    if known:
        parts.append(
            "CONNAISSANCES DÉJÀ ACQUISES (à compléter/actualiser, ne pas répéter) :\n"
            + json.dumps(known, ensure_ascii=False)[:6000]
        )
    if sources:
        parts.append(
            "SOURCES (extraits à analyser, jamais à recopier) :\n"
            + json.dumps(sources, ensure_ascii=False)[:12000]
        )
    else:
        parts.append(
            "Aucune source externe fournie : produis la synthèse à partir de tes "
            "connaissances propres, avec une confidence prudente."
        )

    user = "\n\n".join(parts)
    result = await structured_generate(
        _SYNTHESIS_SYSTEM,
        [{"role": "user", "content": user}],
        SYNTHESIS_SCHEMA,
        max_tokens=4096,
        task="doc_analysis",
        provider=provider,
    )
    result.setdefault("keywords", [])
    result.setdefault("sources", [])
    result.setdefault("domain", domain or "general")
    try:
        result["confidence"] = max(0.0, min(1.0, float(result.get("confidence", 0.5))))
    except (TypeError, ValueError):
        result["confidence"] = 0.5
    return result
