# Migration des edge functions → backend Node/Python

Toute la logique des 5 edge functions Supabase est désormais portée dans le backend.
**On garde Supabase** comme base de données (Postgres) et fournisseur d'authentification :
Node se connecte au Postgres Supabase et vérifie les JWT Supabase via `/auth/v1/user`.

## Répartition
- **Node** (`node-api`) : auth, accès Postgres, CRUD, file de tâches, chat streaming, orchestration.
- **Python** (`python-ia`) : génération IA sans état (formations, applications).

## Table de correspondance des endpoints

| Edge function (avant) | Endpoint backend (après) | Auth | Service |
|---|---|---|---|
| `POST /functions/v1/chat` | `POST /api/chat` | JWT | Node (+Python pour les actions) |
| `POST /functions/v1/generate-formation` | `POST /api/generate/formation` | JWT | Node → Python |
| `POST /functions/v1/generate-application` | `POST /api/generate/application` | JWT | Node → Python |
| `POST /functions/v1/manage-database` (body `{action}`) | `POST /api/database` (body `{action}`) | JWT | Node |
| `agent-tasks` créer (POST + JWT) | `POST /api/agent-tasks` | JWT | Node |
| `agent-tasks` lister (GET + JWT) | `GET /api/agent-tasks` | JWT | Node |
| `agent-tasks?action=poll` (x-agent-key) | `GET /api/agent-tasks/poll?user_id=…` | agent-key | Node |
| `agent-tasks?action=update` (x-agent-key) | `POST /api/agent-tasks/update` | agent-key | Node |

Les **corps de requête et de réponse sont identiques** à ceux des edge functions
(mêmes champs, mêmes formes), pour minimiser les changements côté clients.

## Configuration requise (`backend/.env`)

```
DATABASE_URL=postgres://postgres.<ref>:<password>@…pooler.supabase.com:6543/postgres
DATABASE_SSL=true
SUPABASE_URL=https://<ref>.supabase.co
SUPABASE_ANON_KEY=<clé anon>
LOVABLE_API_KEY=<clé passerelle IA>
```

`DATABASE_URL` : Supabase > Project Settings > Database > Connection string (URI).

## Ce qu'il reste à faire côté clients (étape suivante)

La logique est migrée ; il faut maintenant **repointer les consommateurs** vers le backend.

### Frontend existant (`src/`, app Supabase)
Remplacer les appels aux edge functions par le backend. Points à modifier :
| Fichier | Changement |
|---|---|
| `src/hooks/useDatabase.ts` | `supabase.functions.invoke("manage-database", …)` → `POST {API}/api/database` |
| `src/components/AiChat.tsx` | `CHAT_URL` → `{API}/api/chat` |
| `src/pages/Formations.tsx` | `…/functions/v1/generate-formation` → `{API}/api/generate/formation` |
| `src/pages/Applications.tsx`, `AppChatPanel.tsx`, `AppPreview.tsx` | `…/generate-application` → `{API}/api/generate/application` |
| `src/components/AgentTasksPanel.tsx` | `TASK_URL` → `{API}/api/agent-tasks` (+ `/poll`, `/update`) |

> Ajouter un `VITE_API_URL` (ex. `http://localhost:3000`) et l'utiliser partout.
> Le token JWT est déjà disponible (`session.access_token`) et s'envoie en `Authorization: Bearer …`.

### Agent local (`agent/`)
Le worker poll/update. Repointer sa base d'URL :
- `poll` : `GET {API}/api/agent-tasks/poll?user_id=…` (en-tête `x-agent-key`)
- `update` : `POST {API}/api/agent-tasks/update` (en-tête `x-agent-key`)

## Décommissionnement des edge functions
Une fois les clients repointés et validés, les fonctions `supabase/functions/*`
peuvent être retirées du déploiement. **Ne pas les supprimer avant** d'avoir vérifié
que chaque flux passe par le backend (voir la table ci-dessus).

## Sécurité
- Le filtrage par `user_id` est fait explicitement dans chaque requête SQL
  (le pool tourne en direct, donc hors RLS — comportement identique aux edge functions).
- Dette connue conservée : `x-agent-key` n'est vérifiée qu'en présence, pas en valeur.
  À durcir (hash de clé par utilisateur) — cf. `docs/SOULBAH_AI_ARCHITECTURE.md`.
