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

from .llm import text_generate_json, vision_generate_json
from .parsing import parse_bool

# Types d'étapes reconnus par l'agent (doit refléter agent/skills/).
VALID_STEP_TYPES = {
    "open_app", "type_text", "hotkey", "wait", "screenshot",
    "click", "double_click", "right_click", "move_mouse", "drag", "scroll",
    "window",
    "move_file", "write_file", "read_file", "list_dir", "make_dir",
    "run_command",
    "record_screen", "start_recording_bg", "stop_recording_bg", "edit_video", "resolve_montage",
    "phone_list_devices", "phone_tap", "phone_swipe", "phone_type", "phone_key",
    "phone_open_app", "phone_screenshot",
}

SKILLS_CATALOG = """SKILLS DISPONIBLES (les seuls types d'étapes autorisés) :
Applications & saisie :
- open_app    : ouvre une application installée. Champ : app (ex. "notepad", "chrome", "code").
- type_text   : tape du texte au clavier dans la fenêtre active. Champ : text.
- hotkey      : raccourci clavier. Champ : keys (liste, ex. ["ctrl","s"], ["enter"], ["alt","tab"]).
- wait        : attend N secondes (max 300). Champ : seconds. À placer après open_app (2-3 s).
- screenshot  : capture l'écran. Champ optionnel : path (.png).

Souris (coordonnées en pixels) :
- click / double_click / right_click : clic. Champs optionnels : x, y (sinon position actuelle).
- move_mouse  : déplace le curseur. Champs : x, y.
- drag        : glisse jusqu'à x, y.
- scroll      : molette. Champ : dy (positif=haut, négatif=bas).

Fenêtres :
- window      : gère une fenêtre. Champs : action ("focus"|"minimize"|"maximize"|"close"), window_title.

Fichiers (chemins absolus, restreints à la whitelist utilisateur) :
- move_file   : déplace un fichier. Champs : src, dest.
- write_file  : écrit un fichier. Champs : path, content.
- read_file   : lit un fichier. Champ : path.
- list_dir    : liste un dossier. Champ : path.
- make_dir    : crée un dossier. Champ : path.

Commandes de développement (Git, compile, tests — programmes en allowlist) :
- run_command : exécute un programme SANS shell. Champs : program (git|npm|node|python|pytest|cargo|dotnet|go|tsc|make…), args (liste), cwd (dossier whitelisté), timeout (optionnel).
                Exemples : {"program":"git","args":["init"]} ; {"program":"npm","args":["test"]}.

Téléphone Android (nécessite adb + un appareil connecté — commence TOUJOURS par phone_list_devices) :
- phone_list_devices : liste les téléphones connectés. Aucun champ.
- phone_tap          : tape à l'écran. Champs : x, y.
- phone_swipe        : glisse. Champs : x1, y1, x2, y2, duration_ms (optionnel).
- phone_type         : tape du texte. Champ : text.
- phone_key          : touche système. Champ : keycode (ex. "KEYCODE_BACK", "KEYCODE_HOME", "KEYCODE_ENTER").
- phone_open_app     : lance une app par son package. Champ : package (ex. "com.android.chrome").
- phone_screenshot   : capture l'écran du téléphone. Champ : path (.png).
                       iOS n'est PAS supporté par ces skills.

Démonstrations vidéo (chemins whitelistés, durée bornée) :
- record_screen  : enregistre l'écran pendant N secondes (max 120). Champs : path (.mp4, obligatoire), duration (secondes), fps (optionnel, def. 10).
- start_recording_bg / stop_recording_bg : enregistrement en ARRIÈRE-PLAN pour filmer une démo PENDANT qu'on agit. Démarre (path .mp4), puis fais les actions (open_app, click, type_text…), puis arrête (même path). À privilégier pour les démonstrations réelles.
- edit_video     : montage SIMPLE et rapide (concaténation + titre) sans logiciel externe. Champs : clips (liste .mp4), title (optionnel), output (.mp4).
- resolve_montage: montage PROFESSIONNEL via DaVinci Resolve installe sur le poste (import medias, timeline, export MP4 local). Champs : clips (liste d'images/videos dans l'ordre), audio (narration .mp3, optionnel), output (.mp4), project (nom optionnel).
                   A privilegier quand l'utilisateur veut un rendu professionnel. Necessite Resolve installe et OUVERT.

CONTRAINTES :
- Utilise UNIQUEMENT ces types. Pas d'opérateurs shell (&&, |, ;) dans args.
- Chaque étape a un champ note : courte explication de son but.
- Chemins : si le contexte fournit des DOSSIERS AUTORISÉS, chaque chemin (path, src,
  dest, cwd, output, clips, audio) doit être un chemin ABSOLU strictement à l'intérieur
  de l'un d'eux — recopie leur orthographe EXACTE, n'invente JAMAIS un autre dossier
  (pas de C:\\Users\\Public, pas de %USERNAME%, pas de nom d'utilisateur deviné)."""

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
    "Une etape SIMULEE (detail « [dry-run] ») ne prouve rien : ce n'est jamais une "
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
# `content`, contenus lus…) ne partent JAMAIS en clair vers le LLM évaluateur.
_MASKED_KEYS = {"text", "content"}
_MASK_PREFIX = "[texte masqué"
_DRY_RUN_MARK = "[dry-run]"


def _mask_text(value: str) -> str:
    if value.startswith(_MASK_PREFIX):
        return value  # déjà masqué par l'agent
    return f"[texte masqué : {len(value)} car.]"


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
            if mask and str(k).lower() in _MASKED_KEYS and isinstance(v, str):
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


def not_evaluable_reason(steps, result) -> str | None:
    """Raison pour laquelle une exécution n'est PAS évaluable (T10), ou None.

    Un run simulé (dry-run), un plan vide, une tâche annulée ou un rapport sans
    aucune étape exécutée ne prouvent rien : jamais « success », jamais de mémoire.
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
        details = [str(e.get("detail", "")) for e in entries if isinstance(e, dict)]
        if any(d.lstrip().startswith(_DRY_RUN_MARK) for d in details):
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
