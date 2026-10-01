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
   (ignorée) ; 410 = supprimée (ignorée) ; erreur réseau/5xx = nouvel essai au prochain cycle.
3. Exécution des étapes dans l'ordre ; arrêt à la première étape en échec/refusée.
   Évènements (`POST /event`, avec `attempt`) : timeline, captures live, **heartbeat** toutes les 30 s.
   Si une étape doit être confirmée, l'agent émet d'abord `approval_required`
   (`{step_index, action, summary}`), puis `approval_result` (`{step_index, approved}`) ;
   `step_started` n'est émis **qu'après** l'autorisation.
4. Statut final (`POST /update`, avec `attempt`) :
   - `completed` : toutes les étapes ont réussi ;
   - `failed` : étape en échec/refusée, délai dépassé, ou **plan vide** (`result.empty_plan = true`) ;
   - `cancelled` : arrêt demandé depuis l'app (`control = stop`) ou Ctrl+C sur le PC.
     Un arrêt n'est jamais un échec : le serveur ne l'évalue pas.
   Le thread heartbeat est arrêté **et terminé** avant l'envoi du final.

Garanties de robustesse :
- **409 sur un évènement/heartbeat** (tentative périmée ou tâche plus `in_progress`) :
  l'exécution s'arrête après l'étape en cours, **aucun statut final** n'est envoyé.
- **410** (tâche supprimée côté serveur) sur un évènement, le contrôle, le heartbeat, le
  claim ou le final : la tâche est **abandonnée immédiatement** et toute mise à jour en
  attente pour elle est oubliée.
- **Anti double exécution** (`agent/.pending_updates.json`) :
  - final non accepté (réseau, 5xx, 401…) : persisté et renvoyé avec backoff. Tant qu'un
    final est en attente, la tâche reste **en finalisation** : l'agent lui envoie un heartbeat
    et **ne prend aucune nouvelle tâche** ;
  - si le serveur ne considère plus la tâche comme la nôtre (409) ou après ~10 min d'échec,
    le résultat est conservé 24 h : si la tâche revient au poll, l'agent la réclame et
    **renvoie ce résultat sans la ré-exécuter** (`result.final_replayed = true`) ;
  - final **rejeté** (400/404…) : remplacé par un final `failed` minimal
    (`result.final_rejected = true`, `artifacts` = fichiers produits).
- **Délai par étape** (`SOULBAH_STEP_TIMEOUT`, 900 s par défaut, étendu pour les skills
  longs par nature : montage, commandes) : au-delà, l'étape échoue et la tâche s'arrête.
  Un heartbeat sans progression finit par s'arrêter : une tâche bloquée ne reste pas vivante.
- **Annulation par tâche** : chaque étape reçoit son propre jeton d'annulation (`CancelToken`).
  Un skill bloqué abandonné ne peut ni être « ré-armé » ni perturber la tâche suivante.
