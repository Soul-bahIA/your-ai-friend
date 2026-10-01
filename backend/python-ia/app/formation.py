"""Moteur de contenu de formation — pipeline pédagogique multi-étapes.

1. analyze_request  : demande → sujet, niveau, audience, objectifs, compétences,
                      + requêtes de recherche à lancer (moteur KB-first, côté node).
2. build_program    : analyse + notes de recherche → programme (modules, glossaire, FAQ).
3. build_module     : détaille UN module (chapitres, exercices, quiz, cas, projet).

Le découpage en deux temps (programme puis modules) évite la troncature d'un gros
curriculum et permet de paralléliser la génération des modules côté orchestrateur.
Tout passe par l'orchestrateur multi-fournisseurs (tâche « formation »).
"""
from __future__ import annotations

import json

from .llm import structured_generate

# --- Étape 1 : analyse de la demande ------------------------------------------------
ANALYSIS_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "subject": {"type": "string"},
        "level": {"type": "string", "enum": ["débutant", "intermédiaire", "avancé"]},
        "audience": {"type": "string"},
        "objectives": {"type": "array", "items": {"type": "string"}},
        "skills": {"type": "array", "items": {"type": "string"}},
        "prerequisites": {"type": "array", "items": {"type": "string"}},
        "research_queries": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["subject", "level", "audience", "objectives", "skills", "prerequisites", "research_queries"],
}

_ANALYSIS_SYSTEM = (
    "Tu es concepteur pédagogique. Analyse une demande de formation et renvoie : le "
    "sujet précis, le niveau (débutant/intermédiaire/avancé), l'audience cible, les "
    "objectifs pédagogiques, les compétences à enseigner, les prérequis, et 3 à 5 "
    "requêtes de recherche (research_queries) ciblées qui permettront de documenter la "
    "formation (concepts clés, bonnes pratiques, exemples réels)."
)


async def analyze_request(topic: str, details: str | None, provider: str | None = None) -> dict:
    user = f"DEMANDE DE FORMATION :\n{topic}" + (f"\n\nDÉTAILS : {details}" if details else "")
    result = await structured_generate(
        _ANALYSIS_SYSTEM, [{"role": "user", "content": user}], ANALYSIS_SCHEMA,
        max_tokens=1500, task="formation", provider=provider,
    )
    result.setdefault("research_queries", [])
    return result


# --- Étape 2 : programme (squelette + glossaire + FAQ) ------------------------------
PROGRAM_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "title": {"type": "string"},
        "description": {"type": "string"},
        "level": {"type": "string"},
        "duration": {"type": "string"},
        "audience": {"type": "string"},
        "objectives": {"type": "array", "items": {"type": "string"}},
        "modules": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "title": {"type": "string"},
                    "summary": {"type": "string"},
                    "objectives": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["title", "summary", "objectives"],
            },
        },
        "glossary": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"term": {"type": "string"}, "definition": {"type": "string"}},
                "required": ["term", "definition"],
            },
        },
        "faq": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"question": {"type": "string"}, "answer": {"type": "string"}},
                "required": ["question", "answer"],
            },
        },
    },
    "required": ["title", "description", "level", "duration", "audience", "objectives", "modules", "glossary", "faq"],
}

_PROGRAM_SYSTEM = (
    "Tu es un formateur professionnel. À partir de l'analyse et des notes de recherche "
    "(synthèses originales), conçois le PROGRAMME d'une formation de qualité "
    "professionnelle en français : titre, description, durée estimée, 4 à 6 modules à "
    "progression pédagogique logique (chacun avec résumé et objectifs), un glossaire "
    "(8-15 termes) et une FAQ (5-8 questions). Contenu ORIGINAL, jamais copié des sources."
)


async def build_program(analysis: dict, research_notes: list[dict], provider: str | None = None) -> dict:
    user = (
        f"ANALYSE :\n{json.dumps(analysis, ensure_ascii=False)}\n\n"
        f"NOTES DE RECHERCHE (synthèses à exploiter, jamais à recopier) :\n"
        f"{json.dumps(research_notes, ensure_ascii=False)[:12000]}"
    )
    program = await structured_generate(
        _PROGRAM_SYSTEM, [{"role": "user", "content": user}], PROGRAM_SCHEMA,
        max_tokens=4096, task="formation", provider=provider,
    )
    program.setdefault("modules", [])
    return program


# --- Étape 3 : détail d'un module ---------------------------------------------------
MODULE_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "chapters": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "title": {"type": "string"},
                    "content": {"type": "string"},
                    "key_points": {"type": "array", "items": {"type": "string"}},
                    "examples": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["title", "content", "key_points", "examples"],
            },
        },
        "exercises": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"question": {"type": "string"}, "solution": {"type": "string"}},
                "required": ["question", "solution"],
            },
        },
        "quiz": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "question": {"type": "string"},
                    "choices": {"type": "array", "items": {"type": "string"}},
                    "answer": {"type": "integer"},
                    "explanation": {"type": "string"},
                },
                "required": ["question", "choices", "answer", "explanation"],
            },
        },
        "case_study": {"type": "string"},
        "project": {"type": "string"},
        "demo_plan": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "software": {"type": "string"},
                    "goal": {"type": "string"},
                    "narration": {"type": "string"},
                },
                "required": ["software", "goal", "narration"],
            },
        },
    },
    "required": ["chapters", "exercises", "quiz", "case_study", "project", "demo_plan"],
}

_MODULE_SYSTEM = (
    "Tu es un formateur professionnel. Détaille UN module de formation en français, de "
    "qualité niveau Udemy/YouTube : 2 à 4 chapitres (explications claires, points clés, "
    "exemples concrets), 2-4 exercices avec corrigés, un quiz (3-5 questions à choix "
    "multiples avec l'index de la bonne réponse et une explication), une étude de cas et "
    "un projet pratique. Ajoute un demo_plan : les démonstrations RÉELLES à réaliser sur "
    "ordinateur (logiciel à ouvrir, but, et narration à dire). Contenu ORIGINAL."
)


async def build_module(
    program_title: str, module: dict, research_notes: list[dict], provider: str | None = None
) -> dict:
    user = (
        f"FORMATION : {program_title}\n\n"
        f"MODULE À DÉTAILLER :\n{json.dumps(module, ensure_ascii=False)}\n\n"
        f"NOTES DE RECHERCHE (à exploiter, jamais à recopier) :\n"
        f"{json.dumps(research_notes, ensure_ascii=False)[:8000]}"
    )
    detail = await structured_generate(
        _MODULE_SYSTEM, [{"role": "user", "content": user}], MODULE_SCHEMA,
        max_tokens=6000, task="formation", provider=provider,
    )
    for key in ("chapters", "exercises", "quiz", "demo_plan"):
        detail.setdefault(key, [])
    detail.setdefault("case_study", "")
    detail.setdefault("project", "")
    return detail
