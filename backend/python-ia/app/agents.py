"""Cerveau central (Chief Agent) — comprend une demande et la route vers l'agent
spécialisé approprié. Aucun agent ne travaille seul : tout passe par ce coordinateur.

Chaque agent spécialisé correspond à une capacité réelle de SoulBah AI (formation,
recherche, code, contrôle du poste…). Le coordinateur classe la demande, estime la
complexité, propose un découpage en sous-tâches et désigne l'agent principal — la
brique d'exécution (côté node) dispatche ensuite vers la route correspondante.
"""
from __future__ import annotations

from .llm import structured_generate

# Registre des agents spécialisés (extensible). `capability` = brique d'exécution cible.
AGENTS: dict[str, dict[str, str]] = {
    "chat": {"label": "Chat Agent", "capability": "chat", "desc": "conversation, questions-réponses générales"},
    "code": {"label": "Code Agent", "capability": "generate", "desc": "écriture, correction, revue de code"},
    "app_builder": {"label": "App Builder Agent", "capability": "generate_application", "desc": "création d'applications complètes"},
    "formation": {"label": "Formation Agent", "capability": "generate_formation", "desc": "création de cours et formations"},
    "research": {"label": "Research Agent", "capability": "research", "desc": "recherche d'informations + synthèse"},
    "knowledge": {"label": "Knowledge Agent", "capability": "knowledge", "desc": "stockage/récupération de connaissances"},
    "desktop": {"label": "Desktop Agent", "capability": "agent_goal", "desc": "contrôle de l'ordinateur (ouvrir, cliquer, taper, fichiers, commandes)"},
    "vision": {"label": "Vision Agent", "capability": "vision", "desc": "analyse d'écran / d'images"},
    "video": {"label": "Video Agent", "capability": "formation_video", "desc": "montage et production vidéo"},
    "database": {"label": "Database Agent", "capability": "database", "desc": "opérations sur la base de données"},
    "devops": {"label": "DevOps Agent", "capability": "agent_goal", "desc": "build, tests, déploiement, CI/CD"},
    "security": {"label": "Security Agent", "capability": "generate", "desc": "analyse et revue de sécurité"},
    "marketing": {"label": "Marketing Agent", "capability": "generate", "desc": "contenu et stratégie marketing"},
    "design": {"label": "Design Agent", "capability": "generate", "desc": "UI/UX, design, maquettes"},
    "learning": {"label": "Learning Agent", "capability": "self_improve", "desc": "auto-amélioration, optimisation des workflows"},
}

ROUTE_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "agent": {"type": "string", "enum": list(AGENTS.keys())},
        "task_type": {
            "type": "string",
            "enum": ["chat", "creation_application", "creation_formation", "montage_video",
                     "automatisation_pc", "recherche_analyse"],
        },
        "reason": {"type": "string"},
        "complexity": {"type": "string", "enum": ["simple", "moyenne", "complexe"]},
        "subtasks": {"type": "array", "items": {"type": "string"}},
        "needs_memory_check": {"type": "boolean"},
    },
    "required": ["agent", "task_type", "reason", "complexity", "subtasks", "needs_memory_check"],
}


def _catalog() -> str:
    return "\n".join(f"- {aid} ({a['label']}) : {a['desc']}" for aid, a in AGENTS.items())


_CHIEF_SYSTEM = (
    "Tu es le cerveau central (Chief Agent) de SoulBah AI, un OS intelligent multi-agents. "
    "Tu comprends la demande de l'utilisateur, identifies le type de tâche, estimes la "
    "complexité, la découpes en sous-tâches et désignes l'AGENT SPÉCIALISÉ principal.\n\n"
    "AGENTS DISPONIBLES :\n" + _catalog() + "\n\n"
    "Règles : choisis l'agent le plus adapté (agent = l'un des identifiants ci-dessus). "
    "needs_memory_check = true si consulter la mémoire/base de connaissances avant d'agir "
    "est pertinent. subtasks = étapes de haut niveau (3-6 max)."
)


async def route_request(request: str, provider: str | None = None) -> dict:
    result = await structured_generate(
        _CHIEF_SYSTEM,
        [{"role": "user", "content": f"DEMANDE :\n{request}"}],
        ROUTE_SCHEMA,
        max_tokens=1200,
        task="reasoning",
        provider=provider,
    )
    # Enrichit avec les métadonnées de l'agent choisi (label + capacité d'exécution).
    agent = AGENTS.get(result.get("agent", ""), {})
    result["agent_label"] = agent.get("label", result.get("agent", ""))
    result["capability"] = agent.get("capability", "")
    return result
