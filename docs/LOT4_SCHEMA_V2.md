# LOT 4 — Schéma V2 additif (`soulbah`)

Source des exigences : `docs/SOULBAH_V2_LOT0_AUDIT.md` §9.4 (machine à états), §9.5 (messages), §9.6
(parallélisme), §9.7 (verrous), §9.8 (preuves), §9.9 (reprise), §9.10 (niveaux), §12 (migrations,
correspondance des 18 tables, règles « Jamais »), §13 ligne « 4. Schéma V2 additif ».

## 1. Principes

- **Additif et idempotent** : 12 migrations `20261001120000` → `20261001121100`, toutes rejouables
  (`IF NOT EXISTS`, `CREATE OR REPLACE`, `DROP TRIGGER IF EXISTS` puis `CREATE`, contraintes `NOT VALID`
  puis `VALIDATE` dans un bloc d'exception). Vérifié par `scripts/ci/apply_migrations.sh` : second passage
  sans erreur et schéma `public`, `auth` **et `soulbah`** identique (pg_dump comparé).
- **Rien n'est supprimé, renommé ni modifié** : `public.*` conserve ses tables, le CHECK de statut
  d'`agent_tasks` (5 statuts) est intact, aucune FK sur `agent_events.task_id`, la dimension de
  `knowledge_base.embedding` n'est pas changée en place, `modules_status` reste. Les lignes existantes ne
  sont jamais réécrites : les statuts hérités sont **dérivés par des vues**.
- **Schéma `soulbah` fermé** : `REVOKE ALL` pour PUBLIC, anon, authenticated (schéma et privilèges par défaut),
  RLS activée sur chaque table sans aucune policy. Seul node-api (rôle `soulbah_api`, `BYPASSRLS`) y
  écrit. Supabase : ne pas exposer `soulbah` dans l'API (« Exposed schemas »).
- **Dates** : les fichiers portent la date du jour (2026-10-01), pas celle proposée par l'audit
  (`20261015…`, dans le futur : même piège que la migration LOT 1 renommée).

## 2. Les 12 fichiers

| # | Fichier | Objets |
|---|---|---|
| 1 | `v2_schema` | schéma `soulbah` fermé, `set_updated_at()`, aides `is_security_level`, `is_json_array`, `is_json_object` |
| 2 | `v2_users_sessions` | `user_settings` (max_parallel_agents CHECK 1–32, plafond L0–L3, budget), `sessions` (8 statuts, plan versionné, budget/dépense, `simulated`) |
| 3 | `v2_agents_runtimes` | `agent_keys` + `kind`, `scopes`, `expires_at`, `capabilities`, `last_seen_at` ; `runtimes` (max_slots 1–32, 1 par clé) ; `agents` (rôle versionné, IDLE/BUSY/WAITING/STOPPED/FAILED) |
| 4 | `v2_tasks` | `tasks` (10 états, attempt, bail, idempotency_key, niveau, ressources, spec, critères, `simulated`), trigger `tasks_check_transition` (§9.4), `agents.current_task_id`, `agent_tasks.v2_task_id` |
| 5 | `v2_task_dependencies` | `task_dependencies` (hard/soft) + trigger anti-cycle (même session, verrou de session) |
| 6 | `v2_messages` | `messages` (9 types, corrélation, reply_to, payload objet ≤ 64 Ko, ack) |
| 7 | `v2_actions_tool_calls` | `actions` (planned → verified, UNIQUE task/attempt/step, « simulated jamais verified »), `tool_calls` (exit_code, http_status, jetons, coût, fournisseur) |
| 8 | `v2_knowledge` | `knowledge_base` + source_uri, mime, ingest_status, embedding_model, last_written_at, `doc_status` nullable ; vue `knowledge_documents` ; `knowledge_chunks` (tsvector généré, `embedding vector` sans dimension, HNSW partiel par modèle) |
| 9 | `v2_memory` | `agent_memory` + session_id, scope, source_task_id, evidence_ids, confidence, validated_by/at, expires_at, is_simulation ; CHECK « validated exige preuve ou validateur » ; vue `memories` |
| 10 | `v2_skills_evaluations_checkpoints` | `skills` (UNIQUE name/version, catalog/learned), `evaluations` (1 par tentative, verdict, confiance, `action_taken`), `checkpoints` |
| 11 | `v2_artifacts_recordings_permissions_leases` | `artifacts` (sha256 unique par utilisateur), `recordings`, `permissions` (grants/demandes, payload_sha256, token_hash), `resource_leases` (unique partiel exclusif) |
| 12 | `v2_audit` | `audit_logs` chaîné (prev_hash/row_hash, sha256 natif), `audit_chain_head`, triggers immuables, `verify_audit_chain()` |

Les deux tables supplémentaires de l'audit (`resource_leases`, `audit_chain_head`) sont incluses :
**20 tables** et 2 vues dans `soulbah`.

## 3. Points de conception

- **Machine à états en base** (`tasks_check_transition`) : la table §9.4 est appliquée telle quelle ;
  CANCELLED atteignable depuis tout état non terminal ; FAILED → READY (relance manuelle) autorisé ;
  READY → RUNNING exige `attempt = attempt + 1`. node-api (LOT 7) applique la même table ; la base
  refuse ce que le code laisserait passer.
- **Anti-cycle** : CTE récursive bornée (profondeur 1000) depuis la dépendance ajoutée ; les deux
  tâches doivent être dans la même session, verrouillée `FOR UPDATE` pour sérialiser les insertions
  concurrentes d'un même DAG.
- **Audit chaîné** : `row_hash = sha256(prev_hash | id | user | session | task | actor | action | entity |
  entity_id | data::jsonb (canonique) | created_at UTC µs)`. La tête de chaîne est verrouillée et avancée
  dans le trigger **BEFORE INSERT** (un trigger AFTER ne tournerait qu'en fin d'instruction et laisserait
  toutes les lignes d'un INSERT multi-lignes sur le même prev_hash). UPDATE, DELETE et TRUNCATE lèvent
  `insufficient_privilege`. `verify_audit_chain()` renvoie `(ok, checked, broken_at)` et détecte aussi
  une tête désynchronisée.
- **Mémoire** : la contrainte accepte la forme V1 (`metadata.validated_by`, posée par
  `routes/agentMemory.ts`) jusqu'au LOT 8 ; la vue `soulbah.memories` expose le statut effectif
  (ligne héritée « validated » sans preuve → `proposed`) et masque les lignes expirées.
- **pgvector** : `knowledge_chunks.embedding` est `vector` sans dimension (T38) ; l'index HNSW est un
  index d'expression partiel `((embedding::vector(1536)) vector_cosine_ops) WHERE embedding_model = …`,
  un par modèle. Le stub local (`--stub-vector`) réécrit aussi `vector` sans dimension et saute les HNSW
  avec clause WHERE ; les vérifications vectorielles réelles restent dans le job CI `db`.
- **Rôle `soulbah_api`** : `scripts/sql/soulbah_api_grants.sql` accorde USAGE + S/I/U/D sur toutes les
  tables du schéma, séquences et fonctions, puis **retire** UPDATE/DELETE/TRUNCATE sur `audit_logs`.
  `scripts/ci/api_role_checks.sql` vérifie insertion de session/tâche, transition, audit, refus de
  modification de l'audit, lecture des vues.

## 4. Critères de sortie (audit §13) et preuves

| Critère | Preuve |
|---|---|
| Application idempotente | `apply_migrations.sh` : 31 migrations, 27 rejouées, schéma `public`+`auth`+`soulbah` identique (local PG 18.1 avec stub ; job CI `db` avec pgvector) |
| `soulbah.*` refusé à authenticated | `schema_checks.sql` : `has_schema_privilege` faux pour anon/authenticated ; `SET ROLE authenticated` → `insufficient_privilege` sur `soulbah.tasks`, `soulbah.memories`, INSERT `audit_logs`, `verify_audit_chain()` |
| Le trigger refuse le cycle A → B → A | `schema_checks.sql` : A→B→C puis C→A refusé, B→A refusé, auto-dépendance et dépendance inter-sessions refusées |
| UPDATE/DELETE d'audit refusés | `schema_checks.sql` : UPDATE, DELETE, TRUNCATE → `insufficient_privilege` ; altération hors triggers détectée par `verify_audit_chain()` (`broken_at` = ligne modifiée) ; aussi vérifié pour `soulbah_api` |
| Suites V1 vertes | node-api 209 + 12 intégration (sur la base migrée V2), python-ia, agent inchangés ; `tsc -b` frontend avec `types.ts` étendu ; `check_api_grants.py` OK |
| Restauration et types régénérés | `RESTAURATION_BASE.sql` régénéré (`scripts/build_restore_sql.sh`) ; `frontend/src/integrations/supabase/types.ts` : colonnes publiques ajoutées (le schéma `soulbah` n'est pas exposé à PostgREST) |

Vérifications supplémentaires dans `schema_checks.sql` : CHECK 1–32 de `max_parallel_agents`, chemin
nominal PENDING → READY → RUNNING → VALIDATING → COMPLETED, refus de PENDING → RUNNING, de READY → RUNNING
sans `attempt+1`, de VALIDATING → RUNNING et des sorties d'un état terminal, FAILED → READY → CANCELLED,
tâche simulée jamais COMPLETED, unicité du verrou exclusif, idempotence des actions, « simulated jamais
verified », vue `memories` (hérité → proposed, validated sans preuve refusé, formes V1 et V2 acceptées,
scope inconnu refusé), vue `knowledge_documents` (recherche → finding dérivé, aucune ligne réécrite),
chunks (tsvector, unicité, type `vector` sans dimension et HNSW partiel quand pgvector est présent),
`agent_tasks.v2_task_id` remis à NULL à la suppression de la tâche V2.

## 5. Application sur Supabase

Ordre inchangé (§12) : vérifier hardening et LOT 1 appliqués, `backup_db.ps1`, répétition locale
(`bash scripts/dev_db/dev_db.sh reset`), run CI `db` vert, puis `supabase db push`. Après application :
`scripts/sql/post_restore_checks.sql`, puis rejouer `scripts/sql/soulbah_api_grants.sql` (nouveaux droits
sur `soulbah`). Ne pas exposer le schéma `soulbah` à l'API Supabase.
