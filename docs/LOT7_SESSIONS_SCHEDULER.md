# LOT 7 — Sessions, file, scheduler, bus

Source des exigences : `docs/SOULBAH_V2_LOT0_AUDIT.md` §9.3 (Orchestrator, Scheduler), §9.4 (machine
à états), §9.5 (messages), §9.6 (`max_parallel_agents`), §9.7 (verrous), §9.9 (reprise), §13 ligne « 7.
Sessions, file, scheduler, bus » (critères : 6 workers factices, 1 000 entrelacements → 0 double bail ;
RUNNING ≤ max pour 1, 3 et 6 ; toutes les transitions du §9.4 testées, aucune autre acceptée).

## 1. Modules (`backend/node-api/src/v2/`)

| Module | Rôle |
|---|---|
| `tasks/stateMachine.ts` | table des transitions §9.4 (pure), états terminaux et à bail, backoff 30 s / 2 min / 8 min, politique de retry (`afterFailure`), raisons non rejouables |
| `tasks/repo.ts` | `transitionTask` : UPDATE gardé par l'état de départ (CAS), colonnes autorisées, libération des ressources et des agents en quittant un état à bail, audit dans la transaction |
| `sessions/dag.ts` | `validatePlan` : nœuds (clé, titre, rôle, niveau, spec, critères, ressources, priorité, retries), arêtes hard/soft, détection de cycle, ordre topologique |
| `sessions/repo.ts` | cycle de session (DRAFT → PLANNING → AWAITING_APPROVAL → RUNNING/PAUSED → terminal), `setPlan` (tâches PENDING + dépendances, plan versionné), `approveSession` (+ grant L1 de session), `cancelSession`, `closeSessionIfDone`, réglage `max_parallel_agents` |
| `scheduler/parallelism.ts` | plafond effectif = min(global, utilisateur, mission, slots du runtime), bornes 1–32 |
| `scheduler/scheduler.ts` | `tick()` (verrou consultatif, PENDING → READY/BLOCKED, RETRYING → READY, escalade BLOCKED → FAILED, reaper des baux → RETRYING direct ou FAILED, ressources échues, clôture de session) ; `lease()` (verrou par utilisateur + `FOR UPDATE SKIP LOCKED`, ressources exclusives/partagées sous SAVEPOINT, READY → RUNNING `attempt+1`, agent BUSY) ; `keepalive()` (prolongation, ordre `continue`/`stop`, réponses et messages en attente) |
| `bus/messages.ts` | 9 types et leurs effets d'état ; `validate()` (simulé → jamais COMPLETED ; sans critère → COMPLETED ; avec critères → VALIDATING pour le LOT 10) ; `answerQuestion` |
| `routes/sessions.ts` | API utilisateur (JWT) sessions et tâches |
| `routes/runtime.ts` | API runtime (clé agent) : register, lease, keepalive, result, message, checkpoint, ack |
| `routes/stream.ts` | SSE `GET /api/v2/stream?session_id=` : instantané émis à chaque changement (polling base, repli robuste prévu par l'audit §14 ; LISTEN/NOTIFY branchable sans changer le contrat) |

Le scheduler tourne dans `server.ts` toutes les `SOULBAH_SCHEDULER_INTERVAL_SECONDS` (5 s) après la
connexion à la base, avec essai non bloquant du verrou ; les actions utilisateur (approbation, reprise,
relance) déclenchent un tick immédiat.

## 2. Contrats

**Utilisateur (JWT)**

| Route | Effet |
|---|---|
| `POST /api/v2/sessions` `{goal, max_security_level?, max_parallel_agents?, budget_usd?, environment?, simulated?, plan?}` | DRAFT, ou AWAITING_APPROVAL si `plan` est fourni |
| `POST /api/v2/sessions/:id/plan` `{plan: {nodes, edges}}` | tâches PENDING, dépendances, `plan_version + 1` ; 400 cycle / forme ; 409 hors DRAFT/PLANNING/AWAITING_APPROVAL |
| `POST /api/v2/sessions/:id/approve` | RUNNING + grant L1 de session (`permissions.kind='grant'`) ; tick immédiat |
| `POST /api/v2/sessions/:id/pause` · `/resume` · `/cancel` | PAUSED (plus de nouveaux baux) · RUNNING · CANCELLED (tâches annulées, grants révoqués) |
| `PATCH /api/v2/sessions/:id` `{max_parallel_agents}` | surcharge par mission, relue à chaque bail ; baisser ne bloque que les nouveaux baux |
| `GET /api/v2/sessions`, `/:id`, `/:id/messages` | listes ; `/:id` renvoie session, tâches, agents, `busy_agents` (« x/6 ») |
| `GET /api/v2/tasks/:id` · `POST /:id/answer` · `/:id/retry` · `/:id/cancel` | détail ; WAITING → RUNNING ; FAILED → READY (manuel, audité) ; → CANCELLED |
| `GET /api/v2/stream?session_id=` | SSE `event: snapshot` (statut, tâches, agents BUSY, dernier message, dernière ligne d'audit), `: ping` |

**Runtime (clé agent)** — toute écriture est clôturée par `(task_id, attempt, lease_owner)` ; le runtime
doit appartenir à la clé appelante.

| Route | Effet |
|---|---|
| `POST /api/v2/runtime/register` `{hostname, version, max_slots, capabilities}` | upsert `runtimes` (1 par clé), `agent_keys.kind='runtime'` → `{runtime_id, max_slots, lease_seconds, max_parallel}` |
| `POST /api/v2/runtime/lease` `{runtime_id, slots}` | tâches READY attribuées (`attempt+1`, `lease_owner=runtime:<id>`, ressources acquises) |
| `POST /api/v2/runtime/keepalive` `{runtime_id, tasks:[{task_id, attempt}]}` | prolonge ; par tâche `control: continue|stop`, `answers`, `messages` non acquittés |
| `POST /api/v2/runtime/tasks/:id/result` `{runtime_id, attempt, result, simulated?}` | TASK_RESULT → VALIDATING → COMPLETED (sans critère) ; 409 bail non détenu ; 410 tâche disparue |
| `POST /api/v2/runtime/tasks/:id/message` `{runtime_id, attempt, type, payload}` | un des 9 types (effets ci-dessous) |
| `POST /api/v2/runtime/tasks/:id/checkpoint` `{runtime_id, attempt, seq, step_cursor, variables}` | `checkpoints` (idempotent), bail prolongé |
| `GET /api/v2/runtime/tasks/:id` · `POST /api/v2/runtime/messages/:id/ack` | état, réponses, dernier checkpoint · acquittement |

**Effets des 9 messages** (§9.5) : TASK_RESULT → VALIDATING puis validation ; QUESTION → WAITING ;
BLOCKER → BLOCKED (escalade 24 h) ; EVIDENCE → ajoutée à `result.evidence` ; REVIEW_REQUEST → tâche
`qa_reviewer` PENDING dépendant (hard) de la tâche ; ERROR → RETRYING (backoff, `retry_count+1`) ou
FAILED (reprises épuisées, `policy_refused`) ; TASK_REQUEST, REVIEW_RESULT, KNOWLEDGE_FOUND → stockés et
audités (effets complets aux LOTS 11, 12, 13). Un message d'une tentative périmée est refusé (409).

## 3. Garanties de la file

- **0 double bail** : `SELECT … FOR UPDATE SKIP LOCKED` sur les tâches READY + CAS `WHERE status = 'READY'` ;
  un bail = `attempt + 1`, `lease_owner`, `lease_expires_at`, un agent BUSY, une ligne d'audit.
- **RUNNING ≤ max** : la capacité est comptée sous verrou consultatif par utilisateur
  (`hashtext('soulbah.lease:<user>')`) ; plafond effectif relu à chaque bail ; surcharge par mission comptée
  par session.
- **Ressources** (§9.7) : acquises dans la transaction du bail, SAVEPOINT par tâche (un conflit saute la
  tâche sans rien annuler), unicité des exclusifs garantie par l'index partiel du LOT 4, libérées à la sortie
  d'un état à bail et par le reaper.
- **Reaper** (§9.4, §9.9) : bail expiré → RETRYING **directement** (jamais via FAILED), `next_attempt_at`
  = backoff ; reprises épuisées → FAILED ; une relance manuelle (FAILED → READY) reste possible.
- **Machine à états** : vérifiée en code (`assertTransition`) ET en base (trigger LOT 4) ; chaque transition
  est une ligne `audit_logs` (`task.transition`, `from`, `to`, `attempt`).

## 4. Critères de sortie (audit §13) et preuves

| Critère | Preuve |
|---|---|
| 6 workers factices, 1 000 entrelacements : 0 double bail | `test/integration/v2Scheduler.pg.test.ts` : 1 000 appels `lease()` concurrents sur 6 runtimes et 40 tâches → aucune tâche attribuée deux fois, `attempt = 1`, 6 agents BUSY, 6 lignes d'audit READY → RUNNING |
| RUNNING ≤ max pour 1, 3 et 6 | même fichier : plafond utilisateur 1, 3, 6 → exactement 1, 3, 6 tâches à bail après 300 appels concurrents ; surcharge par mission (2 puis 1) respectée |
| Toutes les transitions §9.4 testées, aucune autre acceptée | `test/v2Core.test.ts` : les 100 paires d'états comparées à la table de l'audit recopiée indépendamment ; côté base : `scripts/ci/schema_checks.sql` (LOT 4) |
| Dépendances, ressources, reaper, bus, clôture | `v2Scheduler.pg.test.ts` : promotion READY après COMPLETED des dépendances, ressource exclusive (1 seule) / partagée (plusieurs), bail expiré → RETRYING → READY → FAILED → relance, QUESTION/réponse, EVIDENCE, REVIEW_REQUEST, BLOCKER, ERROR → RETRYING, session COMPLETED/FAILED |

## 5. Variables

| Variable | Défaut | Rôle |
|---|---|---|
| `SOULBAH_MAX_PARALLEL_AGENTS` | 6 | plafond global (1–32) |
| `SOULBAH_LEASE_SECONDS` | 90 | durée d'un bail, prolongé par keepalive |
| `SOULBAH_SCHEDULER_INTERVAL_SECONDS` | 5 | période du tick |
| `SOULBAH_STREAM_INTERVAL_MS` | 2000 | période de relecture du flux SSE |

## 6. Corrections apportées au schéma LOT 4 (migrations non encore appliquées sur Supabase)

- `permissions_decision_consistent` : `approved`/`denied` exigent `decided_at` ; `revoked` (grant révoqué
  après approbation) et `expired` ne sont plus contraints.
- `audit_logs.seq` : attribué par le trigger BEFORE INSERT sous le verrou de la tête de chaîne (une
  identité était tirée avant le verrou : sous concurrence, l'ordre des numéros divergeait de l'ordre de
  chaînage et `verify_audit_chain()` signalait une fausse rupture).

## 7. Limites et suites

- La validation par critères (DSL §9.8) laisse les tâches en VALIDATING : LOT 10.
- Les messages TASK_REQUEST (patch de plan) et REVIEW_RESULT (merge) sont stockés sans effet d'état : LOTS 11 et 12.
- Le runtime P3 (superviseur, sous-processus, journal) qui consomme ces routes est le LOT 8 ; l'agent V1
  continue de passer par `/api/agent-tasks`.
- Le flux SSE repose sur un polling de la base ; LISTEN/NOTIFY (pooler :5432) pourra l'alimenter.
