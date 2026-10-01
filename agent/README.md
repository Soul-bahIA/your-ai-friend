# SoulBah Agent — worker local

Le processus qui tourne **sur votre poste** et exécute réellement les tâches créées
depuis l'app web (page Automatisation / moteur de raisonnement). Il interroge la file
de tâches du **backend Node** (`/api/agent-tasks`), exécute chaque étape via des
*skills* soumis à un **gate de permissions**, et remonte timeline, captures et
résultat en temps réel.

## Fonctionnement

1. `GET /api/agent-tasks/poll` (en-tête `x-agent-key`) → jusqu'à 5 tâches `pending`.
   Chaque tâche porte `requeue_count`, mémorisé comme **`attempt`** pour son exécution.
2. **Claim** atomique : `POST /update` `{status: "in_progress", attempt}`. 409 = déjà prise
   (ignorée) ; erreur réseau/5xx = nouvel essai au prochain cycle.
3. Exécution des étapes dans l'ordre ; arrêt à la première étape en échec/refusée.
   Évènements (`POST /event`, avec `attempt`) : timeline, captures live, **heartbeat** toutes les 30 s.
4. Statut final `completed` / `failed` (`POST /update`, avec `attempt`).

Garanties de robustesse :
- **409 sur un évènement/heartbeat** (tentative périmée ou tâche plus `in_progress`) :
  l'exécution s'arrête après l'étape en cours, **aucun statut final** n'est envoyé.
- **Update final en échec** (réseau, 5xx) : persisté dans `agent/.pending_updates.json`
  et renvoyé avec backoff exponentiel (avant chaque poll et au démarrage) pendant ~10 min.
  Un 409 sur cet update le retire de la file. Une tâche dont l'update est en attente
  n'est pas ré-exécutée.
- **Délai par étape** (`SOULBAH_STEP_TIMEOUT`, 900 s par défaut, étendu pour les skills
  longs par nature : montage, commandes) : au-delà, l'étape échoue et la tâche s'arrête.
  Un heartbeat sans progression finit par s'arrêter : une tâche bloquée ne reste pas vivante.
