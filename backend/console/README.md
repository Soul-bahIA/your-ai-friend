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
- Connexion : `POST /api/analyze` exige un JWT Supabase. La console propose une connexion
  e-mail / mot de passe (si `VITE_SUPABASE_URL` et `VITE_SUPABASE_KEY` sont définis) ou le collage
  d'un jeton d'accès. Le jeton est conservé pour l'onglet (sessionStorage) et envoyé en
  `Authorization: Bearer …` ; la déconnexion appelle `POST /api/auth/logout`.
- Formulaire d'analyse de texte → `POST /api/analyze` (Node → Python IA → Rust → Postgres).
- Affichage du résultat (label, confiance, statistiques calculées par Rust).
- Barre de santé temps réel (`GET /health/deep`) : état de l'API, de Postgres et du service IA.
  Hors `SOULBAH_ENV=dev`, cette route exige un JWT : sans session, la barre affiche
  « Connexion requise » (et se met à jour dès la connexion). « API injoignable » signifie
  qu'aucune réponse n'a été lue : backend arrêté **ou requête bloquée par CORS** (voir ci-dessous).

## CORS : autoriser l'origine de la console (obligatoire)

La console tourne sur **http://localhost:5173** ; le navigateur n'accepte les réponses de
`node-api` que si cette origine figure dans `CORS_ORIGINS` du backend. Ni la valeur par défaut de
`node-api` (CORS_ORIGINS vide → `localhost:8080` / `127.0.0.1:8080`, l'application web) ni la ligne
`CORS_ORIGINS` de `backend/.env.example` n'incluent le port 5173 : ajoutez-le dans `backend/.env`,
**à côté** des origines de l'application web :

```
CORS_ORIGINS=http://localhost:8080,http://127.0.0.1:8080,http://localhost:5173,http://127.0.0.1:5173
```

Sans cela, les appels authentifiés (en-tête `Authorization` → requête préliminaire CORS) sont
bloqués et la barre de santé affiche « API injoignable ». Le repli de `docker-compose.yml` inclut
`http://localhost:5173`, mais il est ignoré dès que `backend/.env` définit `CORS_ORIGINS`.

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
| `VITE_SUPABASE_URL` | — | URL du projet Supabase (connexion e-mail / mot de passe) |
| `VITE_SUPABASE_KEY` | — | Clé publique (anon) Supabase |
| `VITE_DEV_HOST` | `localhost` | Hôte du serveur de dev (`0.0.0.0` pour l'exposer au réseau) |

> Vite fige les variables `VITE_*` **au build**. En Docker, elles sont passées via les `ARG`
> `VITE_API_URL`, `VITE_SUPABASE_URL` et `VITE_SUPABASE_KEY` du Dockerfile.

## Build de production

```bash
npm run build      # typecheck + bundle statique dans dist/
npm run preview    # sert dist/ localement pour vérifier
npm test           # tests unitaires (node --test, sans dépendance ; Node ≥ 22.6)
```

## Docker

Image incluse (build Vite + service nginx statique) :

```bash
docker build --build-arg VITE_API_URL=http://localhost:3000 \
  --build-arg VITE_SUPABASE_URL=https://<ref>.supabase.co \
  --build-arg VITE_SUPABASE_KEY=<clé publique anon> \
  -t soulbah-console .
docker run -p 127.0.0.1:5173:80 soulbah-console
```

Sans `VITE_SUPABASE_URL` / `VITE_SUPABASE_KEY` au build, la connexion e-mail / mot de passe est
indisponible (seul le collage d'un jeton reste possible).

Ou via le `docker-compose.yml` du backend (service `console` déjà intégré) :

```bash
cd ../backend
docker compose up --build      # lance backend + console d'un coup
```

> Le service `console` du `docker-compose.yml` ne transmet aujourd'hui que `VITE_API_URL` :
> dans cette configuration, utilisez le collage d'un jeton, ou construisez l'image vous-même
> avec les `--build-arg` ci-dessus. Pensez aussi à `CORS_ORIGINS` (section CORS).

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
│   ├── api/health.ts          # décodage /health/deep + message de la barre (pur)
│   ├── api/auth.ts            # session : connexion Supabase ou jeton collé
│   └── components/
│       ├── AuthPanel.tsx
│       ├── HealthBar.tsx
│       └── ResultCard.tsx
├── test/health.test.ts        # npm test
└── Dockerfile
```

## Lien avec Flutter
Cette console et l'app Flutter tapent **exactement la même API Node** (port 3000).
Le code de `src/api/client.ts` est le pendant TypeScript de ce que fait le client HTTP Dart côté mobile.
