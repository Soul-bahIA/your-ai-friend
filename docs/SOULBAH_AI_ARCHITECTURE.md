# SoulBah AI — Architecture (état réel, LOT 1)

> Document vivant : il décrit ce qui **existe** dans le dépôt et le **contrat LOT 1** en cours
> d'implémentation. Il ne décrit pas la cible V2.
> - Audit de référence : [`SOULBAH_V2_LOT0_AUDIT.md`](SOULBAH_V2_LOT0_AUDIT.md) (problèmes T#/S#,
>   capacités C01–C38).
> - Cible V2 : audit §9, architecture « Split-Plane ».
> - Feuille de route en 15 lots : audit §13.
> - Contrat commun du LOT 1 : [`LOT1_CONTRAT.md`](LOT1_CONTRAT.md).
> - Reprise de Supabase : [`SUPABASE_REPRISE.md`](SUPABASE_REPRISE.md).

---

## 1. Processus réels

Tout tourne sur **un seul PC Windows**, hors Docker. Le projet Supabase est actuellement en
pause.

```
 Navigateur : app web frontend/ (Vite + React, :8080)
   │ REST + JWT Supabase (/api/*)        ▲ Realtime : agent_tasks, agent_events, formations, system_logs
   │ + accès PostgREST direct : chat_*, formations, applications, system_logs, profiles
   │   (bornés par la RLS) ; lecture seule de knowledge_base, agent_tasks, agent_keys
   ▼
 backend/node-api  Fastify 5 / TypeScript  :3000 (HOST=127.0.0.1 par défaut)
   │ file agent_tasks · objectif → plan → évaluation · mémoire · KB · chat SSE · clés agent
   ├── pg ──────────────────────────────► Supabase Postgres (+ Auth, Realtime, pgvector)
   ├── HTTP + x-ia-token ───────────────► backend/python-ia  FastAPI :8000
   │                                        prompts plan/évaluation, routeur de fournisseurs,
   │                                        vidéo (slides + TTS), PDF
   ▲
   │ HTTP x-agent-key : announce · poll · claim/update · event · control
 agent/  worker Python (venv agent/.venv) — exécute les étapes sur le poste, avec confirmation

 backend/console      console web de test du backend (n'est pas l'application)
 backend/rust-compute démo /infer gelée, profil compose `demo` uniquement, aucun rôle en V2
```

## 2. Composants

| Dossier | Rôle | Remarques |
|---|---|---|
| `frontend/` | Application web (React, Vite, shadcn-ui) : chat, formations, applications, base de connaissances, automatisation (objectifs, tâches, cockpit), sécurité (clés agent). | Appelle `/api/*` avec le JWT Supabase. Lit certaines tables en direct (RLS). |
| `backend/node-api` | API principale et plan de contrôle : JWT, file de tâches de l'agent, orchestration objectif → plan → évaluation, mémoire, KB (hash, versions, embeddings), chat SSE, maintenance. | Connexion Postgres en `postgres` aujourd'hui (S4) ; rôle `soulbah_api` prévu : [`SUPABASE_REPRISE.md`](SUPABASE_REPRISE.md) §10. |
| `backend/python-ia` | Service IA sans état : plan et évaluation (LLM), génération de formations et d'applications, vidéo, PDF, routeur multi-fournisseurs. | Appelé par node-api uniquement, avec `x-ia-token`. |
| `agent/` | Worker local : poll, claim, exécution des skills (souris, clavier, fenêtres, fichiers, commandes, capture, enregistrement, montage, téléphone), outbox des résultats. | Mode `confirm` par défaut ; workspace dédié (§4). |
| `backend/console` | Console de test (`/api/analyze`, `/health/deep`). | Service compose `console`. |
| `backend/rust-compute` | Démo `/infer`. | Gelée ; profil compose `demo`. |
| `supabase/migrations` | Schéma versionné (source de vérité). | Voir §5. |
| `scripts/` | Sauvegardes, venvs, régénération de `RESTAURATION_BASE.sql`, outillage CI (`scripts/ci/`). | |

## 3. Flux d'une tâche agent

