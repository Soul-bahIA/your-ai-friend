"""Moteur de raisonnement — Comprendre → Planifier → (Exécuter) → Observer → Corriger.

  - plan_goal          : objectif en langage naturel → plan d'étapes exécutables
  - evaluate_execution : rapport d'exécution → verdict (success/retry/abort) + correction ;
                         verdict "not_evaluable" SANS appel LLM pour un run simulé
                         (dry-run), un plan vide, une tâche annulée ou 0 étape exécutée.

Les étapes sont contraintes aux skills réellement installés sur l'agent. On n'utilise
PAS les sorties structurées ici (le schéma multi-champs dépasse leur limite de
complexité) : on décrit la forme JSON dans le prompt, puis on parse et on filtre en Python.
"""
from __future__ import annotations

import json
import re

from .llm import text_generate_json, vision_generate_json
from .parsing import parse_bool
from .tool_catalog import load_catalog, path_params, tool_names

# --- Catalogue d'outils (LOT 2) ----------------------------------------------------
# Les types d'étapes et leurs champs viennent du catalogue GÉNÉRÉ depuis les manifestes
# de l'agent (app/generated/tool_catalog.json ← shared/tools/catalog.json ←
# agent/skills/manifests.py) : plus aucune liste tenue à la main ici.
_TYPE_LABELS = {"string": "texte", "integer": "entier", "number": "nombre", "boolean": "booléen", "array": "liste"}
_ITEM_LABELS = {"string": "textes", "integer": "entiers", "number": "nombres", "boolean": "booléens"}


def _num(value) -> str:
    return str(int(value)) if isinstance(value, (int, float)) and float(value).is_integer() else str(value)


def _param_kind(p: dict) -> str:
    types = p["type"] if isinstance(p["type"], list) else [p["type"]]
    if p.get("is_path"):
        return "liste de chemins absolus" if types == ["array"] else "chemin absolu"
    labels = []
    for t in types:
        item = (p.get("items") or {}).get("type")
        labels.append(f"liste de {_ITEM_LABELS.get(item, item)}" if t == "array" and item else _TYPE_LABELS.get(t, t))
    return " ou ".join(labels)


def _param_line(p: dict, required: bool) -> str:
    details = []
    if p.get("enum"):
        details.append("∈ " + "|".join(p["enum"]))
    lo, hi = p.get("min"), p.get("max")
    if lo is not None and hi is not None:
        details.append(f"de {_num(lo)} à {_num(hi)}" + (", valeur hors bornes ramenée" if p.get("clamped") else ""))
    elif lo is not None:
        details.append(f"≥ {_num(lo)}")
    elif hi is not None:
        details.append(f"≤ {_num(hi)}")
    if p.get("extensions"):
        details.append("fichier " + " ou ".join(p["extensions"]))
    if p.get("max_length"):
        details.append(f"≤ {p['max_length']} car.")
    if p.get("max_items"):
        details.append(f"{p['max_items']} éléments max")
    if "default" in p:
        details.append("défaut " + json.dumps(p["default"], ensure_ascii=False))
    kind = ", ".join([_param_kind(p), *details])
    return f"    · {p['name']}{'*' if required else ''} ({kind}) : {p['description']}"


def _tool_block(tool: dict, examples: bool) -> list[str]:
    level = tool["security_level"]
    esc = tool.get("escalation")
    if esc:
        level += f" ; {esc['level']} si {esc['when']}"
    lines = [f"- {tool['name']} [{level}] : {tool['description']}"]
    # Groupes « au moins l'un de » : le premier paramètre courant est présenté comme obligatoire.
    starred = set()
    for group in tool.get("required_any", []):
        current = [g for g in group if not any(p["name"] == g and p["deprecated"] for p in tool["params"])]
        if current:
            starred.add(current[0])
        if len(current) > 1:
            lines.append(f"    · au moins l'un de : {', '.join(current)}")
    shown = [p for p in tool["params"] if not p["deprecated"]]
    if not shown:
        lines.append("    · aucun champ")
    for p in shown:
        lines.append(_param_line(p, p["required"] or p["name"] in starred))
    if examples and tool.get("examples"):
        ex = tool["examples"][0]
        ordered = {"type": ex.get("type"), **{k: v for k, v in ex.items() if k != "type"}}
        lines.append("    Ex. : " + json.dumps(ordered, ensure_ascii=False))
    return lines


