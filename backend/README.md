# SOULBAH IA — Backend polyglotte

Architecture microservices auto-hébergée : API web (`frontend/`), agent local Windows (`agent/`),
console de test (`backend/console/`). node-api est le **plan de contrôle** (auth, file des tâches agent,
évaluation, mémoire, base de connaissances) ; python-ia est le **seul routeur de modèles**.

## 🏗️ Architecture

```
  Clients : web React · agent local · Flutter
                 │  HTTP / JSON (REST)
                 ▼
        ┌─────────────────────┐
        │  Node.js (Fastify)  │   API principale — port 3000
        │  = passerelle / BFF │   auth, routage, persistance
        └──────────┬──────────┘
             │            │
             ▼            ▼
   ┌──────────────┐   ┌──────────────┐
   │  Python IA   │   │ PostgreSQL   │   port 5432
   │  (FastAPI)   │   │  (données)   │
   │  port 8000   │   └──────────────┘
   └──────┬───────┘
          │  HTTP / JSON
          ▼
   ┌──────────────┐
   │ Rust (Axum)  │   calculs intensifs — port 8080
   │ port 8080    │   CPU-bound (statistiques, crible…)
   └──────────────┘
```

### Rôle de chaque service

| Service | Techno | Port | Responsabilité |
|---|---|---|---|
| **node-api** | Node.js 22 + Fastify 5 + TypeScript (compilé en `dist/`) | 3000 | Point d'entrée unique des clients. Validation, file des tâches agent, orchestration, accès Postgres (Supabase), appel du service IA. |
| **python-ia** | Python 3.12 + FastAPI | 8000 | Inférence / traitement IA. Délègue les calculs lourds à Rust. |
| **rust-compute** | Rust + Axum + Tokio | 8080 | Calculs numériques intensifs (CPU-bound), isolés pour la performance. |
| **postgres** | PostgreSQL 16 | 5432 | Stockage relationnel persistant. |

> **Pourquoi ce découpage ?** Node gère bien les I/O et sert d'interface. Python a l'écosystème IA. Rust exécute les calculs coûteux sans bloquer le reste. Postgres persiste. Chaque service peut scaler indépendamment.

## 🚀 Démarrage

Pré-requis : **Docker** + **Docker Compose**.

```bash
cd backend
cp .env.example .env        # optionnel, des valeurs par défaut existent
docker compose up --build
```

Au premier lancement, Docker construit 3 images (python-ia, node-api, console ; postgres est l'image
officielle). `rust-compute` (démo gelée) n'est construit et lancé qu'avec le profil `demo` :
`docker compose --profile demo up --build` (le build Rust prend alors quelques minutes). Ensuite tout
démarre dans le bon ordre grâce aux `depends_on` / `healthcheck`.

## 🔌 Endpoints (exposés par node-api)

Auth : **JWT** = `Authorization: Bearer <access_token Supabase>` (vérifié via `/auth/v1/user`, mis en
cache 15 s, invalidé par `POST /api/auth/logout`) ; **clé agent** = `x-agent-key: sbk_…` (hash SHA-256
en base, `user_id` déduit de la clé). Toutes les données sont scopées par utilisateur.

