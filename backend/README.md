# SOULBAH IA — Backend polyglotte

Architecture microservices auto-hébergée pour l'application mobile Flutter.

## 🏗️ Architecture

```
        Flutter (Android / iOS)
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
| **node-api** | Node.js 22 + Fastify 5 + TypeScript | 3000 | Point d'entrée unique pour Flutter. Validation, orchestration, accès Postgres, appel du service IA. |
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

Au premier lancement, Docker construit les 4 images (le build Rust prend quelques minutes). Ensuite tout démarre dans le bon ordre grâce aux `depends_on` / `healthcheck`.

## 🔌 Endpoints (exposés par node-api)

Auth : **JWT** = `Authorization: Bearer <access_token Supabase>` ; **clé agent** = `x-agent-key: sbk_…`
(hash SHA-256 en base, `user_id` déduit de la clé). Toutes les données sont scopées par utilisateur.

| Méthode | Route | Auth | Description |
|---|---|---|---|
| `GET` | `/health` | — | Liveness (sans dépendance) |
| `GET` | `/health/deep` | — | État Postgres + python-ia (`degraded` si l'un est `down`) |
| `POST` | `/api/analyze` · `GET /api/analyze/:id` | JWT | Démo Node → Python → Rust (lignes rattachées à l'utilisateur) |
| `POST` | `/api/chat` | JWT | Chat streaming SSE (+ exécution d'actions `{action}`) |
| `POST` | `/api/generate/formation` · `/api/generate/application` | JWT | Génération (formation : asynchrone, progression temps réel) |
| `POST` | `/api/formations/:id/video` · `/pdf` · `/demos` | JWT | Vidéo MP4, support PDF, démos pour l'agent |
| `POST` | `/api/database` (`{action}`) | JWT | Tables utilisateur (schémas, lignes, migrations) |
| `GET/POST/PATCH/DELETE` | `/api/knowledge`, `/api/knowledge/:id`, `/:id/versions`, `/:id/restore` | JWT | Base de connaissances versionnée |
| `GET/POST` | `/api/knowledge-domains` | JWT (POST : admin) | Référentiel de domaines |
| `POST` | `/api/research` · `GET /api/research/status` | JWT | Recherche KB-first (KB → web → synthèse) |
| `POST` | `/api/orchestrator/route` | JWT | Chief Agent (routage / dispatch) |
| `POST` | `/api/agent/goal` | JWT | Objectif → plan validé → tâche agent |
| `GET/POST/PATCH/DELETE` | `/api/agent/memory[/:id]` · `POST /api/agent/self-improve` | JWT | Mémoire d'exécution |
| `GET/POST/DELETE` | `/api/agent-keys[/:id]` | JWT | Clés de l'agent local |
| `GET/POST` | `/api/agent-tasks` | JWT | Lister (captures retirées) / créer (étapes validées) |
| `POST` | `/api/agent-tasks/:id/control` · `GET /api/agent-tasks/:id/events` | JWT | Pause/stop, timeline |
| `POST` | `/api/agent-tasks/announce` · `GET /poll` · `POST /update` · `POST /event` · `GET /:id/control` | clé agent | Worker local (contrat `attempt` : voir `MIGRATION.md`) |
| `GET` | `/media/*` | — | Fichiers produits (MP4/PDF) |

Limites : 300 req/min global (par utilisateur, sinon IP), 20/min sur les routes coûteuses,
corps 2 Mo (15 Mo pour `update`/`event` de l'agent). Erreurs 5xx : message générique.

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
final res = await http.post(
  Uri.parse('http://10.0.2.2:3000/api/analyze'),
  headers: {'Content-Type': 'application/json'},
  body: jsonEncode({'text': input}),
);
```

## 🗂️ Structure

```
backend/
├── docker-compose.yml      # orchestration des 4 services
├── .env.example
├── README.md
├── node-api/               # API principale (Fastify / TypeScript)
│   └── src/
│       ├── server.ts
│       ├── config.ts
│       ├── db.ts
│       ├── clients/iaClient.ts
│       ├── lib/          # validation & utilitaires purs (testés)
│       ├── services/     # connaissances, recherche, formation, maintenance…
│       └── routes/       # une route par domaine fonctionnel
│   └── test/             # tests vitest
├── python-ia/              # service IA (FastAPI)
│   └── app/{main,config,rust_client}.py
├── rust-compute/           # calculs intensifs (Axum)
│   └── src/main.rs
└── postgres/
    └── init.sql            # schéma initial
```

## 🧩 Étendre le backend

- **Nouvelle route Node** : ajoutez un fichier dans `node-api/src/routes/` et enregistrez-le dans `server.ts`.
- **Vrai modèle IA** : dans `python-ia/app/main.py`, remplacez le placeholder d'`/infer` par votre modèle (transformers, ONNX, appel API…).
- **Nouveau calcul Rust** : ajoutez une route dans `rust-compute/src/main.rs` et appelez-la depuis `python-ia/app/rust_client.py`.
- **Migrations SQL** : ajoutez vos scripts dans `postgres/` (montés au premier démarrage) ou branchez un outil de migration.

## 🛠️ Développement local (sans Docker)

Chaque service se lance indépendamment :

```bash
# Node
cd node-api && npm install && npm run dev

# Python
cd python-ia && pip install -r requirements.txt && uvicorn app.main:app --reload --port 8000

# Rust
cd rust-compute && cargo run
```

Pensez à renseigner les variables d'environnement (`DATABASE_URL`, `IA_SERVICE_URL`, `RUST_SERVICE_URL`, `IA_SERVICE_TOKEN`, `CORS_ORIGINS`…) pour pointer vers `localhost` au lieu des noms de services Docker — liste commentée dans `.env.example`. Hors Docker, node-api écoute sur `127.0.0.1` (définir `HOST=0.0.0.0` pour l'exposer).

node-api démarre même si Postgres est injoignable (mode dégradé : `/health` = 200, `/health/deep` signale `postgres: down`, nouvel essai toutes les 30 s). Au retour de la DB puis toutes les heures : générations bloquées → `Erreur`, purge des `agent_events` (> 3 jours). Arrêt propre sur SIGINT/SIGTERM.

### Tests (node-api)

```bash
cd node-api
npm test            # vitest : validation des étapes, garde attempt, chat, CORS, limites…
npm run typecheck   # tsc --noEmit
```

`test_rag.ts` est une vérification manuelle live (DB + OpenAI) : `RAG_TEST_USER_ID=<uuid> npx tsx test_rag.ts`.