def build_skills_catalog(catalog: dict, examples: bool = True) -> str:
    """Section « skills disponibles » des prompts, construite depuis le catalogue :
    noms canoniques (jamais les alias), champs (* = obligatoire, types, bornes, enum),
    niveaux de sécurité L0–L3, puis les contraintes communes."""
    levels = catalog.get("security_levels", {})
    out = [
        f"SKILLS DISPONIBLES — les seuls types d'étapes autorisés (catalogue d'outils "
        f"v{catalog.get('catalog_version', '?')}, généré depuis les manifestes de l'agent).",
        "Chaque outil : son nom, [son niveau de sécurité], son rôle, puis un champ par ligne (* = obligatoire).",
        "Niveaux : " + " ; ".join(f"{k} = {v}" for k, v in sorted(levels.items())) + ".",
        f"Dans les exemples, « {catalog.get('workspace_placeholder', '')} » désigne l'un des DOSSIERS "
        "AUTORISÉS du contexte.",
    ]
    tools = list(catalog["tools"])
    categories = list(catalog.get("categories", []))
    known = {c["id"] for c in categories}
    orphans = [t for t in tools if t["category"] not in known]
    if orphans:
        categories.append({"id": None, "label": "Autres", "planner_note": ""})
    for cat in categories:
        members = [t for t in tools if t["category"] == cat["id"]] if cat["id"] is not None else orphans
        if not members:
            continue
        note = f" — {cat['planner_note']}" if cat.get("planner_note") else ""
        out.append("")
        out.append(f"{cat['label']}{note} :")
        for tool in members:
            out.extend(_tool_block(tool, examples))
    paths = ", ".join(path_params(catalog))
    out += [
        "",
        "CONTRAINTES :",
        "- Utilise UNIQUEMENT ces types, sous ces noms exacts. Pas d'opérateurs shell (&&, |, ;) dans args.",
        "- Chaque étape a un champ note : courte explication de son but.",
        f"- Chemins : si le contexte fournit des DOSSIERS AUTORISÉS, chaque chemin ({paths}) doit être un "
        "chemin ABSOLU strictement à l'intérieur de l'un d'eux — recopie leur orthographe EXACTE, n'invente "
        "JAMAIS un autre dossier (pas de C:\\Users\\Public, pas de %USERNAME%, pas de nom d'utilisateur deviné).",
    ]
    return "\n".join(out)


_CATALOG = load_catalog()

# Types d'étapes acceptés dans un plan : noms canoniques du catalogue (ceux du prompt).
VALID_STEP_TYPES = tool_names(_CATALOG)

SKILLS_CATALOG = build_skills_catalog(_CATALOG)

_PLAN_SHAPE = (
    "Reponds UNIQUEMENT avec un objet JSON (sans texte autour, sans balises markdown) "
    'de la forme : {"understanding": "<reformulation en une phrase>", '
    '"feasible": true, "reason": "<si infaisable, pourquoi>", '
    '"steps": [{"type": "<type autorise>", "note": "<but>", "app": "..."}]}'
)

_EVAL_SHAPE = (
    "Reponds UNIQUEMENT avec un objet JSON (sans texte autour, sans balises markdown) "
    'de la forme : {"verdict": "success", "reason": "<explication>", '
    '"corrective_steps": [{"type": "...", "note": "..."}]}'
)

