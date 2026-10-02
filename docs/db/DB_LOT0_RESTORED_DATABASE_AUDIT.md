# SOULBAH RESTORED DATABASE AUDIT

DB LOT 0 de la mission « Local-first + Database-first + migrations complètes ». Réalisé le 2026-10-02.
**Aucune écriture sur la base restaurée** : inventaire en transactions `READ ONLY`, sauvegarde par `pg_dump`
(lecture), tous les essais de migration sur des copies locales jetables.

Preuves versionnées :

| Preuve | Fichier |
|---|---|
| Baseline (catalogue complet, empreintes, volumes) | `db/baseline/2026-10-02_restored/catalog.json`, `baseline.json` |
| Inventaire lisible | `db/baseline/2026-10-02_restored/INVENTORY.md` |
| Définitions des fonctions | `db/baseline/2026-10-02_restored/functions.sql` |
| État réel de chaque migration du dépôt | `db/baseline/2026-10-02_restored/migration_state.json` |
| Schema Drift Report brut | `db/baseline/2026-10-02_restored/drift.md`, `drift.json` |
| Schéma attendu par le code | `db/baseline/2026-10-02_expected/catalog.json` |
| Test de restauration | `db/dryrun/2026-10-02/restore_test.json` |
| Rattrapage essayé sur copie | `db/dryrun/2026-10-02/build_catchup_template.json`, `after_catchup/` |

Outillage (`scripts/db/`, 16 tests automatisés verts) : `db_catalog.py` (SoulbahDatabaseBaseline),
`catalog_diff.py` + `schema_drift.py` (SchemaDriftDetector), `migration_state.py` et `migrate.py`
(MigrationPlanner), `restore_test.py`, `build_catchup_template.py`, `lot_selftest.py`, `sqlq.py`.

---

## 1. Où est la base restaurée

| Base | Emplacement | Statut |
|---|---|---|
| **Base Supabase restaurée** | projet `ntvwbafvjgzsjoumtcmb`, pooler `aws-1-eu-central-1`, `DATABASE_URL` de `backend/.env` | Inspectée (lecture seule). C'est la base de production de Soulbah, sortie de pause. |
| Sauvegarde source probable | `Desktop\Ma Base de donnée\db_cluster-17-08-2026@09-27-45.backup.gz` (sauvegarde de cluster Supabase) | Non ouverte. Les données de la base restaurée s'arrêtent à juillet 2026. |
| Service PostgreSQL 18 Windows | `localhost:5432` (service `postgresql-x64-18`, démarrage automatique) | **Non inspecté** : mot de passe inconnu (authentification scram, connexions locales seulement). Si une restauration y a aussi été faite, il faudra le préciser. |
| Base de développement | `127.0.0.1:54329` (`.dev_db`, jetable) | Utilisée par l'application locale et pour les copies d'essai. |

## 2. Moteur et version

PostgreSQL **17.6** (Supabase), base `postgres`, 14,7 Mo, UTF8. Empreinte du schéma au relevé :
`21ed7447…` (tout), `af62842b…` (schémas applicatifs). Paramètres relevés dans `INVENTORY.md`.

## 3. Schémas

| Schéma | Propriétaire fonctionnel | Tables |
|---|---|---|
| `public` | Soulbah (V1) | 18 |
| `auth` | Supabase | 27 |
| `storage` | Supabase | 8 |
| `realtime` | Supabase | 15 |
| `vault` | Supabase | 1 |
| `extensions`, `graphql`, `graphql_public`, `pgbouncer` | Supabase | 0 |
| **`soulbah`** | Soulbah (V2) | **absent** |

## 4. Extensions

`pg_stat_statements 1.11` (extensions), `pgcrypto 1.3` (extensions), `uuid-ossp 1.1` (extensions),
`supabase_vault 0.3.1` (vault), **`vector 0.8.0` installé dans `public`**, `plpgsql`. **`pg_trgm` absent**
alors que la migration `lot1_verif` en a besoin (elle le crée : `CREATE EXTENSION IF NOT EXISTS`).

## 5. Tables, volumes et objets

18 tables publiques, toutes avec RLS activée, **211 lignes au total** :

| Table | Lignes | | Table | Lignes |
|---|---|---|---|---|
| agent_events | 42 | | knowledge_domains | 15 |
| agent_keys | 2 | | knowledge_versions | 0 |
| agent_memory | 4 | | modules_status | 0 |
| agent_tasks | 14 | | profiles | 10 |
| applications | 1 | | system_logs | 59 |
| chat_conversations | 9 | | user_migrations | 0 |
| chat_messages | 32 | | user_roles | 10 |
| formations | 12 | | user_schemas | 0 |
| knowledge_base | 1 (aucun vecteur stocké) | | user_table_data | 0 |

Schéma `auth` : 10 utilisateurs, 10 identités, 45 sessions, 91 jetons de rafraîchissement, **aucun facteur MFA**.
`storage` : aucun bucket, aucun objet.

| Objets du schéma public | Nombre |
|---|---|
| Colonnes | 146 |
| Contraintes (PK, FK, UNIQUE, CHECK) | 38 |
| Index | 43 |
| Vues, vues matérialisées, séquences | 0 |
| Type énuméré | 1 (`app_role` : admin, moderator, user) |
| Fonctions de l'application | 4 (`handle_new_user`, `has_role`, `update_updated_at_column`, `rls_auto_enable` de Supabase) |
| Fonctions de l'extension pgvector dans `public` | 118 |
| Triggers | 8 (`updated_at`) |
| Policies | 49 |
| Publication temps réel | `formations`, `system_logs`, `agent_tasks`, `agent_events` |

Détail colonne par colonne, contrainte par contrainte, index par index : `INVENTORY.md`.

## 6. Rôles et droits

- Rôles Supabase standard (`anon`, `authenticated`, `service_role`, `authenticator`, `supabase_admin`…).
  `postgres` a BYPASSRLS. **Le rôle `soulbah_api`** (moindre privilège prévu pour node-api, `docs/SUPABASE_REPRISE.md`
  §10) **n'existe pas** : node-api se connecte toujours en `postgres`.
