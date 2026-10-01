# SoulBah AI

Plateforme d'**assistant IA personnel** : chat multi-fournisseurs, génération de
**formations** (curriculum, PDF, vidéo narrée) et d'**applications**, **base de
connaissances** avec recherche sémantique (pgvector), base de données dynamique, et un
**agent local** capable de piloter le poste de l'utilisateur (ouvrir des logiciels, saisir
du texte, capturer l'écran, enregistrer des démonstrations…) sous son contrôle.

| Document | Contenu |
|---|---|
| [`docs/SOULBAH_AI_ARCHITECTURE.md`](docs/SOULBAH_AI_ARCHITECTURE.md) | Architecture réelle, flux d'une tâche agent, environnements |
| [`docs/SOULBAH_V2_LOT0_AUDIT.md`](docs/SOULBAH_V2_LOT0_AUDIT.md) | Audit LOT 0 : état réel, problèmes T#/S#, cible V2 (§9) et **feuille de route V2 en 15 lots (§13)** |
| [`docs/LOT1_CONTRAT.md`](docs/LOT1_CONTRAT.md) | Contrat commun du LOT 1 (annulation, approbation, ciblage d'un PC, workspace…) |
| [`docs/SUPABASE_REPRISE.md`](docs/SUPABASE_REPRISE.md) | Check-list ordonnée pour réactiver le projet Supabase (actuellement en pause) |

---

## Architecture

```
 Navigateur ── app web (frontend/ : Vite + React + TS, port 8080)
     │ auth Supabase (JWT)             │ REST + JWT (VITE_API_URL)
     ▼                                 ▼
 Supabase ◀──── Postgres ─────── backend/node-api   (Fastify/TS, port 3000)
 (Auth, Postgres, RLS, Realtime)       │ HTTP interne                ▲
                                       ▼                             │ poll / update (x-agent-key)
                                backend/python-ia (FastAPI, 8000)    │
                                       ┆ (démo facultative)     agent/ (worker Python sur le poste)
                                       ▼
                                backend/rust-compute (Axum, 8080, profil compose `demo`)
```

| Composant | Dossier | Rôle |
|---|---|---|
| **App web** | `frontend/` (`src/`, `index.html`, `vite.config.ts`) | Interface React/Vite/TypeScript (shadcn-ui, Tailwind) : dashboard, chat, formations, applications, base de connaissances, automatisation, sécurité. |
| **Supabase** | `supabase/` | Authentification (JWT) et Postgres managé : schéma versionné dans `supabase/migrations/`, RLS par `user_id`, Realtime. Plus aucune edge function : tout passe par `backend/node-api`. |
| **API Node** | `backend/node-api` | Point d'entrée unique : vérification des JWT Supabase, accès Postgres, chat streaming, file de tâches de l'agent, orchestration. |
| **Service IA** | `backend/python-ia` | Génération IA sans état (formations, applications, TTS/vidéo, PDF), routeur multi-fournisseurs (Anthropic, OpenAI, Gemini, Mistral…). |
| **Démo Rust** | `backend/rust-compute` | Démo `/infer` **gelée**, sans rôle dans la V2 ; lancée seulement avec le profil compose `demo`. |
| **Agent local** | `agent/` | Worker Python qui s'exécute **sur le poste** : récupère les tâches (`agent_tasks`) et les exécute via des *skills*, avec confirmation. |
| **Console de test** | `backend/console/` | Petite console web de test du backend (`/api/analyze`, `/health/deep`). **Ce n'est pas l'application** — voir [`backend/console/README.md`](backend/console/README.md). |

---

## Prérequis

- **Node.js 20+** et npm
- **Python 3.11+** (service IA et agent)
- Un projet **Supabase** (Auth + Postgres ; l'extension `vector` est activée par les migrations)
- Facultatif : **Docker + Docker Compose** (backend en conteneurs), **Rust** (démo rust-compute),
  **Supabase CLI** (migrations), **outils client PostgreSQL** (`pg_dump` / `psql`, sauvegardes),
  **gpg** (fourni avec Git for Windows) ou **age** (chiffrement des sauvegardes)

---

## Fichiers d'environnement

Chaque `.env` se crée à partir de son `.env.example`. **Ne jamais committer un `.env`** (ignorés par git).

| Fichier | Utilisé par | Contenu principal |
|---|---|---|
| `frontend/.env` | app web | `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, `VITE_SUPABASE_PROJECT_ID`, `VITE_API_URL` (ex. `http://localhost:3000`) |
| `backend/.env` | node-api, python-ia, docker compose | `SOULBAH_ENV`, `IA_SERVICE_TOKEN`, `DATABASE_URL`, `DATABASE_SSL`, `PG_SSL_CA`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, clés des fournisseurs IA (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`…), recherche web, ports |
| `agent/.env` | agent local | `SOULBAH_API_URL`, `SOULBAH_AGENT_KEY`, `SOULBAH_PERMISSION_MODE`, `SOULBAH_ALLOWED_DIRS` (défaut : `%USERPROFILE%\SoulbahWorkspace`) |
| `backend/console/.env` | console de test | `VITE_API_URL` |

> Hors Docker, ajoutez dans `backend/.env` : `IA_SERVICE_URL=http://localhost:8000` (sinon Node
> cherche `http://python-ia:8000`, le nom du service Docker) et, pour python-ia,
> `RUST_SERVICE_URL=http://localhost:<port>` si rust-compute tourne.

### Environnement d'exécution : `SOULBAH_ENV`

`SOULBAH_ENV` vaut `dev` (défaut), `test`, `staging` ou `production`. Hors `dev`/`test` :
- node-api et python-ia **refusent de démarrer** sans `IA_SERVICE_TOKEN` ;
- node-api refuse aussi de démarrer sans `PG_SSL_CA` quand `DATABASE_SSL=true`.

| Variable | Rôle |
|---|---|
| `IA_SERVICE_TOKEN` | Jeton partagé node-api → python-ia (en-tête `x-ia-token`), identique des deux côtés. Génération : `python -c "import secrets; print(secrets.token_urlsafe(48))"`. |
| `PG_SSL_CA` | Chemin du certificat CA de Supabase, pour vérifier le certificat du serveur ([`docs/SUPABASE_REPRISE.md`](docs/SUPABASE_REPRISE.md) §9). |

---

## Lancement en local (sans Docker)

Les commandes ci-dessous sont pour **git-bash** (Windows), Linux ou macOS.

### 0. Environnements Python isolés (une fois)
L'agent et python-ia ont des dépendances épinglées différentes : chacun a **son propre venv**,
et rien n'est installé dans le Python global.
```bash
bash scripts/setup_venvs.sh               # crée agent/.venv et backend/python-ia/.venv
# PowerShell : powershell -ExecutionPolicy Bypass -File scripts\setup_venvs.ps1
# Options : agent | python-ia, --no-dev (sans requirements-dev / pytest), --recreate
```

### 1. App web (`frontend/`)
```bash
cd frontend
npm install
cp .env.example .env      # puis renseigner les variables
npm run dev               # http://localhost:8080
```

### 2. API Node (`backend/node-api`)
```bash
cd backend/node-api
npm install
set -a && source <(tr -d '\r' < ../.env) && set +a && npm run start   # http://localhost:3000
```
`tr -d '\r'` neutralise les fins de ligne Windows du `.env`. `npm run dev` = rechargement à chaud.

### 3. Service IA (`backend/python-ia`)
```bash
cd backend/python-ia
source .venv/Scripts/activate            # venv créé à l'étape 0 (Linux/macOS : .venv/bin/activate)
set -a && source <(tr -d '\r' < ../.env) && set +a
python -m uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

### 4. Démo Rust (facultative, gelée)
```bash
cd backend/rust-compute && cargo run
```
⚠️ rust-compute écoute par défaut sur **8080**, comme le serveur de dev Vite : ne lancez pas
les deux sur le même port. Aucune fonctionnalité de l'application n'en dépend.

### 5. Agent local (`agent/`)
```bash
cd agent
cp .env.example .env    # SOULBAH_AGENT_KEY : à générer dans l'app, page Sécurité
.venv/Scripts/python soulbah_agent.py --dry-run --plan mon_plan.json   # simulation d'un plan LOCAL
.venv/Scripts/python soulbah_agent.py                                   # agent réel (mode confirm)
```
- **Workspace** : sans `SOULBAH_ALLOWED_DIRS`, l'agent travaille dans
  `%USERPROFILE%\SoulbahWorkspace`, créé au besoin. Il refuse de démarrer si un dossier
  autorisé contient le dossier de l'agent ou le dépôt SoulBah.
- **Fichiers toujours refusés** : code et config de l'agent, `*.env`, `.ssh`, clés privées,
  `.git/hooks`.
- **`--dry-run`** ne réclame aucune tâche au serveur : il simule un plan local et marque son
  résultat `simulated`.
- **Lanceur Windows** : `agent/Lancer_Agent.bat` doit utiliser `agent\.venv` (T52, chantier
  agent). En attendant, lancer avec le Python du venv comme ci-dessus.

Détails : [`agent/README.md`](agent/README.md).

### Contrôle des tâches de l'agent (contrat LOT 1)
| Action | API (JWT, propriétaire) | Effet |
|---|---|---|
| Choisir le PC | `agent_key_id` dans `POST /api/agent/goal` ou `POST /api/agent-tasks` | La tâche n'est distribuée qu'à cet agent. Une seule clé active : ciblée d'office. Plusieurs clés sans choix : 400 avec la liste des agents. |
| Annuler | `POST /api/agent-tasks/:id/cancel` | Une tâche `pending` passe en `cancelled`. Une tâche `in_progress` reçoit `control='stop'` : l'agent finit l'étape puis envoie `cancelled`. Une tâche annulée n'est jamais évaluée. |
| Approuver une correction | `POST /api/agent-tasks/:id/approve` | Les corrections proposées par l'évaluateur attendent l'approbation (`awaiting_approval`) avant d'être distribuées. Les rejeter, c'est les annuler (`/cancel`). |
| Confirmer une action | console de l'agent | L'événement `approval_required` s'affiche dans le cockpit (« En attente de confirmation sur le PC »). |

---

## Lancement avec Docker

```bash
cd backend
cp .env.example .env      # renseigner DATABASE_URL, SUPABASE_*, clés IA…
docker compose up --build
```
Démarre `postgres` (Postgres local de démo), `python-ia` (interne), `node-api` et la console de
test `console`. **Tous les ports publiés sont liés à `127.0.0.1`** : `5432` (postgres),
`${NODE_API_PORT:-3000}` (node-api) et `${CONSOLE_PORT:-5173}` (console). Rien n'est joignable
depuis le réseau local. `SOULBAH_ENV` (défaut `dev`) et `IA_SERVICE_TOKEN` sont transmis à
node-api et à python-ia.

La démo Rust n'est lancée qu'à la demande : `docker compose --profile demo up --build`.
L'app web principale se lance à part (`npm run dev` dans `frontend/`). Détails :
[`backend/README.md`](backend/README.md).

---

## Base de données

Le schéma est versionné dans **`supabase/migrations/`** (source de vérité).

**Appliquer les migrations** (recommandé) :
```bash
supabase link --project-ref <ref>
supabase db push
```

**Restaurer sur un projet neuf** : [`RESTAURATION_BASE.sql`](RESTAURATION_BASE.sql) est la
concaténation de toutes les migrations, à exécuter dans *Supabase > SQL Editor* sur un projet
**vide**, en une seule transaction. Ne **jamais** l'exécuter sur le projet existant. Après
l'ajout d'une migration, régénérez-le (la CI vérifie qu'il est à jour) :
```bash
bash scripts/build_restore_sql.sh
```

**Règles des migrations** (audit LOT 0 §12) :
- migrations additives et idempotentes : `IF NOT EXISTS`, `DROP POLICY IF EXISTS` puis
  `CREATE`, contraintes `NOT VALID` puis `VALIDATE` tentée ;
- jamais de modification du CHECK de statut d'`agent_tasks`, jamais de FK sur
  `agent_events.task_id`, jamais de suppression de `modules_status`.

Toutes les migrations depuis `20260703000000` sont rejouables.

**Valider les migrations en local** sur un Postgres **jetable** (sans pgvector : DDL
vectoriel remplacé par un stub) :
```bash
export PGHOST=127.0.0.1 PGPORT=55432 PGUSER=postgres PGDATABASE=soulbah_ci   # base jetable
bash scripts/ci/apply_migrations.sh --stub-vector --checks
```
Le script :
- installe le stub Supabase (`scripts/ci/auth_stub.sql`) ;
- applique toutes les migrations, puis rejoue celles qui sont rejouables ;
- vérifie que le schéma est identique après le rejeu ;
- lance les assertions de `scripts/ci/schema_checks.sql`, dans une transaction annulée.

Il refuse de tourner sur une base Supabase réelle.

**Reprise du projet Supabase** (en pause) : suivre [`docs/SUPABASE_REPRISE.md`](docs/SUPABASE_REPRISE.md),
dans l'ordre : sauvegarde, épinglage de la CI, `db push`, edge functions, secrets, rôle
`soulbah_api`.

### Sauvegardes
Les scripts lisent `DATABASE_URL` dans `backend/.env` (ou `BACKUP_DATABASE_URL`) et écrivent
deux fichiers `soulbah_AAAAMMJJ_HHMM` dans `backups/` (ignoré par git, ou `BACKUP_DIR`) :
`.dump` (format custom) et `.sql` (texte). Schémas sauvegardés : `public auth` (modifiable
via `BACKUP_SCHEMAS`). Le mot de passe n'apparaît **jamais** sur la ligne de commande : il
passe par un fichier pgpass temporaire, supprimé en fin de script.

**Chiffrement**, recommandé car le dump contient toutes les données : définir l'une des
variables ci-dessous. Les fichiers en clair sont alors supprimés après chiffrement.

| Variable | Outil | Fichiers produits |
|---|---|---|
| `BACKUP_AGE_RECIPIENT=age1…` | `age` | `.age` |
| `BACKUP_GPG_RECIPIENT=<clé>` | `gpg` (clé publique) | `.gpg` |
| `BACKUP_GPG_PASSPHRASE_FILE=<fichier hors dépôt>` | `gpg`, AES256 symétrique | `.gpg` |
```bash
bash scripts/backup_db.sh                                        # git-bash / Linux / macOS
powershell -ExecutionPolicy Bypass -File scripts\backup_db.ps1   # Windows PowerShell
```
`pg_dump` doit être d'une version ≥ à celle du serveur (Windows : `C:\Program Files\PostgreSQL\<v>\bin`,
détecté automatiquement). Le pooler Supabase en mode transaction (port 6543) est remplacé
automatiquement par le mode session (5432), seul compatible avec `pg_dump`.

Restauration d'une sauvegarde (exemple) :
```bash
gpg -o soulbah.dump -d backups/soulbah_AAAAMMJJ_HHMM.dump.gpg     # si chiffrée (age : age -d -i clé.txt …)
pg_restore --no-owner --no-privileges --dbname "$DATABASE_URL" soulbah.dump
# ou : psql "$DATABASE_URL" -f soulbah.sql
```

---

## Tests et CI

```bash
cd frontend && npm run lint && npx tsc --noEmit -p tsconfig.app.json && npm test && npm run build
cd backend/console && npm run build                         # console de test (tsc + vite)
cd backend/node-api && npx tsc --noEmit && npm test && npm run build
cd backend/python-ia && .venv/Scripts/python -m pytest tests -q
SOULBAH_NO_DOTENV=1 agent/.venv/Scripts/python -m pytest agent/tests -q   # n'utilise jamais agent/.env
```

La CI GitHub Actions ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) comprend 8 jobs :

| Job | Contenu |
|---|---|
| `frontend` | Node 20 et 22. |
| `console` | Console de test. |
| `node-api` | Typage, tests, build. |
| `python-ia` | Python 3.11 et 3.12, dans un venv. |
| `agent` | Runner **windows-latest**. |
| `db` | Image `pgvector/pgvector` : migrations ×2, comparaison de schéma, assertions de policies et de triggers, `RESTAURATION_BASE.sql` à jour. Image à épingler sur la version de Supabase. |
| `compose` | `docker compose config`, avec et sans le profil `demo`. |
| `security` | `npm audit --omit=dev`, `pip-audit` (bloquant pour les dépendances de prod) et gitleaks sur tout l'historique. |

Plancher de non-régression : agent 156, python-ia 55, node-api 38, front 48 tests.

---

## Sécurité

- **Ne jamais committer de `.env`** ni de clé (service role Supabase, clés IA, clé agent).
- **Agent local** :
  - mode `confirm` par défaut (`SOULBAH_PERMISSION_MODE=confirm`) : chaque action sensible
    (clavier, lancement d'application, fichiers) demande une confirmation. N'utilisez
    `--auto` qu'en connaissance de cause.
  - Les opérations fichiers sont limitées au workspace (`%USERPROFILE%\SoulbahWorkspace` par
    défaut, jamais le dépôt) et soumises à une deny-list permanente.
  - Les textes saisis sont masqués dans les logs et les événements.
- **Clé agent** :
  - générée depuis la page *Sécurité* (via `POST /api/agent-keys`), stockée côté serveur
    sous forme de hash SHA-256 uniquement, révocable à tout moment ;
  - le navigateur ne peut que lire et supprimer ses clés (RLS) ;
  - une clé ne donne accès qu'aux tâches de son propriétaire, et à celles qui lui sont
    ciblées.
- **RLS** : chaque table est filtrée par `user_id`.
  - Les tâches de l'agent ne peuvent être créées ou modifiées que via l'API Node (pas
    d'INSERT/UPDATE direct depuis le navigateur).
  - Les INSERT vérifient aussi la propriété de la ligne parente (conversation, entrée de
    connaissance, schéma).
  - **Limite actuelle** : node-api se connecte en `postgres` et contourne la RLS (il filtre
    lui-même par utilisateur). Le passage à un rôle dédié de moindre privilège
    (`soulbah_api`) est décrit dans [`docs/SUPABASE_REPRISE.md`](docs/SUPABASE_REPRISE.md) §10.
- **Exposition** : node-api écoute sur `127.0.0.1` par défaut, et les ports Docker sont liés à
  `127.0.0.1`. Hors `dev`/`test`, le jeton `IA_SERVICE_TOKEN` est obligatoire.
- **Secrets dans git** : la CI lance gitleaks sur tout l'historique. Seule la clé anon
  Supabase historique, publique par conception, est tolérée (`.github/.gitleaksignore`).
- L'agent n'est **pas** distribué par le site web : il s'installe depuis `agent/`.
