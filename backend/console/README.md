# SOULBAH IA — Console de test du backend (`backend/console/`)

> ⚠️ **Ce dossier N'EST PAS l'application SoulBah AI.**
> L'application web (dashboard, chat, formations, agent…) se trouve à la **racine du dépôt**
> (`frontend/`, `npm run dev` → http://localhost:8080). Voir le [README principal](../../README.md).
>
> `backend/console/` est une **petite console de test** du backend polyglotte : elle appelle
> `POST /api/analyze` et `GET /health/deep` de `backend/node-api` pour vérifier la chaîne
> Node → Python IA → Rust → Postgres. Elle sert d'équivalent web au client Flutter
> (même API, mêmes endpoints). Elle s'appelait auparavant `frontend/` ; ce nom désigne désormais l'application principale.

## Stack
- **React 18** + **TypeScript**
- **Vite** (dev server rapide + build statique)
- Aucune dépendance UI lourde — CSS maison, thème sombre.

## Fonctionnalités
- Formulaire d'analyse de texte → `POST /api/analyze` (Node → Python IA → Rust → Postgres).
- Affichage du résultat (label, confiance, statistiques calculées par Rust).
- Barre de santé temps réel (`GET /health/deep`) : état de l'API, de Postgres et du service IA.

## Démarrage (dev)

```bash
cd backend/console
cp .env.example .env          # optionnel (défaut : http://localhost:3000)
npm install
npm run dev
```

Ouvre http://localhost:5173. Le backend (`cd backend && docker compose up`) doit tourner en parallèle.

## Configuration

| Variable | Défaut | Rôle |
|---|---|---|
| `VITE_API_URL` | `http://localhost:3000` | URL de l'API Node à contacter |

> Vite fige les variables `VITE_*` **au build**. En Docker, elles sont passées via l'`ARG VITE_API_URL` du Dockerfile.

## Build de production

```bash
npm run build      # typecheck + bundle statique dans dist/
npm run preview    # sert dist/ localement pour vérifier
```

## Docker

Image incluse (build Vite + service nginx statique) :

```bash
docker build --build-arg VITE_API_URL=http://localhost:3000 -t soulbah-console .
docker run -p 5173:80 soulbah-console
```

Ou via le `docker-compose.yml` du backend (service `console` déjà intégré) :

```bash
cd ../backend
docker compose up --build      # lance backend + console d'un coup
```

## Structure

```
backend/console/
├── index.html
├── vite.config.ts
├── src/
│   ├── main.tsx
│   ├── App.tsx
│   ├── index.css
│   ├── api/client.ts          # client HTTP typé (analyze, deepHealth)
│   └── components/
│       ├── HealthBar.tsx
│       └── ResultCard.tsx
└── Dockerfile
```

## Lien avec Flutter
Cette console et l'app Flutter tapent **exactement la même API Node** (port 3000).
Le code de `src/api/client.ts` est le pendant TypeScript de ce que fait le client HTTP Dart côté mobile.
