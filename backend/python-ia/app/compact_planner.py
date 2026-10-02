"""Planificateur et évaluateur COMPACTS pour les modèles locaux (V3).

Le prompt complet du planificateur V1 (catalogue de tous les outils, exemples, contraintes)
fait ≈ 7 000 jetons : il dépasse le contexte d'un petit modèle local (4 096 jetons sur le PC de
référence) et prendrait plusieurs minutes à lire sur CPU. Quand le premier modèle de la chaîne
est local, on envoie à la place :
  - seulement les outils PERTINENTS pour l'objectif (mots-clés → catégories du catalogue,
    plus un socle : attente, capture, inspection d'interface) ;
  - une ligne par outil et une par champ, un exemple court ;
  - un schéma JSON qui CONTRAINT la sortie (grammaire llama.cpp) : JSON toujours valide, types
    d'étapes limités aux outils proposés.
Le plan reste ensuite filtré et validé exactement comme un plan du cloud (aucune règle relâchée).
"""
from __future__ import annotations

import json
import unicodedata
from typing import Any

# Mots-clés (sans accents, en minuscules) → catégories d'outils du catalogue.
KEYWORDS: dict[str, tuple[str, ...]] = {
    "filesystem": ("fichier", "dossier", "repertoire", "cree", "creer", "ecri", "enregistre", "sauvegarde",
                   "lis ", "lire", "liste", "deplace", "copie", ".txt", ".md", ".json", "document", "note"),
    "app_launch": ("ouvre", "ouvrir", "lance", "lancer", "demarre", "application", "logiciel", "bloc-notes",
                   "bloc notes", "notepad", "navigateur", "chrome", "edge", "firefox", "calculatrice",
                   "explorateur", "vs code", "vscode", "visual studio", "paint", "word", "excel"),
    "keyboard": ("tape", "taper", "ecris dans", "saisi", "raccourci", "touche", "clavier", "ctrl", "entree"),
    "mouse": ("clique", "cliquer", "souris", "double-clic", "defiler", "glisse"),
    "window": ("fenetre", "ferme", "fermer", "minimise", "agrandi", "bascule", "premier plan"),
    "shell": ("commande", "terminal", "npm", "python", "node", "pytest", "script", "tests", "lance les tests"),
    "git": ("git", "branche", "commit", "fusion", "worktree"),
    "video": ("video", "enregistre l'ecran", "enregistrer l'ecran", "filme", "montage", "demo"),
    "voice": ("dis ", "parle", "voix", "audio", "prononce", "a voix haute", "message vocal", ".wav"),
    "web": ("site", "page web", "http", "url", "internet"),
    "phone": ("telephone", "android", "smartphone"),
    "screen": ("capture", "ecran", "screenshot"),
}
ALWAYS = ("generic", "screen")
DEFAULT = ("filesystem", "app_launch", "keyboard")
MAX_TOOLS = 16
PLAN_MAX_TOKENS = 700
EVAL_MAX_TOKENS = 400
SECTION_CHARS = 5000


def _plain(text: str) -> str:
    norm = unicodedata.normalize("NFD", text.lower())
    return "".join(c for c in norm if unicodedata.category(c) != "Mn")


def categories_for(goal: str, internet: bool = True) -> list[str]:
    g = _plain(goal)
    found = [cat for cat, words in KEYWORDS.items() if any(w in g for w in words)]
    if not any(c not in ("screen",) for c in found):
        found += list(DEFAULT)
    if not internet:
        found = [c for c in found if c != "web"]
    return list(dict.fromkeys([*found, *ALWAYS]))


def select_tools(catalog: dict, goal: str, internet: bool = True) -> list[dict]:
    cats = categories_for(goal, internet)
    tools = [t for t in catalog["tools"] if t["category"] in cats]
    order = {c: i for i, c in enumerate(cats)}
    tools.sort(key=lambda t: (order.get(t["category"], 99), t["name"]))
    return tools[:MAX_TOOLS]


def _first_sentence(text: str, limit: int = 150) -> str:
    s = text.split(". ")[0].strip()
    return (s if len(s) <= limit else s[: limit - 1] + "…").rstrip(".") + "."


def _field(p: dict) -> str:
    t = p["type"] if isinstance(p["type"], str) else "/".join(p["type"])
    if p.get("is_path"):
        t = "chemin absolu"
    if p.get("enum"):
        t = "|".join(p["enum"][:6])
    return f"{p['name']}{'*' if p['required'] else ''} ({t})"


def compact_catalog(tools: list[dict], workspace: str) -> str:
    lines = []
    for t in tools:
        fields = [_field(p) for p in t["params"] if not p.get("deprecated")]
        lines.append(f"- {t['name']} [{t['security_level']}] : {_first_sentence(t['description'])}")
        if fields:
            lines.append(f"    champs : {', '.join(fields)}")
        if t.get("examples"):
            ex = dict(t["examples"][0])
            lines.append("    ex. : " + json.dumps(ex, ensure_ascii=False).replace(workspace, "<dossier autorisé>"))
    return "\n".join(lines)


def allowed_dirs_from_context(context: str | None) -> list[str]:
    """Dossiers autorisés transmis par node dans le contexte (lignes « - C:\\… » après
    « DOSSIERS AUTORISÉS »)."""
    if not context or "DOSSIERS AUTORIS" not in context:
        return []
    section = context.split("DOSSIERS AUTORIS", 1)[1]
    out: list[str] = []
    for line in section.splitlines()[1:]:
        line = line.strip()
        if not line.startswith("- "):
            if out:
                break
            continue
        path = line[2:].strip().rstrip("\\/")
        if len(path) >= 3 and (path[1:3] == ":\\" or path.startswith("/")):
            out.append(path)
    return out[:8]


