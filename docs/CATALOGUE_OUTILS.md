# Catalogue d'outils unique (LOT 2)

Source des exigences : `docs/SOULBAH_V2_LOT0_AUDIT.md` §9.8 (preuves), §9.9 (idempotence), §9.10 (niveaux
L0–L3) et §13 « LOT 2 — Contrat d'outils unique ».

## 1. Principe

Avant le LOT 2, les types d'étapes et leurs champs étaient recopiés à la main dans quatre endroits
(registre des skills de l'agent, gate de permissions, validation node-api, prompt du planificateur
python-ia) et divergeaient : un `start_recording_bg` planifié était par exemple accepté par le serveur
mais refusé par l'agent. Il n'existe désormais qu'**une seule source de vérité** :

```
agent/skills/manifests.py                       ← MANIFESTS : un manifeste par outil (édité à la main)
        │  python scripts/gen_catalog.py
        ▼
shared/tools/catalog.json                       ← catalogue de référence (généré, versionné)
        ├── backend/node-api/src/generated/tool_catalog.json     (copie octet pour octet)
        └── backend/python-ia/app/generated/tool_catalog.json    (copie octet pour octet)
```

Les deux copies existent parce que `docker compose` construit chaque service depuis son propre
dossier : `shared/` est hors du contexte de build des images. Elles sont vérifiées octet par octet
par `gen_catalog.py --check`. Les trois fichiers JSON sont forcés en fins de ligne LF par
`.gitattributes` pour rester identiques à la sortie du générateur quel que soit `core.autocrlf`.

Le catalogue est validé contre `shared/schemas/tool_catalog.schema.json` (JSON Schema 2020-12,
sous-ensemble de mots-clés que `gen_catalog.py` sait vérifier avec la seule bibliothèque standard).

## 2. Qui consomme quoi

| Consommateur | Fichier | Usage du catalogue |
|---|---|---|
| Agent (P3) | `agent/skills/__init__.py` → `manifest_errors()` | Au démarrage (`soulbah_agent.py`, code de sortie 2) et dans les tests : chaque type du registre a un manifeste et inversement, même catégorie, même `timeout_s`, un seul skill par manifeste. |
| Agent, gate | `agent/permissions.py` | `SERVER_CONFIRM_STEP_TYPES` = `confirm_step_types()` ; champs de chemin contrôlés (`_PATH_KEYS`, `_PATH_LIST_KEYS`) = `path_param_names()`. Plus aucune liste codée en dur. |
| node-api (P1) | `src/lib/toolCatalog.ts`, `src/lib/agentSteps.ts` | `AGENT_STEP_TYPES` (noms + alias), `STEP_PARAMS` / `compactStep` (ne garde que les paramètres déclarés), `REQUIRED_FIELDS`, `PATH_KEYS` / `PATH_LIST_KEYS` (confinement aux dossiers autorisés), `SENSITIVE_STEP_TYPES` (`requires_confirmation`). |
| python-ia (P2) | `app/tool_catalog.py`, `app/reasoning.py` | `build_skills_catalog()` construit la section « SKILLS DISPONIBLES » du prompt du planificateur : noms canoniques, niveaux, paramètres typés, exemples, erreurs connues. `_sanitize_steps` n'accepte que les noms canoniques. |
| CI | `.github/workflows/ci.yml`, job `catalog` | `python scripts/gen_catalog.py --check` : 0 à jour, 1 dérive (diff affiché), 2 manifestes ou schéma invalides. |

Règle : **le planificateur n'utilise que les noms canoniques**. Les alias (`mouse`, `press`, `shell`,
`montage`…) restent acceptés par node-api et l'agent pour les plans écrits à la main et les tâches
anciennes, mais n'apparaissent pas dans le prompt.

## 3. Forme d'un manifeste

Un manifeste est construit par `_tool(...)` dans `MANIFESTS` ; sa forme normalisée est exactement celle
de l'entrée JSON du catalogue.