Le statut d'`agent_tasks` garde ses 5 valeurs : `pending`, `in_progress`, `completed`,
`failed`, `cancelled`. Le CHECK n'est jamais modifié. `control` vaut `none`, `pause` ou `stop`.
`updated_at` sert de bail : un agent muet depuis 180 s voit sa tâche remise en file, au plus
3 fois.

1. **Objectif** : `POST /api/agent/goal` (JWT). La mémoire et les `allowed_dirs` de la clé
   ciblée alimentent le planner (python-ia `/agent/plan`), puis node-api valide les étapes et
   insère la tâche `pending`.
   - **Ciblage d'un PC** (contrat §7) : paramètre `agent_key_id` facultatif, stocké dans
     `agent_tasks.target_agent_key_id`.
   - Sans ce paramètre : si l'utilisateur a une seule clé active, elle est ciblée ; s'il en a
     plusieurs, l'API répond 400 avec la liste des agents.
2. **Poll** : `GET /api/agent-tasks/poll` (`x-agent-key`) renvoie au plus 5 tâches
   `pending`, de l'utilisateur de la clé, avec `target_agent_key_id` NULL ou égal à la clé
   appelante, hors corrections en attente d'approbation. Index partiel
   `idx_agent_tasks_poll` (T46).
3. **Claim** : `POST /api/agent-tasks/update` `in_progress` avec `attempt`. L'UPDATE est gardé
   par `status='pending' AND requeue_count=attempt` (409 sinon). Le claim écrit
   `claimed_by_key_id`.
4. **Exécution** : étapes séquentielles, avec la permission vérifiée avant chaque action.
   Contrat §12–§14 :
   - l'événement `approval_required` est émis avant une confirmation, puis `approval_result` ;
   - les textes saisis sont masqués dans les logs, événements et résultats ;
   - un heartbeat part toutes les 30 s.
5. **Fin** : `completed`, `failed` ou `cancelled`, gardé par `attempt`. Une erreur réseau
   place le résultat dans l'outbox locale.
6. **Évaluation** (node-api → python-ia `/agent/evaluate`). Elle n'a jamais lieu pour une
   tâche `cancelled`, ni pour un résultat `empty_plan` ou `simulated`. Les mémoires sont
   écrites en `proposed` ; seul l'utilisateur les passe en `validated` (contrat §4, §9).
   Une correction proposée porte `goal_meta.awaiting_approval=true` (contrat §6) :
   - elle ne part qu'après `POST /api/agent-tasks/:id/approve` ;
   - la rejeter, c'est l'annuler.

**Annulation** (contrat §2) : `POST /api/agent-tasks/:id/cancel` (JWT, propriétaire).
- Une tâche `pending` passe en `cancelled` immédiatement.
- Une tâche `in_progress` reçoit `control='stop'` : l'agent termine l'étape courante puis
  envoie `cancelled`.
- Poser `control`, même avec une valeur identique, ne prolonge plus le bail (trigger, T45) ;
  le heartbeat, lui, le prolonge.

**Tâche disparue** (contrat §3) : `control`, `event`, `update` et heartbeat répondent
`410 {error:"gone"}`, et l'agent abandonne la tâche.

**Événements** (`agent_events`, télémétrie, sans FK sur `task_id`, purgés à 3 jours) :
- `data.source` vaut `agent` ou `formation` ;
- les captures ne sont pas stockées en base (`data.has_image=true`) : la dernière est servie
  par `GET /api/agent-tasks/:id/screenshot` (contrat §8).

**Dry-run** (contrat §5) : `--dry-run --plan fichier.json` exécute un plan local en
simulation. Il ne réclame aucune tâche au serveur, et son résultat porte `simulated=true`.

## 4. Environnements, secrets, exposition

