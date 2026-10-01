# SoulBah AI

Plateforme d'**assistant IA personnel** : chat multi-fournisseurs, génération de
**formations** (curriculum, PDF, vidéo narrée) et d'**applications**, **base de
connaissances** avec recherche sémantique (pgvector), base de données dynamique, et un
**agent local** capable de piloter le poste de l'utilisateur (ouvrir des logiciels, saisir
du texte, capturer l'écran, enregistrer des démonstrations…) sous son contrôle.

Architecture détaillée et feuille de route : [`docs/SOULBAH_AI_ARCHITECTURE.md`](docs/SOULBAH_AI_ARCHITECTURE.md).

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
                                       │                        agent/ (worker Python sur le poste)
                                       ▼
                                backend/rust-compute (Axum, 8080)
```

| Composant | Dossier | Rôle |
|---|---|---|
| **App web** | `frontend/` (`src/`, `index.html`, `vite.config.ts`) | Interface React/Vite/TypeScript (shadcn-ui, Tailwind) : dashboard, chat, formations, applications, base de connaissances, automatisation, sécurité. |
| **Supabase** | `supabase/` | Authentification (JWT) et Postgres managé : schéma versionné dans `supabase/migrations/`, RLS par `user_id`, Realtime. Plus aucune edge function : tout passe par `backend/node-api`. |
| **API Node** | `backend/node-api` | Point d'entrée unique : vérification des JWT Supabase, accès Postgres, chat streaming, file de tâches de l'agent, orchestration. |
| **Service IA** | `backend/python-ia` | Génération IA sans état (formations, applications, TTS/vidéo, PDF), routeur multi-fournisseurs (Anthropic, OpenAI, Gemini, Mistral…). |
| **Calculs** | `backend/rust-compute` | Calculs CPU intensifs appelés par le service IA. |
| **Agent local** | `agent/` | Worker Python qui s'exécute **sur le poste** : récupère les tâches (`agent_tasks`) et les exécute via des *skills*, avec confirmation. |
| **Console de test** | `backend/console/` | Petite console web de test du backend (`/api/analyze`, `/health/deep`). **Ce n'est pas l'application** — voir [`backend/console/README.md`](backend/console/README.md). |

---

## Prérequis

- **Node.js 20+** et npm
- **Python 3.11+** (service IA et agent)
- Un projet **Supabase** (Auth + Postgres ; l'extension `vector` est activée par les migrations)
- Facultatif : **Docker + Docker Compose** (backend en conteneurs), **Rust** (rust-compute hors Docker),
  **Supabase CLI** (migrations), **outils client PostgreSQL** (`pg_dump` / `psql`, sauvegardes)

---

## Fichiers d'environnement

Chaque `.env` se crée à partir de son `.env.example`. **Ne jamais committer un `.env`** (ignorés par git).

| Fichier | Utilisé par | Contenu principal |
|---|---|---|
| `frontend/.env` | app web | `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, `VITE_SUPABASE_PROJECT_ID`, `VITE_API_URL` (ex. `http://localhost:3000`) |
| `backend/.env` | node-api, python-ia, docker compose | `DATABASE_URL`, `DATABASE_SSL`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, clés des fournisseurs IA (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`…), recherche web, ports |
| `agent/.env` | agent local | `SOULBAH_API_URL`, `SOULBAH_AGENT_KEY`, `SOULBAH_PERMISSION_MODE`, `SOULBAH_ALLOWED_DIRS` |
| `backend/console/.env` | console de test | `VITE_API_URL` |

> Hors Docker, ajoutez dans `backend/.env` : `IA_SERVICE_URL=http://localhost:8000` (sinon Node
> cherche `http://python-ia:8000`, le nom du service Docker) et, pour python-ia,
> `RUST_SERVICE_URL=http://localhost:<port>` si rust-compute tourne.

---

## Lancement en local (sans Docker)