| Champ | Sens |
|---|---|
| `name`, `aliases` | Type canonique (identifiant `^[a-z][a-z0-9_]{0,39}$`) et synonymes historiques. Un type ne peut appartenir qu'à un manifeste. |
| `version` | Semver de l'outil (`1.0.0` par défaut) ; `CATALOG_VERSION` versionne le catalogue entier. |
| `category` | Catégorie du gate de permissions (`Skill.category`) : `app_launch`, `keyboard`, `generic`, `screen`, `mouse`, `window`, `filesystem`, `shell`, `phone`, `video`. L'ordre de `CATEGORIES` est celui des sections du prompt. |
| `security_level` | `L0` lecture sans effet · `L1` réversible et confiné au workspace · `L2` effet réel · `L3` irréversible (audit §9.10). `escalation` = `{level, when}` quand une condition fait monter le niveau. |
| `requires_confirmation` | Action à effet réel : le serveur pose `payload.requires_confirmation=true` et l'agent confirme TOUJOURS sur le PC, même en mode auto. |
| `requires_desktop_input` | Prend le contrôle du clavier, de la souris ou de la fenêtre au premier plan (ressource exclusive `desktop.input`). |
| `idempotent` | Rejouable sans danger après un crash (audit §9.9). |
| `timeout_s` | Délai propre de l'outil, `null` = délai global `SOULBAH_STEP_TIMEOUT` (900 s). Doit être égal à `skill.timeout_s`. |
| `params` | Liste de `_param(...)` : `type` (`string`, `integer`, `number`, `boolean`, `array`, ou liste de types), `required`, `enum`, `min`/`max` (+ `clamped` si la valeur est ramenée dans les bornes au lieu d'être refusée), `max_length`, `items`, `max_items`, `default`, `extensions`, `pattern`, `is_path` (confiné aux dossiers autorisés), `is_secret_text` (masqué dans journaux, évènements et prompts), `deprecated`. |
| `required_any` | Groupes « au moins l'un de », par ex. `[["app", "software", "name"]]`. |
| `evidence` | Preuves produites (`kind` parmi `EVIDENCE_KINDS`, `confidence` `high`/`medium`/`low`/`none`, `field`). `self_report` + `none` = aucune preuve : l'évaluateur doit exiger une capture. |
| `examples` | 1 à 2 exemples valides ; les chemins utilisent `<dossier autorisé>` (`WORKSPACE_PLACEHOLDER`), remplacé par le planificateur par un dossier réellement autorisé. Chaque exemple est validé contre les paramètres du manifeste. |
| `known_errors` | Messages d'erreur attendus, repris dans le prompt pour que le planificateur les évite. |

Champs descriptifs acceptés sur toute étape et ignorés par l'agent : `COMMON_FIELDS` = `description`,
`note`, `type`.

## 4. Les 30 outils du catalogue v1.0.0

| Outil | Catégorie | Niveau | Confirmé | Desktop | Idempotent | Alias |
|---|---|---|---|---|---|---|
| `wait` | generic | L0 | | | ✔ | `sleep` |
| `list_dir` | filesystem | L0 | | | ✔ | |
| `read_file` | filesystem | L0 | | | ✔ | |
| `phone_list_devices` | phone | L0 | | | ✔ | |
| `make_dir` | filesystem | L1 | | | ✔ | |
| `write_file` | filesystem | L1 | ✔ | | ✔ | |
| `move_file` | filesystem | L1 | ✔ | | | `move` |
| `screenshot` | screen | L1 | | | ✔ | `capture` |
| `phone_screenshot` | phone | L1 | | | ✔ | |
| `record_screen` | video | L1 | | | ✔ | `start_recording` |
| `start_recording_bg` | video | L1 | | | | |
| `stop_recording_bg` | video | L1 | | | | |
| `edit_video` | video | L1 | | | ✔ | `montage` |
| `resolve_montage` | video | L2 | | | ✔ | |
| `open_app` | app_launch | L2 | | ✔ | | `launch`, `open_software` |
| `window` | window | L2 | | ✔ | | `close_window`, `focus_window`, `maximize_window`, `minimize_window` |
| `click` | mouse | L2 | | ✔ | | `mouse` |
| `double_click` | mouse | L2 | | ✔ | | |
| `right_click` | mouse | L2 | | ✔ | | |
| `move_mouse` | mouse | L2 | | ✔ | ✔ | |
| `drag` | mouse | L2 | | ✔ | | |
| `scroll` | mouse | L2 | | ✔ | | |
| `type_text` | keyboard | L2 | ✔ | ✔ | | `keyboard`, `type` |
| `hotkey` | keyboard | L2 | ✔ | ✔ | | `key`, `press` |
| `run_command` | shell | L2 | ✔ | | | `run_script`, `shell` |
| `phone_open_app` | phone | L2 | ✔ | | ✔ | |
| `phone_tap` | phone | L2 | ✔ | | | |
| `phone_swipe` | phone | L2 | ✔ | | | |
| `phone_type` | phone | L2 | ✔ | | | |
| `phone_key` | phone | L2 | ✔ | | | |

Aucun outil L3 n'existe encore : les niveaux et l'escalade sont prévus pour le LOT 6 (sécurité et audit).

## 5. Ajouter ou modifier un outil

1. Écrire le skill dans `agent/skills/` (classe `Skill` : `name`, `category`, `timeout_s`, `validate`,
   `run`) et l'enregistrer dans `REGISTRY` (`agent/skills/__init__.py`) sous son nom canonique et ses
   alias.
2. Ajouter le manifeste correspondant dans `MANIFESTS` (`agent/skills/manifests.py`) avec `_tool(...)`.
   Catégorie et `timeout_s` doivent être identiques au skill ; marquer `is_path` sur tout paramètre de
   chemin et `is_secret_text` sur tout texte libre saisi ou écrit ; fixer `requires_confirmation`
   pour tout effet réel hors workspace.
3. Régénérer et vérifier :

   ```bash
   python scripts/gen_catalog.py          # réécrit les 3 fichiers JSON
   python scripts/gen_catalog.py --check  # doit renvoyer 0
   ```

4. Versionner les trois fichiers générés AVEC le manifeste dans le même commit. Ne jamais éditer un
   `tool_catalog.json` ou `catalog.json` à la main : la CI le refuserait (code 1 avec le diff).
5. Lancer les trois suites : `agent/` (`pytest`, dont `tests/test_tool_catalog.py`),
   `backend/python-ia/` (`pytest`), `backend/node-api/` (`npm test`). node-api et python-ia n'ont rien
   d'autre à modifier : validation, `compactStep`, confinement des chemins et prompt du planificateur
   se dérivent du catalogue.
6. Incrémenter `version` de l'outil si ses paramètres changent de façon incompatible, et
   `CATALOG_VERSION` lors d'un changement de forme du catalogue (mettre à jour le schéma).

Un manifeste incohérent (type en double, exemple invalide, paramètre `clamped` sans bornes, niveau
inconnu…) fait échouer `gen_catalog.py` avec le code 2 et la liste des problèmes
(`manifests.manifest_problems()`), et empêche l'agent de démarrer.

## 6. Critères de sortie du LOT 2 (audit §13) et tests qui les couvrent

| Critère | Test |
|---|---|
| `--check` renvoie 0 sur le dépôt ; une dérive injectée dans `catalog.json` ou dans une copie renvoie 1 avec le fichier fautif | `agent/tests/test_tool_catalog.py` (section « Catalogue généré : --check et dérive ») |
| Manifestes invalides → code 2 | `agent/tests/test_tool_catalog.py::test_invalid_manifests_exit_2` |
| L'agent refuse de démarrer si registre et manifestes divergent | `agent/tests/test_tool_catalog.py::test_agent_refuses_to_start_on_manifest_drift` |
| Un `start_recording_bg` planifié est accepté par le serveur (validation, `compactStep`, confinement) **et** par l'agent (gate) | `backend/node-api/test/toolCatalog.test.ts` (« start_recording_bg planifié ») ; `agent/tests/test_tool_catalog.py::test_planned_start_recording_bg_is_accepted_by_the_agent` |
| Le prompt du planificateur est construit depuis le catalogue (noms, niveaux, paramètres, exemples) | `backend/python-ia/tests/test_tool_catalog.py` |
| Les champs de chemin et les étapes confirmées de node-api et de l'agent viennent de la même source | `backend/node-api/test/toolCatalog.test.ts`, `agent/tests/test_tool_catalog.py` |

État au 2026-10-01 : agent 488 tests, python-ia 326, node-api 196, tous verts ; `gen_catalog.py --check`
renvoie 0.
