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
| `POST /functions/v1/generate-formation` | `POST /api/generate/formation` (asynchrone) | JWT | Node → Python |
| `POST /functions/v1/generate-application` | `POST /api/generate/application` | JWT | Node → Python |
| `POST /functions/v1/manage-database` (body `{action}`) | `POST /api/database` (body `{action}`) | JWT | Node |
| `agent-tasks` créer (POST + JWT) | `POST /api/agent-tasks` (étapes validées) | JWT | Node |
| `agent-tasks` lister (GET + JWT) | `GET /api/agent-tasks[?status=]` | JWT | Node |
| `agent-tasks?action=poll` | `GET /api/agent-tasks/poll` | clé agent | Node |
| `agent-tasks?action=update` | `POST /api/agent-tasks/update` | clé agent | Node |

Routes ajoutées depuis : `POST /api/agent-tasks/announce|event`, `GET|POST /api/agent-tasks/:id/control`,
`GET /api/agent-tasks/:id/events`, `GET|POST|DELETE /api/agent-keys`, `POST /api/agent/goal`,
`GET|POST|PATCH|DELETE /api/agent/memory`, `POST /api/agent/self-improve`,
`POST /api/formations/:id/{video,pdf,demos}`, `/api/knowledge*`, `/api/knowledge-domains`,
`POST /api/research`, `GET /api/research/status`, `POST /api/orchestrator/route`,
`POST /api/analyze` + `GET /api/analyze/:id` (JWT, scopés par utilisateur). Liste complète : `README.md`.

### Contrat agent local (clé + tentative)
- **Authentification** : en-tête `x-agent-key: sbk_…`. Seul le **hash SHA-256** est stocké
  (`agent_keys.key_hash`) ; le `user_id` est **déduit de la clé** (plus jamais transmis par l'agent).
  Clés gérées par l'utilisateur via `/api/agent-keys` (la clé en clair n'est renvoyée qu'à la création).
- **Poll** : chaque tâche renvoyée contient `requeue_count` (= numéro de tentative, `attempt`).
- **Claim** : `POST /update {task_id, status:"in_progress"}` n'aboutit que si la tâche est `pending`
  (sinon 409) ; la réponse contient `requeue_count`.
- **update / event** acceptent un champ optionnel `attempt` (entier). Si `attempt` ≠ `requeue_count`
  courant, ou si la tâche n'est plus `in_progress` (évènements, heartbeat, fin `completed|failed|cancelled`)
  → **409** `{error}`. Tâche d'un autre compte / inexistante → 404.
- Statuts autorisés : `pending, in_progress, completed, failed, cancelled` (400 sinon).
- `type: "heartbeat"` rafraîchit le signe de vie sans créer de ligne `agent_events`.
- Les tâches ne sont créées **que** via l'API (policy RLS INSERT retirée côté Supabase).

## Configuration requise (`backend/.env`)

Voir `backend/.env.example` (commenté) pour la liste complète. Minimum :

```
DATABASE_URL=postgres://postgres.<ref>:<password>@…pooler.supabase.com:6543/postgres
DATABASE_SSL=true
PG_SSL_CA=/chemin/vers/supabase-ca.pem   # recommandé : vérification TLS stricte
SUPABASE_URL=https://<ref>.supabase.co
SUPABASE_ANON_KEY=<clé anon>
IA_SERVICE_URL=http://localhost:8000
IA_SERVICE_TOKEN=<secret partagé avec python-ia>
OPENAI_API_KEY=<clé>                      # ou une autre clé de fournisseur
CORS_ORIGINS=http://localhost:8080
```

`DATABASE_URL` : Supabase > Project Settings > Database > Connection string (URI).

## Ce qu'il reste à faire côté clients (étape suivante)

La logique est migrée ; il faut maintenant **repointer les consommateurs** vers le backend.

### Frontend existant (`frontend/src/`, app Supabase)
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
- `poll` : `GET {API}/api/agent-tasks/poll` (en-tête `x-agent-key` ; le user_id est déduit de la clé)
- `update` : `POST {API}/api/agent-tasks/update` (en-tête `x-agent-key`)

## Décommissionnement des edge functions
Une fois les clients repointés et validés, les fonctions `supabase/functions/*`
peuvent être retirées du déploiement. **Ne pas les supprimer avant** d'avoir vérifié
que chaque flux passe par le backend (voir la table ci-dessus).

## Sécurité
- Le filtrage par `user_id` est fait explicitement dans chaque requête SQL (le pool tourne
  en direct, hors RLS). Les écritures croisées sont vérifiées (ex. `insert_data` exige que
  le `schema_id` appartienne à l'utilisateur ; `knowledge-domains` réservé aux admins `has_role`).
- Clé agent : vérifiée en valeur (hash SHA-256), `user_id` déduit de la clé.
- Erreurs 5xx : message générique côté client, détail uniquement dans les logs.
- Limitation de débit (`@fastify/rate-limit`), CORS par liste blanche, corps limité à 2 Mo
  (15 Mo pour `/api/agent-tasks/update|event`, qui transportent des captures).
- python-ia : jeton inter-services `IA_SERVICE_TOKEN` (en-tête `x-ia-token`) ; un 401/403/5xx
  de python-ia est renvoyé au client en 502 (429 → 429, 503 → 503), jamais en 401.
