# Migration des edge functions → backend Node/Python (et contrat LOT 1)

Toute la logique des 5 edge functions Supabase est portée dans le backend.
**On garde Supabase** comme base de données (Postgres) et fournisseur d'authentification :
Node se connecte au Postgres Supabase et vérifie les JWT Supabase via `/auth/v1/user`.
Le frontend (`frontend/src/lib/api.ts`) et l'agent local (`agent/client.py`) passent déjà par le
backend ; les edge functions ne sont plus appelées.

## Répartition
- **Node** (`node-api`) : plan de contrôle — auth, accès Postgres, file des tâches agent, évaluation,
  mémoire, base de connaissances, chat streaming, orchestration.
- **Python** (`python-ia`) : seul routeur de modèles (planification, évaluation, génération, vidéo, PDF).

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

Liste complète des routes : `README.md`.

## Prérequis base de données (LOT 1)

Appliquer **`supabase/migrations/20261001090000_lot1_fixes.sql` AVANT de déployer ce node-api** :
`agent_tasks.target_agent_key_id` / `claimed_by_key_id` (FK `agent_keys` ON DELETE SET NULL), index
de poll partiel, trigger qui ne prolonge plus le bail quand seul `control` change. Sans elle, poll,
claim et création de tâches échouent (node-api journalise une erreur explicite au démarrage).

## Contrat agent local (clé + tentative + ciblage)

- **Authentification** : en-tête `x-agent-key: sbk_…`. Seul le **hash SHA-256** est stocké ; le
  `user_id` et la **clé appelante** sont déduits de la clé. Une clé = un PC.
- **Poll** : `GET /poll` ne renvoie que les tâches `pending` dont `target_agent_key_id` est NULL ou
  égal à la clé appelante, **hors** corrections en attente d'approbation
  (`payload.goal_meta.awaiting_approval = true`). Chaque tâche contient `requeue_count` (= `attempt`).
  La remise en file des tâches orphelines n'est plus faite au poll mais par le **reaper global**.