- **Pause / stop** : lus entre les étapes, et toutes les 3 s pendant une étape longue
  (`wait`, enregistrements, rendu Resolve s'interrompent proprement).
- **Enregistrements en arrière-plan** toujours finalisés (fin de tâche + `atexit`).
- **Backoff du poll** (plafond 60 s) quand le backend est injoignable.
- Journal console + fichier tournant `agent/logs/agent.log` (1 Mo × 5).

## Skills

| Skill | Types d'étape | Catégorie | Contrôle |
|---|---|---|---|
| `open_app` | `open_app`, `open_software`, `launch` | app_launch | allowlist d'applis, entrée* |
| `screenshot` | `screenshot`, `capture` | screen | `path` facultatif : whitelist + `.png` |
| `type_text` | `type_text`, `type`, `keyboard` | keyboard | entrée* |
| `hotkey` | `hotkey`, `press`, `key` | keyboard | entrée* |
| `mouse` | `mouse`, `click`, `move_mouse`, `drag`, `scroll`, `double_click`, `right_click` | mouse | entrée* |
| `window` | `window`, `focus_window`, `minimize_window`, `maximize_window`, `close_window` | window | entrée* |
| `wait` | `wait`, `sleep` | generic | non sensible (≤ 300 s, interruptible) |
| `move_file` | `move_file`, `move` | filesystem | whitelist, pas de `.git` |
| `file_ops` | `write_file`, `read_file`, `list_dir`, `make_dir` | filesystem | whitelist, pas d'écriture dans `.git` |
| `run_command` | `run_command`, `run_script`, `shell` | shell | allowlist stricte + **confirmation toujours** |
| `record_screen` | `record_screen`, `start_recording` | video | whitelist, `.mp4`/`.avi` |
| `start_recording_bg` / `stop_recording_bg` | idem | video | whitelist, `.mp4`/`.avi` |
| `edit_video` | `edit_video`, `montage` | video | whitelist, sortie `.mp4` |
| `resolve_montage` | `resolve_montage` | video | whitelist, sortie `.mp4` (voir `INSTALLER_DAVINCI_RESOLVE.md`) |
| `phone_list_devices` | `phone_list_devices` | phone | lecture seule |
| `phone` | `phone_tap`, `phone_swipe`, `phone_type`, `phone_key`, `phone_open_app`, `phone_screenshot` | phone | ADB, valeurs validées/échappées |

\* *entrée* : souris/clavier/fenêtres/applis — confirmation exigée même en mode `auto`,
sauf pré-autorisation explicite (`--allow-input-control`).

## Modes

| Mode | Effet |
|---|---|
| `confirm` (défaut) | Confirmation `[o/N]` avant chaque action sensible. Sans réponse en `SOULBAH_CONFIRM_TIMEOUT` s (120) : **refus**. Sans console : refus. |
| `auto` (`--auto`) | Pas de confirmation pour fichiers/vidéo/téléphone (toujours bornés par la whitelist). **`run_command` et les actions d'entrée restent confirmés.** |
| `--allow-input-control` | Pré-autorise souris/clavier/fenêtres/applis (pas `run_command`). |
| `--dry-run` | Décrit les actions sans rien exécuter (validations de sécurité appliquées). |

## Modèle de sécurité

- **Whitelist de dossiers** (`SOULBAH_ALLOWED_DIRS`) : tout chemin (`path`, `src`, `dest`,
  `cwd`, `output`, `audio`, `clips`) est résolu (`realpath`, insensible à la casse sous
  Windows) et doit se trouver dans un dossier autorisé. Liste vide = aucun chemin autorisé.
- **`run_command`** : aucun shell ; `cwd` obligatoire dans la whitelist ; programmes et
  sous-commandes en allowlist fermée :
  - `git` : `status | diff | log | show | branch | add | commit | init` — jamais d'option
    globale, ni `-c`/`-C`/`--config*`/`--git-dir`/`--exec-path`/`--upload-pack`…
  - `npm` : `test | ci | install` (sans argument) | `run <script>`
  - `python`/`python3` : `<script.py> [args]` ; `node` : `<script.js|.mjs|.cjs> [args]` —
    script dans la whitelist, aucune option `-c/-e/-m/-r/-p/-i/--eval/--require/--import…`
    (même collée ou avec `=`).
  - `pytest` : chemins de tests (whitelist) + options de lecture (`-q -v -x -k --maxfail --tb…`).
  - `npx`, `pip`, `pnpm`, `yarn`, shells… : **refusés**.
  - Tout argument ressemblant à un chemin (absolu, `..`, séparateur, y compris
    `--opt=valeur` et `-Fvaleur`) doit se résoudre dans la whitelist.
- **`open_app`** : nom simple uniquement (aucun séparateur, guillemet ni métacaractère
  `& | < > ^ % ! ( ) ; ,`…), allowlist (défaut + `SOULBAH_ALLOWED_APPS`), shells et hôtes
  de script interdits ; résolution vers un `.exe` absolu (table connue, `PATH` sans le
  dossier courant, registre *App Paths*) ; lancement direct sans `cmd /c start`.
- **ADB** : `device_id`, `keycode`, `package` validés par motif ; texte échappé pour le shell du téléphone.
- **Clé validée par hash** côté backend (table `agent_keys`) ; `poll`/`update`/`event`
  sont scopés par l'utilisateur de la clé. Révocable depuis la page Sécurité.
- L'agent n'a que les droits de l'utilisateur qui le lance.

## Installation

```bash
cd agent
python -m venv .venv
# Windows : .venv\Scripts\activate    |    Unix : source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env          # puis renseignez vos valeurs
```

Sous Windows, `Lancer_Agent.bat` démarre l'agent en mode `confirm`.

## Utilisation

```bash
python soulbah_agent.py --dry-run     # décrit les actions sans rien exécuter
python soulbah_agent.py --once        # un seul cycle de poll
python soulbah_agent.py               # boucle continue, confirmation avant chaque action sensible
python soulbah_agent.py --auto        # moins de confirmations — à vos risques
```

Ctrl+C arrête proprement après le cycle en cours.

## Variables d'environnement

| Variable | Défaut | Rôle |
|---|---|---|
| `SOULBAH_API_URL` | `http://localhost:3000` | Backend Node |
| `SOULBAH_AGENT_KEY` | — (obligatoire) | Clé `x-agent-key` (page Sécurité) |
| `SOULBAH_POLL_INTERVAL` | `5` | Intervalle de poll (s) |
| `SOULBAH_PERMISSION_MODE` | `confirm` | `confirm` ou `auto` |
| `SOULBAH_DRY_RUN` | `false` | Simulation |
| `SOULBAH_ALLOWED_DIRS` | (vide) | Dossiers autorisés, séparés par `;` (Windows) / `:` |
| `SOULBAH_ALLOW_INPUT_CONTROL` | `false` | Pré-autorise souris/clavier/fenêtres/applis |
| `SOULBAH_ALLOWED_APPS` | (vide) | Applis supplémentaires pour `open_app` (noms, virgules) |
| `SOULBAH_STEP_TIMEOUT` | `900` | Délai max d'une étape (s) |
| `SOULBAH_CONFIRM_TIMEOUT` | `120` | Délai de réponse à une confirmation (s), puis refus |
| `RESOLVE_SCRIPT_API` / `RESOLVE_SCRIPT_LIB` | chemins Resolve par défaut | Scripting DaVinci Resolve |

## Format d'une tâche

```json
{
  "title": "Démo VS Code",
  "steps": [
    { "type": "open_software", "software": "vscode" },
    { "type": "wait", "seconds": 3 },
    { "type": "type_text", "text": "console.log('hello')" },
    { "type": "run_command", "program": "git", "args": ["status"], "cwd": "C:\\Users\\...\\soulbah_workspace\\app" },
    { "type": "screenshot", "path": "C:\\Users\\...\\soulbah_workspace\\demo.png" }
  ]
}
```

Ajouter un type d'action = ajouter un skill dans `skills/` (avec `validate()` pour ses
règles de sécurité) et l'enregistrer dans `skills/__init__.py`.

## Tests

```bash
pip install pytest
python -m pytest -q tests
```

Les tests n'exécutent aucune commande ni aucune action à l'écran (validateurs, gate,
executor avec skills factices, file des updates, cycle d'une tâche avec faux client).

## Structure
```
agent/
├── soulbah_agent.py     # boucle principale, claim/heartbeat/409, backoff, journaux
├── config.py            # chargement .env
├── client.py            # HTTP vers /api/agent-tasks (attempt, issues ok/409/retry)
├── pending.py           # file locale des updates finaux (.pending_updates.json)
├── permissions.py       # gate (whitelist, validation, confirmation avec délai, dry-run)
├── executor.py          # étapes avec délai, pause/stop, nettoyage en fin de tâche
├── skills/              # 17 skills (voir tableau) + base.py (contrat, annulation)
└── tests/               # suite pytest
```