| Sujet | Règle |
|---|---|
| `SOULBAH_ENV` | `dev` (défaut), `test`, `staging` ou `production`. Hors `dev`/`test`, node-api et python-ia refusent de démarrer sans `IA_SERVICE_TOKEN`, et node-api sans `PG_SSL_CA` quand `DATABASE_SSL=true`. |
| `IA_SERVICE_TOKEN` | Même valeur pour node-api et python-ia (`backend/.env`). Envoyé dans l'en-tête `x-ia-token`. |
| `PG_SSL_CA` | Chemin du certificat CA de Supabase. Sans lui, la connexion est chiffrée mais non vérifiée (S13). |
| Exposition réseau | node-api écoute par défaut sur `127.0.0.1` (`HOST`) hors Docker. Dans `backend/docker-compose.yml`, tous les ports publiés sont liés à `127.0.0.1`, et python-ia et rust-compute ne sont pas publiés. |
| Python | Un venv par composant (`agent/.venv`, `backend/python-ia/.venv`), créé par `scripts/setup_venvs.ps1` ou `.sh` (T34). |
| Workspace de l'agent | `SOULBAH_ALLOWED_DIRS` vaut par défaut `%USERPROFILE%\SoulbahWorkspace`, créé au besoin (contrat §14). L'agent refuse de démarrer si un dossier autorisé contient l'agent ou le dépôt. La deny-list est permanente : code et config de l'agent, `*.env`, `.ssh`, clés privées, `.git/hooks`, `git --separate-git-dir`/`--template`. |
| Clé agent | Hachée (SHA-256) en base, affichée une seule fois et révocable depuis la page *Sécurité*. Elle est créée par `POST /api/agent-keys` et révoquée par `DELETE /api/agent-keys/:id` (qui annule d'abord les tâches de ce PC) ; le navigateur ne peut que la lire (RLS, LOT 1). **Pas d'expiration** en V1 : reportée au LOT 4 (`agent_keys.expires_at`, audit §12 « agents ») — S20 partiel. |

## 5. Données

- **Supabase Postgres**, schéma dans `supabase/migrations/` (19 migrations).
  - Règles (audit §12) : migrations additives et idempotentes depuis `20260703000000` ;
    contraintes `NOT VALID` puis `VALIDATE` tentée.
  - Interdits : modifier le CHECK de statut d'`agent_tasks`, ajouter une FK sur
    `agent_events.task_id`, supprimer `modules_status` (dépréciée, T48).
- **Migrations LOT 1** :
  - `20261001090000_lot1_fixes.sql` (anciennement `20261002000000`, renommée avant tout
    `db push` pour ne pas être datée du lendemain) :
    - ciblage d'un PC : FK `agent_keys` `ON DELETE SET NULL` et index de poll ;
    - trigger de bail (T45) ;
    - `has_role` retiré à anon, nouvelle fonction `is_admin()` (S19) ;
    - `agent_keys` en lecture et suppression seules côté client, INSERT qui vérifient la
      propriété de la ligne parente (S20) ;
    - CHECK `status`/`level` sur `agent_memory`.
  - `20261001100000_lot1_verif.sql` (suite de la vérification) :
    - la révocation d'une clé (`ON DELETE SET NULL`) ne prolonge plus le bail d'une tâche ;
    - `agent_memory` : statut par défaut `proposed`, client en lecture + suppression
      (S11), index trigramme `pg_trgm` sur `goal` (T11) ;
    - vagues G2/G3 : plus de DELETE client sur `agent_tasks`, `knowledge_base` en lecture
      seule pour le client (contrat §11) ; `agent_keys` en lecture seule ;
    - vague G4 : `has_role` n'est plus exécutable par `authenticated`.
- **RLS** : chaque table est filtrée par `user_id`. **Limite actuelle (S4)** : node-api se
  connecte en `postgres` et contourne donc la RLS. Il applique lui-même le filtrage par
  utilisateur dans chaque requête.
- **Restauration** : `RESTAURATION_BASE.sql` concatène les migrations et sert pour un projet
  **neuf** uniquement. Sur le projet existant, utiliser `supabase db push`.
- **Sauvegardes** : `scripts/backup_db.ps1` / `.sh`. Le mot de passe passe par un fichier
  pgpass temporaire ; le chiffrement gpg/age est obligatoire, sauf
  `BACKUP_ALLOW_PLAINTEXT=1` (S30) ; les droits (GRANT/REVOKE) sont conservés dans le dump
  (S19). Après restauration : `scripts/sql/post_restore_checks.sql`.
- **Rôle `soulbah_api`** (S4) : droits dans `scripts/sql/soulbah_api_grants.sql`, vérifiés
  contre le SQL de node-api (`scripts/ci/check_api_grants.py`) et sur une vraie base
  (`scripts/ci/api_role_checks.sql`).
- **pgvector** : absent du PG18 local. Le DDL vectoriel est remplacé par un stub en local
  (`scripts/ci/apply_migrations.sh --stub-vector`) et vérifié pour de vrai dans le job CI
  `db`, dont l'image `pgvector/pgvector` doit être épinglée sur la version de Supabase.

## 6. Tests et CI

`.github/workflows/ci.yml` :

| Job | Contenu |
|---|---|
| `frontend` | Node 20/22 : lint, `tsc -p tsconfig.app.json`, vitest, build. |
| `console` | Build de `backend/console` (avec `tsc`). |
| `node-api` | `tsc`, vitest, `npm run build`. |
| `python-ia` | Python 3.11/3.12 : venv, compileall, pytest. |
| `agent` | `windows-latest` : venv, pytest `agent/tests` avec `SOULBAH_NO_DOTENV=1`. |
| `db` | `pgvector/pgvector` + `scripts/ci/auth_stub.sql` : migrations appliquées deux fois, schéma identique après rejeu, assertions `scripts/ci/schema_checks.sql` (FK, trigger, policies, droits, index), `scripts/sql/post_restore_checks.sql`, rôle `soulbah_api` (statique + `api_role_checks.sql`), `RESTAURATION_BASE.sql` à jour. |
| `scripts` | Postgres 16 : `scripts/ci/test_backup_db.sh` (URL avec « + », refus du dump en clair, droits conservés) et `test_backup_db.ps1` sous pwsh. |
| `compose` | `docker compose config`, avec et sans le profil `demo` ; variables documentées transmises aux services (`scripts/ci/check_compose_env.py`). |
| `docker-build` | `docker compose build` (python-ia, node-api, console) ; rust-compute non bloquant. |
| `rust` | `cargo check --locked` de rust-compute, non bloquant (Cargo.lock généré en artefact tant qu'il n'est pas versionné, T50). |
| `security` | `npm audit --omit=dev` (frontend, node-api), `pip-audit` (bloquant en prod, non bloquant en dev), gitleaks sur tout l'historique. |

`.github/workflows/codeql.yml` : CodeQL (`javascript-typescript`, `python`, requêtes
`security-extended`) à chaque push sur `main`, sur les PR et chaque lundi.

Plancher de non-régression (contrat §15) : agent 156, python-ia 55, node-api 38, front 48 tests.

## 7. Cible V2 (résumé, non implémenté)

L'audit retient une architecture à trois plans (§9) :

- **P1 contrôle** = node-api, seul écrivain d'un schéma `soulbah` additif. Il porte les
  sessions, le DAG, le scheduler, les baux, l'audit chaîné et les niveaux L0–L3.
- **P2 modèles** = python-ia, seul routeur de modèles.
- **P3 exécution** = `agent/`, transformé en runtime à N sous-processus clôturés par bail,
  avec un Tool Gateway et des preuves.

Une tâche n'y est terminée que sur preuves. Ordre de livraison : audit §13 (LOT 1 sécurité et
défauts confirmés → … → LOT 15 dashboard et benchmarks).

## 8. Historique

- Les 5 edge functions Supabase (`chat`, `generate-formation`, `generate-application`,
  `manage-database`, `agent-tasks`) ont été remplacées par `backend/node-api`. Le détail est
  dans [`backend/MIGRATION.md`](../backend/MIGRATION.md). Leur suppression côté Supabase
  figure dans la check-list de reprise.
- L'ancienne feuille de route en « phases 0–6 » de ce document est remplacée par le plan en
  15 lots de l'audit LOT 0 : l'agent local, le planner et l'évaluateur LLM, la mémoire et la
  KB existent désormais, à des niveaux de maturité détaillés dans l'audit §3.
