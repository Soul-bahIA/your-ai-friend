# Architecture cible de la base Soulbah (DB LOT 0 → plan des DB LOT 1 à 16)

Décisions prises le 2026-10-02 à partir de la base restaurée (`db/baseline/2026-10-02_restored/`), du schéma
attendu par le code (31 migrations, `db/baseline/2026-10-02_expected/`) et de la mission « Local-first +
Database-first ». Règle directrice : **réutiliser avant de créer, jamais de système parallèle**.

## 1. Décisions transversales

| Sujet | Décision | Pourquoi |
|---|---|---|
| Schémas (§103) | **Un seul schéma applicatif nouveau : `soulbah`** (existant V2), tables préfixées par domaine (`project_`, `agent_`, `policy_`, `memory_`, `security_`…). Pas de schémas `core`/`brain`/`security`. | `soulbah` est déjà réservé au plan de contrôle : jamais exposé à PostgREST, droits révoqués pour `anon`/`authenticated`, rôle `soulbah_api` couvert par « ALL TABLES IN SCHEMA soulbah ». Un schéma par domaine n'apporterait aucune isolation de plus (même rôle, même API) et doublerait les grants, les privilèges par défaut et les contrôles de CI. |
| Schéma `public` | Modifié seulement par les 15 migrations du dépôt déjà écrites (rattrapage) et par le durcissement des droits du DB LOT 16. Aucune nouvelle table V1. | Le `public` est exposé à PostgREST : chaque table y coûte des policies. La V2 a déjà fait ce choix. |
| Journaux et décisions | **Ajout seul** par trigger (`soulbah.append_only()`), identité `bigint` pour les tables à fort volume. | §56-59 : un agent ne peut pas effacer ses traces. Même modèle que `audit_logs` et `schema_migration_runs`. |
| Audit (§58) | **`audit_events` = vue** sur `soulbah.audit_logs` (chaînée SHA-256) qui extrait de `data` les clés `actor_type`, `agent_id`, `project_id`, `environment`, `resource`, `before`, `after`, `approval_id`, `evidence_ids`. Aucune colonne ajoutée à `audit_logs`. | Ajouter des colonnes hors du hash affaiblirait la chaîne ; les mettre dans `data` les inclut dans le hash. |
| Trusted Core (§55, §113) | Lignes marquées `immutable = true` (réglages, politiques, garde-fous critiques) protégées par trigger : modification refusée sauf si la transaction a posé `SET LOCAL soulbah.trusted_core = 'unlocked'`, réservé au chemin Trusted Core de node-api (identité humaine habilitée, double validation). | Barrière en base, indépendante du code des agents : un agent qui passe par la passerelle d'outils ne peut pas poser ce réglage. |
| Vecteurs (§37-39) | pgvector 0.8.0 présent sur Supabase (dans `public`, laissé en place) ; **absent du PostgreSQL local** (à installer, décision séparée). Chaque vecteur porte `embedding_model_id` et sa dimension ; un index HNSW partiel par modèle ; table `knowledge_embedding_jobs` pour la réindexation (ancien index → réindexation en arrière-plan → validation → bascule → nettoyage). DDL vectoriel isolé dans `db06_vector_embeddings`. | Interdit de mélanger des vecteurs incompatibles ; le banc local simule `vector` par `real[]`. |
| Fichiers vs base (§68-71) | Base = métadonnées, relations, états, mémoire, audit, missions, sécurité, configuration. Fichiers (dossier `%LOCALAPPDATA%\Soulbah`, workspace) = modèles, vidéos, enregistrements, jeux de données, grands artefacts. **`soulbah.artifacts` (existant : sha256, uri, taille, type)** est le registre ; pas de stockage objet local tant qu'un besoin mesuré n'apparaît pas. | Déjà le modèle V2 (0 base64 en base). |
| Local-first | La base de référence reste **PostgreSQL** (Supabase restaurée aujourd'hui ; PostgreSQL 18 local déjà installé). Les migrations sont identiques des deux côtés ; le gestionnaire `scripts/db/migrate.py` tient l'historique des deux. | Même schéma partout ; le mode OFFLINE n'exige qu'une base locale. |
| Identité | Pas de nouvelle table d'utilisateurs : `auth.users` (Supabase) ou l'authentification locale de node-api. Les principaux des politiques sont `user`, `agent`, `role`. | Rien de parallèle à `auth`. |

## 2. Décision table par table

Statuts : **REUSE** (objet existant, nom exact), **EXTEND** (colonnes ou tables filles ajoutées à l'existant),
**NEW**, **MERGE** (couvert par une autre table ou une vue), **DEFER** (à créer avec le code qui l'utilisera).

### DB LOT 1 — Core (`20261002110100_db01_core.sql`)

| Demandé | Décision | Objet |
|---|---|---|
| system_settings | NEW | `soulbah.system_settings` (clé, valeur jsonb, critique, immuable, version) + `system_settings_history` (ajout seul, ancien/nouveau/auteur/raison) |
| system_versions | NEW | `soulbah.system_versions` (composant, version, commit, version précédente, infos de retour arrière) |
| system_health | NEW | `soulbah.system_health` (état courant par composant) ; l'historique est au DB LOT 14 |
| feature_flags | NEW | `soulbah.feature_flags` + `feature_flags_history` (ajout seul) |
| environments | NEW | `soulbah.environments` : LOCAL, DEV, TEST, STAGING, PRODUCTION (semés) |
| interrupteurs maîtres, STOP, SAFE MODE (§48-54, §96-97) | NEW | `soulbah.system_state` (une ligne) + `system_state_history` (ajout seul) |
| aides communes (§9) | NEW | `soulbah.assert_table_shape()`, `append_only()`, `protect_immutable()`, `trusted_core_unlocked()`, `is_environment()`, `is_autonomy_level()`, `is_severity()` |

### DB LOT 2 — Projects (`20261002110200_db02_projects.sql`)

| Demandé | Décision | Objet |
|---|---|---|
| projects | NEW | `soulbah.projects` (slug, nom, genre, statut) — semés : soulbah, 224solutions, 224connect |
| project_repositories | NEW | chemin ou URL, VCS, branche, autorisation d'accès, dernier commit indexé |
| project_environments | NEW | (projet × environnement) : URL, source de base, déploiement |
| project_components | NEW | frontend, backend, api, db, worker… avec chemin |
| project_dependencies | NEW | paquet, version, écosystème, premières et dernières observations, vulnérabilités connues |
| project_versions | NEW | version, commit, environnement, date |

### DB LOT 3 — Agents (`20261002110300_db03_agents.sql`)

| Demandé | Décision | Objet |
|---|---|---|
| agents (registre) | NEW | `soulbah.agent_definitions` — **pas `agents`** : `soulbah.agents` existe déjà et désigne une instance d'agent par tâche. Semées : les 7 rôles V2 |
| agent_versions | NEW | `agent_definition_versions` (prompt, outils, permissions, modèle, skills, statut draft/canary/active/retired) |
| agent_capabilities | NEW | `agent_capabilities` |
| agent_permissions | NEW | `agent_permissions` (permission × environnement × décision), appliquées par le moteur de politiques (lot 4) |
| agent_assignments | NEW | `agent_assignments` (définition × projet × environnement × niveau d'autonomie) |
| agent_status | NEW | `agent_status` (état courant : actif, suspendu, en quarantaine, charge, dernière erreur) |
| agent_metrics | NEW | `agent_metrics` (par période : réussites, échecs, reprises, durées, interventions humaines, coût) |
| agent_runs | **REUSE + EXTEND** | `soulbah.agents` (une ligne par exécution d'agent) + colonnes `definition_id`, `version_id`, `outcome`, `finished_at` |
| agent_tasks | **REUSE** | `soulbah.tasks` (+ `agent_definition_id`) — `public.agent_tasks` (V1) est intouchable |
| agent_steps | REUSE | `soulbah.actions` |
| agent_tool_calls | REUSE | `soulbah.tool_calls` |
| agent_results | REUSE | `soulbah.tasks.result` + `soulbah.evaluations` |
| agent_failures | NEW | `agent_failures` (cause probable, cause racine, leçon validée liée à la mémoire) |
| agent_watchdog_events | NEW | ajout seul |
| agent_evaluations | REUSE | `soulbah.evaluations` |
| agent_peer_reviews | NEW | `agent_peer_reviews` (relecteur ≠ auteur, contrainte) |
| agent_quarantines | NEW | `agent_quarantines` |

### DB LOT 4 — Policies, guardrails, permissions (`20261002110400_db04_policies_guardrails.sql`)

| Demandé | Décision | Objet |
|---|---|---|
| roles, permissions, role_permissions, principal_roles, resource policies (§28) | NEW | `soulbah.roles`, **`permission_definitions`** (semées : `filesystem.read`… `self_improvement.activate`, `database.read/write/migrate/admin`) — pas `permissions` : `soulbah.permissions` (V2) désigne déjà les demandes d'approbation ; `role_permissions`, `principal_roles`, `resource_policies` |
| policies, policy_versions, policy_rules, policy_bindings | NEW | versionnées ; `policy_versions` ajout seul |
| policy_decisions | NEW | ajout seul (qui, quoi, projet, environnement, décision, version de politique, preuve) |
| autonomy levels (§25) | NEW | `autonomy_rules` (agent × projet × environnement → niveau), historisées |
| guardrails, guardrail_versions, guardrail_assignments, guardrail_events | NEW | `guardrails` (catégories Filesystem … Agent Communication, niveaux SAFE/STANDARD/ADVANCED/CUSTOM, critique, immuable), versions et événements en ajout seul |
| Trusted Core | — | lignes `immutable` protégées par trigger (lot 1) |

### DB LOT 5 — Memory (`20261002110500_db05_memory.sql`)

| Demandé | Décision | Objet |
|---|---|---|
| memories (types, métadonnées, statuts) | NEW | `soulbah.memory_items` : type WORKING…SKILL, projet, agent, source, provenance, confiance, validation, fraîcheur, version, statut ACTIVE/STALE/SUPERSEDED/INVALID/ARCHIVED, `supersedes_id` |
| memory_relationships | NEW | supports / contradicts / supersedes / derived_from / related_to |
| memory_contradictions | NEW | avec résolution |
| public.agent_memory (V1), vue soulbah.memories | REUSE, inchangées | les 4 leçons V1 validées sont **copiées** dans `memory_items` (source `v1:agent_memory`, idempotent) |

### DB LOT 6 — Knowledge, research, embeddings (`20261002110600_db06_knowledge_research.sql`, `20261002110650_db06_vector_embeddings.sql`)

| Demandé | Décision | Objet |
|---|---|---|
| knowledge_items, knowledge_versions | **REUSE** | `public.knowledge_base`, `public.knowledge_versions`, `soulbah.knowledge_chunks`, vue `soulbah.knowledge_documents` |
| knowledge_sources, knowledge_relationships, knowledge_validation | NEW | `soulbah.knowledge_sources` (provenance, `retrieved_at`, `last_verified_at`, politique de fraîcheur), `knowledge_relationships`, `knowledge_validations` (ajout seul) |
| research_sessions, research_queries, research_sources, research_findings, research_knowledge_candidates | NEW | cinq tables, sources jamais supprimées |
| embeddings (§38) | NEW + EXTEND | `soulbah.embedding_models` (nom, fournisseur local/cloud, dimensions, version, statut) ; `knowledge_chunks` + `memory_items` reçoivent `embedding_model_id` ; `knowledge_embedding_jobs` (réindexation) ; index HNSW par modèle (fichier vectoriel, seulement si pgvector est présent) |

### DB LOT 7 — Project Brain (`20261002110800_db07_project_brain.sql`)

| Demandé | Décision | Objet |
|---|---|---|
| project_brain_documents, _components, _relationships, _snapshots | NEW | documents (architecture, décisions, notes générées), composants logiques, relations typées entre nœuds (document, composant, fichier, symbole, table, route, écran), instantanés (empreinte et couverture) |
| project_brain_symbols | MERGE | = `code_symbols` (lot 8) ; `project_brain_relationships` les référence |
| couverture et zones inconnues (§43-45) | NEW | `project_brain_coverage` (mesurée, jamais inventée), `knowledge_gaps` |
| Architecture Decision Memory, Git Memory (§16-17) | NEW | `project_decisions`, `project_commits` (ajout seul) |

### DB LOT 8 — Code, DB, API, UI intelligence (`20261002110900_db08_code_db_api_ui_intelligence.sql`)

NEW : `code_files`, `code_symbols`, `code_dependencies`, `code_references`, `code_change_events` (ajout seul),
`code_index_state` ; `db_sources`, `db_schemas`, `db_tables`, `db_columns`, `db_relations`, `db_indexes`,
`db_policies`, `db_functions`, `db_triggers`, `db_snapshots` ; `api_services`, `api_endpoints`,
`api_dependencies`, `api_consumers`, `api_security_rules` ; `ui_surfaces`, `ui_routes`, `ui_components`,
`ui_actions`, `ui_api_links` ; `user_flows`, `user_flow_steps`, `user_flow_dependencies`. Le contenu du code
n'est pas stocké : chemins, empreintes, positions, métadonnées.

### DB LOT 9 — Skills et tools (`20261002111000_db09_skills_tools.sql`)

| Demandé | Décision | Objet |
|---|---|---|
| skills | **REUSE + EXTEND** | `soulbah.skills` + `current_version_id`, `project_scope`, `category` |
| skill_versions, skill_steps, skill_requirements, skill_tools, skill_tests, skill_metrics, skill_candidates | NEW | candidat → tests → validation → promotion |
| tools, tool_versions, tool_permissions, tool_health, tool_benchmarks | NEW | registre synchronisé depuis `shared/tools/catalog.json` par node-api (pas de semence SQL : une seule source) |
| tool_candidates, tool_builds, tool_tests, tool_security_reviews | NEW | constructeur d'outils |

### DB LOT 10 — Models, benchmarks, datasets, training (`20261002111100_db10_models_benchmarks.sql`)

NEW : `models`, `model_versions`, `model_capabilities`, `model_benchmarks`, `model_hardware_requirements`,
`model_security_status`, `model_routing_rules`, `model_routing_history` (ajout seul), `model_competitions`
(champion / challenger), `model_candidates`, `model_comparison_results`, `shadow_runs`, `shadow_comparisons`,
`benchmarks`, `benchmark_versions`, `benchmark_tasks`, `benchmark_runs`, `benchmark_results`, `golden_tasks`,
`golden_task_expected_results`, `datasets`, `dataset_versions`, `dataset_items`, `dataset_sources`,
`dataset_quality_checks`, `training_configs`, `training_runs`, `training_results`, `training_artifacts`.
`embedding_models` (lot 6) reçoit `model_id`. Le registre local `%LOCALAPPDATA%\Soulbah\models\registry.json`
reste la source des fichiers ; la base en porte les métadonnées.

### DB LOT 11 — Sécurité et Digital Immune System (`20261002111200_db11_security_immune.sql`)

| Demandé | Décision | Objet |
|---|---|---|
| security_patterns, bug_pattern | NEW (MERGE) | `security_patterns` avec `pattern_kind` security / bug (signature, conditions, cause racine, correctif, test, projets touchés, première et dernière observation) |
| security_findings | NEW | statuts DETECTED … VERIFIED, sévérité justifiée, confiance ≠ preuve |
| security_incidents, incidents | NEW (MERGE) | une table `incidents` (genre security / reliability / performance / data) ; vue `security_incidents` |
| incident_events, incident_actions, incident_evidence, incident_decisions, incident_recovery_steps | NEW | événements et décisions en ajout seul |
| security_fixes, security_regression_tests, security_detection_rules | NEW | |
| vues SOC (§57) | NEW | `v_soc_active_incidents`, `v_soc_open_findings`, `v_soc_critical_findings`, `v_soc_quarantined_agents`, `v_soc_recent_fixes`, `v_soc_regressions`, `v_soc_coverage` — sur les tables réelles |
| audit_events | MERGE | vue sur `audit_logs` (décision transversale) |

### DB LOT 12 — Missions, checkpoints, contexte, contrôle de l'ordinateur (`20261002111300_db12_missions_checkpoints.sql`)

| Demandé | Décision | Objet |
|---|---|---|
| missions, mission_results | **REUSE + EXTEND** | `soulbah.sessions` + `project_id`, `environment_name`, `autonomy_level`, `mission_kind`, `result`, `result_summary` |
| mission_tasks, mission_dependencies | REUSE | `soulbah.tasks` (+ `project_id`), `soulbah.task_dependencies` |
| mission_checkpoints (§61-62) | **REUSE + EXTEND** | `soulbah.checkpoints` + `label`, `kind`, `state_artifact_id`, `resumable` ; `session_checkpoints` NEW pour l'état de mission entre tâches |
| context_builds, context_sources, context_items, context_metrics | NEW | |
| computer_sessions, computer_observations, computer_permissions | NEW | `computer_observations` référence `artifacts` avec classe de sensibilité (§65 : password, token, bank, pii → rétention stricte) |
| computer_actions | MERGE | vue sur `soulbah.actions` (outils bureau et téléphone) |

### DB LOT 13 — Self-improvement (`20261002111400_db13_self_improvement.sql`)

NEW : `improvement_candidates`, `improvement_experiments`, `improvement_benchmarks` (lien `benchmark_runs`),
`improvement_approvals` (ajout seul), `improvement_deployments` (version précédente, retour arrière), liées à
`system_versions`.

### DB LOT 14 — Observability (`20261002111500_db14_observability.sql`)

NEW : `health_checks` (définitions), `health_events` (ajout seul), `resource_metrics` (ajout seul, identité :
CPU, RAM, GPU, VRAM, disque, base, modèles, agents, files), `notifications` (§51, §88 : alertes au PDG).

### DB LOT 15 — Index et performance (`20261002111600_db15_indexes_performance.sql`)

Index couvrants des 18 clés étrangères sans index relevées sur le schéma attendu (public et V2) ; index partiels
des requêtes de file (tâches prêtes, approbations en attente). Tables de quelques lignes aujourd'hui : création
dans la transaction, sans `CONCURRENTLY` ; `transaction=none` à utiliser le jour où une table est volumineuse.

### DB LOT 16 — Hardening (`20261002111700_db16_hardening.sql`)

Vérification finale (lève une exception si une table de `soulbah` n'a pas la RLS, si `anon`/`authenticated` ont
un droit dessus, si un journal déclaré n'a pas son trigger d'ajout seul, si un commentaire manque) ; retrait
des droits inutiles de `anon`/`authenticated` sur `public` (TRUNCATE, TRIGGER, REFERENCES, MAINTAIN) et
privilèges par défaut correspondants ; droits par défaut pour `soulbah_api` s'il existe. **Non fait** : déplacer
pgvector hors de `public` (changement de `search_path` à évaluer sur Supabase, hors périmètre).

## 3. Dépendances entre lots

```text
01 ─┬─ 02 ─┬─ 03 ─┬─ 04 ─ 05 ─ 06 ─ 06v ─ 07 ─ 08 ─ 09 ─ 10 ─ 11 ─ 12 ─ 13 ─ 14 ─ 15 ─ 16
```

Chaque lot ne dépend que des précédents (clés étrangères). Les lots 15 et 16 portent sur l'ensemble.

## 4. Données migrées (semences idempotentes)

| Lot | Données | Source |
|---|---|---|
| 1 | 5 environnements ; ligne unique `system_state` (valeurs prudentes : STOP non enclenché, SAFE MODE off, Internet et IA externes refusés, production OFF, auto-amélioration OFF, autopilot OFF, migrations PREPARE_ONLY) | mission |
| 2 | 3 projets (soulbah, 224solutions, 224connect) | mission |
| 3 | 7 définitions d'agents | `shared/roles/roles.json` (versions 1.0.0 → 1.2.0) |
| 4 | 4 rôles (pdg, super_admin, admin, user), 20 permissions nommées, politique de base SAFE, garde-fous par catégorie (12) | mission §7-9 |
| 5 | leçons V1 validées (4 lignes) copiées dans `memory_items` | `public.agent_memory` |
| 6 | 2 modèles d'embeddings connus (text-embedding-3-small 1536, nomic-embed-text-v1.5 768) | registre local |

Toutes les semences utilisent `ON CONFLICT DO NOTHING` sur une clé naturelle : rejouables, jamais destructives.


## 5. Réalisation (2026-10-02, après rédaction des lots) — écarts avec les décisions ci-dessus

| Décision initiale | Ce qui a été fait | Pourquoi |
|---|---|---|
| Journaux en ajout seul avec clés étrangères `CASCADE` / `SET NULL` | **`ON DELETE RESTRICT`** vers les catalogues (projets, dépôts, définitions d'agents, politiques, garde-fous, règles de routage) ; **pas de FK** vers les lignes opérationnelles purgées (sessions, tâches, agents, fichiers de code) — colonne `uuid` nue indexée | L'action référentielle était de toute façon refusée par le trigger d'ajout seul, avec une erreur trompeuse (constaté au banc du lot 8). Règle ajoutée aux conventions. |
| Lot 10 sans semence | Semences **réelles** du registre local (`%LOCALAPPDATA%\Soulbah\models\registry.json`) : 2 modèles (`qwen2.5-1.5b-instruct` Q4_K_M, `nomic-embed-text-v1.5` Q8_0) avec empreintes SHA-256, sources épinglées par révision, licence, besoins RAM ; statut de sécurité `checked` (pas `approved` : l'approbation est humaine) ; benchmark de fumée `local_smoke` v1 gelé (5 tâches) et son exécution du 2026-10-02 09:48 (4/5, latences, jetons) ; 6 capacités mesurées ou déclarées. Aucune version n'est « active » | Les faits existaient déjà dans le registre ; les copier donne une base mesurée sans rien inventer. L'activation exige un statut de sécurité approuvé par un humain (trigger). |
| `permissions` (mission) | `permission_definitions` | Collision avec `soulbah.permissions` V2 (approbations) : `CREATE TABLE IF NOT EXISTS` l'aurait masquée (§9). |
| Lot 15 : index des FK | 23 index (5 `public`, 18 `soulbah`) **relevés automatiquement** sur la copie intégrée (`gen_lot15`), partiels sur les colonnes nullables ; **retrait de 2 index V2 en double** (`idx_actions_task`, `idx_knowledge_chunks_document`) | Le test du lot (index en double interdits) les a trouvés. |
| Lot 16 : `ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah REVOKE EXECUTE … FROM PUBLIC` | **Retiré** : une entrée par schéma s'ajoute au défaut global, elle ne peut rien lui retirer, et elle laissait une entrée résiduelle au retour arrière (constaté au banc). Règle : chaque migration retire PUBLIC de ses fonctions ; le lot 16 vérifie et échoue sinon | Sémantique de PostgreSQL (`SetDefaultACL` : baseline vide pour les entrées par schéma). |
| Lot 16 : commentaires | 19 tables et 2 vues V2 sans commentaire reçoivent le leur (retirés par le retour arrière) | La vérification « un commentaire par table » doit tenir sur tout le schéma. |
| Lot 12 : `sessions.result` | Contrainte `NOT VALID` puis validée après un `UPDATE` qui déduit le résultat des sessions déjà terminées (jamais `success` sans preuve : `partial`/`failure`/`cancelled`) ; trigger `sessions_default_result` pour l'avenir | Compatibilité avec node-api V2 (qui ne pose pas encore `result`) : 57/57 tests. |
| Lot 14 : métriques en ajout seul | `retention_guard()` : UPDATE refusé ; DELETE/TRUNCATE seulement sous `soulbah.retention_purge = on`, posé par `purge_resource_metrics(interval ≥ 1 jour)` | Une série de mesures doit pouvoir être purgée sans contourner le journal. |
| Lot 12 : vue `computer_actions` | Jointure sur `soulbah.tools.category` (mouse, keyboard, screen, window, app_launch, phone, video, voice), registre synchronisé depuis `shared/tools/catalog.json` | Pas de liste d'outils codée en dur dans la vue. |
| Lot 10 / 13 : gardes | Triggers : activation d'un modèle (sécurité approuvée + empreinte), règle de routage vers une version active, entraînement (configuration approuvée, jeu gelé), déploiement d'amélioration (approbation humaine non révoquée, `system_state.self_improvement ≠ OFF`, `production_changes` pour PRODUCTION) | Les règles de la mission (« jamais sans approbation ») sont dans la base, pas seulement dans le code. |

Semences ajoutées au tableau du §4 : lot 10 (ci-dessus) ; lot 16 (`system_versions` : `database.schema`
`2026-10-02.lots-01-16`). Les 4 leçons V1 copiées par le lot 5 et les 2 modèles d'embeddings du lot 6 sont
confirmés sur la copie intégrée (`db/baseline/2026-10-02_integrated/`).