Les commandes ci-dessous sont pour **git-bash** (Windows), Linux ou macOS.

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
python -m venv .venv && source .venv/Scripts/activate   # Linux/macOS : source .venv/bin/activate
pip install -r requirements.txt
set -a && source <(tr -d '\r' < ../.env) && set +a
uvicorn app.main:app --reload --port 8000
```

### 4. Calculs Rust (facultatif)
```bash
cd backend/rust-compute && cargo run
```
⚠️ rust-compute écoute par défaut sur **8080**, comme le serveur de dev Vite : ne lancez pas
les deux sur le même port (ou utilisez Docker pour le backend).

### 5. Agent local (`agent/`)
```bash
cd agent
pip install -r requirements.txt
cp .env.example .env               # SOULBAH_AGENT_KEY : à générer dans l'app, page Sécurité
python soulbah_agent.py --dry-run  # test sans aucune action réelle
```
Sous Windows : double-cliquer sur **`agent/Lancer_Agent.bat`**. Détails : [`agent/README.md`](agent/README.md).

---

## Lancement avec Docker

```bash
cd backend
cp .env.example .env      # renseigner DATABASE_URL, SUPABASE_*, clés IA…
docker compose up --build
```
Démarre `postgres` (Postgres local de démo, 5432), `rust-compute` (8080), `python-ia` (8000),
`node-api` (3000) et la console de test `console` (5173). L'app web principale se lance à
part (`npm run dev` dans `frontend/`). Détails : [`backend/README.md`](backend/README.md).

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
**vide** (une seule transaction). Après l'ajout d'une migration, régénérez-le :
```bash
bash scripts/build_restore_sql.sh
```

### Sauvegardes
Les scripts lisent `DATABASE_URL` dans `backend/.env` (ou `BACKUP_DATABASE_URL`) et écrivent
dans `backups/` (ignoré par git) deux fichiers `soulbah_AAAAMMJJ_HHMM` : `.dump` (format custom)
et `.sql` (texte). Schémas sauvegardés : `public auth` (modifiable via `BACKUP_SCHEMAS`).
```bash
bash scripts/backup_db.sh                                        # git-bash / Linux / macOS
powershell -ExecutionPolicy Bypass -File scripts\backup_db.ps1   # Windows PowerShell
```
`pg_dump` doit être d'une version ≥ à celle du serveur (Windows : `C:\Program Files\PostgreSQL\<v>\bin`,
détecté automatiquement). Le pooler Supabase en mode transaction (port 6543) est remplacé
automatiquement par le mode session (5432), seul compatible avec `pg_dump`.

Restauration d'une sauvegarde (exemple) :
```bash
pg_restore --no-owner --no-privileges --dbname "$DATABASE_URL" backups/soulbah_AAAAMMJJ_HHMM.dump
# ou : psql "$DATABASE_URL" -f backups/soulbah_AAAAMMJJ_HHMM.sql
```

---

## Tests et CI

```bash
cd frontend && npm run lint && npm test && npm run build  # app web
cd backend/node-api && npx tsc --noEmit                   # API Node
python -m compileall -q backend/python-ia/app agent       # Python (syntaxe)
```
La CI GitHub Actions ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) exécute ces
vérifications pour l'app web (Node 20/22), `node-api`, `python-ia` (Python 3.11/3.12, `pytest`
si `tests/` existe) et l'agent (`pytest agent/tests` si présent).

---

## Sécurité

- **Ne jamais committer de `.env`** ni de clé (service role Supabase, clés IA, clé agent).
- **Agent local** : mode `confirm` par défaut (`SOULBAH_PERMISSION_MODE=confirm`) — chaque
  action sensible (clavier, lancement d'application, fichiers) demande une confirmation.
  N'utilisez `--auto` qu'en connaissance de cause. Les opérations fichiers sont limitées à
  `SOULBAH_ALLOWED_DIRS` ; `--dry-run` décrit un plan sans l'exécuter.
- **Clé agent** : générée depuis la page *Sécurité*, stockée côté serveur sous forme de hash
  SHA-256 uniquement, révocable à tout moment ; elle ne donne accès qu'aux tâches de son propriétaire.
- **RLS** : chaque table est filtrée par `user_id`. Les tâches de l'agent ne peuvent être
  créées ou modifiées que via l'API Node (pas d'INSERT/UPDATE direct depuis le navigateur).
- L'agent n'est **pas** distribué par le site web : il s'installe depuis `agent/`.