- **Claim** : `POST /update {task_id, status:"in_progress", attempt}` n'aboutit que si la tâche est
  `pending`, ciblée sur cette clé (ou aucune) et non en attente d'approbation ; écrit
  `claimed_by_key_id`. Sinon 409 (ou 410 si la tâche n'existe plus).
- **update / event / heartbeat** : `attempt` optionnel (entier). Si `attempt` ≠ `requeue_count`, si la
  tâche n'est plus `in_progress` ou si elle a été réclamée par une autre clé → **409**.
  **Tâche supprimée / inexistante → 410 `{error:"gone", control:"stop"}`** (aussi pour
  `GET /:id/control`) : l'agent abandonne immédiatement la tâche et ses mises à jour en attente.
- Statuts : `pending, in_progress, completed, failed, cancelled` (400 sinon). **`cancelled` est un
  final accepté** (garde `attempt`) et n'est **jamais évalué**.
- **Annulation** : `POST /api/agent-tasks/:id/cancel` (JWT) — `pending` → `cancelled` ;
  `in_progress` → `control='stop'` ; l'agent finit l'étape courante puis envoie `status:"cancelled"`.
- **Captures** : `image_b64` d'un évènement (niveau racine de `data`) doit être du **base64 strict
  ≤ 2 Mo de texte** (sinon **400**) ; il est retiré avant insertion (`data.has_image=true`) et gardé en
  mémoire 10 min. Tout `image_b64` **imbriqué** dans `data` est retiré (jamais stocké ni diffusé).
  Mémoire bornée : 128 Mo au total, 24 Mo / 50 tâches par utilisateur (ses plus anciennes captures
  sont évincées d'abord), expirées balayées chaque minute. Les captures du rapport final sont retirées
  de `result` (les 3 dernières **valides** sont passées en mémoire à l'évaluation).
  `data.source` est forcé à `agent` pour les évènements de l'agent.
- `type: "heartbeat"` rafraîchit le signe de vie sans créer de ligne `agent_events`.
- Corps : **3 Mo max pour `event`**, 15 Mo pour `update` (413 au-delà) ; hors captures, `data` ≤ 64 Ko
  et `result` ≤ 1 Mo.
- **Reaper global** (toutes les 60 s, une seule instance via verrou consultatif) : tâche
  `in_progress` muette depuis `AGENT_TASK_STALE_SECONDS` → `cancelled` si un stop était demandé, sinon
  `pending` (`requeue_count+1`, `claimed_by_key_id` effacé) au plus 3 fois, puis `failed`. À la remise
  en file, `control` repart à `none`, sauf : pause demandée par l'utilisateur → conservée ; **étape à
  effet réel déjà lancée** (`step_started|step_done|step_failed` d'une étape run_command, write_file,
  move_file, type_text, hotkey, phone_*…) → **`pause`** : l'agent rejouant le plan depuis l'étape 0
  (reprise à l'étape prévue au LOT 8), il attend un « Reprendre » explicite (ou une annulation).
  L'évènement `task_requeued` porte `data.{requeue_count, control, side_effects}`.
- **Révocation d'une clé** (`DELETE /api/agent-keys/:id`) : dans la même transaction, les tâches
  `pending` ciblant ce PC (corrections en attente comprises) et les tâches `in_progress` qu'il exécutait
  passent en `cancelled` (+ `control='stop'`) — jamais reprises ni finalisées par un autre PC.

## Changements d'API LOT 1 (pour le frontend)

| Route | Corps / réponse |
|---|---|
| `POST /api/agent/goal` | `{goal, agent_key_id?}` → `{success, task_id, understanding, steps, target_agent_key_id}`. Plusieurs clés sans `agent_key_id` → **400 `{error, agents:[{id,name}]}`** ; clé inconnue → 400 ; une seule clé → ciblée d'office. Le planner ne voit que les `allowed_dirs` de la clé ciblée ; tout chemin hors de ces dossiers → 422 (`reason`). |
| `POST /api/agent-tasks` | `{task_type, payload:{steps,…}, priority?, agent_key_id?}` ; même règle de ciblage ; chemins (`src, dest, path, cwd, output, audio, clips[]`) absolus et dans les `allowed_dirs` de la clé ciblée, sinon 400. `payload.requires_confirmation=true` posé par le serveur dès qu'une étape agit réellement (run_command, write_file, move_file, type_text, hotkey, phone_*). |
| `POST /api/agent-tasks/:id/cancel` | → `{success, status, control, task:{id,status,control}}` (statut APRÈS l'appel) ; terminée → 409 `{error,status}` ; absente → 404. Sert aussi à **rejeter** une correction. |
| `POST /api/agent-tasks/:id/cancel?scope=goal` | annule **tout l'objectif** (tâches actives de même `goal_meta.root_task_id`, racine comprise) → `{success, scope:"goal", root_task_id, cancelled:[ids], stopping:[ids], tasks:[{id,status,control}]}` ; rien d'actif → 409 ; absente → 404 ; autre `scope` → 400. |
| `DELETE /api/agent-keys/:id` | → `{success, cancelled_task_ids}` (tâches du PC annulées, voir ci-dessus) ; absente → 404. |
| `POST /api/agent-tasks/:id/approve` | → `{success, task_id, status, task:{id,status,control,payload}}` (`payload.goal_meta.awaiting_approval=false`, `approved_at`) ; pas en attente → 409 ; absente → 404. |
| `DELETE /api/agent-tasks/:id` | tâche terminée (`completed/failed/cancelled`) → **204** ; active → 409 (annuler d'abord) ; absente → 404. |
| `POST /api/agent-tasks/:id/control` | `{control: pause|resume|stop}` ; même valeur → `{success, control, unchanged:true}` (aucune écriture, bail non prolongé) ; tâche terminée → 409. |
| `GET /api/agent-tasks/:id/screenshot` | → `{image_b64, mime, at}` (propriétaire seulement, capture < 10 min) ou 404. `Cache-Control: no-store`. |
| `GET /api/agent-tasks/:id/events` | plus aucune image : `data.has_image=true` → appeler `/screenshot`. Évènements de formation : `data.source='formation'` (à ignorer dans le cockpit). |
| `GET /api/agent-tasks` | colonnes `target_agent_key_id`, `claimed_by_key_id` en plus. |
| `GET /api/agent-keys` | `allowed_dirs` en plus (choix du PC). |
| `POST /api/chat` (action) | `{action:{name,arguments}, confirmed:true}` — `confirmed:true` accepté au premier niveau **ou** dans `action`. Sans lui : 200 `{success:false, requires_confirmation:true, action}` et **rien n'est exécuté**. |
| `POST /api/auth/logout` | Bearer requis → `{success:true}` : le JWT est oublié du cache **et révoqué sur l'instance** (refusé 401 sans consulter Supabase jusqu'à son `exp`, ≤ 1 h) — même pour une requête arrivée avant `signOut`. Autre instance : 15 s max. |
| `POST /api/formations/:id/demos` | **501** `{error, code:"demos_not_implemented"}` (plus de tâches sans étapes). |
| `POST /api/orchestrator/route` | échec de planification dispatchée → 4xx relayé (400/422/429…) ou **502**, avec `success:false`. |
| `provider` (research, generate/formation, orchestrator) | refusé (400) s'il n'est pas dans `LLM_ALLOWED_OVERRIDES`. |
| `POST/PATCH /api/knowledge` | `confidence` ∈ [0,1] et types vérifiés → 400 sinon ; `content_hash` client ignoré, recalculé à chaque écriture. |
| `POST /api/research` | `verified:false` et entrée `source:'llm_synthesis'`, `category:'recherche'`, confiance ≤ 0.3, `sources[].verified=false` quand aucune source web n'a été récupérée ; jamais resservie comme `kb`. Une synthèse web (`web_synthesis`) resservie depuis la KB (`source:'kb'`) a **toujours** `verified:false`, comme toute entrée citant une source `verified:false` ; une synthèse web fraîche n'est `verified:true` que si toutes ses URL citées ont été récupérées. |
| `GET /health/deep` | JWT exigé hors `SOULBAH_ENV=dev`. |

### Évaluation d'un objectif (`result.evaluation` + évènement `evaluation`)

Une tâche `goal` terminée `completed|failed` est évaluée au plus une fois (tâche de fond suivie,
réservation atomique via `result.evaluation_status` : `running | done | skipped | error`). Jamais pour
une tâche `cancelled`, stoppée (`control='stop'`), simulée (`result.simulated`), à plan vide
(`result.empty_plan`) ou sans étape exécutée.

`result.evaluation = {verdict, llm_verdict, reason, action_taken, corrective_task_id?, at}` ; le même
`action_taken` / `corrective_task_id` figure dans `data` de l'évènement `agent_events.type='evaluation'`.
`verdict` est le verdict **effectif** (`success | retry | abort | not_evaluable`, ou `null` si
l'évaluation a échoué) ; `retry` n'est écrit que si une correction a réellement été créée.

| `action_taken` | Signification |
|---|---|
| `none` | non évaluable (python-ia `not_evaluable`) : ni correction, ni mémoire |
| `memory_proposed` | succès ; mémoire « solution » écrite en `proposed` |
| `correction_awaiting_approval` | correction créée (`corrective_task_id`), en attente de `/approve` (rejet = `/cancel`) |
| `correction_invalid` | le LLM proposait une correction invalide / hors whitelist : aucune tâche créée |
| `max_attempts_reached` | nouvelle tentative conseillée mais 3 tentatives atteintes : abandon |
| `abandoned` | verdict `abort` |
| `evaluation_failed` | service IA indisponible / erreur : rien n'est décidé |

Une correction porte `payload.goal_meta = {goal, attempt, max_attempts, parent_task_id, root_task_id,
awaiting_approval:true, correction_reason}` et cible le même PC que la tâche évaluée (sa cible, à
défaut le PC qui l'a exécutée — `claimed_by_key_id`) ; elle est créée dans la **même transaction** que
l'écriture de `result.evaluation`. Le texte saisi (`text`, `content`) est masqué
(`[texte masqué : N car.]`) avant tout envoi au LLM. Un libellé de masquage recopié par le LLM dans une
étape corrective est **restauré** depuis la tâche évaluée (même type, même champ, même longueur), sinon
la correction est refusée (`correction_invalid`) ; un plan d'objectif qui en contient un est refusé
(422). La mémoire « solution » omet les textes saisis (`Plan réussi (textes saisis omis) : …`).
Les noms de PC renvoyés dans `agents:[{id,name}]` valent le libellé de la clé, sinon `PC <8 premiers
caractères de l'id>` (comme le front).

### Mémoire

L'évaluateur et l'auto-amélioration écrivent en `proposed`. `POST /api/agent/memory` est `proposed`
par défaut ; `validated` (POST ou PATCH) est une action explicite de l'utilisateur, tracée dans
`metadata.validated_by`. Une ligne `validated` sans `validated_by` (verdicts historiques, insertions
directes) est lue comme `proposed` (`GET` renvoie `status` effectif + `stored_status`). La
planification exclut les entrées `rejected`, inclut les leçons générales (`goal='(général)'`), classe
par pertinence et injecte au plus 6 entrées (≤ 3 000 car.) marquées « données non fiables ».

## Configuration requise (`backend/.env`)

Voir `backend/.env.example` (commenté) pour la liste complète. Minimum :

```
SOULBAH_ENV=dev                            # staging/production : jeton IA + CA obligatoires
DATABASE_URL=postgres://postgres.<ref>:<password>@…pooler.supabase.com:6543/postgres
DATABASE_SSL=true
PG_SSL_CA=/chemin/vers/supabase-ca.pem     # obligatoire hors dev/test
SUPABASE_URL=https://<ref>.supabase.co
SUPABASE_ANON_KEY=<clé anon>
IA_SERVICE_URL=http://localhost:8000
IA_SERVICE_TOKEN=<secret partagé avec python-ia>   # obligatoire hors dev/test
OPENAI_API_KEY=<clé>                       # ou une autre clé de fournisseur
CORS_ORIGINS=http://localhost:8080
```

`DATABASE_URL` : Supabase > Project Settings > Database > Connection string (URI).
Production : `npm run build` puis `npm run start:prod` (`node dist/server.js`) ; l'image Docker fait de
même (plus de `tsx` en production).

## Décommissionnement des edge functions
Les clients sont repointés ; les fonctions `supabase/functions/*` peuvent être retirées du
déploiement après vérification de chaque flux sur l'environnement restauré.

## Sécurité
- Le filtrage par `user_id` est fait explicitement dans chaque requête SQL (le pool tourne en direct,
  hors RLS). Les écritures croisées sont vérifiées (ex. `insert_data` exige que le `schema_id`
  appartienne à l'utilisateur ; `knowledge-domains` réservé aux admins `has_role`).
- Clé agent : vérifiée en valeur (hash SHA-256), `user_id` déduit de la clé ; ciblage par PC.
- Erreurs 5xx : message générique côté client, détail uniquement dans les logs ; aucun texte d'erreur
  amont (python-ia, fournisseur LLM) n'est relayé, même pour un 400/422.
- Limitation de débit (`@fastify/rate-limit`, IP réelle derrière proxy via `TRUST_PROXY`), CORS par
  liste blanche, corps limité à 2 Mo (15 Mo pour `/api/agent-tasks/update|event`).
- python-ia : jeton inter-services `IA_SERVICE_TOKEN` (en-tête `x-ia-token`, obligatoire hors dev/test),
  budget `x-deadline-ms` envoyé à chaque appel, usage `x-llm-usage` journalisé. Statuts amont :
  401/403/5xx → 502, 429 → 429, 503 → 503, 504/499 → 504, 413 → 413 ; jamais 401 vers le navigateur.
- Chat : la base de connaissances est injectée (top 8, ≤ 12 000 car.) dans le message utilisateur
  comme données non fiables, jamais dans le prompt système ; aucun outil n'est exécuté sans
  `confirmed:true`.
- `/media/*` : noms UUID, `Cache-Control: private`, `nosniff`, ni listing ni fichiers cachés ;
  médias non référencés purgés après `MEDIA_RETENTION_DAYS`.