- `anon` et `authenticated` ont **tous les droits de table** sur chaque table publique (SELECT, INSERT, UPDATE,
  DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN) : droits par défaut de Supabase. La RLS borne les lignes pour
  SELECT, INSERT, UPDATE et DELETE ; TRUNCATE n'est pas exposé par l'API Supabase.
- `has_role(uuid, app_role)` est exécutable par PUBLIC, `anon` et `authenticated` (révocation prévue par
  `lot1_fixes`, non appliquée).

## 7. Historique des migrations

**Aucun.** Ni `supabase_migrations.schema_migrations` (historique de la CLI Supabase), ni historique propre à
Soulbah. Le système officiel du dépôt est la CLI Supabase (`supabase db push`), vérifié en CI par
`scripts/ci/apply_migrations.sh`. Sur cette base, les migrations ont donc été appliquées hors CLI (éditeur SQL ou
Lovable) : un `supabase db push` tenterait de tout rejouer et échouerait sur les migrations de février 2026, non
rejouables.

L'état réel a été établi **objet par objet** : chaque migration du dépôt est rejouée sur une base locale jetable,
le catalogue est photographié après chacune, puis ses objets sont cherchés dans la base restaurée
(`migration_state.py`) :

| Période | Migrations | Verdict |
|---|---|---|
| Février → juillet 2026 | 16 (`20260218031213` → `20260707000000`) | **APPLIED** : tous leurs objets présents |
| `20261001000000_hardening` | 1 | **NOT_APPLIED** (84 objets absents) |
| `20261001090000_lot1_fixes` | 1 | **NOT_APPLIED** (31) |
| `20261001100000_lot1_verif` | 1 | **PARTIAL** (1 présent, 12 absents) |
| V2 `20261001120000` → `20261001121100` | 12 | **NOT_APPLIED** : schéma `soulbah` inexistant |

La base restaurée correspond donc au **schéma du 7 juillet 2026**.

## 8. La base restaurée correspond-elle au code actuel ?

**Non.** Écarts classés (`drift.md`), base restaurée contre schéma attendu par les 31 migrations du dépôt :