- **Pause / stop** : lus entre les étapes, et toutes les 3 s pendant une étape longue
  (`wait`, enregistrements, commandes, rendu Resolve s'interrompent proprement). En pause :
  une lecture toutes les 2 s, un seul évènement (+ un rappel par minute) ; une **erreur de
  lecture pendant la pause ne relance pas** l'exécution.
- **Ctrl+C** : interrompt la tâche en cours (étape annulée, final `cancelled`, une
  confirmation en attente est refusée), puis arrête l'agent. Un second Ctrl+C force l'arrêt.
- **Clé révoquée** : 401/403 sont diagnostiqués « clé agent révoquée ou invalide » (et non
  « backend injoignable ») ; après 3 refus consécutifs, l'agent s'arrête (code 3).
- **Enregistrements en arrière-plan** toujours finalisés (fin de tâche + `atexit`).
- **Backoff du poll** (plafond 60 s) quand le backend est injoignable.
- Journal console + fichier tournant `agent/logs/agent.log` (1 Mo × 5).

## Skills

| Skill | Types d'étape | Catégorie | Contrôle |
|---|---|---|---|
| `open_app` | `open_app`, `open_software`, `launch` | app_launch | allowlist d'applis, entrée* |
| `screenshot` | `screenshot`, `capture` | screen | `path` facultatif : whitelist + `.png` ; voir « Captures » |
| `type_text` | `type_text`, `type`, `keyboard` | keyboard | entrée*, fenêtre cible vérifiée (S3) |
| `hotkey` | `hotkey`, `press`, `key` | keyboard | entrée*, touches validées, raccourcis à risque confirmés |
| `mouse` | `mouse`, `click`, `move_mouse`, `drag`, `scroll`, `double_click`, `right_click` | mouse | entrée*, paramètres numériques validés |
| `window` | `window`, `focus_window`, `minimize_window`, `maximize_window`, `close_window` | window | entrée*, titre exact/regex, ambiguïté refusée |
| `wait` | `wait`, `sleep` | generic | non sensible (≤ 300 s, interruptible) |
| `move_file` | `move_file`, `move` | filesystem | whitelist + deny-list |
| `file_ops` | `write_file`, `read_file`, `list_dir`, `make_dir` | filesystem | whitelist + deny-list |
| `run_command` | `run_command`, `run_script`, `shell` | shell | allowlist stricte + **confirmation toujours** |
| `record_screen` | `record_screen`, `start_recording` | video | whitelist, `.mp4`/`.avi` |
| `start_recording_bg` / `stop_recording_bg` | idem | video | whitelist, `.mp4`/`.avi` |
| `edit_video` | `edit_video`, `montage` | video | whitelist, sortie `.mp4` vérifiée, audio conservé |
| `resolve_montage` | `resolve_montage` | video | whitelist, sortie `.mp4` vérifiée (voir `INSTALLER_DAVINCI_RESOLVE.md`) |
| `phone_list_devices` | `phone_list_devices` | phone | lecture seule |
| `phone` | `phone_tap`, `phone_swipe`, `phone_type`, `phone_key`, `phone_open_app`, `phone_screenshot` | phone | entrée*, ADB, valeurs validées/échappées |

\* *entrée* : souris/clavier/fenêtres/applis/**téléphone** — confirmation exigée même en mode
`auto`, sauf pré-autorisation explicite (`--allow-input-control`) ; les actions **à risque**
restent confirmées même pré-autorisées (voir « Contrôle d'entrée »).

Détails utiles :
- **`hotkey`** : `"keys": "Ctrl+S"` ou `["ctrl", "s"]` envoie exactement ctrl+s (touches
  normalisées en minuscules, alias FR/EN : `entrée`, `échap`, `suppr`, `cmd`→`win`…).
  Une touche inconnue est une **erreur de validation**.
- **`mouse`** : `x`/`y` doivent être des **nombres** (jamais une chaîne : pyautogui
  chercherait une image à partir d'un fichier) ; `button` ∈ left/right/middle ; `clicks` 1–3.
- **`window`** : `match` = `contains` (défaut pour focus/minimize/maximize), `exact` (défaut
  et obligatoire pour `close`, avec `regex`), ou `regex` (explicite). Si plusieurs fenêtres
  correspondent, l'action est **refusée** (« fenêtre ambiguë »).
- **`type_text`** : `method` = `clipboard` (défaut), `unicode` (Windows, SendInput, sans
  presse-papier) ou `typewrite` ; `window_title` facultatif (fenêtre attendue). Le
  presse-papier précédent est **sauvegardé puis restauré** après le collage, et le texte
  collé est exclu de l'historique Win+V et du cloud. Si le presse-papier contient autre
  chose que du texte (image, fichiers, HTML…), il n'est pas touché : saisie `unicode`.
- **Enregistrement** (`record_screen`, `start/stop_recording_bg`) : cadence constante calée
  sur l'horloge réelle (images dupliquées si la capture est lente) → la durée de la vidéo
  correspond au temps réel ; le fps réellement capturé est renvoyé (`capture_fps`). Codec
  H.264 (`avc1`) si OpenCV le fournit, sinon `mp4v` avec un avertissement. `monitor` :
  1 = écran principal (défaut), 0 = tous les écrans. `start_recording_bg` **échoue** si le
  fichier ne peut pas être créé (dossier absent, codec…) au lieu d'annoncer un démarrage.
- **`edit_video`** : l'audio des clips est conservé (AAC) ; l'export est vérifié par une sonde.
- **`resolve_montage`** : aucun faux succès (statut du job « Complete », fichier présent,
  récent, non vide et décodable), narration posée au début d'une piste audio dédiée et
  ses erreurs font échouer l'étape, exécution idempotente (timeline et rendu uniques,
  remplacement atomique de la sortie).

## Modes

| Mode | Effet |
|---|---|
| `confirm` (défaut) | Confirmation `[o/N]` avant chaque action sensible. Sans réponse en `SOULBAH_CONFIRM_TIMEOUT` s (120) : **refus**. Sans console : refus. |
| `auto` (`--auto`) | Pas de confirmation pour fichiers/vidéo/captures (toujours bornés par la whitelist et la deny-list). **`run_command`, les actions d'entrée et le téléphone restent confirmés.** |
| `--allow-input-control` | Pré-autorise souris/clavier/fenêtres/applis/téléphone (pas `run_command`), **sauf actions à risque**. |
| `--dry-run --plan plan.json` | Simule un **plan local** : aucune tâche n'est réclamée au serveur, aucune action n'est exécutée, le rapport (JSON sur la sortie standard) porte `simulated: true`. `--plan` seul implique `--dry-run`. |

Les confirmations affichent le **contenu complet**, sur la console locale uniquement :
texte à taper, contenu à écrire (en entier jusqu'à 2000 caractères, sinon le début, avec
taille et sha256), commande complète avec son `cwd` et ce qu'elle exécute. Une action
**L3** (risquée/irréversible : `npm install` avec scripts, `git branch -d`) exige de taper
`confirmer` au lieu de `o`.

## Modèle de sécurité

- **Workspace** (`SOULBAH_ALLOWED_DIRS`, défaut `%USERPROFILE%\SoulbahWorkspace`, créé au
  besoin) : tout chemin (`path`, `src`, `dest`, `cwd`, `output`, `audio`, `clips`) est résolu
  (`realpath`, insensible à la casse sous Windows) et doit s'y trouver. **L'agent refuse de
  démarrer** si un dossier autorisé contient le dossier de l'agent ou le dépôt SoulBah, ou
  se trouve à l'intérieur du dépôt.
- **Deny-list permanente** (même dans le workspace, même en mode auto) : code et config de
  l'agent et tout le dépôt SoulBah, fichiers `.env` / `*.env` / `.env.*`, dossiers `.ssh` /
  `.gnupg`, clés privées (`id_rsa*`, `id_ed25519*`, `*.pem`, `*.key`, `*.ppk`, `*.p12`,
  `*.pfx`), tout dossier `.git` (hooks compris) et tout dossier qui **est** un dépôt git
  (dépôt nu, `--separate-git-dir`).
- **TOCTOU** : les chemins sont revalidés **juste avant l'exécution** (après la confirmation) :
  un lien/jonction remplacé entre-temps est refusé.
- **`run_command`** : aucun shell ; `cwd` obligatoire dans le workspace ; programmes et
  sous-commandes en allowlist fermée :
  - `git` : `status | diff | log | show | branch | add | commit | init` — jamais d'option
    globale, ni `-c`/`-C`/`--config*`/`--git-dir`/`--exec-path`/`--upload-pack`…, ni
    `--separate-git-dir`/`--template`/`--output` (même **abrégées** : `--sep=`…) ;
    `branch -D` / `--force` / `-M` refusés, `branch -d` = L3 ; `init` : `-q`, `-b <branche>`,
    un dossier du workspace ; arguments visant un `.env`, une clé ou `.git` refusés
    (`git add .env`, `git show HEAD:.env`). Chaque commande git est lancée avec
    `-c core.hooksPath=/dev/null -c core.fsmonitor=false -c safe.bareRepository=explicit` :
    aucun hook, fsmonitor ou dépôt nu implicite ne peut exécuter de code.
  - `npm` : `test | ci | install` (sans argument) | `run <script>`. `install`/`ci` reçoivent
    `--ignore-scripts`, sauf `"allow_scripts": true` dans l'étape (confirmation **L3**).
    La confirmation montre les lignes `pre<script>`/`<script>`/`post<script>` de `package.json`.
  - `python`/`python3` : `<script.py> [args]` ; `node` : `<script.js|.mjs|.cjs> [args]` —
    script dans le workspace, aucune option `-c/-e/-m/-r/-p/-i/--eval/--require/--import…`
    (même collée ou avec `=`). La confirmation montre le début du script et son sha256.
    `python3` n'est jamais résolu vers le raccourci Microsoft Store (WindowsApps) : le vrai
    `python.exe` est utilisé, sinon erreur explicite.
  - `pytest` : chemins de tests (workspace) + options de lecture (`-q -v -x -k --maxfail --tb…`).
    La confirmation liste les `conftest.py` (code exécuté) et les `addopts` de configuration.
  - `npx`, `pip`, `pnpm`, `yarn`, shells… : **refusés**.
  - Tout argument ressemblant à un chemin (absolu, `..`, séparateur, y compris
    `--opt=valeur` et `-Fvaleur`) doit se résoudre dans le workspace, hors deny-list.
  - Délai (`timeout`, 120 s par défaut, 600 max) ou arrêt : **tout l'arbre de processus**
    est tué (Job Object Windows « kill on close », filet `taskkill /T /F`) — plus de
    `node.exe` survivant à `npm.cmd`.
- **`open_app`** : nom simple uniquement (aucun séparateur, guillemet ni métacaractère
  `& | < > ^ % ! ( ) ; ,`…), allowlist (défaut + `SOULBAH_ALLOWED_APPS`), shells et hôtes
  de script interdits ; résolution vers un `.exe` absolu (table connue, `PATH` sans le
  dossier courant, registre *App Paths*) ; lancement direct sans `cmd /c start`.
- **ADB** : `device_id`, `keycode`, `package` validés par motif ; coordonnées numériques ;
  texte échappé pour le shell du téléphone.
- **Textes masqués** : le texte tapé (`type_text`, `phone_type`) et le contenu écrit
  (`write_file`) sont remplacés par `[texte masqué : N car.]` dans les journaux, les
  évènements et les résultats. Ils ne sont visibles que sur la console locale, au moment
  de la confirmation.
- **Clé validée par hash** côté backend (table `agent_keys`) ; `poll`/`update`/`event`
  sont scopés par l'utilisateur de la clé. Révocable depuis la page Sécurité.
- L'agent n'a que les droits de l'utilisateur qui le lance.

### Contrôle d'entrée = exécution de code (S3)

Piloter clavier et souris permet d'ouvrir un terminal et d'y taper des commandes. Même avec
`--allow-input-control`, l'agent **redemande confirmation** pour :
- les raccourcis avec la touche Windows (Win+R, Win+X, menu Démarrer…), `ctrl+shift+esc`
  (gestionnaire des tâches), `ctrl+alt+suppr`, `` ctrl+` `` / `` ctrl+shift+` `` /
  `ctrl+shift+c` (terminaux VS Code), `ctrl+shift+p` et `F1` (palettes de commandes),
  `alt+F2` et `ctrl+alt+t` (Linux) ;
- `type_text` quand la fenêtre au premier plan est **inconnue** : terminal ou hôte de
  commandes (cmd, PowerShell, Windows Terminal…), Explorateur / boîte « Exécuter »,
  application hors allowlist `open_app`, fenêtre non identifiable, ou fenêtre qui ne
  correspond pas au `window_title` demandé.

Risque résiduel documenté : un clic souris pré-autorisé peut atteindre n'importe quelle
fenêtre, et une saisie dans VS Code peut viser son terminal s'il a déjà le focus.

### Captures d'écran (S17)

L'image de l'écran quitte le poste (backend, LLM évaluateur). En mode `confirm`, une
capture est donc confirmée, **sauf** dans une tâche planifiée par le serveur à partir d'un
objectif de l'utilisateur (`payload.goal_meta` présent), où les captures font partie de la
boucle Observer prévue. En mode `auto`, elles ne sont pas confirmées.

## Installation

```bash
cd agent
python -m venv .venv
# Windows : .venv\Scripts\activate    |    Unix : source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env          # puis renseignez vos valeurs
```

Ou, depuis la racine du dépôt : `powershell -ExecutionPolicy Bypass -File scripts\setup_venvs.ps1 -Target agent`.

Sous Windows, `Lancer_Agent.bat` utilise **`agent\.venv`** : il le crée au premier
lancement (avec le lanceur `py -3` ou `python`, jamais le raccourci Microsoft Store),
installe `requirements.txt` si les dépendances manquent, puis démarre l'agent en mode
`confirm`. Les arguments sont transmis (`Lancer_Agent.bat --auto`).

**Migration LOT 1** : si `SOULBAH_ALLOWED_DIRS` pointait vers le dépôt SoulBah (ou un
dossier parent), l'agent refuse désormais de démarrer. Laissez la variable vide pour
utiliser `%USERPROFILE%\SoulbahWorkspace`, ou indiquez un dossier dédié hors du dépôt.

## Utilisation

```bash
python soulbah_agent.py --dry-run --plan plan.json   # simule un plan local, aucune tâche serveur
python soulbah_agent.py --once        # un seul cycle de poll
python soulbah_agent.py               # boucle continue, confirmation avant chaque action sensible
python soulbah_agent.py --auto        # moins de confirmations — à vos risques
```

Codes de sortie : 0 = arrêt normal ; 1 = plan simulé avec au moins une étape refusée ;
2 = configuration refusée (workspace, plan illisible, dry-run sans plan) ;
3 = clé agent révoquée ou invalide ; 130 = arrêt forcé (second Ctrl+C).

## Variables d'environnement

| Variable | Défaut | Rôle |
|---|---|---|
| `SOULBAH_API_URL` | `http://localhost:3000` | Backend Node |
| `SOULBAH_AGENT_KEY` | — (obligatoire, sauf `--dry-run`) | Clé `x-agent-key` (page Sécurité) |
| `SOULBAH_POLL_INTERVAL` | `5` | Intervalle de poll (s) |
| `SOULBAH_PERMISSION_MODE` | `confirm` | `confirm` ou `auto` |
| `SOULBAH_DRY_RUN` | `false` | Simulation : exige `--plan`, ne réclame jamais de tâche |
| `SOULBAH_ALLOWED_DIRS` | `%USERPROFILE%\SoulbahWorkspace` | Workspace, dossiers séparés par `;` (Windows) / `:` — hors du dépôt SoulBah |
| `SOULBAH_ALLOW_INPUT_CONTROL` | `false` | Pré-autorise souris/clavier/fenêtres/applis/téléphone (actions à risque toujours confirmées) |
| `SOULBAH_ALLOWED_APPS` | (vide) | Applis supplémentaires pour `open_app` (noms, virgules) ; aussi fenêtres cibles connues pour `type_text` |
| `SOULBAH_STEP_TIMEOUT` | `900` | Délai max d'une étape (s) |
| `SOULBAH_CONFIRM_TIMEOUT` | `120` | Délai de réponse à une confirmation (s), puis refus |
| `SOULBAH_NO_DOTENV` | (vide) | `1` = ne pas charger `agent/.env` (tests hermétiques) |
| `RESOLVE_SCRIPT_API` / `RESOLVE_SCRIPT_LIB` | chemins Resolve par défaut | Scripting DaVinci Resolve |

## Format d'une tâche

```json
{
  "title": "Démo VS Code",
  "steps": [
    { "type": "open_software", "software": "vscode" },
    { "type": "wait", "seconds": 3 },
    { "type": "type_text", "text": "console.log('hello')", "window_title": "Visual Studio Code" },
    { "type": "hotkey", "keys": "ctrl+s" },
    { "type": "run_command", "program": "git", "args": ["status"], "cwd": "C:\\Users\\...\\SoulbahWorkspace\\app" },
    { "type": "screenshot", "path": "C:\\Users\\...\\SoulbahWorkspace\\demo.png" }
  ]
}
```

Un plan sans étape est refusé (`failed`, `result.empty_plan = true`). Le même format (ou
une simple liste d'étapes) sert de fichier `--plan` pour le dry-run.

Ajouter un type d'action = ajouter un skill dans `skills/` (avec `validate()` pour ses
règles de sécurité, `describe()` **sans texte en clair**, et si besoin `confirm_details()`,
`confirm_level()`, `input_risk()`) et l'enregistrer dans `skills/__init__.py`. Les skills
longs consultent `current_token()` (jeton d'annulation de l'étape).

## Tests

```bash
pip install pytest
SOULBAH_NO_DOTENV=1 python -m pytest -q tests       # PowerShell : $env:SOULBAH_NO_DOTENV='1'
```

Les tests sont **hermétiques** : `tests/conftest.py` pose `SOULBAH_NO_DOTENV=1`, le vrai
`agent/.env` n'est jamais chargé. Ils n'agissent pas sur l'écran : validateurs, gate,
executor avec skills factices, faux serveur reproduisant les gardes de node (double
exécution, 409/410, clé révoquée), presse-papier simulé. Quelques tests utilisent de vrais
processus inoffensifs (arbre python tué au délai, hook git jamais exécuté via l'agent,
montage moviepy, capture d'écran de 2 s).

## Structure
```
agent/
├── soulbah_agent.py     # boucle principale, claim/heartbeat/409/410, finalisation, dry-run local, Ctrl+C
├── config.py            # chargement .env (SOULBAH_NO_DOTENV), workspace par défaut
├── client.py            # HTTP vers /api/agent-tasks (attempt ; issues ok/409/410/401/retry/rejet)
├── pending.py           # outbox des finals + registre de rejeu (.pending_updates.json)
├── permissions.py       # gate (workspace, deny-list, validation, confirmations, approbations, TOCTOU)
├── executor.py          # étapes avec délai, jetons d'annulation, pause/stop, plan vide, simulation
├── skills/              # 17 skills + base.py (contrat, CancelToken, masquage), safety.py (deny-list),
│                        # proctree.py (arbre de processus), recording.py, media_probe.py, desktop.py
└── tests/               # suite pytest
```
