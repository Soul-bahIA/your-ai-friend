"""Manifestes des outils de l'agent — contrat d'outils UNIQUE (LOT 2).

Un manifeste par type d'étape canonique (les synonymes historiques sont ses `aliases`).
C'est la SOURCE DE VÉRITÉ des types d'étapes et de leurs paramètres :

  - scripts/gen_catalog.py en génère shared/tools/catalog.json (trié, stable) et ses
    copies backend/node-api/src/generated/ et backend/python-ia/app/generated/ ;
    `--check` échoue (code 1) à la moindre dérive ;
  - node-api (src/lib/agentSteps.ts) : types autorisés, compactStep, champs
    obligatoires, chemins contrôlés, étapes à confirmer ;
  - python-ia (app/reasoning.py) : prompt du planificateur (noms, champs, niveaux) ;
  - agent : le registre des skills est confronté aux manifestes au démarrage
    (skills.manifest_errors) et dans les tests ; le gate en dérive les champs de
    chemin et les étapes confirmées sur demande du serveur.

Ce module n'importe QUE la bibliothèque standard (aucun skill, aucune lib graphique) :
scripts/gen_catalog.py le charge directement par son chemin.

Ajouter un outil : docs/CATALOGUE_OUTILS.md.
"""
from __future__ import annotations

import re
from typing import Any

CATALOG_VERSION = "1.0.0"
GENERATED_FROM = "agent/skills/manifests.py"

# Champs descriptifs acceptés sur toute étape (ignorés par l'agent, affichés à l'utilisateur).
COMMON_FIELDS = ("description", "note", "type")

# Préfixe des chemins dans les exemples : le planificateur le remplace par l'un des
# DOSSIERS AUTORISÉS fournis en contexte (jamais un dossier deviné).
WORKSPACE_PLACEHOLDER = "<dossier autorisé>"

# Audit V2 §9.10.
SECURITY_LEVELS = {
    "L0": "lecture sans effet (fichiers du workspace, appareils connectés, attente) — automatique",
    "L1": "réversible et confiné au workspace (écriture, captures, enregistrements, montage simple) — "
          "automatique après approbation de la session",
    "L2": "effet réel (souris, clavier, fenêtres, applications, téléphone, commandes, logiciels tiers) — "
          "grant de session ou approbation par action avec le contenu complet",
    "L3": "irréversible (suppression, scripts d'installation, secrets, promotion) — approbation par action, "
          "payload complet, jamais en lot",
}

# Catégories du gate de permissions (Skill.category). L'ordre est celui des sections du
# prompt du planificateur.
CATEGORIES: tuple[dict[str, str], ...] = (
    {"id": "app_launch", "label": "Applications",
     "planner_note": "uniquement les applications de l'allowlist du PC (jamais de shell ni d'hôte de script)"},
    {"id": "keyboard", "label": "Clavier",
     "planner_note": "agit sur la fenêtre au premier plan : précise window_title quand c'est possible"},
    {"id": "generic", "label": "Attente", "planner_note": "interruptible par un arrêt"},
    {"id": "screen", "label": "Écran",
     "planner_note": "la capture est jointe au rapport : l'évaluateur VOIT le résultat"},
    {"id": "mouse", "label": "Souris", "planner_note": "coordonnées en pixels de l'écran"},
    {"id": "window", "label": "Fenêtres",
     "planner_note": "plusieurs fenêtres correspondantes = refus : donne un titre précis"},
    {"id": "filesystem", "label": "Fichiers",
     "planner_note": "chemins absolus, restreints aux dossiers autorisés du PC"},
    {"id": "shell", "label": "Commandes de développement",
     "planner_note": "programmes en allowlist, exécutés SANS shell, toujours confirmés sur le PC"},
    {"id": "phone", "label": "Téléphone Android",
     "planner_note": "adb + appareil connecté ; commence TOUJOURS par phone_list_devices ; iOS non supporté"},
    {"id": "video", "label": "Démonstrations vidéo", "planner_note": "chemins dans les dossiers autorisés"},
    {"id": "git", "label": "Dépôts git (worktrees)",
     "planner_note": "une worktree et une branche soulbah/<session>/<tâche> par tâche ; fusion vers "
                     "soulbah/<session>/integration seulement, tests verts exigés ; suppression et push = L3"},
    {"id": "web", "label": "Web (lecture)",
     "planner_note": "lecture seule, http/https publics ; cite l'URL lue (preuve http_status + sha256)"},
)

PARAM_TYPES = ("string", "integer", "number", "boolean", "array")
CONFIDENCES = ("high", "medium", "low", "none")
# Types de preuves (audit V2 §9.8) produits par les outils.
EVIDENCE_KINDS = (
    "command_output", "device_list", "dir_listing", "exit_code", "file_content", "file_path",
    "process", "screenshot", "self_report", "video_probe", "video_stats", "window_title",
    # LOT 12 (mêmes noms que shared/schemas/evidence.schema.json)
    "http_status", "sha256", "test_report", "ui_state",
)

_IDENT_RE = re.compile(r"^[a-z][a-z0-9_]{0,39}$")
_SEMVER_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
_LEVELS = ("L0", "L1", "L2", "L3")

# Branches que l'agent peut créer, valider, fusionner, supprimer ou pousser (LOT 12).
GIT_BRANCH_PATTERN = r"^soulbah/[a-z0-9][a-z0-9_-]{0,63}/[a-z0-9][a-z0-9_.-]{0,63}$"
GIT_INTEGRATION_PATTERN = r"^soulbah/[a-z0-9][a-z0-9_-]{0,63}/integration$"


# --- Constructeurs (forme normalisée, identique à celle du catalogue JSON) ----------
def _param(
    name: str,
    type_: str | tuple[str, ...],
    description: str,
    *,
    required: bool = False,
    enum: tuple[str, ...] | None = None,
    minimum: float | None = None,
    maximum: float | None = None,
    clamped: bool = False,
    max_length: int | None = None,
    items: str | None = None,
    max_items: int | None = None,
    default: Any = None,
    extensions: tuple[str, ...] | None = None,
    pattern: str | None = None,
    is_path: bool = False,
    is_secret_text: bool = False,
    deprecated: bool = False,
) -> dict[str, Any]:
    """Paramètre d'une étape. `clamped` : une valeur hors [min, max] est RAMENÉE dans
    les bornes par l'agent (sinon elle est refusée par validate())."""
    p: dict[str, Any] = {
        "name": name,
        "type": list(type_) if isinstance(type_, tuple) else type_,
        "description": description,
        "required": required,
        "is_path": is_path,
        "is_secret_text": is_secret_text,
        "deprecated": deprecated,
    }
    if enum is not None:
        p["enum"] = list(enum)
    if minimum is not None:
        p["min"] = minimum
    if maximum is not None:
        p["max"] = maximum
    if clamped:
        p["clamped"] = True
    if max_length is not None:
        p["max_length"] = max_length
    if items is not None:
        p["items"] = {"type": items}
    if max_items is not None:
        p["max_items"] = max_items
    if default is not None:
        p["default"] = default
    if extensions is not None:
        p["extensions"] = list(extensions)
    if pattern is not None:
        p["pattern"] = pattern
    return p