_PLAN_SYSTEM = (
    "Tu es le planificateur de SoulBah AI, un agent qui controle l'ordinateur de "
    "l'utilisateur (Windows) via un petit ensemble de skills.\n\n"
    + SKILLS_CATALOG
    + "\n\nTa mission : transformer l'objectif en un plan d'etapes minimal et fiable "
    "(8 etapes max). Termine par une etape screenshot si le resultat est visible a "
    "l'ecran (texte tape, fenetre ouverte...) : cela permet a l'evaluateur de verifier "
    "visuellement le resultat.\n\n"
    "REGLE IMPORTANTE — mauvais outil : si l'objectif est de GENERER DU CONTENU "
    "(creer/rediger une FORMATION, un cours, une APPLICATION, un article, un document...), "
    "ce n'est PAS le role de cet agent. Reponds feasible=false, steps vide, et mets dans "
    "reason exactement : \"Pour creer une formation, utilisez la page Formations. Pour une "
    "application, la page Applications. Cet agent sert a piloter votre ordinateur (ouvrir "
    "des logiciels, taper, cliquer, fichiers, commandes).\"\n"
    "Mets aussi feasible a false (avec reason, steps vide) si l'objectif est impossible "
    "avec ces skills, dangereux, ou trop vague.\n\n"
    + _PLAN_SHAPE
)

_EVAL_SYSTEM = (
    "Tu es l'evaluateur de SoulBah AI. On te donne un objectif, le plan execute et le "
    "rapport d'execution (une entree par etape : ok + detail).\n\n"
    + SKILLS_CATALOG
    + "\n\nVerdicts :\n"
    "- success : objectif atteint (toutes les etapes utiles ont reussi).\n"
    "- retry   : une etape a echoue mais c'est corrigeable — fournis corrective_steps "
    "(nouveau plan complet corrigeant la cause : autre nom d'app, delai plus long, etc.).\n"
    "- abort   : echec non corrigeable (permission refusee, dependance manquante) — "
    "corrective_steps vide.\n"
    "Une etape SIMULEE (champ simulated=true, detail « [simulation] … » ou, ancien "
    "format, « [dry-run] … ») ne prouve rien : ce n'est jamais une "
    "preuve de succes. Les textes saisis sont masques (« [texte masque : N car.] ») : "
    "verifie le resultat sur les captures, pas sur le texte saisi.\n\n"
    + _EVAL_SHAPE
)


def _sanitize_steps(steps) -> list:
    """Ne garde que les étapes dont le type est un skill réel de l'agent."""
    out = []
    if isinstance(steps, list):
        for s in steps:
            if isinstance(s, dict) and s.get("type") in VALID_STEP_TYPES:
                out.append(s)
    return out


async def plan_goal(goal: str, context: str | None = None) -> dict:
    user = f"OBJECTIF DE L'UTILISATEUR :\n{goal}"
    if context:
        user += f"\n\nCONTEXTE :\n{context}"
    plan = await text_generate_json(
        _PLAN_SYSTEM, [{"role": "user", "content": user}], max_tokens=4096, task="automation"
    )
    plan.setdefault("understanding", goal)
    if not isinstance(plan.get("reason"), str):
        plan["reason"] = str(plan.get("reason") or "")
    plan["steps"] = _sanitize_steps(plan.get("steps"))
    # bool("false") vaut True en Python (T43) : parsing strict, absent = True,
    # valeur inconnue (null, "peut-être", liste…) = False (prudence).
    plan["feasible"] = parse_bool(plan.get("feasible", True), default=False) and len(plan["steps"]) > 0
    return plan


_MAX_FIELD_CHARS = 4_000      # par chaîne du rapport (sorties de commandes, fichiers lus…)
_MAX_SECTION_CHARS = 40_000   # par bloc JSON injecté dans le prompt
_MAX_DEPTH = 12


def _is_binary_key(key) -> bool:
    k = str(key).lower()
    return k == "image_b64" or k.endswith("_b64") or k == "base64"