def _path_schema(allowed: list[str]) -> dict[str, Any]:
    """Chemin : texte. Un motif regex limitant aux dossiers autorisés a été essayé, mais le moteur de
    grammaire de llama.cpp (b11325) le rejette (« output does not match the expected peg-native
    format ») : les dossiers autorisés restent dans le contexte, et l'agent refuse tout chemin hors
    de sa liste blanche avant d'agir (la vraie barrière)."""
    return {"type": "string"}


def _param_schema(p: dict, allowed: list[str]) -> dict[str, Any]:
    types = p["type"] if isinstance(p["type"], list) else [p["type"]]
    variants: list[dict[str, Any]] = []
    for t in types:
        if t == "array":
            item_t = (p.get("items") or {}).get("type", "string")
            item = _path_schema(allowed) if p.get("is_path") else {"type": item_t}
            variants.append({"type": "array", "items": item})
        elif t == "string":
            if p.get("enum"):
                variants.append({"type": "string", "enum": list(p["enum"])})
            elif p.get("is_path"):
                variants.append(_path_schema(allowed))
            else:
                variants.append({"type": "string"})
        else:
            variants.append({"type": t})
    return variants[0] if len(variants) == 1 else {"anyOf": variants}


def _required(tool: dict) -> list[str]:
    req = [p["name"] for p in tool["params"] if p["required"] and not p.get("deprecated")]
    for group in tool.get("required_any", []):
        current = [g for g in group if not any(p["name"] == g and p.get("deprecated") for p in tool["params"])]
        if current and not any(g in req for g in current):
            req.append(current[0])
    return req


def step_schema(tool: dict, allowed: list[str]) -> dict[str, Any]:
    props: dict[str, Any] = {"type": {"const": tool["name"]}, "note": {"type": "string"}}
    for p in tool["params"]:
        if not p.get("deprecated"):
            props[p["name"]] = _param_schema(p, allowed)
    return {"type": "object", "required": ["type", *_required(tool), "note"], "properties": props,
            "additionalProperties": False}


def plan_schema(tools: list[dict], allowed: list[str] | None = None) -> dict[str, Any]:
    """Schéma de plan : une variante PAR OUTIL, avec ses champs obligatoires (la grammaire force le
    modèle à les écrire) et des chemins limités aux dossiers autorisés quand ils sont connus."""
    allowed = allowed or []
    return {
        "type": "object",
        "required": ["understanding", "feasible", "reason", "steps"],
        "properties": {
            "understanding": {"type": "string"},
            "feasible": {"type": "boolean"},
            "reason": {"type": "string"},
            "steps": {"type": "array", "maxItems": 8, "items": {"anyOf": [step_schema(t, allowed) for t in tools]}},
        },
    }


def plan_system(catalog: dict, goal: str, internet: bool = True, context: str | None = None
                ) -> tuple[str, dict[str, Any]]:
    tools = select_tools(catalog, goal, internet)
    system = (
        "Tu es le planificateur de SoulBah AI, un agent qui AGIT sur l'ordinateur Windows de l'utilisateur.\n"
        "Transforme l'objectif en un plan JSON d'étapes (8 au plus), avec UNIQUEMENT ces outils "
        "(* = champ obligatoire) :\n"
        + compact_catalog(tools, catalog.get("workspace_placeholder", "<dossier autorisé>"))
        + "\n\nRègles :\n"
        "- Chaque étape : \"type\" (nom exact d'un outil ci-dessus), ses champs, et \"note\" (but en quelques mots).\n"
        "- Chemins ABSOLUS, à l'intérieur d'un des DOSSIERS AUTORISÉS du contexte : recopie leur orthographe exacte.\n"
        "- Après open_app, ajoute une étape wait de 2 secondes avant d'agir dans la fenêtre.\n"
        "- Si l'objectif est irréalisable avec ces outils, dangereux ou trop vague : feasible=false, steps vide, "
        "reason explique pourquoi.\n"
        "- understanding : reformule l'objectif en une phrase, EN FRANÇAIS.\n"
        "Réponds UNIQUEMENT par l'objet JSON {\"understanding\", \"feasible\", \"reason\", \"steps\"}."
    )
    return system, plan_schema(tools, allowed_dirs_from_context(context))


def eval_system(catalog: dict, used: list[str]) -> str:
    tools = [t for t in catalog["tools"] if t["name"] in used][:MAX_TOOLS]
    return (
        "Tu es l'évaluateur de SoulBah AI. On te donne un objectif, le plan exécuté et le rapport "
        "d'exécution (une entrée par étape : ok + détail).\nOutils utilisés :\n"
        + compact_catalog(tools, catalog.get("workspace_placeholder", "<dossier autorisé>"))
        + "\n\nVerdicts : success (objectif atteint), retry (échec corrigeable : donne corrective_steps, un "
        "nouveau plan complet), abort (échec non corrigeable). Une étape simulée ou un texte masqué ne "
        "prouve rien.\nRéponds UNIQUEMENT par l'objet JSON {\"verdict\", \"reason\", \"corrective_steps\"}."
    )


EVAL_SCHEMA: dict[str, Any] = {
    "type": "object",
    "required": ["verdict", "reason", "corrective_steps"],
    "properties": {
        "verdict": {"type": "string", "enum": ["success", "retry", "abort"]},
        "reason": {"type": "string"},
        "corrective_steps": {"type": "array", "maxItems": 8,
                             "items": {"type": "object", "required": ["type"], "additionalProperties": True,
                                       "properties": {"type": {"type": "string"}}}},
    },
}