def _ev(kind: str, confidence: str, description: str, field: str | None = None) -> dict[str, Any]:
    e: dict[str, Any] = {"kind": kind, "confidence": confidence, "description": description}
    if field is not None:
        e["field"] = field
    return e


def _tool(
    name: str,
    *,
    category: str,
    level: str,
    description: str,
    idempotent: bool,
    examples: tuple[dict[str, Any], ...],
    params: tuple[dict[str, Any], ...] = (),
    aliases: tuple[str, ...] = (),
    required_any: tuple[tuple[str, ...], ...] = (),
    requires_desktop_input: bool = False,
    requires_confirmation: bool = False,
    timeout_s: float | None = None,
    evidence: tuple[dict[str, Any], ...] = (),
    known_errors: tuple[str, ...] = (),
    escalation: dict[str, str] | None = None,
    version: str = "1.0.0",
) -> dict[str, Any]:
    """Manifeste d'un type d'étape.

    - `requires_confirmation` : action à effet réel ; le serveur pose
      payload.requires_confirmation et l'agent la confirme TOUJOURS sur le PC.
    - `requires_desktop_input` : prend le contrôle du clavier, de la souris ou de la
      fenêtre au premier plan (ressource exclusive `desktop.input`).
    - `idempotent` : peut être rejouée sans danger après un crash (audit §9.9).
    - `timeout_s` : délai propre de l'outil ; None = délai global de l'agent
      (SOULBAH_STEP_TIMEOUT, 900 s par défaut).
    """
    t: dict[str, Any] = {
        "name": name,
        "aliases": sorted(aliases),
        "version": version,
        "description": description,
        "category": category,
        "security_level": level,
        "requires_desktop_input": requires_desktop_input,
        "requires_confirmation": requires_confirmation,
        "idempotent": idempotent,
        "timeout_s": timeout_s,
        "params": list(params),
        "required_any": [list(g) for g in required_any],
        "evidence": list(evidence),
        "examples": list(examples),
        "known_errors": list(known_errors),
    }
    if escalation is not None:
        t["escalation"] = dict(escalation)
    return t


_W = WORKSPACE_PLACEHOLDER

# Paramètres partagés
_X = _param("x", "number", "Abscisse en pixels (avec y ; sans x/y : position actuelle du curseur).",
            minimum=-100000, maximum=100000)
_Y = _param("y", "number", "Ordonnée en pixels (avec x).", minimum=-100000, maximum=100000)
_X_REQ = _param("x", "number", "Abscisse cible en pixels.", required=True, minimum=-100000, maximum=100000)
_Y_REQ = _param("y", "number", "Ordonnée cible en pixels.", required=True, minimum=-100000, maximum=100000)
_BUTTON = _param("button", "string", "Bouton de la souris.", enum=("left", "right", "middle"), default="left")
_CLICKS = _param("clicks", "integer", "Nombre de clics.", minimum=1, maximum=3, default=1)
_DEVICE = _param("device_id", "string", "Identifiant adb du téléphone (facultatif si un seul appareil est connecté).",
                 max_length=64, pattern=r"^[A-Za-z0-9._:-]{1,64}$")
_FS_PATH = _param("path", "string", "Chemin absolu dans un dossier autorisé.", required=True, is_path=True)
_VIDEO_EXT = (".mp4", ".avi")
_VIDEO_PATH = _param("path", "string", "Fichier vidéo de sortie (.mp4 ou .avi) dans un dossier autorisé existant.",
                     required=True, is_path=True, extensions=_VIDEO_EXT)
_FPS = _param("fps", "integer", "Images par seconde.", minimum=1, maximum=30,
              clamped=True, default=10)
_MONITOR = _param("monitor", "integer", "Écran filmé : 1 = écran principal, 0 = tous les écrans.",
                  minimum=0, maximum=16, default=1)
_NO_EVIDENCE = _ev("self_report", "none", "Aucune preuve : seul le compte rendu de l'agent (vérifier par une capture).")
_ADB_EXIT = _ev("exit_code", "low", "Code de retour d'adb : la commande est partie, son effet n'est pas vérifié.")
_ADB_MISSING = "adb introuvable : installer Android Platform Tools et l'ajouter au PATH"
_INPUT_LOCK = "contrôle d'entrée non pré-autorisé : confirmation exigée sur le PC"

