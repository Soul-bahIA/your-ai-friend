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


def step_schema(tool: dict, allowed: list[str], note: bool = True) -> dict[str, Any]:
    """`note=False` (DAG) : pas de champ « note » — moins de jetons à générer sur CPU."""
    props: dict[str, Any] = {"type": {"const": tool["name"]}}
    if note:
        props["note"] = {"type": "string"}
    for p in tool["params"]:
        if not p.get("deprecated"):
            props[p["name"]] = _param_schema(p, allowed)
    return {"type": "object", "required": ["type", *_required(tool), *(["note"] if note else [])], "properties": props,
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


# --- V3 LOT 4 : proposition de DAG multi-agents par un modèle local -------------------------------
DAG_MAX_NODES = 6
DAG_MAX_STEPS = 4
DAG_MAX_CRITERIA = 2
DAG_MAX_TOKENS = 1500
# Mesuré sur le PC de référence (qwen2.5-1.5b, 2 cœurs) : ≈ 3,5 jetons/s sous grammaire JSON, ≈ 1 200
# jetons de prompt — un DAG de 3 nœuds dépasse les 280 s du délai ordinaire. Délai long imposé.
DAG_TIMEOUT_S = 600.0
LEVELS = ("L0", "L1", "L2", "L3")

# Critères d'acceptation proposables (forme exigée par node-api, evaluation/criteria.ts).
CRITERIA_SCHEMAS: dict[str, dict[str, Any]] = {
    "file_exists": {"required": ["path"], "properties": {"path": {"type": "string"}}},
    "file_contains": {"required": ["path", "text"], "properties": {"path": {"type": "string"}, "text": {"type": "string"}}},
    "command_succeeds": {"required": [], "properties": {"command": {"type": "string"}}},
    "tests_pass": {"required": [], "properties": {"command": {"type": "string"}}},
    "ui_element_state": {"required": ["name"], "properties": {"name": {"type": "string"}, "state": {"type": "string"},
                                                               "window_title": {"type": "string"}}},
    "video_valid": {"required": ["path"], "properties": {"path": {"type": "string"}}},
    "llm_rubric": {"required": ["rubric"], "properties": {"rubric": {"type": "string"}}},
}


def _criterion_schema(ctype: str) -> dict[str, Any]:
    spec = CRITERIA_SCHEMAS[ctype]
    return {"type": "object", "required": ["type", *spec["required"]],
            "properties": {"type": {"const": ctype}, **spec["properties"]}, "additionalProperties": False}


def dag_tools(catalog: dict, goal: str, roles: list[dict], internet: bool = True) -> list[dict]:
    """Outils pertinents pour l'objectif ET planifiables par au moins un rôle exécuté sur le PC."""
    allowed = {t for r in roles if r.get("executor") != "p1" for t in r.get("tools", [])}
    return [t for t in select_tools(catalog, goal, internet) if t["name"] in allowed]


def _levels(max_level: str) -> list[str]:
    return list(LEVELS[: LEVELS.index(max_level) + 1]) if max_level in LEVELS else list(LEVELS[:3])


def dag_roles(roles: list[dict], tools: list[dict]) -> list[tuple[dict, list[dict]]]:
    """Rôles proposables au modèle local, chacun avec SES outils pertinents. Seuls les rôles exécutés sur
    le PC : un rôle du serveur exige des champs de spec (relecture, rédaction) que le petit modèle ne
    sait pas produire — mesuré : nœuds refusés à coup sûr par validateDag."""
    out = []
    for r in roles:
        if r.get("executor") == "p1":
            continue
        own = [t for t in tools if t["name"] in set(r.get("tools", []))]
        if own:
            out.append((r, own))
    return out


def dag_schema(tools: list[dict], roles: list[dict], max_level: str) -> dict[str, Any]:
    """Un nœud = une variante PAR RÔLE : le rôle est une constante et ses étapes n'utilisent que les outils
    de ce rôle (mesuré en réel : sans cette contrainte, le petit modèle mettait write_file dans le rôle
    desktop_operator, refusé par validateDag)."""
    crit = {"type": "array", "maxItems": DAG_MAX_CRITERIA, "items": {"anyOf": [_criterion_schema(c) for c in CRITERIA_SCHEMAS]}}
    variants = []
    for role, own in dag_roles(roles, tools) or [({"name": r["name"], "max_security_level": r.get("max_security_level", "L1")}, []) for r in roles]:
        cap = min(_levels(max_level), _levels(role.get("max_security_level", "L1")), key=len)
        steps: dict[str, Any] = {"type": "array", "maxItems": DAG_MAX_STEPS,
                                 "items": {"anyOf": [step_schema(t, [], note=False) for t in own]} if own else {"type": "object"}}
        variants.append({
            "type": "object",
            "required": ["key", "title", "role", "security_level", "steps", "acceptance_criteria"],
            "properties": {
                "key": {"type": "string"},
                "title": {"type": "string"},
                "role": {"const": role["name"]},
                "security_level": {"type": "string", "enum": cap},
                "steps": steps,
                "acceptance_criteria": crit,
            },
            "additionalProperties": False,
        })
    node: dict[str, Any] = variants[0] if len(variants) == 1 else {"anyOf": variants}
    edge = {"type": "object", "required": ["from", "to"],
            "properties": {"from": {"type": "string"}, "to": {"type": "string"},
                           "kind": {"type": "string", "enum": ["hard", "soft"]}},
            "additionalProperties": False}
    # Pas de champ « feasible » : mesuré en réel, le petit modèle le remplissait AVANT d'écrire ses nœuds
    # et se déclarait « irréalisable » à tort. Ordre imposé par la grammaire : comprendre, planifier,
    # puis (facultatif) expliquer. Plan vide = irréalisable ; sinon validateDag (node) juge le plan.
    return {
        "type": "object",
        "required": ["understanding", "nodes", "edges"],
        "properties": {
            "understanding": {"type": "string"},
            "nodes": {"type": "array", "maxItems": DAG_MAX_NODES, "items": node},
            "edges": {"type": "array", "maxItems": 12, "items": edge},
            "reason": {"type": "string"},
        },
    }


def dag_system(catalog: dict, goal: str, roles: list[dict], allowed_dirs: list[str], max_level: str,
               internet: bool = True) -> tuple[str, dict[str, Any]]:
    tools = dag_tools(catalog, goal, roles, internet)
    role_lines = [f"- {r['name']} (niveau max {r.get('max_security_level', 'L1')}) : "
                  f"{_first_sentence(r.get('description', ''), 120)} Outils : {', '.join(t['name'] for t in own)}"
                  for r, own in dag_roles(roles, tools)]
    dirs = "\n".join(f"- {d}" for d in allowed_dirs) or "(aucun : n'utilise AUCUN chemin de fichier)"
    system = (
        "Tu es le planificateur multi-agents de SoulBah AI. Découpe l'objectif en tâches (nœuds) confiées à des "
        f"rôles, avec leurs dépendances (edges). {DAG_MAX_NODES} nœuds au plus. Tu PROPOSES : le serveur valide, "
        "l'utilisateur approuve.\n\nRÔLES :\n" + "\n".join(role_lines)
        + "\n\nOUTILS (* = champ obligatoire) :\n" + compact_catalog(tools, catalog.get("workspace_placeholder", "<dossier autorisé>"))
        + f"\n\nDOSSIERS AUTORISÉS (chemins absolus, à l'intérieur) :\n{dirs}\n\n"
        f"Plafond de sécurité : {max_level}.\n"
        "Règles :\n"
        "- key : identifiant court et UNIQUE par nœud (ex. fichier_a, fichier_b ; jamais le nom du rôle). role : un "
        "rôle ci-dessus ; ses étapes n'utilisent QUE ses outils.\n"
        "- security_level ≥ niveau [Lx] de chaque outil du nœud.\n"
        "- Un nœud qui touche le bureau (clic, clavier, fenêtre, application) commence par screenshot ou ui_snapshot.\n"
        "- Un nœud qui modifie quelque chose (niveau L2) a au moins un critère vérifiable (ex. file_exists avec le chemin écrit).\n"
        "- Tâches indépendantes = aucun edge entre elles (exécution en parallèle). Edge {from, to} : to dépend de from.\n"
        "- Irréalisable avec ces rôles et outils : nodes et edges vides, reason explique pourquoi.\n"
        "- understanding : l'objectif reformulé en une phrase, EN FRANÇAIS.\n"
        "Réponds UNIQUEMENT par l'objet JSON {understanding, nodes, edges, reason}."
    )
    return system, dag_schema(tools, roles, max_level)