# Contrat LOT 1 §12 : les textes saisis (type_text/phone_type `text`, write_file
# `content`, contenus lus…) ne partent JAMAIS en clair vers le LLM évaluateur, quel
# que soit leur type (un code PIN numérique ou une liste ne fait pas exception).
_MASKED_KEYS = {"text", "content"}
# Libellé EXACT posé par l'agent / node (même expression que node redact.ts
# ALREADY_MASKED) : une chaîne qui ne fait que COMMENCER par ce libellé est masquée.
_ALREADY_MASKED = re.compile(r"\[texte masqué : [0-9]+ car\.\]")
# Marqueurs de détail d'une étape simulée : agent LOT 1 « [simulation] … », ancien
# agent « [dry-run] … ».
_SIMULATED_MARKS = ("[simulation]", "[dry-run]")


def _mask_text(value) -> str:
    """Libellé « [texte masqué : N car.] » pour toute valeur non nulle (comme l'agent,
    agent/skills/base.py mask_text) ; un libellé déjà exact est conservé tel quel."""
    if isinstance(value, str):
        if _ALREADY_MASKED.fullmatch(value):
            return value
        n = len(value)
    elif isinstance(value, (list, tuple)):
        n = len("".join(str(v) for v in value))
    else:
        n = len(str(value))
    return f"[texte masqué : {n} car.]"


def _scrub(value, depth: int = 0, mask: bool = False):
    """Nettoie un rapport avant de l'injecter dans le prompt (défense en profondeur) :
    retire les captures base64 (clés image_b64/*_b64 — les images passent par le canal
    vision, pas par le texte), tronque les chaînes trop longues et, si `mask`, remplace
    les champs text/content par « [texte masqué : N car.] »."""
    if depth > _MAX_DEPTH:
        return "[…]"
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            if _is_binary_key(k):
                continue
            if mask and str(k).lower() in _MASKED_KEYS and v is not None:
                out[k] = _mask_text(v)
            else:
                out[k] = _scrub(v, depth + 1, mask)
        return out
    if isinstance(value, list):
        return [_scrub(v, depth + 1, mask) for v in value]
    if isinstance(value, str) and len(value) > _MAX_FIELD_CHARS:
        return value[:_MAX_FIELD_CHARS] + f"… [tronqué, {len(value)} caractères]"
    return value


def _dump_for_prompt(value, mask: bool = False) -> str:
    text = json.dumps(_scrub(value, mask=mask), ensure_ascii=False)
    if len(text) > _MAX_SECTION_CHARS:
        text = text[:_MAX_SECTION_CHARS] + " … [tronqué]"
    return text


def _executed_entries(result: dict) -> list | None:
    """Entrées d'exécution du rapport de l'agent (`steps`, ou `results` en ancien
    format) ; None si le rapport ne le dit pas."""
    for key in ("steps", "results"):
        entries = result.get(key)
        if isinstance(entries, list):
            return entries
    return None


def _is_simulated_entry(entry) -> bool:
    if not isinstance(entry, dict):
        return False
    if parse_bool(entry.get("simulated"), False):
        return True
    detail = entry.get("detail")
    return isinstance(detail, str) and detail.lstrip().startswith(_SIMULATED_MARKS)


def not_evaluable_reason(steps, result) -> str | None:
    """Raison pour laquelle une exécution n'est PAS évaluable (T10), ou None.

    Un run simulé (dry-run), un plan vide, une tâche annulée ou un rapport sans
    aucune étape exécutée ne prouvent rien : jamais « success », jamais de mémoire.
    Simulé = `result.simulated`, OU une entrée `simulated` vraie, OU un détail
    « [simulation] … » (agent LOT 1) / « [dry-run] … » (ancien agent).
    """
    result = result if isinstance(result, dict) else {}
    if parse_bool(result.get("simulated"), False):
        return "Exécution simulée (dry-run) : aucune preuve d'exécution réelle."
    if parse_bool(result.get("empty_plan"), False) or not steps:
        return "Plan vide : aucune étape n'a été planifiée."
    if parse_bool(result.get("cancelled"), False) or result.get("status") == "cancelled":
        return "Tâche annulée : une tâche annulée n'est jamais évaluée."
    entries = _executed_entries(result)
    if entries is not None:
        if not entries:
            return "Aucune étape exécutée."
        if any(_is_simulated_entry(e) for e in entries):
            return "Exécution simulée (dry-run) : aucune preuve d'exécution réelle."
    return None