MANIFESTS: tuple[dict[str, Any], ...] = (
    # --- Applications ------------------------------------------------------------
    _tool(
        "open_app",
        aliases=("open_software", "launch"),
        category="app_launch", level="L2", requires_desktop_input=True, idempotent=False,
        description="Ouvre une application installée et autorisée sur le PC. Ajoute ensuite un wait de 2-3 s "
                    "(4-5 s pour un gros logiciel) avant d'agir dans sa fenêtre.",
        params=(
            _param("app", "string", "Nom simple de l'application, jamais un chemin (ex. « notepad », « chrome », "
                                    "« code », « explorer », « calc »).", max_length=64),
            _param("software", "string", "Ancien synonyme de app.", max_length=64, deprecated=True),
            _param("name", "string", "Ancien synonyme de app.", max_length=64, deprecated=True),
        ),
        required_any=(("app", "software", "name"),),
        evidence=(_ev("process", "low", "Exécutable lancé (ne prouve pas que la fenêtre est prête).", "exe"),),
        examples=({"type": "open_app", "app": "notepad"}, {"type": "open_app", "app": "chrome"}),
        known_errors=("application non autorisée : l'ajouter à SOULBAH_ALLOWED_APPS sur le PC",
                      "application interdite (shell ou hôte de script)",
                      "application introuvable sur ce poste", _INPUT_LOCK),
    ),
    # --- Clavier -----------------------------------------------------------------
    _tool(
        "type_text",
        aliases=("type", "keyboard"),
        category="keyboard", level="L2", requires_desktop_input=True, requires_confirmation=True, idempotent=False,
        description="Tape du texte dans la fenêtre au premier plan (collage par le presse-papier, restauré ensuite ; "
                    "fiable quel que soit le clavier). Le texte est masqué dans les journaux.",
        params=(
            _param("text", "string", "Texte à saisir.", required=True, max_length=20000, is_secret_text=True),
            _param("window_title", "string", "Titre (ou partie du titre) de la fenêtre attendue au premier plan.",
                   max_length=200),
            _param("method", "string", "clipboard (défaut), unicode (Windows, sans presse-papier) ou typewrite "
                                       "(ASCII, touche par touche).",
                   enum=("clipboard", "unicode", "typewrite"), default="clipboard"),
            _param("interval", "number", "Délai entre deux caractères en secondes (unicode, typewrite).",
                   minimum=0, maximum=1),
        ),
        evidence=(_ev("self_report", "none", "Nombre de caractères saisis ; le texte n'est jamais renvoyé."),),
        examples=({"type": "type_text", "text": "Bonjour !", "window_title": "Bloc-notes"},),
        known_errors=("fenêtre cible inconnue ou différente de window_title : confirmation exigée sur le PC",
                      "presse-papier indisponible",
                      "fenêtre protégée (lancée en administrateur) : saisie refusée"),
    ),
    _tool(
        "hotkey",
        aliases=("press", "key"),
        category="keyboard", level="L2", requires_desktop_input=True, requires_confirmation=True, idempotent=False,
        description="Envoie une touche ou un raccourci clavier (touches d'une liste fermée). Un raccourci qui ouvre un "
                    "terminal, la palette de commandes ou utilise la touche Windows reste confirmé sur le PC.",
        params=(
            _param("keys", ("array", "string"), "Touches : liste (ex. [\"ctrl\", \"s\"], [\"enter\"], "
                                                "[\"alt\", \"tab\"]) ou chaîne « ctrl+s ».",
                   required=True, items="string", max_items=5),
        ),
        evidence=(_NO_EVIDENCE,),
        examples=({"type": "hotkey", "keys": ["ctrl", "s"]}, {"type": "hotkey", "keys": ["enter"]}),
        known_errors=("touche inconnue", "trop de touches (5 au plus)", "touche répétée"),
    ),
    # --- Attente -----------------------------------------------------------------
    _tool(
        "wait",
        aliases=("sleep",),
        category="generic", level="L0", idempotent=True,
        description="Attend N secondes. À placer après open_app (2-3 s) ou avant une capture.",
        params=(
            _param("seconds", "number", "Durée en secondes.", minimum=0, maximum=300,
                   clamped=True, default=1),
        ),
        examples=({"type": "wait", "seconds": 3},),
        known_errors=("champ 'seconds' invalide", "attente interrompue (arrêt demandé)"),
    ),
    # --- Écran -------------------------------------------------------------------
    _tool(
        "screenshot",
        aliases=("capture",),
        category="screen", level="L1", idempotent=True,
        description="Capture l'écran entier. Termine un plan par une capture quand le résultat est visible à l'écran "
                    "(texte tapé, fenêtre ouverte…) : l'évaluateur vérifie sur l'image.",
        params=(
            _param("path", "string", "Fichier .png de destination ; sans path : fichier temporaire.", is_path=True,
                   extensions=(".png",)),
        ),
        evidence=(_ev("screenshot", "low", "Image de l'écran jointe au rapport (jugement visuel).", "image_b64"),
                  _ev("file_path", "medium", "Fichier .png enregistré.", "path")),
        examples=({"type": "screenshot"}, {"type": "screenshot", "path": f"{_W}/capture.png"}),
        known_errors=("la capture doit être un fichier .png", "dépendance 'mss' non installée"),
    ),
    # --- Souris ------------------------------------------------------------------
    _tool(
        "click",
        aliases=("mouse",),
        category="mouse", level="L2", requires_desktop_input=True, idempotent=False,
        description="Clic de souris en (x, y), ou à la position actuelle sans x/y.",
        params=(_X, _Y, _BUTTON, _CLICKS),
        evidence=(_NO_EVIDENCE,),
        examples=({"type": "click", "x": 640, "y": 360}, {"type": "click", "x": 100, "y": 200, "button": "left",
                                                           "clicks": 1}),
        known_errors=("champs 'x' et 'y' : les deux ou aucun", "coordonnées hors bornes", _INPUT_LOCK),
    ),
    _tool(
        "double_click",
        category="mouse", level="L2", requires_desktop_input=True, idempotent=False,
        description="Double-clic en (x, y), ou à la position actuelle sans x/y.",
        params=(_X, _Y, _BUTTON),
        evidence=(_NO_EVIDENCE,),
        examples=({"type": "double_click", "x": 200, "y": 150},),
        known_errors=("champs 'x' et 'y' : les deux ou aucun", _INPUT_LOCK),
    ),
    _tool(
        "right_click",
        category="mouse", level="L2", requires_desktop_input=True, idempotent=False,
        description="Clic droit en (x, y), ou à la position actuelle sans x/y.",
        params=(_X, _Y, _CLICKS),
        evidence=(_NO_EVIDENCE,),
        examples=({"type": "right_click", "x": 200, "y": 150},),
        known_errors=("champs 'x' et 'y' : les deux ou aucun", _INPUT_LOCK),
    ),
    _tool(
        "move_mouse",
        category="mouse", level="L2", requires_desktop_input=True, idempotent=True,
        description="Déplace le curseur en (x, y).",
        params=(_X_REQ, _Y_REQ),
        evidence=(_NO_EVIDENCE,),
        examples=({"type": "move_mouse", "x": 500, "y": 300},),
        known_errors=("move_mouse nécessite x et y", _INPUT_LOCK),
    ),
    _tool(
        "drag",
        category="mouse", level="L2", requires_desktop_input=True, idempotent=False,
        description="Glisse (bouton gauche maintenu) de la position actuelle jusqu'à (x, y).",
        params=(_X_REQ, _Y_REQ),
        evidence=(_NO_EVIDENCE,),
        examples=({"type": "drag", "x": 800, "y": 400},),
        known_errors=("drag nécessite x et y", _INPUT_LOCK),
    ),
    _tool(
        "scroll",
        category="mouse", level="L2", requires_desktop_input=True, idempotent=False,
        description="Molette de la souris à la position actuelle.",
        params=(_param("dy", "integer", "Crans de molette : positif = vers le haut, négatif = vers le bas.",
                       minimum=-10000, maximum=10000, default=0),),
        evidence=(_NO_EVIDENCE,),
        examples=({"type": "scroll", "dy": -5},),
        known_errors=("champ 'dy' invalide (entier)", _INPUT_LOCK),
    ),
    # --- Fenêtres ----------------------------------------------------------------
    _tool(
        "window",
        aliases=("focus_window", "minimize_window", "maximize_window", "close_window"),
        category="window", level="L2", requires_desktop_input=True, idempotent=False,
        description="Agit sur une fenêtre par son titre : focus, minimize, maximize ou close (les alias "
                    "focus_window, minimize_window, maximize_window et close_window fixent l'action).",
        params=(
            _param("action", "string", "Action sur la fenêtre.", enum=("focus", "minimize", "maximize", "close"),
                   default="focus"),
            _param("window_title", "string", "Titre de la fenêtre.", max_length=256),
            _param("match", "string", "Correspondance du titre : contains (défaut, sauf close), exact (défaut pour "
                                      "close) ou regex ; close exige exact ou regex.",
                   enum=("contains", "exact", "regex")),
            _param("title", "string", "Ancien synonyme de window_title.", max_length=256, deprecated=True),
        ),
        required_any=(("window_title", "title"),),
        evidence=(_ev("window_title", "medium", "Titre de la fenêtre effectivement ciblée (dans le détail)."),),
        examples=({"type": "window", "action": "focus", "window_title": "Bloc-notes"},
                  {"type": "window", "action": "close", "window_title": "Sans titre - Bloc-notes", "match": "exact"}),
        known_errors=("aucune fenêtre ne correspond", "fenêtre ambiguë : plusieurs fenêtres correspondent",
                      "close : correspondance exact ou regex requise", _INPUT_LOCK),
    ),
    # --- Fichiers ----------------------------------------------------------------
    _tool(
        "move_file",
        aliases=("move",),
        category="filesystem", level="L1", requires_confirmation=True, idempotent=False,
        description="Déplace ou renomme un fichier (dossiers de destination créés au besoin). Jamais rejoué à "
                    "l'aveugle après un crash.",
        params=(
            _param("src", "string", "Fichier source.", required=True, is_path=True),
            _param("dest", "string", "Destination.", required=True, is_path=True),
        ),
        evidence=(_ev("file_path", "medium", "Chemin final après le déplacement.", "path"),),
        examples=({"type": "move_file", "src": f"{_W}/brouillon.txt", "dest": f"{_W}/archives/brouillon.txt"},),
        known_errors=("source introuvable", "déplacement refusé depuis/vers un dossier .git",
                      "chemin hors liste blanche ou interdit"),
    ),
    _tool(
        "write_file",
        category="filesystem", level="L1", requires_confirmation=True, idempotent=True,
        description="Écrit (ou remplace) un fichier texte UTF-8 ; dossiers parents créés au besoin. Le contenu est "
                    "masqué dans les journaux et affiché en entier à la confirmation.",
        params=(
            _FS_PATH,
            _param("content", "string", "Contenu texte du fichier.", is_secret_text=True, default=""),
        ),
        evidence=(_ev("file_path", "medium", "Fichier écrit (nombre de caractères dans le détail).", "path"),),
        examples=({"type": "write_file", "path": f"{_W}/notes.txt", "content": "Bonjour"},),
        known_errors=("écriture refusée dans un dossier .git",
                      "chemin hors liste blanche ou interdit (.env, clés, code de l'agent…)"),
    ),
    _tool(
        "read_file",
        category="filesystem", level="L0", idempotent=True,
        description="Lit un fichier texte (8000 premiers caractères).",
        params=(_FS_PATH,),
        evidence=(_ev("file_content", "high", "Contenu lu (masqué avant tout envoi au LLM).", "content"),),
        examples=({"type": "read_file", "path": f"{_W}/notes.txt"},),
        known_errors=("fichier introuvable", "chemin hors liste blanche ou interdit"),
    ),
    _tool(
        "list_dir",
        category="filesystem", level="L0", idempotent=True,
        description="Liste le contenu d'un dossier.",
        params=(_FS_PATH,),
        evidence=(_ev("dir_listing", "high", "Entrées du dossier, triées.", "entries"),),
        examples=({"type": "list_dir", "path": _W},),
        known_errors=("dossier introuvable", "chemin hors liste blanche ou interdit"),
    ),
    _tool(
        "make_dir",
        category="filesystem", level="L1", idempotent=True,
        description="Crée un dossier (et ses parents) ; sans effet s'il existe déjà.",
        params=(_FS_PATH,),
        evidence=(_ev("self_report", "none", "Dossier prêt (détail seulement)."),),
        examples=({"type": "make_dir", "path": f"{_W}/projet"},),
        known_errors=("écriture refusée dans un dossier .git", "chemin hors liste blanche ou interdit"),
    ),
    # --- Commandes ---------------------------------------------------------------
    _tool(
        "run_command",
        aliases=("run_script", "shell"),
        category="shell", level="L2", requires_confirmation=True, idempotent=False, timeout_s=630,
        escalation={"level": "L3", "when": "npm ci/install avec allow_scripts=true, ou git branch -d"},
        description="Exécute un programme de développement SANS shell. Allowlist stricte : git (status, diff, log, "
                    "show, branch, add, commit, init), npm (test, ci, install, run <script>), python/node <script>, "
                    "pytest. Jamais d'opérateur shell (&&, |, ;) dans args.",
        params=(
            _param("program", "string", "Programme à lancer.", required=True,
                   enum=("git", "npm", "python", "python3", "node", "pytest")),
            _param("args", "array", "Arguments, ex. [\"status\"], [\"run\", \"build\"], [\"script.py\"].",
                   items="string", max_items=64),
            _param("cwd", "string", "Dossier de travail (obligatoire).", required=True, is_path=True),
            _param("timeout", "number", "Délai maximal en secondes.", minimum=1, maximum=600,
                   clamped=True, default=120),
            _param("allow_scripts", "boolean", "npm ci/install : autorise les scripts d'installation (action L3).",
                   default=False),
        ),
        evidence=(_ev("exit_code", "high", "Code de sortie du programme.", "returncode"),
                  _ev("command_output", "medium", "Sortie standard (4000 caractères au plus).", "stdout"),
                  _ev("command_output", "medium", "Sortie d'erreur (4000 caractères au plus).", "stderr")),
        examples=({"type": "run_command", "program": "git", "args": ["status"], "cwd": f"{_W}/app"},
                  {"type": "run_command", "program": "npm", "args": ["test"], "cwd": f"{_W}/app", "timeout": 300}),
        known_errors=("programme non autorisé", "champ 'cwd' obligatoire", "argument suspect refusé (opérateur shell)",
                      "interpréteur Python introuvable (raccourci Microsoft Store)",
                      "délai dépassé : arbre de processus arrêté"),
    ),
    # --- Git (LOT 12 : une worktree par tâche, fusion testée) ----------------------
    _tool(
        "git_worktree",
        category="git", level="L1", idempotent=True, timeout_s=120,
        description="Crée (ou retire) la worktree git d'une tâche sur sa branche soulbah/<session>/<tâche>, à partir "
                    "de base (HEAD par défaut). Idempotent : une worktree déjà prête sur la branche est réutilisée. "
                    "Chaque tâche de code travaille dans SA worktree.",
        params=(
            _param("repo", "string", "Dépôt git source (dossier autorisé).", required=True, is_path=True),
            _param("path", "string", "Dossier de la worktree (vide ou inexistant).", required=True, is_path=True),
            _param("branch", "string", "Branche de la tâche : soulbah/<session>/<tâche> (minuscules).", required=True,
                   max_length=140, pattern=GIT_BRANCH_PATTERN),
            _param("base", "string", "Référence de départ (branche, tag ou commit).", max_length=200),
            _param("action", "string", "create (défaut) ou remove.", enum=("create", "remove"), default="create"),
        ),
        evidence=(_ev("file_path", "medium", "Dossier de la worktree prête.", "path"),),
        examples=({"type": "git_worktree", "repo": f"{_W}/app", "path": f"{_W}/wt/t1", "branch": "soulbah/s1/t1"},),
        known_errors=("champ 'branch' : branche soulbah/<session>/<tâche> attendue",
                      "le dossier de worktree existe déjà et n'est pas vide", "git introuvable dans le PATH"),
    ),
    _tool(
        "git_commit",
        category="git", level="L1", idempotent=True, timeout_s=120,
        description="git add -A puis commit dans la worktree d'une tâche (branche soulbah/… uniquement). Rien à "
                    "valider = succès. Identité « SoulBah Agent » si le dépôt n'en a pas.",
        params=(
            _param("cwd", "string", "Worktree de la tâche.", required=True, is_path=True),
            _param("message", "string", "Message de commit.", required=True, max_length=500),
            _param("add_all", "boolean", "Ajoute tous les fichiers modifiés avant le commit.", default=True),
        ),
        evidence=(_ev("exit_code", "high", "Code de sortie de git commit.", "returncode"),
                  _ev("command_output", "medium", "Branche et commit produit.", "stdout")),
        examples=({"type": "git_commit", "cwd": f"{_W}/wt/t1", "message": "Ajoute la fonction de tri"},),
        known_errors=("pas une worktree git", "commit refusé hors d'une branche Soulbah"),
    ),
    _tool(
        "git_merge",
        category="git", level="L2", requires_confirmation=True, idempotent=False, timeout_s=900,
        description="Fusionne la branche d'une tâche dans soulbah/<session>/integration, DANS la worktree "
                    "d'intégration, puis lance les tests (test_program/test_args, mêmes règles que run_command). "
                    "Conflit = fusion abandonnée ; tests rouges = fusion annulée. Jamais vers une branche de "
                    "l'utilisateur.",
        params=(
            _param("repo", "string", "Dépôt git source.", required=True, is_path=True),
            _param("path", "string", "Worktree d'intégration (créée si absente).", required=True, is_path=True),
            _param("source", "string", "Branche de la tâche à fusionner.", required=True, max_length=140,
                   pattern=GIT_BRANCH_PATTERN),
            _param("target", "string", "Branche d'intégration soulbah/<session>/integration.", required=True,
                   max_length=140, pattern=GIT_INTEGRATION_PATTERN),
            _param("base", "string", "Point de départ de la branche d'intégration si elle n'existe pas.",
                   max_length=200),
            _param("test_program", "string", "Programme de tests (allowlist de run_command).",
                   enum=("npm", "python", "python3", "node", "pytest")),
            _param("test_args", "array", "Arguments des tests, ex. [\"test\"].", items="string", max_items=64),
            _param("test_timeout", "number", "Délai des tests en secondes.", minimum=1, maximum=600, clamped=True,
                   default=600),
        ),
        evidence=(_ev("exit_code", "high", "Code de sortie des tests après fusion.", "returncode"),
                  _ev("command_output", "medium", "Branche d'intégration, commit de fusion et branche fusionnée.",
                      "summary"),
                  _ev("test_report", "high", "Rapport des tests lancés sur le résultat de la fusion.", "test_report")),
        examples=({"type": "git_merge", "repo": f"{_W}/app", "path": f"{_W}/wt/integration", "source": "soulbah/s1/t1",
                   "target": "soulbah/s1/integration", "test_program": "npm", "test_args": ["test"]},),
        known_errors=("conflit de fusion : fusion abandonnée", "tests rouges après fusion : intégration remise à son état",
                      "commande de tests refusée", "fusion déjà en cours"),
    ),
    _tool(
        "git_branch_delete",
        category="git", level="L3", requires_confirmation=True, idempotent=False, timeout_s=60,
        description="Supprime une branche soulbah/… (force=true : même non fusionnée). Action L3 : approbation par "
                    "action, jamais couverte par un grant de session.",
        params=(
            _param("repo", "string", "Dépôt git.", required=True, is_path=True),
            _param("branch", "string", "Branche soulbah/<session>/<tâche> à supprimer.", required=True, max_length=140,
                   pattern=GIT_BRANCH_PATTERN),
            _param("force", "boolean", "Supprime même une branche non fusionnée (-D).", default=False),
        ),
        evidence=(_ev("exit_code", "high", "Code de sortie de git branch.", "returncode"),),
        examples=({"type": "git_branch_delete", "repo": f"{_W}/app", "branch": "soulbah/s1/t1"},),
        known_errors=("seules les branches soulbah/… peuvent être supprimées",
                      "action L3 : « confirmer » attendu ou approbation L3"),
    ),
    _tool(
        "git_push",
        category="git", level="L3", requires_confirmation=True, idempotent=False, timeout_s=300,
        description="Pousse une branche soulbah/… vers un dépôt distant, JAMAIS en force. Action L3 : approbation par "
                    "action.",
        params=(
            _param("repo", "string", "Dépôt git.", required=True, is_path=True),
            _param("branch", "string", "Branche soulbah/<session>/… à pousser.", required=True, max_length=140,
                   pattern=GIT_BRANCH_PATTERN),
            _param("remote", "string", "Dépôt distant.", max_length=64, default="origin"),
        ),
        evidence=(_ev("exit_code", "high", "Code de sortie de git push.", "returncode"),
                  _ev("command_output", "medium", "Sortie de git push.", "stdout")),
        examples=({"type": "git_push", "repo": f"{_W}/app", "branch": "soulbah/s1/integration"},),
        known_errors=("seules les branches soulbah/… peuvent être poussées", "push refusé (non fast-forward)"),
    ),
    # --- Web, interface, éditeur (LOT 12) ------------------------------------------
    _tool(
        "browser_get",
        category="web", level="L1", idempotent=True, timeout_s=90,
        description="Lit une page web publique (http/https) : statut, URL finale, titre, sha256 du contenu, extrait "
                    "de texte. engine=browser : Chromium sans interface (Playwright) pour les pages JavaScript. "
                    "Adresses privées ou locales refusées.",
        params=(
            _param("url", "string", "URL http(s) à lire.", required=True, max_length=2000),
            _param("engine", "string", "auto (HTTP simple), http ou browser.", enum=("auto", "http", "browser"),
                   default="auto"),
            _param("timeout", "number", "Délai en secondes.", minimum=1, maximum=60, default=20),
        ),
        evidence=(_ev("http_status", "high", "Statut HTTP et URL lue.", "http"),
                  _ev("sha256", "high", "Empreinte du contenu reçu.", "sha256"),
                  _ev("command_output", "low", "Extrait du texte visible (2000 caractères au plus).", "excerpt")),
        examples=({"type": "browser_get", "url": "https://example.com/"},),
        known_errors=("schéma refusé (http ou https seulement)", "adresse non publique refusée",
                      "page trop volumineuse", "Playwright n'est pas installé"),
    ),
    _tool(
        "ui_snapshot",
        category="screen", level="L0", idempotent=True, timeout_s=30,
        description="Inspecte une fenêtre sans agir : titre, classe, processus, DPI, état et contrôles (libellés). "
                    "Le texte d'un champ de saisie n'est jamais renvoyé : seulement sa longueur et son sha256. "
                    "Rapide (< 2 s) : à utiliser pour observer avant et vérifier après une action.",
        params=(
            _param("window_title", "string", "Titre (ou partie) de la fenêtre ; sans titre : fenêtre au premier plan.",
                   max_length=200),
            _param("max_controls", "integer", "Nombre maximal de contrôles décrits.", minimum=0, maximum=1000,
                   default=200),
            _param("hash_text", "boolean", "Calcule l'empreinte du champ de texte principal.", default=True),
        ),
        evidence=(_ev("window_title", "high", "Titre de la fenêtre inspectée.", "title"),
                  _ev("ui_state", "high", "État de la fenêtre (nom, état, classe, contrôles, DPI).", "ui_state"),
                  _ev("sha256", "high", "Empreinte UTF-8 du texte du champ principal.", "text_sha256")),
        examples=({"type": "ui_snapshot", "window_title": "Bloc-notes"},),
        known_errors=("aucune fenêtre visible dont le titre contient …", "ui_snapshot n'est disponible que sous Windows"),
    ),
    _tool(
        "vscode_open",
        category="app_launch", level="L2", requires_desktop_input=True, idempotent=False,
        description="Ouvre un dossier ou un fichier (à une ligne) dans VS Code installé sur le PC.",
        params=(
            _param("path", "string", "Dossier ou fichier à ouvrir.", required=True, is_path=True),
            _param("line", "integer", "Ligne où placer le curseur (fichier).", minimum=1, maximum=1000000),
            _param("new_window", "boolean", "Ouvre une nouvelle fenêtre.", default=False),
        ),
        evidence=(_ev("process", "low", "Exécutable lancé (ne prouve pas que la fenêtre est prête).", "exe"),),
        examples=({"type": "vscode_open", "path": f"{_W}/app"},),
        known_errors=("VS Code introuvable sur ce poste", "chemin introuvable", _INPUT_LOCK),
    ),
    # --- Téléphone ---------------------------------------------------------------
    _tool(
        "phone_list_devices",
        category="phone", level="L0", idempotent=True,
        description="Liste les téléphones Android connectés (adb devices). À appeler AVANT toute autre action "
                    "téléphone.",
        evidence=(_ev("device_list", "high", "Identifiants des appareils connectés.", "devices"),),
        examples=({"type": "phone_list_devices"},),
        known_errors=(_ADB_MISSING, "délai dépassé"),
    ),
    _tool(
        "phone_tap",
        category="phone", level="L2", requires_confirmation=True, idempotent=False,
        description="Touche l'écran du téléphone en (x, y).",
        params=(_param("x", "number", "Abscisse en pixels de l'écran du téléphone.", required=True),
                _param("y", "number", "Ordonnée en pixels de l'écran du téléphone.", required=True),
                _DEVICE),
        evidence=(_ADB_EXIT,),
        examples=({"type": "phone_tap", "x": 540, "y": 1200},),
        known_errors=("champs 'x' et 'y' requis (nombres)", _ADB_MISSING, _INPUT_LOCK),
    ),
    _tool(
        "phone_swipe",
        category="phone", level="L2", requires_confirmation=True, idempotent=False,
        description="Glisse sur l'écran du téléphone de (x1, y1) à (x2, y2).",
        params=(_param("x1", "number", "Abscisse de départ.", required=True),
                _param("y1", "number", "Ordonnée de départ.", required=True),
                _param("x2", "number", "Abscisse d'arrivée.", required=True),
                _param("y2", "number", "Ordonnée d'arrivée.", required=True),
                _param("duration_ms", "integer", "Durée du geste en millisecondes.", minimum=1, maximum=10000,
                       default=300),
                _DEVICE),
        evidence=(_ADB_EXIT,),
        examples=({"type": "phone_swipe", "x1": 540, "y1": 1600, "x2": 540, "y2": 400, "duration_ms": 300},),
        known_errors=("champs 'x1','y1','x2','y2' requis (nombres)", _ADB_MISSING, _INPUT_LOCK),
    ),
    _tool(
        "phone_type",
        category="phone", level="L2", requires_confirmation=True, idempotent=False,
        description="Tape du texte dans le champ actif du téléphone (masqué dans les journaux).",
        params=(_param("text", "string", "Texte à saisir.", required=True, max_length=1000, is_secret_text=True),
                _DEVICE),
        evidence=(_ADB_EXIT,),
        examples=({"type": "phone_type", "text": "bonjour"},),
        known_errors=("texte trop long (1000 caractères au plus)", _ADB_MISSING, _INPUT_LOCK),
    ),
    _tool(
        "phone_key",
        category="phone", level="L2", requires_confirmation=True, idempotent=False,
        description="Appuie sur une touche système du téléphone.",
        params=(_param("keycode", "string", "Code Android : KEYCODE_BACK, KEYCODE_HOME, KEYCODE_ENTER… ou un nombre.",
                       required=True, pattern=r"^(KEYCODE_[A-Z0-9_]{1,40}|[0-9]{1,3})$"),
                _DEVICE),
        evidence=(_ADB_EXIT,),
        examples=({"type": "phone_key", "keycode": "KEYCODE_HOME"},),
        known_errors=("champ 'keycode' invalide", _ADB_MISSING, _INPUT_LOCK),
    ),
    _tool(
        "phone_open_app",
        category="phone", level="L2", requires_confirmation=True, idempotent=True,
        description="Lance une application du téléphone par son package.",
        params=(_param("package", "string", "Package Android, ex. « com.android.chrome ».", required=True,
                       pattern=r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$"),
                _DEVICE),
        evidence=(_ADB_EXIT,),
        examples=({"type": "phone_open_app", "package": "com.android.chrome"},),
        known_errors=("champ 'package' invalide", _ADB_MISSING, _INPUT_LOCK),
    ),
    _tool(
        "phone_screenshot",
        category="phone", level="L1", idempotent=True,
        description="Capture l'écran du téléphone dans un fichier .png.",
        params=(_param("path", "string", "Fichier .png de destination.", required=True, is_path=True,
                       extensions=(".png",)),
                _DEVICE),
        evidence=(_ev("file_path", "medium", "Fichier .png enregistré.", "path"),),
        examples=({"type": "phone_screenshot", "path": f"{_W}/telephone.png"},),
        known_errors=("champ 'path' invalide (fichier .png attendu)", _ADB_MISSING, _INPUT_LOCK),
    ),
    # --- Vidéo -------------------------------------------------------------------
    _tool(
        "record_screen",
        aliases=("start_recording",),
        category="video", level="L1", idempotent=True,
        description="Enregistre l'écran pendant une durée fixe (bloquant, 120 s au plus). Pour filmer des actions, "
                    "préfère start_recording_bg / stop_recording_bg.",
        params=(
            _VIDEO_PATH,
            _param("duration", "number", "Durée en secondes.", minimum=1, maximum=120,
                   clamped=True, default=5),
            _FPS,
            _MONITOR,
        ),
        evidence=(_ev("video_stats", "medium", "Images écrites, durée réelle, fps capturé et codec.", "frames"),),
        examples=({"type": "record_screen", "path": f"{_W}/demo.mp4", "duration": 8, "fps": 10},),
        known_errors=("dossier de sortie introuvable", "dépendance manquante (cv2, mss, numpy)",
                      "codec H.264 indisponible : repli mp4v (avertissement)"),
    ),
    _tool(
        "start_recording_bg",
        category="video", level="L1", idempotent=False,
        description="Démarre l'enregistrement de l'écran EN ARRIÈRE-PLAN puis rend la main : enchaîne les actions à "
                    "filmer (open_app, click, type_text…) puis stop_recording_bg avec le MÊME path. À privilégier "
                    "pour les démonstrations (arrêt automatique après 600 s).",
        params=(_VIDEO_PATH, _FPS, _MONITOR),
        evidence=(_ev("file_path", "medium", "Fichier vidéo ouvert (démarrage annoncé seulement une fois ouvert).",
                      "path"),),
        examples=({"type": "start_recording_bg", "path": f"{_W}/demo.mp4", "fps": 10},),
        known_errors=("un enregistrement est déjà en cours pour ce chemin", "dossier de sortie introuvable",
                      "dépendance manquante (cv2, mss)"),
    ),
    _tool(
        "stop_recording_bg",
        category="video", level="L1", idempotent=False,
        description="Arrête l'enregistrement démarré par start_recording_bg (même path) et finalise la vidéo.",
        params=(_param("path", "string", "Même fichier que pour start_recording_bg.", required=True, is_path=True,
                       extensions=_VIDEO_EXT),),
        evidence=(_ev("video_stats", "medium", "Images, durée réelle, fps capturé et codec.", "frames"),
                  _ev("file_path", "medium", "Fichier vidéo finalisé, non vide.", "path")),
        examples=({"type": "stop_recording_bg", "path": f"{_W}/demo.mp4"},),
        known_errors=("aucun enregistrement en cours pour ce chemin", "fichier vidéo absent ou vide"),
    ),
    _tool(
        "edit_video",
        aliases=("montage",),
        category="video", level="L1", idempotent=True, timeout_s=1800,
        description="Montage simple et rapide sans logiciel externe : titre facultatif puis concaténation des clips "
                    "(audio conservé), export .mp4 vérifié par une sonde.",
        params=(
            _param("clips", "array", "Clips vidéo, dans l'ordre.", required=True, items="string", max_items=200,
                   is_path=True),
            _param("output", "string", "Fichier .mp4 de sortie.", required=True, is_path=True, extensions=(".mp4",)),
            _param("title", "string", "Titre affiché 2 s en ouverture.", max_length=200),
        ),
        evidence=(_ev("video_probe", "high", "Sonde de l'export (taille, fps, images, dimensions, durée).", "probe"),),
        examples=({"type": "edit_video", "clips": [f"{_W}/a.mp4", f"{_W}/b.mp4"], "title": "Ma démo",
                   "output": f"{_W}/final.mp4"},),
        known_errors=("clip introuvable", "dépendance 'moviepy' non installée", "export invalide (sonde)"),
    ),
    _tool(
        "resolve_montage",
        category="video", level="L2", idempotent=True, timeout_s=1920,
        description="Montage PROFESSIONNEL via DaVinci Resolve installé et OUVERT sur le PC (import des médias, "
                    "timeline, narration, export .mp4 local vérifié). À privilégier pour un rendu professionnel.",
        params=(
            _param("clips", "array", "Images ou vidéos, dans l'ordre.", required=True, items="string", max_items=200,
                   is_path=True),
            _param("output", "string", "Fichier .mp4 de sortie.", required=True, is_path=True, extensions=(".mp4",)),
            _param("audio", "string", "Narration (.mp3, .wav) posée au début d'une piste dédiée.", is_path=True),
            _param("project", "string", "Nom du projet Resolve.", max_length=100, default="SoulBah Formation"),
        ),
        evidence=(_ev("video_probe", "high", "Sonde du rendu (fichier récent, non vide, décodable).", "probe"),),
        examples=({"type": "resolve_montage", "clips": [f"{_W}/intro.png", f"{_W}/demo.mp4"],
                   "audio": f"{_W}/narration.mp3", "output": f"{_W}/formation.mp4", "project": "Formation"},),
        known_errors=("DaVinci Resolve fermé ou scripting externe désactivé (Préférences > Système > Général)",
                      "médias introuvables", "export Resolve invalide"),
    ),
)


# --- Accès dérivés ------------------------------------------------------------------
def step_types(manifest: dict[str, Any]) -> tuple[str, ...]:
    """Nom canonique puis alias."""
    return (manifest["name"], *manifest["aliases"])


def manifest_by_type() -> dict[str, dict[str, Any]]:
    """Type d'étape (nom ou alias) → manifeste."""
    return {t: m for m in MANIFESTS for t in step_types(m)}


def get_manifest(step_type: str) -> dict[str, Any] | None:
    return manifest_by_type().get(step_type)


def path_param_names() -> tuple[tuple[str, ...], tuple[str, ...]]:
    """(paramètres chemin simples, paramètres listes de chemins), tous outils confondus,
    dans l'ordre de première déclaration."""
    single: list[str] = []
    lists: list[str] = []
    for m in MANIFESTS:
        for p in m["params"]:
            if not p["is_path"]:
                continue
            target = lists if p["type"] == "array" else single
            if p["name"] not in target:
                target.append(p["name"])
    return tuple(single), tuple(lists)


def confirm_step_types() -> frozenset[str]:
    """Types (noms + alias) des outils à effet réel que le serveur fait confirmer."""
    return frozenset(t for m in MANIFESTS if m["requires_confirmation"] for t in step_types(m))


def secret_param_names() -> frozenset[str]:
    """Paramètres de texte libre à masquer (journaux, évènements, LLM)."""
    return frozenset(p["name"] for m in MANIFESTS for p in m["params"] if p["is_secret_text"])


def declared_param_error(step: dict[str, Any]) -> str | None:
    """Contraintes DÉCLARÉES par le manifeste de l'étape (LOT 12) : type, enum, bornes non
    « clamped », longueur, nombre d'éléments et motif. Les skills récents l'appellent depuis
    validate() : le manifeste est alors la seule source de ces règles."""
    m = get_manifest(str(step.get("type", "")).strip())
    if m is None:
        return None
    for p in m["params"]:
        name = p["name"]
        value = step.get(name)
        if value is None:
            continue
        if not _type_ok(value, p["type"]):
            return f"champ '{name}' : type {p['type']} attendu"
        if "enum" in p and value not in p["enum"]:
            return f"champ '{name}' : valeur attendue parmi {', '.join(p['enum'])}"
        if isinstance(value, (int, float)) and not isinstance(value, bool) and not p.get("clamped"):
            if "min" in p and value < p["min"]:
                return f"champ '{name}' : minimum {p['min']}"
            if "max" in p and value > p["max"]:
                return f"champ '{name}' : maximum {p['max']}"
        if isinstance(value, str):
            if "max_length" in p and len(value) > p["max_length"]:
                return f"champ '{name}' : {p['max_length']} caractères au plus"
            if "pattern" in p and not re.match(p["pattern"], value):
                return f"champ '{name}' : format invalide — {p['description']}"
        if isinstance(value, list):
            if "max_items" in p and len(value) > p["max_items"]:
                return f"champ '{name}' : {p['max_items']} éléments au plus"
            item_type = (p.get("items") or {}).get("type")
            if item_type and not all(_type_ok(v, item_type) for v in value):
                return f"champ '{name}' : éléments de type {item_type} attendus"
    return None


# --- Contrôle structurel ----------------------------------------------------------
def _type_ok(value: Any, type_: str | list[str]) -> bool:
    types = type_ if isinstance(type_, list) else [type_]
    for t in types:
        if t == "string" and isinstance(value, str):
            return True
        if t == "boolean" and isinstance(value, bool):
            return True
        if t == "integer" and isinstance(value, int) and not isinstance(value, bool):
            return True
        if t == "number" and isinstance(value, (int, float)) and not isinstance(value, bool):
            return True
        if t == "array" and isinstance(value, list):
            return True
    return False


def _param_problems(where: str, p: dict[str, Any]) -> list[str]:
    out: list[str] = []
    name = p.get("name")
    if not isinstance(name, str) or not _IDENT_RE.match(name):
        return [f"{where} : nom de paramètre invalide {name!r}"]
    if name in COMMON_FIELDS:
        out.append(f"{where}.{name} : nom réservé aux champs communs")
    types = p["type"] if isinstance(p["type"], list) else [p["type"]]
    if not types or any(t not in PARAM_TYPES for t in types):
        out.append(f"{where}.{name} : type invalide {p['type']!r}")
    if not isinstance(p.get("description"), str) or not p["description"].strip():
        out.append(f"{where}.{name} : description manquante")
    if "enum" in p and (types != ["string"] or not p["enum"]):
        out.append(f"{where}.{name} : enum réservé aux textes, non vide")
    numeric = set(types) <= {"integer", "number"}
    if ("min" in p or "max" in p) and not numeric:
        out.append(f"{where}.{name} : min/max réservés aux nombres")
    if "min" in p and "max" in p and p["min"] > p["max"]:
        out.append(f"{where}.{name} : min > max")
    if p.get("clamped") and "min" not in p and "max" not in p:
        out.append(f"{where}.{name} : clamped sans bornes")
    if "items" in p and "array" not in types:
        out.append(f"{where}.{name} : items réservé aux listes")
    if "array" in types and "items" not in p:
        out.append(f"{where}.{name} : liste sans type d'élément (items)")
    if p["is_path"] and not (types == ["string"] or (types == ["array"] and p.get("items") == {"type": "string"})):
        out.append(f"{where}.{name} : is_path exige un texte ou une liste de textes")
    if p.get("extensions") and not p["is_path"]:
        out.append(f"{where}.{name} : extensions réservées aux chemins")
    if p["is_secret_text"] and types != ["string"]:
        out.append(f"{where}.{name} : is_secret_text exige un texte")
    if p["deprecated"] and p["required"]:
        out.append(f"{where}.{name} : un paramètre obsolète ne peut pas être obligatoire")
    if "default" in p and not _type_ok(p["default"], p["type"]):
        out.append(f"{where}.{name} : défaut incompatible avec le type")
    if "pattern" in p:
        try:
            re.compile(p["pattern"])
        except re.error as e:
            out.append(f"{where}.{name} : pattern invalide ({e})")
    return out


def _example_problems(where: str, m: dict[str, Any], ex: Any) -> list[str]:
    if not isinstance(ex, dict):
        return [f"{where} : objet attendu"]
    out: list[str] = []
    if ex.get("type") != m["name"]:
        out.append(f"{where} : type {ex.get('type')!r} ≠ {m['name']!r}")
    params = {p["name"]: p for p in m["params"]}
    for key, value in ex.items():
        if key in COMMON_FIELDS:
            continue
        p = params.get(key)
        if p is None:
            out.append(f"{where} : paramètre non déclaré « {key} »")
            continue
        if p["deprecated"]:
            out.append(f"{where} : paramètre obsolète « {key} »")
        if not _type_ok(value, p["type"]):
            out.append(f"{where} : « {key} » de type invalide")
        if "enum" in p and value not in p["enum"]:
            out.append(f"{where} : « {key} » hors enum")
        if p["is_path"]:
            for v in (value if isinstance(value, list) else [value]):
                if not (isinstance(v, str) and (v == WORKSPACE_PLACEHOLDER
                                                or v.startswith(WORKSPACE_PLACEHOLDER + "/"))):
                    out.append(f"{where} : le chemin « {key} » doit commencer par {WORKSPACE_PLACEHOLDER}")
    for p in m["params"]:
        if p["required"] and p["name"] not in ex:
            out.append(f"{where} : paramètre obligatoire absent « {p['name']} »")
    for group in m["required_any"]:
        if not any(g in ex for g in group):
            out.append(f"{where} : il faut l'un de {group}")
    return out


def manifest_problems() -> list[str]:
    """Incohérences des manifestes (liste vide = contrat valide)."""
    out: list[str] = []
    seen: dict[str, str] = {}
    categories = {c["id"] for c in CATEGORIES}
    for m in MANIFESTS:
        name = m["name"]
        if not isinstance(name, str) or not _IDENT_RE.match(name):
            out.append(f"nom d'outil invalide {name!r}")
            continue
        for t in step_types(m):
            if not _IDENT_RE.match(t):
                out.append(f"{name} : alias invalide {t!r}")
            if t in seen:
                out.append(f"type « {t} » déclaré par {seen[t]} et {name}")
            seen[t] = name
        if not _SEMVER_RE.match(str(m["version"])):
            out.append(f"{name} : version non semver {m['version']!r}")
        if m["category"] not in categories:
            out.append(f"{name} : catégorie inconnue {m['category']!r}")
        if m["security_level"] not in _LEVELS:
            out.append(f"{name} : niveau inconnu {m['security_level']!r}")
        esc = m.get("escalation")
        if esc is not None and (esc.get("level") not in _LEVELS or not str(esc.get("when", "")).strip()
                                or _LEVELS.index(esc["level"]) <= _LEVELS.index(m["security_level"])):
            out.append(f"{name} : escalade invalide (niveau supérieur + condition)")
        if not str(m["description"]).strip():
            out.append(f"{name} : description manquante")
        timeout = m["timeout_s"]
        if timeout is not None and (not _type_ok(timeout, "number") or timeout <= 0):
            out.append(f"{name} : timeout_s invalide")
        names = [p.get("name") for p in m["params"]]
        if len(set(names)) != len(names):
            out.append(f"{name} : paramètre déclaré deux fois")
        for p in m["params"]:
            out.extend(_param_problems(name, p))
        by_name = {p["name"]: p for p in m["params"]}
        for group in m["required_any"]:
            if len(group) < 2 or any(g not in by_name for g in group):
                out.append(f"{name} : groupe required_any invalide {group}")
            elif all(by_name[g]["deprecated"] for g in group):
                out.append(f"{name} : groupe required_any sans paramètre courant")
        for e in m["evidence"]:
            if e.get("kind") not in EVIDENCE_KINDS or e.get("confidence") not in CONFIDENCES:
                out.append(f"{name} : preuve invalide {e}")
        if not 1 <= len(m["examples"]) <= 2:
            out.append(f"{name} : 1 ou 2 exemples attendus")
        for i, ex in enumerate(m["examples"]):
            out.extend(_example_problems(f"{name}.examples[{i}]", m, ex))
        if not all(isinstance(k, str) and k.strip() for k in m["known_errors"]):
            out.append(f"{name} : known_errors doit être une liste de textes")
    return out


def build_catalog() -> dict[str, Any]:
    """Catalogue JSON (outils triés par nom) écrit par scripts/gen_catalog.py."""
    return {
        "catalog_version": CATALOG_VERSION,
        "generated_from": GENERATED_FROM,
        "common_fields": sorted(COMMON_FIELDS),
        "workspace_placeholder": WORKSPACE_PLACEHOLDER,
        "security_levels": dict(SECURITY_LEVELS),
        "categories": [dict(c) for c in CATEGORIES],
        "tools": sorted((dict(m) for m in MANIFESTS), key=lambda m: m["name"]),
    }