| Écart | Nombre | Origine |
|---|---|---|
| `missing_schema` | 1 | `soulbah` (V2) |
| `missing_table` | 20 | 19 tables V2 + `public.analysis_requests` (hardening) |
| `missing_column` | 308 | tables V2 surtout, colonnes LOT 1 de `agent_tasks` |
| `missing_check_constraint`, `missing_foreign_key`, `missing_primary_key`, `missing_unique_constraint` | 123, 57, 20, 8 | V2, hardening, LOT 1 |
| `missing_index` | 89 | V2, hardening, LOT 1 (dont l'index trigramme de `agent_memory`) |
| `missing_function` | 13 | V2 + `is_admin`, `agent_tasks_set_updated_at`, `agent_tasks_keep_updated_at_on_control` |
| `missing_trigger` | 14 | V2 + `update_agent_tasks_updated_at_control` |
| `missing_policy` / `extra_policy` / `policy_definition_mismatch` | 8 / 9 / 6 | policies remplacées par hardening et LOT 1 |
| `extra_grant` | 8 | `EXECUTE has_role` pour PUBLIC, anon, authenticated ; droits de `rls_auto_enable` (Supabase) |
| `extra_index` | 3 | `idx_agent_keys_hash`, `idx_agent_tasks_user_status`, `idx_agent_memory_goal_trgm` (B-tree mal nommé) |
| `column_definition_mismatch` | 1 | `agent_memory.status` par défaut `validated` (LOT 1 : `proposed`) |
| `trigger_definition_mismatch` | 1 | trigger `updated_at` d'`agent_tasks` (LOT 1) |
| `missing_extension` / `extra_extension` | 1 / 5 | `pg_trgm` manquant ; extensions Supabase en plus |
| `unverified_vector_index` | 1 | index HNSW présent, non comparable localement (pgvector absent en local) |
| `duplicate_index`, `invalid_policy`, `orphan_table` | 0 | — |

Trois fonctions (`handle_new_user`, `has_role`, `update_updated_at_column`) ont été écrites avec des fins de ligne
Windows et des espaces supplémentaires : comparées sans tenir compte des espaces, elles sont **identiques** au
dépôt. Aucun objet applicatif n'a été créé hors migrations, sauf `rls_auto_enable` et son déclencheur d'événement
`ensure_rls`, ajoutés par Supabase pour activer la RLS sur toute nouvelle table publique (à ne pas toucher).

## 9. Sauvegarde et restauration — prouvées

| Étape | Résultat |
|---|---|
| Sauvegarde | `scripts/backup_db.sh` (schémas `public` et `auth`), chiffrée AES-256 par gpg : `backups/soulbah_20261002_1239.dump.gpg` (376 Ko) et `.sql.gpg` (386 Ko). Phrase de passe générée hors du dépôt : `%USERPROFILE%\.soulbah\backup_passphrase.txt`. |
| Lisibilité | `pg_restore -l` : 490 entrées. |
| Restauration isolée | Base locale neuve : **0 erreur**, structure et droits identiques, **211 lignes identiques sur 18 tables**. |
| Écarts connus | pgvector simulé localement ; extensions propres à Supabase ; **publications temps réel non incluses** par un dump filtré par schéma. |
| Fichiers déchiffrés | supprimés après le test. |

**Limite trouvée** : après une restauration depuis ces sauvegardes, la diffusion temps réel de `formations`,
`system_logs`, `agent_tasks` et `agent_events` est perdue tant que les `ALTER PUBLICATION … ADD TABLE` des
migrations ne sont pas rejoués. La procédure de restauration doit l'inclure.

## 10. Rattrapage essayé sur une copie — prouvé

Sur une copie locale restaurée depuis la sauvegarde (`build_catchup_template.py`) :

1. historique créé (`20261002100000_db00`), 16 migrations inscrites comme déjà appliquées, avec la preuve ;
2. essai à blanc des 15 migrations en attente : il a **détecté avant toute écriture** que `v2_knowledge` échoue
   sans pgvector (normal en local ; présent sur Supabase) ;
3. application avec pgvector simulé : 15 migrations appliquées, chacune dans sa transaction, durées enregistrées ;
4. **contrôles de la CI verts** sur les vraies données : `schema_checks`, `post_restore_checks`, `api_role_checks` ;
5. schéma obtenu = schéma attendu, aux écarts connus près (historique, pgvector, publications, extensions,
   `rls_auto_enable`).

Point de données relevé : la contrainte `agent_memory_validated_requires_proof` reste `NOT VALID` parce que des
lignes existantes de `agent_memory` ne la respectent pas (défaut historique `validated`). C'est voulu par la
migration (pas d'échec) : ces lignes devront être revues avant `VALIDATE CONSTRAINT`.

## 11. Risques de sécurité — synthèse et traitement

Analyse complète : `db/analysis/2026-10-02_security.json` (21 constats, chacun avec justification, preuves et
recommandation). Ce tableau dit ce que chaque constat devient avec les migrations préparées.

| ID | Sévérité | Constat | Traitement |
|---|---|---|---|
| SEC-01 | HIGH | `agent_tasks` : INSERT/UPDATE/DELETE directs via PostgREST (injection de tâches exécutées par l'agent du PC) | **Rattrapage** : `hardening` §1 (policies INSERT/UPDATE supprimées) puis `lot1_verif` §4 (policy DELETE). Le front n'écrit déjà plus directement (`frontend/src/lib/noDirectWrites.test.ts`). |
| SEC-02 | MEDIUM | `profiles` lisibles par tout utilisateur authentifié (2 adresses e-mail) | **Rattrapage** : `hardening` §8. |
| SEC-03 | MEDIUM | Clés agent sans expiration, jamais renouvelées depuis l'exposition signalée | **Action utilisateur** (prérequis P1 : rotation des clés) — hors migration. |
| SEC-04 | MEDIUM | 45 jetons de rafraîchissement actifs recopiés dans les copies locales | **Corrigé dans les copies** (`restore_test.py` les efface par défaut). En production : révocation des sessions à décider par l'utilisateur. |
| SEC-05 | MEDIUM | Vérificateurs SCRAM dans `catalog.json` | **Corrigé** (`db_catalog.redact_catalog()`, commit `7388843`) ; vérifié sur tous les catalogues de ce jour : 0 occurrence. |
| SEC-06 | MEDIUM | node-api se connecte en `postgres` ; le rôle `soulbah_api` n'existe pas | **Étape du mode d'emploi** (§18) : créer le rôle, jouer `scripts/sql/soulbah_api_grants.sql` ; le DB LOT 16 lui donne les droits sur les objets futurs du schéma `soulbah` s'il existe. |
| SEC-07 | LOW | `has_role` (SECURITY DEFINER) exécutable par PUBLIC, anon, authenticated | **Rattrapage** : `lot1_fixes` §3, `lot1_verif` §6. |
| SEC-08 | LOW | `agent_keys` : policy FOR ALL | **Rattrapage** : `lot1_fixes` §4a, `lot1_verif` §5. |
| SEC-09 | LOW | `agent_memory` : policy FOR ALL, `validated` par défaut | **Rattrapage** : `lot1_verif` §2, `lot1_fixes` §6. |
| SEC-10 | LOW | `knowledge_base` : écritures client directes | **Rattrapage** : `lot1_verif` §4. |
| SEC-11 | LOW | Insertions rattachées aux données d'un autre compte | **Rattrapage** : `lot1_fixes` §4b. |
| SEC-12 | LOW | TRUNCATE, TRIGGER, REFERENCES, MAINTAIN accordés à anon/authenticated sur `public`, et par défaut | **DB LOT 16** (droits présents et privilèges par défaut du rôle `postgres` dans `public`). |
| SEC-13 | LOW | pgvector installée dans `public` (118 fonctions exposées) | **Non traité** : `ALTER EXTENSION vector SET SCHEMA extensions` à évaluer sur une copie avec le vrai pgvector, hors périmètre. |
| SEC-14 | LOW | Aucun MFA | **Action utilisateur** (tableau de bord Supabase). |
| SEC-15 / DATA-01 | LOW / MEDIUM | 2 tâches agent `pending` de juillet servies au premier poll | **Décision utilisateur** avant de reconnecter un agent : les annuler par l'API (`DELETE /api/agent-tasks/:id` n'accepte que les tâches terminées : passer par un `UPDATE status = 'cancelled'` en SQL, ou laisser l'agent les traiter). |
| SEC-16 | LOW | Pas de FK `user_id → auth.users` sur 9 tables | **Rattrapage** : `hardening` §3 (ajoutées NOT VALID puis validées ; aucun orphelin relevé). |
| SEC-17 à SEC-20 | INFO | Policies TO public, fonctions trigger SECURITY DEFINER, realtime, surface hors `public` | Connus, sans action : SEC-18 ne concerne que des fonctions de trigger (non appelables) ; SEC-19 (événements DELETE non filtrés par la RLS) reste un comportement Supabase. |
| SEC-21 | INFO | Aucune migration de sécurité appliquée | C'est l'objet du rattrapage ; `post_restore_checks.sql` passe après (prouvé sur copie, §10 et §17). |

Règle tenue par les lots (DB_MIGRATION_CONVENTIONS.md) : RLS sur toute table de `soulbah` sans policy, aucun
droit pour anon/authenticated/PUBLIC (tables, vues, séquences, fonctions), journaux en ajout seul, Trusted Core
pour les lignes immuables, jamais d'identifiant de connexion dans une table (`db_sources.connection_ref` refuse
toute URL ou mot de passe par contrainte CHECK). Le DB LOT 16 vérifie tout cela et **échoue si un lot a oublié**.

## 12. Risques de performance

| Point | État relevé | Traitement |
|---|---|---|
| Volumes | 211 lignes sur 18 tables (`public`) ; schéma `soulbah` vide avant les lots | Aucun risque immédiat : index créés dans la transaction (pas de `CONCURRENTLY`). |
| Clés étrangères sans index | **23** après rattrapage + lots 01-14 (relevé automatique sur la copie intégrée) : 5 dans `public` (`agent_memory.source_task_id`, `chat_messages.user_id`, `knowledge_versions.user_id`, `user_migrations.user_id`, `user_table_data.user_id`), 12 héritées de V2 (`actions.user_id`, `agents.current_task_id/runtime_id`, `artifacts.session_id`, `evaluations.user_id`, `messages.from_agent_id/reply_to`, `permissions.action_id/decided_by`, `recordings.artifact_id/user_id`, `tool_calls.action_id`) et 6 introduites par les lots (`environment_name` de 4 tables, `agents.version_id`, `projects.owner_user_id`) | **DB LOT 15** : 23 index (partiels sur les colonnes nullables), puis vérification « plus aucune FK sans index » ; le DB LOT 16 le revérifie. |
| Index en double (V2) | `idx_actions_task` = `actions_idempotency` ; `idx_knowledge_chunks_document` = `knowledge_chunks_unique` | **DB LOT 15** les retire (recréés par le retour arrière). |
| Index de `public` vs attendu | 3 en trop, 22 manquants (DRIFT-PUB-14) | Le rattrapage crée les index attendus par le code (`idx_agent_tasks_poll`…). |
| Tables à croissance continue | `resource_metrics`, `health_events`, `model_routing_history`, `code_change_events`, `incident_events`, `audit_logs` | `resource_metrics` : purge contrôlée (`soulbah.purge_resource_metrics(interval)`, rétention minimale d'un jour). Les autres journaux sont en ajout seul strict : une politique de rétention (archivage en artefact puis purge sous Trusted Core) reste à écrire — volumes nuls aujourd'hui. |
| Vecteurs | `knowledge_chunks.embedding` sans dimension fixe (V2) | DB LOT 6v : `embedding_model_id`, index HNSW **partiels par modèle** (1536 OpenAI, 768 nomic), tâches de ré-indexation ; exige pgvector (présent sur Supabase, simulé en local). |
| Files d'attente | Index partiels V2 présents (`idx_tasks_ready`, `idx_tasks_retrying`, `idx_tasks_lease`, `idx_permissions_pending`) | Rien à ajouter. |

## 13. Carte code ↔ base

**node-api** (seul écrivain de `public` et `soulbah`, connexion `postgres` aujourd'hui — SEC-06). Références SQL
relevées dans `backend/node-api/src` (occurrences de `FROM/INTO/UPDATE/JOIN`) :

| Table | Occ. | Table | Occ. | Table | Occ. |
|---|---|---|---|---|---|
| `public.agent_tasks` | 31 | `soulbah.tasks` | 24 | `soulbah.sessions` | 12 |
| `public.formations` | 12 | `public.agent_keys` | 11 | `public.agent_events` | 11 |
| `soulbah.runtimes` | 9 | `soulbah.permissions` | 9 | `public.knowledge_base` | 8 |
| `soulbah.resource_leases` | 6 | `soulbah.messages` | 6 | `soulbah.artifacts` | 6 |
| `public.user_table_data` | 5 | `public.user_schemas` | 5 | `soulbah.agents` | 5 |
| `soulbah.actions` | 5 | `public.chat_conversations` | 5 | `public.applications` | 5 |
| `public.agent_memory` | 5 | `public.user_migrations` | 4 | `soulbah.task_dependencies` | 4 |
| `public.analysis_requests` | 4 | `soulbah.user_settings` | 3 | `soulbah.evaluations` | 3 |
| `soulbah.audit_logs` | 3 | `public.knowledge_versions` | 3 | `soulbah.checkpoints` | 2 |
| `public.knowledge_domains` | 2 | `public.chat_messages` | 2 | | |

Toutes ces tables existent après le rattrapage ; **aucune n'existe dans `soulbah` sur la base restaurée telle
quelle** (DRIFT-PUB-02 : node-api V2 ne démarre pas correctement dessus).

**frontend** (accès direct à Supabase par la clé anon, sous RLS) : `formations` (6), `applications` (5),
`system_logs` (4), `chat_conversations` (4), `profiles` (3), `chat_messages` (2), `agent_tasks` (2, lectures
seulement — le test `noDirectWrites` interdit les écritures), `knowledge_base` (1). Les policies de lecture de
ces tables sont conservées par le rattrapage ; les écritures client supprimées (SEC-01, SEC-08, SEC-10) ne sont
plus faites par le front.

**python-ia** et **agent** : aucun accès SQL direct (ils passent par node-api).

**Tables des lots 01-16** : aucun code ne les consomme encore. Elles préparent les lots applicatifs des missions
Control Center / Autonomie / Intelligence Lab (synchronisation du registre des outils, Project Brain, SOC,
routage des modèles, missions étendues). Les écritures de node-api sur les tables V2 étendues (`sessions`,
`tasks`, `checkpoints`, `skills`, `agents`) restent valides : colonnes ajoutées nullables ou avec défaut, prouvé
par les 57 tests d'intégration de node-api sur la copie intégrée (§17).

## 14. Tables existantes, manquantes, réutilisables, à ne pas toucher

| Catégorie | Tables |
|---|---|
| **Existantes et conservées** (`public`, 18 + 1) | `agent_events`, `agent_keys`, `agent_memory`, `agent_tasks`, `applications`, `chat_conversations`, `chat_messages`, `formations`, `knowledge_base`, `knowledge_domains`, `knowledge_versions`, `profiles`, `system_logs`, `user_migrations`, `user_roles`, `user_schemas`, `user_table_data`, `modules_status` (dépréciée, jamais supprimée) ; `analysis_requests` créée par le rattrapage. |
| **Manquantes que le code exige** | tout le schéma `soulbah` (21 tables V2 + 2 vues + fonctions d'audit) et les objets de `hardening`/`lot1_fixes`/`lot1_verif` (colonnes de ciblage de `agent_tasks`, `analysis_requests`, CHECK, FK `user_id`, policies corrigées) → **rattrapage**. |
| **Réutilisées et étendues par les lots** | `soulbah.sessions` (= missions : projet, environnement, autonomie, genre, résultat), `soulbah.tasks` (projet, définition d'agent), `soulbah.checkpoints` (libellé, genre, artefact d'état), `soulbah.skills` (versions, catégorie, projet), `soulbah.agents` (définition, version, issue), `soulbah.knowledge_chunks` (modèle d'embedding), `soulbah.permissions` (approbations V2, conservée telle quelle), `public.agent_memory` (V1 : conservée ; ses leçons validées copiées dans `memory_items`). |
| **Réutilisées sans changement** | `soulbah.audit_logs` (+ vue `audit_events`), `soulbah.actions` (+ vue `computer_actions`), `soulbah.artifacts`, `soulbah.recordings`, `soulbah.runtimes`, `soulbah.messages`, `soulbah.task_dependencies`, `soulbah.evaluations`, `soulbah.tool_calls`, `soulbah.resource_leases`, `soulbah.user_settings`. |
| **Nouvelles** (lots 01-16) | 167 tables et 10 vues dans `soulbah` (détail par lot au §16 ; architecture dans `DB_TARGET_ARCHITECTURE.md`). |
| **À ne pas toucher** (interdits de `docs/SUPABASE_REPRISE.md` §12, vérifiés par le DB LOT 16 et la CI) | le CHECK de statut de `agent_tasks` ; pas de FK sur `agent_events.task_id` ; `modules_status` ; la chaîne de hachage de `audit_logs` ; les schémas `auth`, `storage`, `realtime`, `vault`, `extensions` (Supabase). |

## 15. Structures en double ou orphelines

| Constat | Décision |
|---|---|
| `soulbah.permissions` (approbations V2) et la table `permissions` demandée par la mission (catalogue des permissions nommées) : **même nom, rôles différents** — `CREATE TABLE IF NOT EXISTS` aurait silencieusement gardé la table V2 (le danger §9) | Catalogue nommé `soulbah.permission_definitions` ; `assert_table_shape()` après chaque création clé. |
| `audit_events`, `security_incidents`, `computer_actions` demandées comme tables alors que `audit_logs`, `incidents`, `actions` les contiennent | Vues (DB LOT 11, 12) : une seule source de vérité. |
| `soulbah.memories` et `soulbah.knowledge_documents` (vues V2 sur `public.agent_memory` et `public.knowledge_base`) | Conservées, documentées (DB LOT 16). |
| Index V2 en double (`idx_actions_task`, `idx_knowledge_chunks_document`) | Retirés (DB LOT 15). |
| `rls_auto_enable()` + event trigger `ensure_rls` créés hors dépôt (DRIFT-PUB-07) | Laissés en place (filet de sécurité Supabase) ; absents de la CI, documenté. |
| `public.agent_tasks` (file V1) et `soulbah.tasks` (V2) : deux files de tâches | Les deux restent : node-api fait le pont V1 → V2 (`agent_tasks.v2_task_id`). |
| 2 tâches `pending` de juillet 2026 (DATA-01) | Décision utilisateur (§11). |
| `supabase/migrations_pending/` vs `supabase/migrations/` | Dossier distinct, jamais lu par `supabase db push` ni la CI ; appliqué uniquement par `migrate.py --pending`. Après application, l'historique de la CLI est réparé (`supabase migration repair`) pour les 31 migrations du dépôt. |

## 16. Plan de migration complet

Toutes les migrations : une transaction chacune, verrou consultatif, inscription dans `soulbah.schema_migrations`
avec empreinte SHA-256, tentatives dans `schema_migration_runs` (ajout seul). « Downtime » : aucune n'exige
d'arrêt ; les `ALTER TABLE … ADD COLUMN` nullables ou avec défaut constant sont instantanés ; `lock_timeout` 10 s
fait échouer proprement la migration si une session tient un verrou (relancer ensuite).

| Migration | Objet | Objets existants réutilisés | Nouveaux objets | Objets modifiés | Migration de données | Risque | Risque d'arrêt | Retour arrière | Tests |
|---|---|---|---|---|---|---|---|---|---|
| `20261002100000_db00` + baseline | Historique des migrations ; inscription des 16 migrations déjà présentes, avec preuve (`migration_state.json`) | schéma `soulbah` s'il existe | `schema_migrations`, `schema_migration_runs`, trigger d'ajout seul | — | 16 lignes d'historique | LOW | aucun | PARTIAL (tables d'historique seulement) | `tests/…db00…test.sql` ; CI de l'outil (18 tests) |
| `20261001000000_hardening` | Policies client d'écriture retirées (SEC-01), CHECK statut/contrôle, FK `user_id` (SEC-16), `analysis_requests`, profils (SEC-02) | 18 tables `public` | `analysis_requests`, FK NOT VALID puis validées | policies, contraintes | validation des FK (0 orphelin) | MEDIUM | aucun | NO (migration du dépôt : revenir par sauvegarde) | prouvée sur copie (§10) + `post_restore_checks.sql` |
| `20261001090000_lot1_fixes` | Ciblage d'un PC dans `agent_tasks`, trigger `updated_at`, `has_role`/`is_admin` (SEC-07), policies (SEC-08, SEC-11), CHECK `agent_memory` | `agent_tasks`, `agent_keys`, `agent_memory` | colonnes, index de poll, `is_admin()` | policies, droits de fonctions | FK `agent_tasks` validées si cohérentes | MEDIUM | aucun | NO | idem |
| `20261001100000_lot1_verif` | Suite LOT 1 : policies restantes (SEC-09, SEC-10, DELETE), index trigram, `has_role` pour authenticated | idem | index | policies | — | MEDIUM | aucun | NO | idem |
| `20261001120000` → `20261001121100` (V2, 12 migrations) | Schéma `soulbah` V2 : sessions, agents, runtimes, tâches, dépendances, messages, actions, appels d'outils, connaissance (vecteurs), mémoire (vues), compétences, évaluations, checkpoints, artefacts, enregistrements, approbations, baux, audit chaîné | `public.knowledge_base`, `public.agent_memory` (vues) | 21 tables, 2 vues, fonctions, triggers, index | `public.agent_tasks.v2_task_id`, `agent_memory` (colonnes V2) | — | MEDIUM | aucun | NO | idem ; 57 tests d'intégration node-api |
| `db01_core` | Noyau : helpers (`append_only`, `assert_table_shape`, Trusted Core), environnements, réglages et état système (historiques), versions, santé, drapeaux | — | 9 tables, 13 fonctions | — | 5 environnements, état système prudent (tout OFF) | MEDIUM | aucun | YES | test SQL (chaque garde), banc 56/56 |
| `db02_projects` | Projets autorisés, dépôts (exclusions `.env*`, clés…), environnements, composants, dépendances, versions | environnements | 6 tables | — | 3 projets | MEDIUM | aucun | YES | idem |
| `db03_agents` | Définitions d'agents versionnées, capacités, permissions, affectations, statut, métriques, échecs, watchdog, revues, quarantaines | `soulbah.agents`, `soulbah.tasks` | 11 tables, 1 fonction | `agents` (+4 col.), `tasks` (+1) | 7 rôles + versions | MEDIUM | aucun | YES | idem |
| `db04_policies_guardrails` | Permissions nommées, rôles immuables, politiques versionnées, décisions, règles d'autonomie, garde-fous critiques immuables | — | 16 tables, 3 fonctions | — | 30 permissions, 4 rôles, politique SAFE (36 règles), 12 garde-fous | MEDIUM | aucun | YES | idem |
| `db05_memory` | Mémoire structurée (fiabilité calculée, remplacement, contradictions), leçon ↔ échec | `public.agent_memory`, `agent_failures` | 3 tables, 3 fonctions | `agent_failures` (+1) | copie des 4 leçons validées (source `v1:agent_memory`) | MEDIUM | aucun | YES | idem |
| `db06_knowledge_research` | Modèles d'embeddings, sources, provenance (RESTRICT), relations, validations, pipeline de recherche | — | 10 tables | — | 2 modèles d'embeddings | MEDIUM | aucun | YES | idem |
| `db06_vector_embeddings` | Modèle d'embedding par ligne, index HNSW partiels, tâches de ré-indexation | `knowledge_chunks`, `memory_items` | 1 table, 3 index HNSW | `knowledge_chunks` (+2), `memory_items` (+3) | rattachement des vecteurs existants à leur modèle | MEDIUM | aucun (pgvector requis) | YES | idem (HNSW simulé en local) |
| `db07_project_brain` | Documents, composants, relations, instantanés, couverture mesurée, zones inconnues, décisions, commits (ajout seul) | projets, dépôts | 8 tables | — | — | MEDIUM | aucun | YES | idem |
| `db08_code_db_api_ui_intelligence` | Index du code (fichiers, symboles, références, événements), bases des projets (jamais d'identifiants), API, interfaces, parcours | projets, environnements, artefacts | 30 tables | `project_environments` (FK) | — | MEDIUM | aucun | YES | idem |
| `db09_skills_tools` | Compétences versionnées (activation sous tests), registre des outils, constructeur d'outils (revue humaine) | `soulbah.skills`, `permission_definitions` | 16 tables, 2 fonctions | `skills` (+5) | — | MEDIUM | aucun | YES | idem |
| `db10_models_benchmarks` | Modèles, versions, matériel, sécurité (approbation humaine), benchmarks gelés, résultats, capacités mesurées, routage + historique, candidats (téléchargement approuvé), compétitions, ombre, jeux de données, entraînement (approuvé) | `embedding_models`, `tool_benchmarks`, artefacts | 29 tables, 4 fonctions | `embedding_models` (+1), `tool_benchmarks` (FK) | 2 modèles du registre local (empreintes réelles), benchmark de fumée 4/5 | MEDIUM | aucun | YES | idem |
| `db11_security_immune` | Motifs, constats (sévérité justifiée), incidents + vue sécurité, chronologie/actions/preuves/décisions/reprise, correctifs (production approuvée), régressions, règles, vues SOC, `audit_events` | `audit_logs`, `agent_quarantines`, `project_commits` | 11 tables, 9 vues, 2 fonctions | `agent_quarantines` (+1), `project_commits` (FK) | — | MEDIUM | aucun | YES | idem |
| `db12_missions_checkpoints` | Missions = sessions étendues, checkpoints de mission, contexte (sources, éléments, mesures), contrôle de l'ordinateur (permissions humaines, observations sensibles éphémères), vue `computer_actions` | `sessions`, `tasks`, `checkpoints`, `actions`, `tools` | 8 tables, 1 vue, 1 fonction | `sessions` (+7), `tasks` (+1), `checkpoints` (+5) | résultat déduit pour les sessions déjà terminées (0 ligne aujourd'hui) | MEDIUM | aucun | YES | idem |
| `db13_self_improvement` | Candidats, expériences (jamais en production), mesures adossées aux benchmarks, approbations humaines (ajout seul), déploiements bloqués par `system_state` | `system_versions`, `benchmark_runs` | 5 tables, 1 fonction | — | — | MEDIUM | aucun | YES | idem |
| `db14_observability` | Contrôles de santé, événements (→ `system_health`), métriques (purge contrôlée), notifications | `system_health` | 4 tables, 3 fonctions | — | — | MEDIUM | aucun | YES | idem |
| `db15_indexes_performance` | 23 index de clés étrangères, retrait de 2 index en double | toutes | 23 index | 2 index retirés | — | LOW | aucun | YES | idem |
| `db16_hardening` | Droits : EXECUTE retiré à PUBLIC sur les fonctions de `soulbah`, TRUNCATE/TRIGGER/REFERENCES/MAINTAIN retirés à anon/authenticated sur `public`, `soulbah_api` (si présent) ; vérifications (RLS, droits, journaux, commentaires, FK indexées, règles « jamais ») ; commentaires des objets V2 ; version `database.schema` | tout le schéma | — | droits, privilèges par défaut, commentaires | 1 ligne `system_versions` | MEDIUM | aucun | PARTIAL (droits rendus, commentaires retirés) | idem |

## 17. Preuves des lots (copies locales, jamais la base réelle)

| Preuve | Fichier | Résultat |
|---|---|---|
| Banc d'essai complet des 17 fichiers (lots 01-16) sur un clone du modèle (base restaurée + rattrapage) : application, test SQL de chaque lot, rejeu de chaque lot sans changement de schéma, **retour arrière de toute la séquence en ordre inverse**, schéma identique à l'état d'avant les lots, réapplication, tests rejoués | `db/dryrun/2026-10-02/lots_integration.json` (+ `.log`) | **56 étapes, 56 OK** |
| Bancs intermédiaires (lots 01-09, 01-10, 01-14) | `lots_01_09.json`, `lots_01_10.json`, `lots_01_14.json` | OK (après corrections décrites dans les fichiers) |
| Contrôles de la CI sur la copie intégrée : `schema_checks.sql`, `post_restore_checks.sql`, `api_role_checks.sql` (droits `soulbah_api` inclus) | `db/dryrun/2026-10-02/integration_checks.json` | **3/3 OK** |
| Tests d'intégration de node-api contre la copie intégrée (`vitest run test/integration --no-file-parallelism`) | idem | **10 fichiers, 57 tests, 57 OK (60 s)** |
| Catalogue de la copie intégrée | `db/baseline/2026-10-02_integrated/` | 188 tables, 12 vues, 44 fonctions, 626 index, 129 triggers dans `soulbah` ; 19 tables dans `public` ; 49 migrations inscrites dans l'historique |
| Outillage | `scripts/db/tests/test_db_tools.py` | 18 tests, 18 OK |
| Copies conservées sur le PostgreSQL local (127.0.0.1:54329) | `soulbah_scratch_full` (intégrée), `soulbah_restore_1654` (restauration de la sauvegarde de 16:54), `soulbah_catchup_template` (modèle figé) | pour vérification manuelle |

## 18. Application sur la base réelle — faite le 2026-10-02 (17:36 → 18:24), preuves

**Autorisation** : demande de l'utilisateur à 16:45 (« il faut appliquer la migration », fichier du bureau avec
le jeton d'accès de la CLI et le mot de passe de la base — jamais affichés ni copiés dans le dépôt), refus du mode
automatique de l'outil sur la première écriture, puis autorisation explicite renouvelée par l'utilisateur après
lecture de l'état et du mode d'emploi. Les trois clés de `migrate.py` ont été fournies à chaque écriture ; chaque
empreinte d'approbation est celle des fichiers du commit `5d79f32` (sauf le lot 06v, corrigé en cours de route,
voir ci-dessous).

**Préalables** (tous faits avant la première écriture) : catalogue frais 16:53 identique à la baseline dans
`public` (`db/baseline/2026-10-02_preapply/`) ; sauvegarde chiffrée 16:54 vérifiée par restauration
(`db/dryrun/2026-10-02/restore_test_1654.json/`, `restore_verified: true`) ; CLI liée au projet, historique
distant vide ; banc local 56/56, CI 3/3 et node-api 57/57 sur la copie intégrée (§17).

| Étape | Heure | Résultat | Preuve |
|---|---|---|---|
| 1. Historique + baseline des 16 migrations prouvées présentes | 17:36 | `20261002100000_db00` appliquée ; 16 versions inscrites `baselined` avec la preuve `migration_state.json` | `soulbah.schema_migrations` |
| 2. Plan + essai à blanc du rattrapage (15 migrations, une transaction annulée) | 17:37 | empreinte conforme ; **15/15 dry_run_ok en 23 s** | sortie `migrate.py plan` / `apply --dry-run` |
| 3. Rattrapage | 17:38 | **15/15 appliquées**, 2,2 à 4,8 s chacune, chacune dans sa transaction | `db/dryrun/2026-10-02/apply_catchup_supabase.json` |
| 4. Contrôles CI sur la base réelle (transactions annulées) | 17:41 | `schema_checks` (partie structurelle) OK, `post_restore_checks` **OK** (il échouait avant : SEC-21) ; `api_role_checks` impossible avant la création du rôle | `checks_supabase_catchup.json` |
| 5. Essai à blanc des 17 lots en une seule transaction | 17:43 | **échec non reproductible** : connexion coupée par le serveur après 93 s au lot 06 (petite instance : 256 Mo de `shared_buffers`, `work_mem` 3,5 Mo) ; rien d'écrit | journal de session |
| 6. Lots 01-05 (essai à blanc réussi dans l'étape 5) | 17:47 | **5/5 appliqués** (9 à 28 s) | `apply_lots_01_05_supabase.json` |
| 7. Lots suivants **un par un**, essai à blanc puis application | 17:53 → 18:22 | 06 OK ; **06v refusé par sa propre garde** (voir correctif) ; 06v OK après correctif ; 07 : connexion coupée pendant l'application (transaction annulée, aucun objet créé, historique vide, tentative `failed` enregistrée), réussi au 2e lancement ; 08 → 15 OK du premier coup | `apply_lots_supabase_1758.json`, `apply_lots_supabase_2221.json`, `apply_db*_supabase.json`, `apply_lots_07_15.log` |
| 8. Rôle `soulbah_api` (SEC-06) | 18:22 | créé : LOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE, NOREPLICATION, NOINHERIT, BYPASSRLS, limite 20 connexions, `search_path = public, extensions`, `statement_timeout = 60s` (SUPABASE_REPRISE §10) ; mot de passe généré, transmis en **vérificateur SCRAM pré-calculé** (jamais en clair vers le serveur), écrit dans `%USERPROFILE%\.soulbah\soulbah_api_password.txt` ; `scripts/sql/soulbah_api_grants.sql` joué (200 tables de `soulbah` accessibles) | `pg_roles` |
| 9. Lot 16 (hardening) | 18:23 | essai à blanc 6 s, application 9 s : vérifications passées sur la base réelle ; droits par défaut de `soulbah_api` posés (3 entrées) | `apply_db16_hardening_supabase.json` |
| 10. `migrate.py verify` | 18:23 | **49 migrations enregistrées, empreintes conformes aux fichiers** | sortie |
| 11. Contrôles CI finaux | 18:24 | **3/3 OK** (`schema_checks` structurel, `post_restore_checks`, `api_role_checks` avec le vrai rôle) | `checks_supabase_final.json` |
| 12. Historique de la CLI Supabase | 18:24 | `supabase migration repair --status applied` des 31 versions du dépôt ; `supabase migration list` : **31 lignes Local = Remote, aucune désalignée** → `supabase db push` ne rejouera rien | sortie CLI |
| 13. Catalogue après application (lecture seule) | 18:25 | 207 tables, 12 vues, 138 triggers, 48 policies, 2 386 colonnes : **identiques à la copie intégrée** ; différences attendues seulement : 3 colonnes `vector` (réelles ici, `real[]` dans le stub), 5 index HNSW présents (sautés par le stub), 93 fonctions pgvector dans `public`, 2 index en double retirés par le lot 15 (le catalogue local date d'avant ce correctif) ; `supabase_migrations` 31, `soulbah.schema_migrations` 49 | `db/baseline/2026-10-02_postapply/` |

**Correctif en cours de route (lot 06v)** : sur Supabase, `assert_table_shape()` (db01, déjà appliqué) compare
`format_type()` sous `search_path = pg_catalog`, qui qualifie les types d'extension : `public.vector` ≠ `vector`,
et la garde §9 a arrêté le lot — exactement son rôle. Le lot 06v vérifie désormais le **nom du type**
(`pg_type.typname` ∈ {`vector`, `_float4`}), indépendant du schéma où vit pgvector (utile pour SEC-13) ; banc
local rejoué **56/56** avant reprise. Le fichier ayant changé, son empreinte n'est plus celle du §18 initial ;
`verify` atteste la conformité des 49 fichiers appliqués.

**Données après application (base réelle)** : `public` inchangé (211 lignes, 2 tâches `pending` de juillet
toujours présentes : décision utilisateur) ; semences : 5 environnements, état système prudent (auto-amélioration
OFF, changements de production OFF, migrations PREPARE_ONLY), 3 projets, 7 agents, 30 permissions, 4 rôles,
36 règles de politique, 12 garde-fous, 4 leçons copiées de `agent_memory`, 2 modèles d'embeddings, 2 modèles et
versions, 5 résultats de benchmark, 1 version de schéma ; 0 policy client d'écriture sur `agent_tasks` ; 0 table
de `soulbah` sans RLS ; 4 index HNSW ; 50 tentatives dans `schema_migration_runs` (49 réussies, 1 échec = la
coupure du lot 07).

**Non fait, à décider par l'utilisateur** : basculer node-api sur `soulbah_api` (`DATABASE_URL` avec cet
utilisateur et le mot de passe du fichier ci-dessus, puis redémarrage et `api_role_checks`) ; les décisions
listées au §19.

**Deux limites de l'instance Supabase constatées** : (1) une transaction unique couvrant les 17 lots fait tomber
la connexion (ressources) — appliquer lot par lot, c'est ce que fait le mode d'emploi ; (2) coupures de connexion
intermittentes (2 sur 36 transactions) : chaque lot étant une transaction, aucune n'a laissé d'état partiel ; le
pilote réessaie après relecture de l'historique.

## 19. Rapport final (§109) — état après exécution

| Rubrique | Contenu |
|---|---|
| Migrations préparées | 1 migration d'historique + baseline de 16 ; 15 migrations du dépôt en attente (rattrapage) ; 17 fichiers de lots (DB LOT 1 → 16), chacun avec `.down.sql` (sauf `db00` et `db16` : PARTIAL, documenté) et test SQL. |
| Objets créés | `soulbah` : 167 tables, 10 vues, 44 fonctions au total après lots (dont 13 helpers du noyau), 626 index, 129 triggers ; `public` : `analysis_requests`, colonnes de `agent_tasks`, FK `user_id`, 5 index de FK. |
| Objets modifiés | V2 : `sessions` (+7 colonnes, contraintes, trigger), `tasks` (+2), `checkpoints` (+5), `skills` (+5), `agents` (+4), `knowledge_chunks` (+2), `agent_failures` (+1), `agent_quarantines` (+1), `embedding_models` (+1), `project_commits` (FK), 2 index V2 retirés, 21 commentaires ; `public` : policies et droits (rattrapage, lot 16). **Aucune suppression de table ni de colonne, aucune donnée supprimée.** |
| Données touchées | Semences idempotentes (environnements 5, état système 1, projets 3, agents 7 + versions 7, permissions 30, rôles 4, politique 1 + 36 règles, garde-fous 12, modèles d'embeddings 2, modèles 2 + versions 2 + matériel 2 + sécurité 2, benchmark de fumée 1 + 5 tâches + 5 résultats + 6 capacités, version de schéma 1) ; copie des 4 leçons validées de `agent_memory` ; résultat déduit pour les sessions V2 déjà terminées (0 aujourd'hui) ; 49 lignes d'historique. Données existantes de `public` : inchangées (211 lignes). |
| Risque | MEDIUM pour les migrations créant des fonctions/triggers (classification automatique), LOW pour les index ; aucun motif destructif (`DROP TABLE`, `TRUNCATE`, `DELETE` de masse) dans les fichiers appliqués ; `lock_timeout` 10 s. |
| Impact applicatif | node-api : nécessaire (rattrapage) ; compatible avec les lots (57/57). Frontend : policies de lecture conservées, écritures client déjà retirées du code. Agent : aucune (passe par node-api). Temps réel : publications inchangées par les lots. |
| Tests passés | banc 56/56 (rejoué après le correctif 06v) ; CI 3/3 sur copie et **3/3 sur la base réelle** ; node-api 57/57 ; outillage 18/18 ; restauration de la sauvegarde de 16:54 vérifiée ; `verify` 49/49 sur la base réelle. |
| Préparation du retour arrière | sauvegarde 16:54 vérifiée ; `.down.sql` de chaque lot prouvés (séquence entière, schéma identique) ; historique de chaque action dans `soulbah.schema_migration_runs`. |
| Reste à décider par l'utilisateur | basculer node-api sur `soulbah_api` (§18) ; rotation des clés agent (SEC-03) et révocation des sessions (SEC-04) ; sort des 2 tâches de juillet (DATA-01) ; création du rôle `soulbah_api` (SEC-06) ; MFA (SEC-14) ; pgvector hors de `public` (SEC-13) ; politique de rétention des journaux. |