| Méthode | Route | Auth | Description |
|---|---|---|---|
| `GET` | `/health` | — | Liveness (sans dépendance) |
| `GET` | `/health/deep` | JWT (public si `SOULBAH_ENV=dev`) | État Postgres + python-ia (`degraded` si l'un est `down`) |
| `POST` | `/api/auth/logout` | Bearer | Oublie le JWT du cache et le révoque sur l'instance jusqu'à son `exp` (à appeler avant `signOut`) |
| `POST` | `/api/analyze` · `GET /api/analyze/:id` | JWT | Démo Node → Python → Rust (lignes rattachées à l'utilisateur) |
| `POST` | `/api/chat` | JWT | Chat streaming SSE ; action `{action, confirmed:true}` (sans `confirmed` : action proposée, rien d'exécuté) |
| `POST` | `/api/generate/formation` · `/api/generate/application` | JWT | Génération (formation : asynchrone, progression `agent_events` avec `data.source='formation'`) |
| `POST` | `/api/formations/:id/video` · `/pdf` | JWT | Vidéo MP4, support PDF |
| `POST` | `/api/formations/:id/demos` | JWT | **501** tant que les démos par gabarit n'existent pas (LOT 11) |
| `POST` | `/api/database` (`{action}`) | JWT | Tables utilisateur (schémas, lignes, migrations) |
| `GET/POST/PATCH/DELETE` | `/api/knowledge`, `/api/knowledge/:id`, `/:id/versions`, `/:id/restore` | JWT | Base de connaissances versionnée (seul écrivain : hash, version, embedding) |
| `GET/POST` | `/api/knowledge-domains` | JWT (POST : admin) | Référentiel de domaines |
| `POST` | `/api/research` · `GET /api/research/status` | JWT | Recherche KB-first (KB → web → synthèse) ; sans web : *finding* non vérifié |
| `POST` | `/api/orchestrator/route` | JWT | Chief Agent (routage / dispatch) ; échec de planification → 4xx/502 `success:false` |
| `POST` | `/api/agent/goal` (`{goal, agent_key_id?}`) | JWT | Objectif → plan validé → tâche agent ciblée |
| `GET/POST/PATCH/DELETE` | `/api/agent/memory[/:id]` · `POST /api/agent/self-improve` | JWT | Mémoire d'exécution (proposée par défaut, validée par l'utilisateur) |
| `GET/POST/DELETE` | `/api/agent-keys[/:id]` | JWT | Clés de l'agent local (= PC ciblables) ; révoquer annule les tâches de ce PC |
| `GET/POST` | `/api/agent-tasks` | JWT | Lister (sans captures) / créer (étapes validées, `agent_key_id?`) |
| `DELETE` | `/api/agent-tasks/:id` | JWT | Supprimer une tâche **terminée** (204 ; 409 si active) |
| `POST` | `/api/agent-tasks/:id/cancel[?scope=goal]` · `/approve` · `/control` | JWT | Annuler (la tâche, ou tout l'objectif avec `scope=goal`) / approuver une correction / pause-reprise-stop |
| `GET` | `/api/agent-tasks/:id/events` · `/screenshot` | JWT | Timeline (sans image) ; dernière capture (mémoire, 10 min) |
| `POST` | `/api/agent-tasks/announce` · `GET /poll` · `POST /update` · `POST /event` · `GET /:id/control` | clé agent | Worker local (contrat : voir `MIGRATION.md`) |
| `GET` | `/media/*` | — | Fichiers produits (MP4/PDF, noms UUID) — `Cache-Control: private`, pas de listing |

Limites : 300 req/min global (par utilisateur, sinon IP — IP réelle derrière un proxy si `TRUST_PROXY`),
20/min sur les routes coûteuses — compteurs **en mémoire de l'instance** (plusieurs instances = limites
multipliées ; un magasin partagé type Redis reste à brancher). Corps 2 Mo ; agent : 3 Mo pour `event`
(une capture base64 ≤ 2 Mo), 15 Mo pour `update` ; captures retirées avant toute écriture en base et
gardées en mémoire bornée (128 Mo au total, 24 Mo / 50 tâches par utilisateur, 10 min). Erreurs 5xx : message générique ; aucun texte d'erreur amont (python-ia,
fournisseur LLM) n'est relayé au client. `provider` imposé par un client : refusé (400) hors
`LLM_ALLOWED_OVERRIDES`.

### Exemple — le flux de bout en bout

```bash
curl -X POST http://localhost:3000/api/analyze \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text": "Cette application est vraiment géniale"}'
```

Réponse type :

```json
{
  "requestId": "b1c9...",
  "label": "positif",
  "score": 0.75,
  "compute": {
    "count": 30,
    "mean": 48.3,
    "std_dev": 27.1,
    "norm": 302.5,
    "primes_under_limit": 9592
  }
}
```

Ce qui s'est passé :
1. **Flutter → Node** : envoi du texte.
2. **Node → Postgres** : insertion d'une ligne `analysis_requests` (status `processing`).
3. **Node → Python** : appel `POST /infer`.
4. **Python → Rust** : appel `POST /compute` pour les statistiques/calculs lourds.
5. **Node → Postgres** : mise à jour avec le résultat (status `done`).
6. **Node → Flutter** : renvoi de la réponse.

## 📱 Côté Flutter

Pointez votre client HTTP sur l'API Node uniquement (les autres services sont internes) :

```dart
// Émulateur Android → l'hôte est 10.0.2.2 ; iOS simulateur → localhost
// La route exige un JWT Supabase (session de l'utilisateur connecté via supabase_flutter).
final token = Supabase.instance.client.auth.currentSession?.accessToken;
final res = await http.post(
  Uri.parse('http://10.0.2.2:3000/api/analyze'),
  headers: {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  },
  body: jsonEncode({'text': input}),
);
```

## 🗂️ Structure

```
backend/
├── docker-compose.yml      # postgres, python-ia, node-api, console (+ rust-compute : profil demo)
├── .env.example
├── README.md
├── node-api/               # API principale (Fastify / TypeScript)
│   └── src/
│       ├── server.ts     # démarrage, minuteurs (reaper, maintenance), arrêt propre
│       ├── app.ts        # buildApp : plugins + enregistrement des routes
│       ├── config.ts
│       ├── db.ts
│       ├── clients/iaClient.ts
│       ├── lib/          # validation & utilitaires purs (testés)
│       ├── services/     # connaissances, recherche, formation, maintenance…
│       └── routes/       # une route par domaine fonctionnel
│   └── test/             # tests vitest
├── python-ia/              # service IA (FastAPI)
│   └── app/{main,config,rust_client}.py
├── rust-compute/           # démo gelée (profil `demo`), calculs CPU (Axum)
│   └── src/main.rs
└── postgres/
    └── init.sql            # Postgres LOCAL de démo uniquement (/api/analyze)

# Schéma réel (Supabase) : supabase/migrations/ à la racine du dépôt.
```

## 🧩 Étendre le backend

- **Nouvelle route Node** : ajoutez un fichier dans `node-api/src/routes/` et enregistrez-le dans `buildApp` (`node-api/src/app.ts`, `app.register(...)`).
- **Vrai modèle IA** : dans `python-ia/app/main.py`, remplacez le placeholder d'`/infer` par votre modèle (transformers, ONNX, appel API…).
- **Nouveau calcul Rust** : ajoutez une route dans `rust-compute/src/main.rs` et appelez-la depuis `python-ia/app/rust_client.py`.
- **Migrations SQL** : le schéma de référence est dans `supabase/migrations/` (racine du dépôt, appliqué par la CLI Supabase) ; `backend/postgres/init.sql` ne sert qu'au Postgres local de démo.

## 🛠️ Développement local (sans Docker)

Chaque service se lance indépendamment :

```bash
# Node (dev : tsx, rechargement à chaud)
cd node-api && npm install && npm run dev
# Node (prod : JS compilé, comme l'image Docker)
cd node-api && npm run build && npm run start:prod   # node dist/server.js

# Python
cd python-ia && .venv/Scripts/python -m uvicorn app.main:app --reload --port 8000   # venv créé par scripts/setup_venvs.ps1

# Rust (démo optionnelle)
cd rust-compute && cargo run
```

Pensez à renseigner les variables d'environnement (`DATABASE_URL`, `IA_SERVICE_URL`, `IA_SERVICE_TOKEN`,
`CORS_ORIGINS`…) pour pointer vers `localhost` au lieu des noms de services Docker — liste commentée dans
`.env.example`. Hors Docker, node-api écoute sur `127.0.0.1` (définir `HOST=0.0.0.0` pour l'exposer).

**`SOULBAH_ENV`** (`dev` par défaut | `test` | `staging` | `production`) : hors `dev`/`test`, node-api
refuse de démarrer sans `IA_SERVICE_TOKEN`, sans `PG_SSL_CA` quand `DATABASE_SSL=true`, avec une base
distante sans `DATABASE_SSL=true`, ou si `DATABASE_URL` contient des paramètres TLS (`sslmode`…, qui
primeraient sur `PG_SSL_CA`) — le contrôle s'exécute avant toute connexion. `/health/deep` n'est public qu'en `dev`.

node-api démarre même si Postgres est injoignable (mode dégradé : `/health` = 200, nouvel essai toutes
les 30 s). Dès que la DB répond :
- contrôle du schéma (colonnes `agent_tasks.target_agent_key_id` / `claimed_by_key_id` de la migration
  `supabase/migrations/20261001090000_lot1_fixes.sql` — erreur journalisée si absentes) ;
- **reaper global** toutes les `REAPER_INTERVAL_SECONDS` (60 s) sous verrou consultatif : tâche
  `in_progress` muette depuis `AGENT_TASK_STALE_SECONDS` → `cancelled` si un stop était demandé, sinon
  remise en file (3 fois max, **en pause** si une étape à effet réel avait déjà été lancée) puis `failed` ;
- maintenance horaire : générations bloquées → `Erreur`, purge des `agent_events` (> 3 jours, images
  héritées retirées), évaluations interrompues, médias non référencés plus vieux que
  `MEDIA_RETENTION_DAYS` (30 j).

Arrêt propre sur SIGINT/SIGTERM : plus de nouvelles requêtes, tâches de fond (évaluations, générations)
attendues jusqu'à 10 s, puis fermeture du pool.

### Tests (node-api)

```bash
cd node-api
npm test            # vitest : 181 tests (unitaires + routes via fastify.inject sur une couche SQL simulée)
npm run typecheck   # tsc --noEmit
npm run build       # tsc -p tsconfig.build.json → dist/
```

`test/agentStepsTable.test.ts` relit `agent/skills/*.py` (lecture seule) et échoue si un skill lit un
paramètre absent de la table `lib/agentSteps.ts` (dérive planner → agent).
`test_rag.ts` est une vérification manuelle live (DB + OpenAI) : `RAG_TEST_USER_ID=<uuid> npx tsx test_rag.ts`.