async def evaluate_execution(
    goal: str, steps: list, result: dict, screenshots: list[str] | None = None
) -> dict:
    reason = not_evaluable_reason(steps, result)
    if reason:
        # Aucun appel LLM (ni coût, ni verdict inventé) : node ne doit ni marquer la
        # tâche réussie, ni créer de correction, ni mémoriser ce résultat.
        return {"verdict": "not_evaluable", "reason": reason, "corrective_steps": [], "evaluable": False}

    user = (
        f"OBJECTIF :\n{goal}\n\n"
        f"PLAN EXECUTE :\n{_dump_for_prompt(steps, mask=True)}\n\n"
        f"RAPPORT D'EXECUTION :\n{_dump_for_prompt(result, mask=True)}"
    )

    if screenshots:
        user += (
            "\n\nDes captures d'ecran REELLES ont ete prises pendant l'execution "
            "(jointes ci-dessous, dans l'ordre chronologique). Regarde-les attentivement : "
            "verifie que ce qui est affiche correspond a l'objectif (texte tape, application "
            "ouverte, contenu attendu) et detecte toute erreur visible (message d'erreur, "
            "popup bloquante, fenetre inattendue, application qui a planté). Base ton verdict "
            "sur ce que tu VOIS, pas seulement sur le rapport textuel."
        )
        ev = await vision_generate_json(_EVAL_SYSTEM, user, screenshots, max_tokens=4096, task="vision")
    else:
        ev = await text_generate_json(
            _EVAL_SYSTEM, [{"role": "user", "content": user}], max_tokens=4096, task="evaluation"
        )

    if ev.get("verdict") not in ("success", "retry", "abort"):
        ev["verdict"] = "abort"
    if not isinstance(ev.get("reason"), str):
        ev["reason"] = str(ev.get("reason") or "")
    ev["evaluable"] = True
    ev["corrective_steps"] = _sanitize_steps(ev.get("corrective_steps"))
    return ev


# ---------------------------------------------------------------------------
# Auto-amélioration — analyse d'un historique d'exécutions pour en tirer des
# bonnes pratiques réutilisables (étapes lentes, erreurs récurrentes).
# ---------------------------------------------------------------------------
_IMPROVE_SHAPE = (
    "Reponds UNIQUEMENT avec un objet JSON (sans texte autour) de la forme : "
    '{"slow_steps": ["..."], "recurring_errors": ["..."], "suggestions": ["..."]}'
)

_IMPROVE_SYSTEM = (
    "Tu analyses l'historique d'execution de l'agent SoulBah AI pour l'ameliorer.\n\n"
    + SKILLS_CATALOG
    + "\n\nA partir du resume fourni (taches recentes : objectif, verdict, etapes avec "
    "duree et succes/echec), identifie :\n"
    "- slow_steps : les types d'etapes recurremment lentes (avec le contexte, ex. "
    "\"open_app est lent pour les gros logiciels, prevoir un wait de 4-5s\").\n"
    "- recurring_errors : les erreurs qui reviennent plusieurs fois (motif commun).\n"
    "- suggestions : des recommandations concretes et actionnables pour les futurs plans "
    "(delais a ajuster, types d'etapes a eviter, precisions a demander a l'utilisateur).\n"
    "Si l'historique est trop court ou ne montre rien de notable, renvoie des listes vides.\n\n"
    + _IMPROVE_SHAPE
)


async def analyze_performance(summary: str) -> dict:
    report = await text_generate_json(
        _IMPROVE_SYSTEM, [{"role": "user", "content": summary}], max_tokens=2048, task="optimization"
    )
    report.setdefault("slow_steps", [])
    report.setdefault("recurring_errors", [])
    report.setdefault("suggestions", [])
    for key in ("slow_steps", "recurring_errors", "suggestions"):
        if not isinstance(report[key], list):
            report[key] = []
    return report
