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
| **node-api** | Node.js 20 + Fastify + TypeScript | 3000 | Point d'entrée unique pour Flutter. Validation, orchestration, accès Postgres, appel du service IA. |
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

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health` | Liveness de l'API |
| `GET` | `/health/deep` | Vérifie Postgres + service Python |
| `POST` | `/api/analyze` | Flux complet : persiste la requête → appelle Python IA (→ Rust) → stocke et renvoie le résultat |
| `GET` | `/api/analyze/:id` | Relit un résultat d'analyse par son id |

### Exemple — le flux de bout en bout

```bash
curl -X POST http://localhost:3000/api/analyze \
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
│       └── routes/{health,analyze}.ts
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

Pensez à renseigner les variables d'environnement (`DATABASE_URL`, `IA_SERVICE_URL`, `RUST_SERVICE_URL`) pour pointer vers `localhost` au lieu des noms de services Docker.
