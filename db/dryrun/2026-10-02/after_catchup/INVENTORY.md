# Inventaire — copie restaurée + rattrapage (essai local, pgvector simulé)

Relevé le 2026-10-02T11:19:37+00:00 en lecture seule (`postgres@127.0.0.1:54329/soulbah_dryrun_copy`).

## Moteur

| Élément | Valeur |
|---|---|
| Version | PostgreSQL 18.1 |
| Base | soulbah_dryrun_copy (15.5 Mo) |
| Encodage, collation | UTF8, C |
| Fuseau | Europe/Paris |
| Empreinte du schéma (tout) | `1a27b77170e615447bc39418eb07edd569f3503d097e7cc128175c224dc51684` |
| Empreinte des schémas applicatifs | `46fdafc7fac2bd4199af4eea3df3b6d0582148c374b2b41c9ed74a1830e96489` |
| default_transaction_read_only | off |
| effective_cache_size | 524288 |
| idle_in_transaction_session_timeout | 0 |
| maintenance_work_mem | 65536 |
| max_connections | 100 |
| max_wal_size | 1024 |
| password_encryption | scram-sha-256 |
| random_page_cost | 4 |
| row_security | on |
| search_path | "$user", public |
| shared_buffers | 16384 |
| statement_timeout | 120000 |
| wal_level | replica |
| work_mem | 4096 |

## Schémas

| Schéma | Géré par | Propriétaire | Empreinte |
|---|---|---|---|
| auth | Supabase / extension | postgres | `3a4393ea32e79720…` |
| extensions | Supabase / extension | postgres | `0286eed801d377a4…` |
| public | Soulbah | pg_database_owner | `b8a6fd6ee85c5579…` |
| soulbah | Soulbah | postgres | `630fc1db60e86d62…` |

## Extensions

| Extension | Version | Schéma |
|---|---|---|
| pg_trgm | 1.6 | extensions |
| pgcrypto | 1.4 | extensions |
| plpgsql | 1.0 | pg_catalog |
| uuid-ossp | 1.1 | extensions |

## Tables des schémas applicatifs

| Table | Lignes | Taille | RLS | Colonnes | Policies | Index |
|---|---|---|---|---|---|---|
| public.agent_events | 42 | 64 Ko | oui | 7 | 1 | 3 |
| public.agent_keys | 2 | 64 Ko | oui | 12 | 1 | 3 |
| public.agent_memory | 4 | 192 Ko | oui | 20 | 2 | 10 |
| public.agent_tasks | 14 | 672 Ko | oui | 17 | 1 | 7 |
| public.analysis_requests | 0 | 40 Ko | oui | 6 | 4 | 4 |
| public.applications | 1 | 64 Ko | oui | 10 | 4 | 2 |
| public.chat_conversations | 9 | 48 Ko | oui | 5 | 4 | 2 |
| public.chat_messages | 32 | 48 Ko | oui | 6 | 3 | 2 |
| public.formations | 12 | 208 Ko | oui | 13 | 4 | 2 |
| public.knowledge_base | 1 | 200 Ko | oui | 26 | 1 | 9 |
| public.knowledge_domains | 15 | 32 Ko | oui | 4 | 1 | 1 |
| public.knowledge_versions | 0 | 48 Ko | oui | 7 | 3 | 2 |
| public.modules_status | 0 | 24 Ko | oui | 6 | 2 | 2 |
| public.profiles | 10 | 48 Ko | oui | 7 | 3 | 2 |
| public.system_logs | 59 | 80 Ko | oui | 7 | 2 | 2 |
| public.user_migrations | 0 | 24 Ko | oui | 6 | 2 | 2 |
| public.user_roles | 10 | 40 Ko | oui | 3 | 2 | 2 |
| public.user_schemas | 0 | 48 Ko | oui | 7 | 4 | 2 |
| public.user_table_data | 0 | 48 Ko | oui | 6 | 4 | 2 |
| soulbah.actions | 0 | 64 Ko | oui | 17 | 0 | 3 |
| soulbah.agents | 0 | 32 Ko | oui | 11 | 0 | 3 |
| soulbah.artifacts | 0 | 40 Ko | oui | 12 | 0 | 4 |
| soulbah.audit_chain_head | 1 | 32 Ko | oui | 4 | 0 | 1 |
| soulbah.audit_logs | 0 | 96 Ko | oui | 13 | 0 | 6 |
| soulbah.checkpoints | 0 | 24 Ko | oui | 7 | 0 | 2 |
| soulbah.evaluations | 0 | 24 Ko | oui | 12 | 0 | 2 |
| soulbah.knowledge_chunks | 0 | 104 Ko | oui | 10 | 0 | 5 |
| soulbah.messages | 0 | 48 Ko | oui | 13 | 0 | 5 |
| soulbah.permissions | 0 | 40 Ko | oui | 17 | 0 | 4 |
| soulbah.recordings | 0 | 24 Ko | oui | 13 | 0 | 2 |
| soulbah.resource_leases | 0 | 80 Ko | oui | 5 | 0 | 4 |
| soulbah.runtimes | 0 | 32 Ko | oui | 12 | 0 | 3 |
| soulbah.schema_migration_runs | 32 | 48 Ko | oui | 11 | 0 | 2 |
| soulbah.schema_migrations | 32 | 64 Ko | oui | 12 | 0 | 1 |
| soulbah.sessions | 0 | 56 Ko | oui | 17 | 0 | 3 |
| soulbah.skills | 0 | 32 Ko | oui | 15 | 0 | 3 |
| soulbah.task_dependencies | 0 | 48 Ko | oui | 4 | 0 | 2 |
| soulbah.tasks | 0 | 128 Ko | oui | 31 | 0 | 9 |
| soulbah.tool_calls | 0 | 40 Ko | oui | 19 | 0 | 4 |
| soulbah.user_settings | 0 | 32 Ko | oui | 7 | 0 | 1 |

Tables des schémas gérés (jamais modifiées par Soulbah) : auth 27.

Volumes des schémas gérés (comptes) : auth.identities 10, auth.mfa_amr_claims 45, auth.one_time_tokens 2, auth.refresh_tokens 91, auth.schema_migrations 82, auth.sessions 45, auth.users 10.

## Colonnes

| Table | Colonne | Type | NOT NULL | Défaut |
|---|---|---|---|---|
| public.agent_events | id | uuid | oui | gen_random_uuid() |
| public.agent_events | task_id | uuid | oui |  |
| public.agent_events | user_id | uuid | oui |  |
| public.agent_events | type | text | oui |  |
| public.agent_events | message | text |  |  |
| public.agent_events | data | jsonb | oui | '{}'::jsonb |
| public.agent_events | created_at | timestamp with time zone | oui | now() |
| public.agent_keys | id | uuid | oui | gen_random_uuid() |
| public.agent_keys | user_id | uuid | oui |  |
| public.agent_keys | key_hash | text | oui |  |
| public.agent_keys | label | text |  |  |
| public.agent_keys | created_at | timestamp with time zone | oui | now() |
| public.agent_keys | last_used_at | timestamp with time zone |  |  |
| public.agent_keys | allowed_dirs | jsonb | oui | '[]'::jsonb |
| public.agent_keys | kind | text | oui | 'agent'::text |
| public.agent_keys | scopes | jsonb | oui | '[]'::jsonb |
| public.agent_keys | expires_at | timestamp with time zone |  |  |
| public.agent_keys | capabilities | jsonb | oui | '{}'::jsonb |
| public.agent_keys | last_seen_at | timestamp with time zone |  |  |
| public.agent_memory | id | uuid | oui | gen_random_uuid() |
| public.agent_memory | user_id | uuid | oui |  |
| public.agent_memory | type | text | oui |  |
| public.agent_memory | goal | text | oui |  |
| public.agent_memory | content | text | oui |  |
| public.agent_memory | metadata | jsonb | oui | '{}'::jsonb |
| public.agent_memory | created_at | timestamp with time zone | oui | now() |
| public.agent_memory | level | text | oui | 'workflow'::text |
| public.agent_memory | status | text | oui | 'proposed'::text |
| public.agent_memory | project_id | uuid |  |  |
| public.agent_memory | updated_at | timestamp with time zone | oui | now() |
| public.agent_memory | session_id | uuid |  |  |
| public.agent_memory | scope | text | oui | 'user'::text |
| public.agent_memory | source_task_id | uuid |  |  |
| public.agent_memory | evidence_ids | jsonb | oui | '[]'::jsonb |
| public.agent_memory | confidence | real | oui | 0.5 |
| public.agent_memory | validated_by | uuid |  |  |
| public.agent_memory | validated_at | timestamp with time zone |  |  |
| public.agent_memory | expires_at | timestamp with time zone |  |  |
| public.agent_memory | is_simulation | boolean | oui | false |
| public.agent_tasks | id | uuid | oui | gen_random_uuid() |
| public.agent_tasks | user_id | uuid | oui |  |
| public.agent_tasks | task_type | text | oui |  |
| public.agent_tasks | status | text | oui | 'pending'::text |
| public.agent_tasks | priority | integer | oui | 5 |
| public.agent_tasks | payload | jsonb | oui | '{}'::jsonb |
| public.agent_tasks | result | jsonb |  |  |
| public.agent_tasks | error_message | text |  |  |
| public.agent_tasks | started_at | timestamp with time zone |  |  |
| public.agent_tasks | completed_at | timestamp with time zone |  |  |
| public.agent_tasks | created_at | timestamp with time zone | oui | now() |
| public.agent_tasks | updated_at | timestamp with time zone | oui | now() |
| public.agent_tasks | control | text | oui | 'none'::text |
| public.agent_tasks | requeue_count | integer | oui | 0 |
| public.agent_tasks | target_agent_key_id | uuid |  |  |
| public.agent_tasks | claimed_by_key_id | uuid |  |  |
| public.agent_tasks | v2_task_id | uuid |  |  |
| public.analysis_requests | id | uuid | oui | gen_random_uuid() |
| public.analysis_requests | user_id | uuid |  |  |
| public.analysis_requests | input_text | text | oui |  |
| public.analysis_requests | status | text | oui | 'pending'::text |
| public.analysis_requests | result | jsonb |  |  |
| public.analysis_requests | created_at | timestamp with time zone | oui | now() |
| public.applications | id | uuid | oui | gen_random_uuid() |
| public.applications | user_id | uuid | oui |  |
| public.applications | title | text | oui |  |
| public.applications | description | text |  |  |
| public.applications | app_type | text |  | 'Web App'::text |
| public.applications | tech_stack | text |  |  |
| public.applications | status | text | oui | 'En test'::text |
| public.applications | source_code | jsonb |  | '{}'::jsonb |
| public.applications | created_at | timestamp with time zone | oui | now() |
| public.applications | updated_at | timestamp with time zone | oui | now() |
| public.chat_conversations | id | uuid | oui | gen_random_uuid() |
| public.chat_conversations | user_id | uuid | oui |  |
| public.chat_conversations | title | text | oui | 'Nouvelle conversation'::text |
| public.chat_conversations | created_at | timestamp with time zone | oui | now() |
| public.chat_conversations | updated_at | timestamp with time zone | oui | now() |
| public.chat_messages | id | uuid | oui | gen_random_uuid() |
| public.chat_messages | conversation_id | uuid | oui |  |
| public.chat_messages | user_id | uuid | oui |  |
| public.chat_messages | role | text | oui |  |
| public.chat_messages | content | text | oui |  |
| public.chat_messages | created_at | timestamp with time zone | oui | now() |
| public.formations | id | uuid | oui | gen_random_uuid() |
| public.formations | user_id | uuid | oui |  |
| public.formations | title | text | oui |  |
| public.formations | description | text |  |  |
| public.formations | lessons_count | integer |  | 0 |
| public.formations | duration | text |  |  |
| public.formations | status | text | oui | 'En cours'::text |
| public.formations | content | jsonb |  | '[]'::jsonb |
| public.formations | created_at | timestamp with time zone | oui | now() |
| public.formations | updated_at | timestamp with time zone | oui | now() |
| public.formations | video_url | text |  |  |
| public.formations | curriculum | jsonb |  |  |
| public.formations | pdf_url | text |  |  |
| public.knowledge_base | id | uuid | oui | gen_random_uuid() |
| public.knowledge_base | user_id | uuid | oui |  |
| public.knowledge_base | title | text | oui |  |
| public.knowledge_base | content | text | oui |  |
| public.knowledge_base | category | text | oui | 'general'::text |
| public.knowledge_base | source | text |  |  |
| public.knowledge_base | tags | text[] |  | '{}'::text[] |
| public.knowledge_base | created_at | timestamp with time zone | oui | now() |
| public.knowledge_base | updated_at | timestamp with time zone | oui | now() |
| public.knowledge_base | description | text |  |  |
| public.knowledge_base | summary | text |  |  |
| public.knowledge_base | domain | text | oui | 'general'::text |
| public.knowledge_base | keywords | text[] | oui | '{}'::text[] |
| public.knowledge_base | sources | jsonb | oui | '[]'::jsonb |
| public.knowledge_base | confidence | real | oui | 0.5 |
| public.knowledge_base | version | integer | oui | 1 |
| public.knowledge_base | links | jsonb | oui | '[]'::jsonb |
| public.knowledge_base | content_hash | text |  |  |
| public.knowledge_base | last_verified_at | timestamp with time zone |  |  |
| public.knowledge_base | embedding | real[] |  |  |
| public.knowledge_base | source_uri | text |  |  |
| public.knowledge_base | mime | text |  |  |
| public.knowledge_base | ingest_status | text |  |  |
| public.knowledge_base | embedding_model | text |  |  |
| public.knowledge_base | last_written_at | timestamp with time zone |  |  |
| public.knowledge_base | doc_status | text |  |  |
| public.knowledge_domains | slug | text | oui |  |
| public.knowledge_domains | label | text | oui |  |
| public.knowledge_domains | is_system | boolean | oui | false |
| public.knowledge_domains | created_at | timestamp with time zone | oui | now() |
| public.knowledge_versions | id | uuid | oui | gen_random_uuid() |
| public.knowledge_versions | entry_id | uuid | oui |  |
| public.knowledge_versions | user_id | uuid | oui |  |
| public.knowledge_versions | version | integer | oui |  |
| public.knowledge_versions | snapshot | jsonb | oui |  |
| public.knowledge_versions | change_note | text |  |  |
| public.knowledge_versions | created_at | timestamp with time zone | oui | now() |
| public.modules_status | id | uuid | oui | gen_random_uuid() |
| public.modules_status | user_id | uuid | oui |  |
| public.modules_status | module_name | text | oui |  |
| public.modules_status | status | text | oui | 'idle'::text |
| public.modules_status | stats | text |  |  |
| public.modules_status | last_active | timestamp with time zone |  | now() |
| public.profiles | id | uuid | oui | gen_random_uuid() |
| public.profiles | user_id | uuid | oui |  |
| public.profiles | display_name | text |  |  |
| public.profiles | avatar_url | text |  |  |
| public.profiles | bio | text |  |  |
| public.profiles | created_at | timestamp with time zone | oui | now() |
| public.profiles | updated_at | timestamp with time zone | oui | now() |
| public.system_logs | id | uuid | oui | gen_random_uuid() |
| public.system_logs | user_id | uuid |  |  |
| public.system_logs | module | text | oui |  |
| public.system_logs | event | text | oui |  |
| public.system_logs | level | text | oui | 'info'::text |
| public.system_logs | details | jsonb |  | '{}'::jsonb |
| public.system_logs | created_at | timestamp with time zone | oui | now() |
| public.user_migrations | id | uuid | oui | gen_random_uuid() |
| public.user_migrations | user_id | uuid | oui |  |
| public.user_migrations | schema_id | uuid | oui |  |
| public.user_migrations | migration_type | text | oui |  |
| public.user_migrations | migration_details | jsonb | oui | '{}'::jsonb |
| public.user_migrations | applied_at | timestamp with time zone | oui | now() |
| public.user_roles | id | uuid | oui | gen_random_uuid() |
| public.user_roles | user_id | uuid | oui |  |
| public.user_roles | role | app_role | oui | 'user'::app_role |
| public.user_schemas | id | uuid | oui | gen_random_uuid() |
| public.user_schemas | user_id | uuid | oui |  |
| public.user_schemas | table_name | text | oui |  |
| public.user_schemas | columns | jsonb | oui | '[]'::jsonb |
| public.user_schemas | description | text |  |  |
| public.user_schemas | created_at | timestamp with time zone | oui | now() |
| public.user_schemas | updated_at | timestamp with time zone | oui | now() |
| public.user_table_data | id | uuid | oui | gen_random_uuid() |
| public.user_table_data | user_id | uuid | oui |  |
| public.user_table_data | schema_id | uuid | oui |  |
| public.user_table_data | row_data | jsonb | oui | '{}'::jsonb |
| public.user_table_data | created_at | timestamp with time zone | oui | now() |
| public.user_table_data | updated_at | timestamp with time zone | oui | now() |
| soulbah.actions | id | uuid | oui | gen_random_uuid() |
| soulbah.actions | task_id | uuid | oui |  |
| soulbah.actions | user_id | uuid | oui |  |
| soulbah.actions | attempt | integer | oui |  |
| soulbah.actions | step_index | integer | oui |  |
| soulbah.actions | tool | text | oui |  |
| soulbah.actions | params | jsonb | oui | '{}'::jsonb |
| soulbah.actions | security_level | text | oui | 'L1'::text |
| soulbah.actions | status | text | oui | 'planned'::text |
| soulbah.actions | evidence | jsonb | oui | '[]'::jsonb |
| soulbah.actions | evidence_confidence | text |  |  |
| soulbah.actions | simulated | boolean | oui | false |
| soulbah.actions | error | text |  |  |
| soulbah.actions | started_at | timestamp with time zone |  |  |
| soulbah.actions | finished_at | timestamp with time zone |  |  |
| soulbah.actions | created_at | timestamp with time zone | oui | now() |
| soulbah.actions | updated_at | timestamp with time zone | oui | now() |
| soulbah.agents | id | uuid | oui | gen_random_uuid() |
| soulbah.agents | session_id | uuid | oui |  |
| soulbah.agents | user_id | uuid | oui |  |
| soulbah.agents | role | text | oui |  |
| soulbah.agents | role_version | text | oui | '1.0.0'::text |
| soulbah.agents | name | text |  |  |
| soulbah.agents | status | text | oui | 'IDLE'::text |
| soulbah.agents | runtime_id | uuid |  |  |
| soulbah.agents | created_at | timestamp with time zone | oui | now() |
| soulbah.agents | updated_at | timestamp with time zone | oui | now() |
| soulbah.agents | current_task_id | uuid |  |  |
| soulbah.artifacts | id | uuid | oui | gen_random_uuid() |
| soulbah.artifacts | user_id | uuid | oui |  |
| soulbah.artifacts | session_id | uuid |  |  |
| soulbah.artifacts | task_id | uuid |  |  |
| soulbah.artifacts | sha256 | text | oui |  |
| soulbah.artifacts | mime | text | oui | 'application/octet-stream'::text |
| soulbah.artifacts | size_bytes | bigint | oui |  |
| soulbah.artifacts | uri | text | oui |  |
| soulbah.artifacts | kind | text | oui | 'file'::text |
| soulbah.artifacts | retention_class | text | oui | 'task'::text |
| soulbah.artifacts | metadata | jsonb | oui | '{}'::jsonb |
| soulbah.artifacts | created_at | timestamp with time zone | oui | now() |
| soulbah.audit_chain_head | id | smallint | oui |  |
| soulbah.audit_chain_head | last_seq | bigint | oui | 0 |
| soulbah.audit_chain_head | last_hash | text | oui | repeat('0'::text, 64) |
| soulbah.audit_chain_head | updated_at | timestamp with time zone | oui | now() |
| soulbah.audit_logs | seq | bigint | oui |  |
| soulbah.audit_logs | id | uuid | oui | gen_random_uuid() |
| soulbah.audit_logs | user_id | uuid |  |  |
| soulbah.audit_logs | session_id | uuid |  |  |
| soulbah.audit_logs | task_id | uuid |  |  |
| soulbah.audit_logs | actor | text | oui |  |
| soulbah.audit_logs | action | text | oui |  |
| soulbah.audit_logs | entity | text |  |  |
| soulbah.audit_logs | entity_id | uuid |  |  |
| soulbah.audit_logs | data | jsonb | oui | '{}'::jsonb |
| soulbah.audit_logs | prev_hash | text | oui |  |
| soulbah.audit_logs | row_hash | text | oui |  |
| soulbah.audit_logs | created_at | timestamp with time zone | oui | now() |
| soulbah.checkpoints | id | uuid | oui | gen_random_uuid() |
| soulbah.checkpoints | task_id | uuid | oui |  |
| soulbah.checkpoints | attempt | integer | oui |  |
| soulbah.checkpoints | seq | integer | oui |  |
| soulbah.checkpoints | step_cursor | integer | oui | 0 |
| soulbah.checkpoints | variables | jsonb | oui | '{}'::jsonb |
| soulbah.checkpoints | created_at | timestamp with time zone | oui | now() |
| soulbah.evaluations | id | uuid | oui | gen_random_uuid() |
| soulbah.evaluations | task_id | uuid | oui |  |
| soulbah.evaluations | user_id | uuid | oui |  |
| soulbah.evaluations | attempt | integer | oui |  |
| soulbah.evaluations | criteria | jsonb | oui | '[]'::jsonb |
| soulbah.evaluations | results | jsonb | oui | '[]'::jsonb |
| soulbah.evaluations | verdict | text | oui |  |
| soulbah.evaluations | confidence | text | oui | 'none'::text |
| soulbah.evaluations | evidence_ids | jsonb | oui | '[]'::jsonb |
| soulbah.evaluations | action_taken | text |  |  |
| soulbah.evaluations | evaluator | text | oui | 'rules'::text |
| soulbah.evaluations | created_at | timestamp with time zone | oui | now() |
| soulbah.knowledge_chunks | id | uuid | oui | gen_random_uuid() |
| soulbah.knowledge_chunks | document_id | uuid | oui |  |
| soulbah.knowledge_chunks | user_id | uuid | oui |  |
| soulbah.knowledge_chunks | chunk_index | integer | oui |  |
| soulbah.knowledge_chunks | content | text | oui |  |
| soulbah.knowledge_chunks | token_count | integer |  |  |
| soulbah.knowledge_chunks | tsv | tsvector |  | to_tsvector('simple'::regconfig, content) |
| soulbah.knowledge_chunks | embedding | real[] |  |  |
| soulbah.knowledge_chunks | embedding_model | text |  |  |
| soulbah.knowledge_chunks | created_at | timestamp with time zone | oui | now() |
| soulbah.knowledge_documents | id | uuid |  |  |
| soulbah.knowledge_documents | user_id | uuid |  |  |
| soulbah.knowledge_documents | title | text |  |  |
| soulbah.knowledge_documents | category | text |  |  |
| soulbah.knowledge_documents | domain | text |  |  |
| soulbah.knowledge_documents | source | text |  |  |
| soulbah.knowledge_documents | source_uri | text |  |  |
| soulbah.knowledge_documents | mime | text |  |  |
| soulbah.knowledge_documents | ingest_status | text |  |  |
| soulbah.knowledge_documents | embedding_model | text |  |  |
| soulbah.knowledge_documents | content_hash | text |  |  |
| soulbah.knowledge_documents | version | integer |  |  |
| soulbah.knowledge_documents | confidence | real |  |  |
| soulbah.knowledge_documents | doc_status | text |  |  |
| soulbah.knowledge_documents | doc_status_derived | boolean |  |  |
| soulbah.knowledge_documents | last_verified_at | timestamp with time zone |  |  |
| soulbah.knowledge_documents | last_written_at | timestamp with time zone |  |  |
| soulbah.knowledge_documents | created_at | timestamp with time zone |  |  |
| soulbah.knowledge_documents | updated_at | timestamp with time zone |  |  |
| soulbah.memories | id | uuid |  |  |
| soulbah.memories | user_id | uuid |  |  |
| soulbah.memories | session_id | uuid |  |  |
| soulbah.memories | scope | text |  |  |
| soulbah.memories | type | text |  |  |
| soulbah.memories | level | text |  |  |
| soulbah.memories | goal | text |  |  |
| soulbah.memories | content | text |  |  |
| soulbah.memories | metadata | jsonb |  |  |
| soulbah.memories | project_id | uuid |  |  |
| soulbah.memories | source_task_id | uuid |  |  |
| soulbah.memories | evidence_ids | jsonb |  |  |
| soulbah.memories | confidence | real |  |  |
| soulbah.memories | status | text |  |  |
| soulbah.memories | stored_status | text |  |  |
| soulbah.memories | validated_by | uuid |  |  |
| soulbah.memories | validated_at | timestamp with time zone |  |  |
| soulbah.memories | expires_at | timestamp with time zone |  |  |
| soulbah.memories | is_simulation | boolean |  |  |
| soulbah.memories | created_at | timestamp with time zone |  |  |
| soulbah.memories | updated_at | timestamp with time zone |  |  |
| soulbah.messages | id | uuid | oui | gen_random_uuid() |
| soulbah.messages | session_id | uuid | oui |  |
| soulbah.messages | task_id | uuid |  |  |
| soulbah.messages | from_agent_id | uuid |  |  |
| soulbah.messages | to_agent_id | uuid |  |  |
| soulbah.messages | to_role | text |  |  |
| soulbah.messages | type | text | oui |  |
| soulbah.messages | correlation_id | uuid |  |  |
| soulbah.messages | reply_to | uuid |  |  |
| soulbah.messages | payload | jsonb | oui | '{}'::jsonb |
| soulbah.messages | requires_ack | boolean | oui | false |
| soulbah.messages | acked_at | timestamp with time zone |  |  |
| soulbah.messages | created_at | timestamp with time zone | oui | now() |
| soulbah.permissions | id | uuid | oui | gen_random_uuid() |
| soulbah.permissions | user_id | uuid | oui |  |
| soulbah.permissions | session_id | uuid |  |  |
| soulbah.permissions | task_id | uuid |  |  |
| soulbah.permissions | action_id | uuid |  |  |
| soulbah.permissions | kind | text | oui |  |
| soulbah.permissions | security_level | text | oui |  |
| soulbah.permissions | scope | jsonb | oui | '{}'::jsonb |
| soulbah.permissions | payload_sha256 | text |  |  |
| soulbah.permissions | payload_presented | jsonb |  |  |
| soulbah.permissions | status | text | oui | 'pending'::text |
| soulbah.permissions | decided_by | uuid |  |  |
| soulbah.permissions | decided_at | timestamp with time zone |  |  |
| soulbah.permissions | expires_at | timestamp with time zone |  |  |
| soulbah.permissions | token_hash | text |  |  |
| soulbah.permissions | created_at | timestamp with time zone | oui | now() |
| soulbah.permissions | updated_at | timestamp with time zone | oui | now() |
| soulbah.recordings | id | uuid | oui | gen_random_uuid() |
| soulbah.recordings | user_id | uuid | oui |  |
| soulbah.recordings | task_id | uuid |  |  |
| soulbah.recordings | artifact_id | uuid |  |  |
| soulbah.recordings | path | text | oui |  |
| soulbah.recordings | status | text | oui | 'recording'::text |
| soulbah.recordings | duration_s | real |  |  |
| soulbah.recordings | fps_requested | real |  |  |
| soulbah.recordings | fps_effective | real |  |  |
| soulbah.recordings | probe | jsonb |  |  |
| soulbah.recordings | started_at | timestamp with time zone | oui | now() |
| soulbah.recordings | stopped_at | timestamp with time zone |  |  |
| soulbah.recordings | created_at | timestamp with time zone | oui | now() |
| soulbah.resource_leases | resource_key | text | oui |  |
| soulbah.resource_leases | holder_task_id | uuid | oui |  |
| soulbah.resource_leases | mode | text | oui | 'exclusive'::text |
| soulbah.resource_leases | expires_at | timestamp with time zone | oui |  |
| soulbah.resource_leases | created_at | timestamp with time zone | oui | now() |
| soulbah.runtimes | id | uuid | oui | gen_random_uuid() |
| soulbah.runtimes | user_id | uuid | oui |  |
| soulbah.runtimes | agent_key_id | uuid | oui |  |
| soulbah.runtimes | hostname | text |  |  |
| soulbah.runtimes | version | text |  |  |
| soulbah.runtimes | max_slots | integer | oui | 6 |
| soulbah.runtimes | capabilities | jsonb | oui | '{}'::jsonb |
| soulbah.runtimes | status | text | oui | 'offline'::text |
| soulbah.runtimes | lease_owner | text |  |  |
| soulbah.runtimes | last_seen_at | timestamp with time zone |  |  |
| soulbah.runtimes | created_at | timestamp with time zone | oui | now() |
| soulbah.runtimes | updated_at | timestamp with time zone | oui | now() |
| soulbah.schema_migration_runs | id | bigint | oui |  |
| soulbah.schema_migration_runs | version | text | oui |  |
| soulbah.schema_migration_runs | action | text | oui |  |
| soulbah.schema_migration_runs | status | text | oui |  |
| soulbah.schema_migration_runs | checksum | text |  |  |
| soulbah.schema_migration_runs | started_at | timestamp with time zone | oui | now() |
| soulbah.schema_migration_runs | execution_ms | integer |  |  |
| soulbah.schema_migration_runs | error | text |  |  |
| soulbah.schema_migration_runs | run_by | text | oui | CURRENT_USER |
| soulbah.schema_migration_runs | app_commit | text |  |  |
| soulbah.schema_migration_runs | details | jsonb | oui | '{}'::jsonb |
| soulbah.schema_migrations | version | text | oui |  |
| soulbah.schema_migrations | name | text | oui |  |
| soulbah.schema_migrations | checksum | text | oui |  |
| soulbah.schema_migrations | source | text | oui |  |
| soulbah.schema_migrations | status | text | oui |  |
| soulbah.schema_migrations | rollback | text | oui | 'NO'::text |
| soulbah.schema_migrations | recovery | text |  |  |
| soulbah.schema_migrations | executed_at | timestamp with time zone | oui | now() |
| soulbah.schema_migrations | execution_ms | integer |  |  |
| soulbah.schema_migrations | applied_by | text | oui | CURRENT_USER |
| soulbah.schema_migrations | app_commit | text |  |  |
| soulbah.schema_migrations | notes | text |  |  |
| soulbah.sessions | id | uuid | oui | gen_random_uuid() |
| soulbah.sessions | user_id | uuid | oui |  |
| soulbah.sessions | goal | text | oui |  |
| soulbah.sessions | status | text | oui | 'DRAFT'::text |
| soulbah.sessions | environment | jsonb | oui | '{}'::jsonb |
| soulbah.sessions | max_security_level | text | oui | 'L2'::text |
| soulbah.sessions | max_parallel_agents | integer |  |  |
| soulbah.sessions | budget_usd | numeric(12,4) |  |  |
| soulbah.sessions | spent_usd | numeric(12,4) | oui | 0 |
| soulbah.sessions | plan | jsonb |  |  |
| soulbah.sessions | plan_version | integer | oui | 0 |
| soulbah.sessions | simulated | boolean | oui | false |
| soulbah.sessions | error | text |  |  |
| soulbah.sessions | created_at | timestamp with time zone | oui | now() |
| soulbah.sessions | updated_at | timestamp with time zone | oui | now() |
| soulbah.sessions | started_at | timestamp with time zone |  |  |
| soulbah.sessions | finished_at | timestamp with time zone |  |  |
| soulbah.skills | id | uuid | oui | gen_random_uuid() |
| soulbah.skills | name | text | oui |  |
| soulbah.skills | version | text | oui |  |
| soulbah.skills | source | text | oui | 'catalog'::text |
| soulbah.skills | status | text | oui | 'active'::text |
| soulbah.skills | security_level | text | oui | 'L1'::text |
| soulbah.skills | schema | jsonb | oui | '{}'::jsonb |
| soulbah.skills | procedure | jsonb | oui | '{}'::jsonb |
| soulbah.skills | permissions | jsonb | oui | '{}'::jsonb |
| soulbah.skills | examples | jsonb | oui | '[]'::jsonb |
| soulbah.skills | known_errors | jsonb | oui | '[]'::jsonb |
| soulbah.skills | tests | jsonb | oui | '[]'::jsonb |
| soulbah.skills | created_by | uuid |  |  |
| soulbah.skills | created_at | timestamp with time zone | oui | now() |
| soulbah.skills | updated_at | timestamp with time zone | oui | now() |
| soulbah.task_dependencies | task_id | uuid | oui |  |
| soulbah.task_dependencies | depends_on_task_id | uuid | oui |  |
| soulbah.task_dependencies | kind | text | oui | 'hard'::text |
| soulbah.task_dependencies | created_at | timestamp with time zone | oui | now() |
| soulbah.tasks | id | uuid | oui | gen_random_uuid() |
| soulbah.tasks | session_id | uuid | oui |  |
| soulbah.tasks | user_id | uuid | oui |  |
| soulbah.tasks | parent_task_id | uuid |  |  |
| soulbah.tasks | node_key | text |  |  |
| soulbah.tasks | title | text | oui |  |
| soulbah.tasks | role | text | oui |  |
| soulbah.tasks | status | text | oui | 'PENDING'::text |
| soulbah.tasks | attempt | integer | oui | 0 |
| soulbah.tasks | retry_count | integer | oui | 0 |
| soulbah.tasks | max_retries | integer | oui | 2 |
| soulbah.tasks | lease_owner | text |  |  |
| soulbah.tasks | lease_expires_at | timestamp with time zone |  |  |
| soulbah.tasks | idempotency_key | text |  |  |
| soulbah.tasks | security_level | text | oui | 'L1'::text |
| soulbah.tasks | resources | jsonb | oui | '[]'::jsonb |
| soulbah.tasks | spec | jsonb | oui | '{}'::jsonb |
| soulbah.tasks | acceptance_criteria | jsonb | oui | '[]'::jsonb |
| soulbah.tasks | result | jsonb |  |  |
| soulbah.tasks | error | text |  |  |
| soulbah.tasks | simulated | boolean | oui | false |
| soulbah.tasks | blocked_reason | text |  |  |
| soulbah.tasks | waiting_reason | text |  |  |
| soulbah.tasks | priority | integer | oui | 5 |
| soulbah.tasks | plan_version | integer | oui | 0 |
| soulbah.tasks | next_attempt_at | timestamp with time zone |  |  |
| soulbah.tasks | escalate_at | timestamp with time zone |  |  |
| soulbah.tasks | created_at | timestamp with time zone | oui | now() |
| soulbah.tasks | updated_at | timestamp with time zone | oui | now() |
| soulbah.tasks | started_at | timestamp with time zone |  |  |
| soulbah.tasks | finished_at | timestamp with time zone |  |  |
| soulbah.tool_calls | id | uuid | oui | gen_random_uuid() |
| soulbah.tool_calls | user_id | uuid | oui |  |
| soulbah.tool_calls | session_id | uuid |  |  |
| soulbah.tool_calls | task_id | uuid |  |  |
| soulbah.tool_calls | action_id | uuid |  |  |
| soulbah.tool_calls | kind | text | oui |  |
| soulbah.tool_calls | name | text | oui |  |
| soulbah.tool_calls | provider | text |  |  |
| soulbah.tool_calls | model | text |  |  |
| soulbah.tool_calls | status | text | oui | 'ok'::text |
| soulbah.tool_calls | exit_code | integer |  |  |
| soulbah.tool_calls | http_status | integer |  |  |
| soulbah.tool_calls | input_tokens | integer |  |  |
| soulbah.tool_calls | output_tokens | integer |  |  |
| soulbah.tool_calls | cost_usd | numeric(12,6) |  |  |
| soulbah.tool_calls | latency_ms | integer |  |  |
| soulbah.tool_calls | error | text |  |  |
| soulbah.tool_calls | metadata | jsonb | oui | '{}'::jsonb |
| soulbah.tool_calls | created_at | timestamp with time zone | oui | now() |
| soulbah.user_settings | user_id | uuid | oui |  |
| soulbah.user_settings | max_parallel_agents | integer | oui | 6 |
| soulbah.user_settings | max_security_level | text | oui | 'L2'::text |
| soulbah.user_settings | daily_budget_usd | numeric(12,4) |  |  |
| soulbah.user_settings | settings | jsonb | oui | '{}'::jsonb |
| soulbah.user_settings | created_at | timestamp with time zone | oui | now() |
| soulbah.user_settings | updated_at | timestamp with time zone | oui | now() |

## Contraintes (PK, FK, UNIQUE, CHECK)

| Table | Nom | Type | Validée | Définition |
|---|---|---|---|---|
| public.agent_events | agent_events_pkey | PK | oui | PRIMARY KEY (id) |
| public.agent_events | agent_events_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.agent_keys | agent_keys_capabilities_object | CHECK | oui | CHECK (soulbah.is_json_object(capabilities)) |
| public.agent_keys | agent_keys_key_hash_key | UNIQUE | oui | UNIQUE (key_hash) |
| public.agent_keys | agent_keys_kind_check | CHECK | oui | CHECK (kind = ANY (ARRAY['agent'::text, 'runtime'::text])) |
| public.agent_keys | agent_keys_pkey | PK | oui | PRIMARY KEY (id) |
| public.agent_keys | agent_keys_scopes_array | CHECK | oui | CHECK (soulbah.is_json_array(scopes)) |
| public.agent_keys | agent_keys_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.agent_memory | agent_memory_confidence_range | CHECK | oui | CHECK (confidence >= 0::double precision AND confidence <= 1::double precision) |
| public.agent_memory | agent_memory_evidence_array | CHECK | oui | CHECK (soulbah.is_json_array(evidence_ids)) |
| public.agent_memory | agent_memory_level_check | CHECK | oui | CHECK (level = ANY (ARRAY['working'::text, 'project'::text, 'user'::text, 'technical'::text, 'documentary'::text, 'workflow'::text, 'error'::text, 'optimization |
| public.agent_memory | agent_memory_pkey | PK | oui | PRIMARY KEY (id) |
| public.agent_memory | agent_memory_scope_check | CHECK | oui | CHECK (scope = ANY (ARRAY['session'::text, 'project'::text, 'user'::text, 'global'::text])) |
| public.agent_memory | agent_memory_session_fk | FK | oui | FOREIGN KEY (session_id) REFERENCES soulbah.sessions(id) ON DELETE SET NULL |
| public.agent_memory | agent_memory_source_task_fk | FK | oui | FOREIGN KEY (source_task_id) REFERENCES soulbah.tasks(id) ON DELETE SET NULL |
| public.agent_memory | agent_memory_status_check | CHECK | oui | CHECK (status = ANY (ARRAY['proposed'::text, 'validated'::text, 'rejected'::text])) |
| public.agent_memory | agent_memory_type_check | CHECK | oui | CHECK (type = ANY (ARRAY['error'::text, 'solution'::text, 'practice'::text])) |
| public.agent_memory | agent_memory_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.agent_memory | agent_memory_validated_requires_proof | CHECK | **NOT VALID** | CHECK (status <> 'validated'::text OR validated_by IS NOT NULL OR metadata ? 'validated_by'::text OR jsonb_typeof(evidence_ids) = 'array'::text AND jsonb_array_ |
| public.agent_tasks | agent_tasks_claimed_by_key_id_fkey | FK | oui | FOREIGN KEY (claimed_by_key_id) REFERENCES agent_keys(id) ON DELETE SET NULL |
| public.agent_tasks | agent_tasks_control_check | CHECK | oui | CHECK (control = ANY (ARRAY['none'::text, 'pause'::text, 'stop'::text])) |
| public.agent_tasks | agent_tasks_pkey | PK | oui | PRIMARY KEY (id) |
| public.agent_tasks | agent_tasks_status_check | CHECK | oui | CHECK (status = ANY (ARRAY['pending'::text, 'in_progress'::text, 'completed'::text, 'failed'::text, 'cancelled'::text])) |
| public.agent_tasks | agent_tasks_target_agent_key_id_fkey | FK | oui | FOREIGN KEY (target_agent_key_id) REFERENCES agent_keys(id) ON DELETE SET NULL |
| public.agent_tasks | agent_tasks_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.agent_tasks | agent_tasks_v2_task_fk | FK | oui | FOREIGN KEY (v2_task_id) REFERENCES soulbah.tasks(id) ON DELETE SET NULL |
| public.analysis_requests | analysis_requests_pkey | PK | oui | PRIMARY KEY (id) |
| public.analysis_requests | analysis_requests_status_check | CHECK | oui | CHECK (status = ANY (ARRAY['pending'::text, 'processing'::text, 'done'::text, 'error'::text])) |
| public.analysis_requests | analysis_requests_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.applications | applications_pkey | PK | oui | PRIMARY KEY (id) |
| public.applications | applications_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.chat_conversations | chat_conversations_pkey | PK | oui | PRIMARY KEY (id) |
| public.chat_conversations | chat_conversations_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.chat_messages | chat_messages_conversation_id_fkey | FK | oui | FOREIGN KEY (conversation_id) REFERENCES chat_conversations(id) ON DELETE CASCADE |
| public.chat_messages | chat_messages_pkey | PK | oui | PRIMARY KEY (id) |
| public.chat_messages | chat_messages_role_check | CHECK | oui | CHECK (role = ANY (ARRAY['user'::text, 'assistant'::text, 'system'::text])) |
| public.chat_messages | chat_messages_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.formations | formations_pkey | PK | oui | PRIMARY KEY (id) |
| public.formations | formations_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.knowledge_base | knowledge_base_confidence_range | CHECK | oui | CHECK (confidence >= 0::double precision AND confidence <= 1::double precision) |
| public.knowledge_base | knowledge_base_doc_status_check | CHECK | oui | CHECK (doc_status IS NULL OR (doc_status = ANY (ARRAY['finding'::text, 'user'::text, 'validated'::text, 'rejected'::text, 'deprecated'::text]))) |
| public.knowledge_base | knowledge_base_ingest_status_check | CHECK | oui | CHECK (ingest_status IS NULL OR (ingest_status = ANY (ARRAY['pending'::text, 'chunked'::text, 'embedded'::text, 'failed'::text]))) |
| public.knowledge_base | knowledge_base_pkey | PK | oui | PRIMARY KEY (id) |
| public.knowledge_base | knowledge_base_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.knowledge_domains | knowledge_domains_pkey | PK | oui | PRIMARY KEY (slug) |
| public.knowledge_versions | knowledge_versions_entry_id_fkey | FK | oui | FOREIGN KEY (entry_id) REFERENCES knowledge_base(id) ON DELETE CASCADE |
| public.knowledge_versions | knowledge_versions_pkey | PK | oui | PRIMARY KEY (id) |
| public.knowledge_versions | knowledge_versions_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.modules_status | modules_status_pkey | PK | oui | PRIMARY KEY (id) |
| public.modules_status | modules_status_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.modules_status | modules_status_user_id_module_name_key | UNIQUE | oui | UNIQUE (user_id, module_name) |
| public.profiles | profiles_pkey | PK | oui | PRIMARY KEY (id) |
| public.profiles | profiles_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.profiles | profiles_user_id_key | UNIQUE | oui | UNIQUE (user_id) |
| public.system_logs | system_logs_pkey | PK | oui | PRIMARY KEY (id) |
| public.system_logs | system_logs_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.user_migrations | user_migrations_pkey | PK | oui | PRIMARY KEY (id) |
| public.user_migrations | user_migrations_schema_id_fkey | FK | oui | FOREIGN KEY (schema_id) REFERENCES user_schemas(id) ON DELETE CASCADE |
| public.user_migrations | user_migrations_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.user_roles | user_roles_pkey | PK | oui | PRIMARY KEY (id) |
| public.user_roles | user_roles_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.user_roles | user_roles_user_id_role_key | UNIQUE | oui | UNIQUE (user_id, role) |
| public.user_schemas | user_schemas_pkey | PK | oui | PRIMARY KEY (id) |
| public.user_schemas | user_schemas_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.user_schemas | user_schemas_user_id_table_name_key | UNIQUE | oui | UNIQUE (user_id, table_name) |
| public.user_table_data | user_table_data_pkey | PK | oui | PRIMARY KEY (id) |
| public.user_table_data | user_table_data_schema_id_fkey | FK | oui | FOREIGN KEY (schema_id) REFERENCES user_schemas(id) ON DELETE CASCADE |
| public.user_table_data | user_table_data_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| soulbah.actions | actions_attempt_positive | CHECK | oui | CHECK (attempt >= 0) |
| soulbah.actions | actions_confidence_check | CHECK | oui | CHECK (evidence_confidence IS NULL OR (evidence_confidence = ANY (ARRAY['high'::text, 'medium'::text, 'low'::text, 'none'::text]))) |
| soulbah.actions | actions_evidence_array | CHECK | oui | CHECK (soulbah.is_json_array(evidence)) |
| soulbah.actions | actions_idempotency | UNIQUE | oui | UNIQUE (task_id, attempt, step_index) |
| soulbah.actions | actions_level_check | CHECK | oui | CHECK (soulbah.is_security_level(security_level)) |
| soulbah.actions | actions_params_object | CHECK | oui | CHECK (soulbah.is_json_object(params)) |
| soulbah.actions | actions_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.actions | actions_simulated_never_verified | CHECK | oui | CHECK (NOT (simulated AND status = 'verified'::text)) |
| soulbah.actions | actions_simulated_status | CHECK | oui | CHECK (status <> 'simulated'::text OR simulated) |
| soulbah.actions | actions_status_check | CHECK | oui | CHECK (status = ANY (ARRAY['planned'::text, 'attempted'::text, 'executed'::text, 'verified'::text, 'failed'::text, 'skipped'::text, 'simulated'::text])) |
| soulbah.actions | actions_step_positive | CHECK | oui | CHECK (step_index >= 0) |
| soulbah.actions | actions_task_id_fkey | FK | oui | FOREIGN KEY (task_id) REFERENCES soulbah.tasks(id) ON DELETE CASCADE |
| soulbah.actions | actions_tool_format | CHECK | oui | CHECK (tool ~ '^[a-z][a-z0-9_]{0,39}$'::text) |
| soulbah.actions | actions_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| soulbah.agents | agents_current_task_fk | FK | oui | FOREIGN KEY (current_task_id) REFERENCES soulbah.tasks(id) ON DELETE SET NULL |
| soulbah.agents | agents_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.agents | agents_role_format | CHECK | oui | CHECK (role ~ '^[a-z][a-z0-9_]{0,63}$'::text) |
| soulbah.agents | agents_runtime_id_fkey | FK | oui | FOREIGN KEY (runtime_id) REFERENCES soulbah.runtimes(id) ON DELETE SET NULL |
| soulbah.agents | agents_session_id_fkey | FK | oui | FOREIGN KEY (session_id) REFERENCES soulbah.sessions(id) ON DELETE CASCADE |
| soulbah.agents | agents_status_check | CHECK | oui | CHECK (status = ANY (ARRAY['IDLE'::text, 'BUSY'::text, 'WAITING'::text, 'STOPPED'::text, 'FAILED'::text])) |
| soulbah.agents | agents_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| soulbah.artifacts | artifacts_kind_check | CHECK | oui | CHECK (kind = ANY (ARRAY['file'::text, 'screenshot'::text, 'video'::text, 'log'::text, 'report'::text, 'diff'::text])) |
| soulbah.artifacts | artifacts_metadata_object | CHECK | oui | CHECK (soulbah.is_json_object(metadata)) |
| soulbah.artifacts | artifacts_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.artifacts | artifacts_retention_check | CHECK | oui | CHECK (retention_class = ANY (ARRAY['ephemeral'::text, 'task'::text, 'session'::text, 'permanent'::text])) |
| soulbah.artifacts | artifacts_session_id_fkey | FK | oui | FOREIGN KEY (session_id) REFERENCES soulbah.sessions(id) ON DELETE SET NULL |
| soulbah.artifacts | artifacts_sha256_format | CHECK | oui | CHECK (sha256 ~ '^[0-9a-f]{64}$'::text) |
| soulbah.artifacts | artifacts_size_positive | CHECK | oui | CHECK (size_bytes >= 0) |
| soulbah.artifacts | artifacts_task_id_fkey | FK | oui | FOREIGN KEY (task_id) REFERENCES soulbah.tasks(id) ON DELETE SET NULL |
| soulbah.artifacts | artifacts_unique_per_user | UNIQUE | oui | UNIQUE (user_id, sha256) |
| soulbah.artifacts | artifacts_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| soulbah.audit_chain_head | audit_chain_head_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.audit_chain_head | audit_chain_head_single | CHECK | oui | CHECK (id = 1) |
| soulbah.audit_logs | audit_logs_action_format | CHECK | oui | CHECK (action ~ '^[a-z][a-z0-9_.]{0,99}$'::text) |
| soulbah.audit_logs | audit_logs_actor_length | CHECK | oui | CHECK (length(actor) >= 1 AND length(actor) <= 200) |
| soulbah.audit_logs | audit_logs_data_object | CHECK | oui | CHECK (soulbah.is_json_object(data)) |
| soulbah.audit_logs | audit_logs_id_key | UNIQUE | oui | UNIQUE (id) |
| soulbah.audit_logs | audit_logs_pkey | PK | oui | PRIMARY KEY (seq) |
| soulbah.audit_logs | audit_logs_prev_hash_format | CHECK | oui | CHECK (prev_hash ~ '^[0-9a-f]{64}$'::text) |
| soulbah.audit_logs | audit_logs_row_hash_format | CHECK | oui | CHECK (row_hash ~ '^[0-9a-f]{64}$'::text) |
| soulbah.checkpoints | checkpoints_attempt_positive | CHECK | oui | CHECK (attempt >= 0) |
| soulbah.checkpoints | checkpoints_cursor_positive | CHECK | oui | CHECK (step_cursor >= 0) |
| soulbah.checkpoints | checkpoints_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.checkpoints | checkpoints_seq_positive | CHECK | oui | CHECK (seq >= 0) |
| soulbah.checkpoints | checkpoints_task_id_fkey | FK | oui | FOREIGN KEY (task_id) REFERENCES soulbah.tasks(id) ON DELETE CASCADE |
| soulbah.checkpoints | checkpoints_unique | UNIQUE | oui | UNIQUE (task_id, attempt, seq) |
| soulbah.checkpoints | checkpoints_variables_object | CHECK | oui | CHECK (soulbah.is_json_object(variables)) |
| soulbah.evaluations | evaluations_attempt_positive | CHECK | oui | CHECK (attempt >= 0) |
| soulbah.evaluations | evaluations_confidence_check | CHECK | oui | CHECK (confidence = ANY (ARRAY['high'::text, 'medium'::text, 'low'::text, 'none'::text])) |
| soulbah.evaluations | evaluations_criteria_array | CHECK | oui | CHECK (soulbah.is_json_array(criteria)) |
| soulbah.evaluations | evaluations_evaluator_check | CHECK | oui | CHECK (evaluator = ANY (ARRAY['rules'::text, 'llm'::text, 'qa_reviewer'::text, 'user'::text])) |
| soulbah.evaluations | evaluations_evidence_array | CHECK | oui | CHECK (soulbah.is_json_array(evidence_ids)) |
| soulbah.evaluations | evaluations_once_per_attempt | UNIQUE | oui | UNIQUE (task_id, attempt) |
| soulbah.evaluations | evaluations_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.evaluations | evaluations_results_array | CHECK | oui | CHECK (soulbah.is_json_array(results)) |
| soulbah.evaluations | evaluations_task_id_fkey | FK | oui | FOREIGN KEY (task_id) REFERENCES soulbah.tasks(id) ON DELETE CASCADE |
| soulbah.evaluations | evaluations_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| soulbah.evaluations | evaluations_verdict_check | CHECK | oui | CHECK (verdict = ANY (ARRAY['success'::text, 'partial'::text, 'failure'::text, 'abort'::text, 'not_evaluable'::text])) |
| soulbah.knowledge_chunks | knowledge_chunks_content_length | CHECK | oui | CHECK (length(content) >= 1 AND length(content) <= 20000) |
| soulbah.knowledge_chunks | knowledge_chunks_document_id_fkey | FK | oui | FOREIGN KEY (document_id) REFERENCES knowledge_base(id) ON DELETE CASCADE |
| soulbah.knowledge_chunks | knowledge_chunks_index_positive | CHECK | oui | CHECK (chunk_index >= 0) |
| soulbah.knowledge_chunks | knowledge_chunks_model_with_embedding | CHECK | oui | CHECK (embedding IS NULL OR embedding_model IS NOT NULL) |
| soulbah.knowledge_chunks | knowledge_chunks_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.knowledge_chunks | knowledge_chunks_tokens_positive | CHECK | oui | CHECK (token_count IS NULL OR token_count >= 0) |
| soulbah.knowledge_chunks | knowledge_chunks_unique | UNIQUE | oui | UNIQUE (document_id, chunk_index) |
| soulbah.knowledge_chunks | knowledge_chunks_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| soulbah.messages | messages_from_agent_id_fkey | FK | oui | FOREIGN KEY (from_agent_id) REFERENCES soulbah.agents(id) ON DELETE SET NULL |
| soulbah.messages | messages_payload_object | CHECK | oui | CHECK (soulbah.is_json_object(payload)) |
| soulbah.messages | messages_payload_size | CHECK | oui | CHECK (pg_column_size(payload) <= 65536) |
| soulbah.messages | messages_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.messages | messages_reply_to_fkey | FK | oui | FOREIGN KEY (reply_to) REFERENCES soulbah.messages(id) ON DELETE SET NULL |
| soulbah.messages | messages_session_id_fkey | FK | oui | FOREIGN KEY (session_id) REFERENCES soulbah.sessions(id) ON DELETE CASCADE |
| soulbah.messages | messages_task_id_fkey | FK | oui | FOREIGN KEY (task_id) REFERENCES soulbah.tasks(id) ON DELETE SET NULL |
| soulbah.messages | messages_to_agent_id_fkey | FK | oui | FOREIGN KEY (to_agent_id) REFERENCES soulbah.agents(id) ON DELETE SET NULL |
| soulbah.messages | messages_to_role_format | CHECK | oui | CHECK (to_role IS NULL OR to_role ~ '^[a-z][a-z0-9_]{0,63}$'::text) |
| soulbah.messages | messages_type_check | CHECK | oui | CHECK (type = ANY (ARRAY['TASK_REQUEST'::text, 'TASK_RESULT'::text, 'QUESTION'::text, 'BLOCKER'::text, 'EVIDENCE'::text, 'REVIEW_REQUEST'::text, 'REVIEW_RESULT' |
| soulbah.permissions | permissions_action_id_fkey | FK | oui | FOREIGN KEY (action_id) REFERENCES soulbah.actions(id) ON DELETE SET NULL |
| soulbah.permissions | permissions_decided_by_fkey | FK | oui | FOREIGN KEY (decided_by) REFERENCES auth.users(id) ON DELETE SET NULL |
| soulbah.permissions | permissions_decision_consistent | CHECK | oui | CHECK ((status <> ALL (ARRAY['approved'::text, 'denied'::text])) OR decided_at IS NOT NULL) |
| soulbah.permissions | permissions_kind_check | CHECK | oui | CHECK (kind = ANY (ARRAY['grant'::text, 'request'::text])) |
| soulbah.permissions | permissions_l3_requires_payload | CHECK | oui | CHECK (kind <> 'request'::text OR security_level <> 'L3'::text OR payload_sha256 IS NOT NULL) |
| soulbah.permissions | permissions_level_check | CHECK | oui | CHECK (soulbah.is_security_level(security_level)) |
| soulbah.permissions | permissions_payload_hash_format | CHECK | oui | CHECK (payload_sha256 IS NULL OR payload_sha256 ~ '^[0-9a-f]{64}$'::text) |
| soulbah.permissions | permissions_payload_object | CHECK | oui | CHECK (payload_presented IS NULL OR soulbah.is_json_object(payload_presented)) |
| soulbah.permissions | permissions_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.permissions | permissions_scope_object | CHECK | oui | CHECK (soulbah.is_json_object(scope)) |
| soulbah.permissions | permissions_session_id_fkey | FK | oui | FOREIGN KEY (session_id) REFERENCES soulbah.sessions(id) ON DELETE CASCADE |
| soulbah.permissions | permissions_status_check | CHECK | oui | CHECK (status = ANY (ARRAY['pending'::text, 'approved'::text, 'denied'::text, 'expired'::text, 'revoked'::text])) |
| soulbah.permissions | permissions_task_id_fkey | FK | oui | FOREIGN KEY (task_id) REFERENCES soulbah.tasks(id) ON DELETE CASCADE |
| soulbah.permissions | permissions_token_hash_format | CHECK | oui | CHECK (token_hash IS NULL OR token_hash ~ '^[0-9a-f]{64}$'::text) |
| soulbah.permissions | permissions_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| soulbah.recordings | recordings_artifact_id_fkey | FK | oui | FOREIGN KEY (artifact_id) REFERENCES soulbah.artifacts(id) ON DELETE SET NULL |
| soulbah.recordings | recordings_duration_positive | CHECK | oui | CHECK (duration_s IS NULL OR duration_s >= 0::double precision) |
| soulbah.recordings | recordings_fps_eff_positive | CHECK | oui | CHECK (fps_effective IS NULL OR fps_effective >= 0::double precision) |
| soulbah.recordings | recordings_fps_req_positive | CHECK | oui | CHECK (fps_requested IS NULL OR fps_requested > 0::double precision) |
| soulbah.recordings | recordings_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.recordings | recordings_probe_object | CHECK | oui | CHECK (probe IS NULL OR soulbah.is_json_object(probe)) |
| soulbah.recordings | recordings_status_check | CHECK | oui | CHECK (status = ANY (ARRAY['recording'::text, 'stopped'::text, 'failed'::text])) |
| soulbah.recordings | recordings_task_id_fkey | FK | oui | FOREIGN KEY (task_id) REFERENCES soulbah.tasks(id) ON DELETE SET NULL |
| soulbah.recordings | recordings_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| soulbah.resource_leases | resource_leases_holder_task_id_fkey | FK | oui | FOREIGN KEY (holder_task_id) REFERENCES soulbah.tasks(id) ON DELETE CASCADE |
| soulbah.resource_leases | resource_leases_key_format | CHECK | oui | CHECK (resource_key ~ '^[a-z][a-z0-9_.-]*(:[^\s]+)*$'::text) |
| soulbah.resource_leases | resource_leases_mode_check | CHECK | oui | CHECK (mode = ANY (ARRAY['exclusive'::text, 'shared'::text])) |
| soulbah.resource_leases | resource_leases_pkey | PK | oui | PRIMARY KEY (resource_key, holder_task_id) |
| soulbah.runtimes | runtimes_agent_key_id_fkey | FK | oui | FOREIGN KEY (agent_key_id) REFERENCES agent_keys(id) ON DELETE CASCADE |
| soulbah.runtimes | runtimes_capabilities_object | CHECK | oui | CHECK (soulbah.is_json_object(capabilities)) |
| soulbah.runtimes | runtimes_max_slots_range | CHECK | oui | CHECK (max_slots >= 1 AND max_slots <= 32) |
| soulbah.runtimes | runtimes_one_per_key | UNIQUE | oui | UNIQUE (agent_key_id) |
| soulbah.runtimes | runtimes_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.runtimes | runtimes_status_check | CHECK | oui | CHECK (status = ANY (ARRAY['online'::text, 'draining'::text, 'offline'::text])) |
| soulbah.runtimes | runtimes_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| soulbah.schema_migration_runs | schema_migration_runs_action_check | CHECK | oui | CHECK (action = ANY (ARRAY['apply'::text, 'baseline'::text, 'rollback'::text, 'verify'::text])) |
| soulbah.schema_migration_runs | schema_migration_runs_checksum_format | CHECK | oui | CHECK (checksum IS NULL OR checksum ~ '^[0-9a-f]{64}$'::text) |
| soulbah.schema_migration_runs | schema_migration_runs_details_object | CHECK | oui | CHECK (jsonb_typeof(details) = 'object'::text) |
| soulbah.schema_migration_runs | schema_migration_runs_execution_ms_check | CHECK | oui | CHECK (execution_ms IS NULL OR execution_ms >= 0) |
| soulbah.schema_migration_runs | schema_migration_runs_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.schema_migration_runs | schema_migration_runs_status_check | CHECK | oui | CHECK (status = ANY (ARRAY['succeeded'::text, 'failed'::text, 'skipped'::text])) |
| soulbah.schema_migration_runs | schema_migration_runs_version_format | CHECK | oui | CHECK (version ~ '^[0-9]{14}$'::text) |
| soulbah.schema_migrations | schema_migrations_checksum_format | CHECK | oui | CHECK (checksum ~ '^[0-9a-f]{64}$'::text) |
| soulbah.schema_migrations | schema_migrations_execution_ms_check | CHECK | oui | CHECK (execution_ms >= 0) |
| soulbah.schema_migrations | schema_migrations_name_length | CHECK | oui | CHECK (length(name) >= 1 AND length(name) <= 200) |
| soulbah.schema_migrations | schema_migrations_pkey | PK | oui | PRIMARY KEY (version) |
| soulbah.schema_migrations | schema_migrations_rollback_check | CHECK | oui | CHECK (rollback = ANY (ARRAY['YES'::text, 'PARTIAL'::text, 'NO'::text])) |
| soulbah.schema_migrations | schema_migrations_source_check | CHECK | oui | CHECK (source = ANY (ARRAY['repo'::text, 'pending'::text, 'manual'::text])) |
| soulbah.schema_migrations | schema_migrations_status_check | CHECK | oui | CHECK (status = ANY (ARRAY['applied'::text, 'baselined'::text, 'rolled_back'::text])) |
| soulbah.schema_migrations | schema_migrations_version_format | CHECK | oui | CHECK (version ~ '^[0-9]{14}$'::text) |
| soulbah.sessions | sessions_budget_positive | CHECK | oui | CHECK (budget_usd IS NULL OR budget_usd >= 0::numeric) |
| soulbah.sessions | sessions_environment_object | CHECK | oui | CHECK (soulbah.is_json_object(environment)) |
| soulbah.sessions | sessions_goal_length | CHECK | oui | CHECK (length(goal) >= 1 AND length(goal) <= 4000) |
| soulbah.sessions | sessions_level_check | CHECK | oui | CHECK (soulbah.is_security_level(max_security_level)) |
| soulbah.sessions | sessions_max_parallel_range | CHECK | oui | CHECK (max_parallel_agents IS NULL OR max_parallel_agents >= 1 AND max_parallel_agents <= 32) |
| soulbah.sessions | sessions_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.sessions | sessions_plan_version_positive | CHECK | oui | CHECK (plan_version >= 0) |
| soulbah.sessions | sessions_spent_positive | CHECK | oui | CHECK (spent_usd >= 0::numeric) |
| soulbah.sessions | sessions_status_check | CHECK | oui | CHECK (status = ANY (ARRAY['DRAFT'::text, 'PLANNING'::text, 'AWAITING_APPROVAL'::text, 'RUNNING'::text, 'PAUSED'::text, 'COMPLETED'::text, 'FAILED'::text, 'CANC |
| soulbah.sessions | sessions_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| soulbah.skills | skills_created_by_fkey | FK | oui | FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL |
| soulbah.skills | skills_examples_array | CHECK | oui | CHECK (soulbah.is_json_array(examples)) |
| soulbah.skills | skills_known_errors_array | CHECK | oui | CHECK (soulbah.is_json_array(known_errors)) |
| soulbah.skills | skills_level_check | CHECK | oui | CHECK (soulbah.is_security_level(security_level)) |
| soulbah.skills | skills_name_format | CHECK | oui | CHECK (name ~ '^[a-z][a-z0-9_]{0,39}$'::text) |
| soulbah.skills | skills_name_version | UNIQUE | oui | UNIQUE (name, version) |
| soulbah.skills | skills_permissions_object | CHECK | oui | CHECK (soulbah.is_json_object(permissions)) |
| soulbah.skills | skills_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.skills | skills_procedure_object | CHECK | oui | CHECK (soulbah.is_json_object(procedure)) |
| soulbah.skills | skills_schema_object | CHECK | oui | CHECK (soulbah.is_json_object(schema)) |
| soulbah.skills | skills_source_check | CHECK | oui | CHECK (source = ANY (ARRAY['catalog'::text, 'learned'::text])) |
| soulbah.skills | skills_status_check | CHECK | oui | CHECK (status = ANY (ARRAY['proposed'::text, 'active'::text, 'deprecated'::text, 'rejected'::text])) |
| soulbah.skills | skills_tests_array | CHECK | oui | CHECK (soulbah.is_json_array(tests)) |
| soulbah.skills | skills_version_semver | CHECK | oui | CHECK (version ~ '^(0\|[1-9][0-9]*)\.(0\|[1-9][0-9]*)\.(0\|[1-9][0-9]*)$'::text) |
| soulbah.task_dependencies | task_dependencies_depends_on_task_id_fkey | FK | oui | FOREIGN KEY (depends_on_task_id) REFERENCES soulbah.tasks(id) ON DELETE CASCADE |
| soulbah.task_dependencies | task_dependencies_kind_check | CHECK | oui | CHECK (kind = ANY (ARRAY['hard'::text, 'soft'::text])) |
| soulbah.task_dependencies | task_dependencies_no_self | CHECK | oui | CHECK (task_id <> depends_on_task_id) |
| soulbah.task_dependencies | task_dependencies_pkey | PK | oui | PRIMARY KEY (task_id, depends_on_task_id) |
| soulbah.task_dependencies | task_dependencies_task_id_fkey | FK | oui | FOREIGN KEY (task_id) REFERENCES soulbah.tasks(id) ON DELETE CASCADE |
| soulbah.tasks | tasks_attempt_positive | CHECK | oui | CHECK (attempt >= 0) |
| soulbah.tasks | tasks_criteria_array | CHECK | oui | CHECK (soulbah.is_json_array(acceptance_criteria)) |
| soulbah.tasks | tasks_level_check | CHECK | oui | CHECK (soulbah.is_security_level(security_level)) |
| soulbah.tasks | tasks_max_retries_range | CHECK | oui | CHECK (max_retries >= 0 AND max_retries <= 10) |
| soulbah.tasks | tasks_node_key_format | CHECK | oui | CHECK (node_key IS NULL OR node_key ~ '^[a-z][a-z0-9_.-]{0,63}$'::text) |
| soulbah.tasks | tasks_parent_task_id_fkey | FK | oui | FOREIGN KEY (parent_task_id) REFERENCES soulbah.tasks(id) ON DELETE SET NULL |
| soulbah.tasks | tasks_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.tasks | tasks_plan_version_positive | CHECK | oui | CHECK (plan_version >= 0) |
| soulbah.tasks | tasks_priority_range | CHECK | oui | CHECK (priority >= 1 AND priority <= 10) |
| soulbah.tasks | tasks_resources_array | CHECK | oui | CHECK (soulbah.is_json_array(resources)) |
| soulbah.tasks | tasks_retry_positive | CHECK | oui | CHECK (retry_count >= 0) |
| soulbah.tasks | tasks_role_format | CHECK | oui | CHECK (role ~ '^[a-z][a-z0-9_]{0,63}$'::text) |
| soulbah.tasks | tasks_session_id_fkey | FK | oui | FOREIGN KEY (session_id) REFERENCES soulbah.sessions(id) ON DELETE CASCADE |
| soulbah.tasks | tasks_simulated_never_completed | CHECK | oui | CHECK (NOT (simulated AND status = 'COMPLETED'::text)) |
| soulbah.tasks | tasks_spec_object | CHECK | oui | CHECK (soulbah.is_json_object(spec)) |
| soulbah.tasks | tasks_status_check | CHECK | oui | CHECK (status = ANY (ARRAY['PENDING'::text, 'READY'::text, 'RUNNING'::text, 'WAITING'::text, 'BLOCKED'::text, 'VALIDATING'::text, 'RETRYING'::text, 'COMPLETED': |
| soulbah.tasks | tasks_title_length | CHECK | oui | CHECK (length(title) >= 1 AND length(title) <= 500) |
| soulbah.tasks | tasks_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| soulbah.tool_calls | tool_calls_action_id_fkey | FK | oui | FOREIGN KEY (action_id) REFERENCES soulbah.actions(id) ON DELETE SET NULL |
| soulbah.tool_calls | tool_calls_cost_positive | CHECK | oui | CHECK (cost_usd IS NULL OR cost_usd >= 0::numeric) |
| soulbah.tool_calls | tool_calls_http_status_range | CHECK | oui | CHECK (http_status IS NULL OR http_status >= 100 AND http_status <= 599) |
| soulbah.tool_calls | tool_calls_in_positive | CHECK | oui | CHECK (input_tokens IS NULL OR input_tokens >= 0) |
| soulbah.tool_calls | tool_calls_kind_check | CHECK | oui | CHECK (kind = ANY (ARRAY['tool'::text, 'model'::text])) |
| soulbah.tool_calls | tool_calls_latency_positive | CHECK | oui | CHECK (latency_ms IS NULL OR latency_ms >= 0) |
| soulbah.tool_calls | tool_calls_metadata_object | CHECK | oui | CHECK (soulbah.is_json_object(metadata)) |
| soulbah.tool_calls | tool_calls_name_length | CHECK | oui | CHECK (length(name) >= 1 AND length(name) <= 120) |
| soulbah.tool_calls | tool_calls_out_positive | CHECK | oui | CHECK (output_tokens IS NULL OR output_tokens >= 0) |
| soulbah.tool_calls | tool_calls_pkey | PK | oui | PRIMARY KEY (id) |
| soulbah.tool_calls | tool_calls_session_id_fkey | FK | oui | FOREIGN KEY (session_id) REFERENCES soulbah.sessions(id) ON DELETE SET NULL |
| soulbah.tool_calls | tool_calls_status_check | CHECK | oui | CHECK (status = ANY (ARRAY['ok'::text, 'error'::text, 'timeout'::text, 'refused'::text])) |
| soulbah.tool_calls | tool_calls_task_id_fkey | FK | oui | FOREIGN KEY (task_id) REFERENCES soulbah.tasks(id) ON DELETE SET NULL |
| soulbah.tool_calls | tool_calls_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| soulbah.user_settings | user_settings_budget_positive | CHECK | oui | CHECK (daily_budget_usd IS NULL OR daily_budget_usd >= 0::numeric) |
| soulbah.user_settings | user_settings_level_check | CHECK | oui | CHECK (soulbah.is_security_level(max_security_level)) |
| soulbah.user_settings | user_settings_max_parallel_range | CHECK | oui | CHECK (max_parallel_agents >= 1 AND max_parallel_agents <= 32) |
| soulbah.user_settings | user_settings_pkey | PK | oui | PRIMARY KEY (user_id) |
| soulbah.user_settings | user_settings_settings_object | CHECK | oui | CHECK (soulbah.is_json_object(settings)) |
| soulbah.user_settings | user_settings_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |

## Index

| Table | Index | Unique | Lectures (idx_scan) | Définition |
|---|---|---|---|---|
| public.agent_events | agent_events_pkey | oui | 0 | CREATE UNIQUE INDEX agent_events_pkey ON public.agent_events USING btree (id) |
| public.agent_events | idx_agent_events_task |  | 0 | CREATE INDEX idx_agent_events_task ON public.agent_events USING btree (task_id, created_at) |
| public.agent_events | idx_agent_events_user |  | 0 | CREATE INDEX idx_agent_events_user ON public.agent_events USING btree (user_id, created_at DESC) |
| public.agent_keys | agent_keys_key_hash_key | oui | 0 | CREATE UNIQUE INDEX agent_keys_key_hash_key ON public.agent_keys USING btree (key_hash) |
| public.agent_keys | agent_keys_pkey | oui | 0 | CREATE UNIQUE INDEX agent_keys_pkey ON public.agent_keys USING btree (id) |
| public.agent_keys | idx_agent_keys_user |  | 0 | CREATE INDEX idx_agent_keys_user ON public.agent_keys USING btree (user_id) |
| public.agent_memory | agent_memory_pkey | oui | 0 | CREATE UNIQUE INDEX agent_memory_pkey ON public.agent_memory USING btree (id) |
| public.agent_memory | idx_agent_memory_expires |  | 0 | CREATE INDEX idx_agent_memory_expires ON public.agent_memory USING btree (expires_at) WHERE (expires_at IS NOT NULL) |
| public.agent_memory | idx_agent_memory_goal_gin_trgm |  | 0 | CREATE INDEX idx_agent_memory_goal_gin_trgm ON public.agent_memory USING gin (goal extensions.gin_trgm_ops) |
| public.agent_memory | idx_agent_memory_level |  | 0 | CREATE INDEX idx_agent_memory_level ON public.agent_memory USING btree (user_id, level) |
| public.agent_memory | idx_agent_memory_scope |  | 0 | CREATE INDEX idx_agent_memory_scope ON public.agent_memory USING btree (user_id, scope, status) |
| public.agent_memory | idx_agent_memory_session |  | 0 | CREATE INDEX idx_agent_memory_session ON public.agent_memory USING btree (session_id) WHERE (session_id IS NOT NULL) |
| public.agent_memory | idx_agent_memory_status |  | 0 | CREATE INDEX idx_agent_memory_status ON public.agent_memory USING btree (user_id, status) |
| public.agent_memory | idx_agent_memory_type |  | 0 | CREATE INDEX idx_agent_memory_type ON public.agent_memory USING btree (user_id, type) |
| public.agent_memory | idx_agent_memory_user |  | 0 | CREATE INDEX idx_agent_memory_user ON public.agent_memory USING btree (user_id, created_at DESC) |
| public.agent_memory | idx_agent_memory_user_goal |  | 0 | CREATE INDEX idx_agent_memory_user_goal ON public.agent_memory USING btree (user_id, goal) |
| public.agent_tasks | agent_tasks_pkey | oui | 0 | CREATE UNIQUE INDEX agent_tasks_pkey ON public.agent_tasks USING btree (id) |
| public.agent_tasks | idx_agent_tasks_claimed_key |  | 0 | CREATE INDEX idx_agent_tasks_claimed_key ON public.agent_tasks USING btree (claimed_by_key_id) WHERE (claimed_by_key_id IS NOT NULL) |
| public.agent_tasks | idx_agent_tasks_poll |  | 0 | CREATE INDEX idx_agent_tasks_poll ON public.agent_tasks USING btree (user_id, priority, created_at) WHERE (status = 'pending'::text) |
| public.agent_tasks | idx_agent_tasks_status |  | 0 | CREATE INDEX idx_agent_tasks_status ON public.agent_tasks USING btree (status, priority, created_at) |
| public.agent_tasks | idx_agent_tasks_target_key |  | 0 | CREATE INDEX idx_agent_tasks_target_key ON public.agent_tasks USING btree (target_agent_key_id) WHERE (target_agent_key_id IS NOT NULL) |
| public.agent_tasks | idx_agent_tasks_user_status_updated |  | 0 | CREATE INDEX idx_agent_tasks_user_status_updated ON public.agent_tasks USING btree (user_id, status, updated_at) |
| public.agent_tasks | idx_agent_tasks_v2_task |  | 0 | CREATE INDEX idx_agent_tasks_v2_task ON public.agent_tasks USING btree (v2_task_id) WHERE (v2_task_id IS NOT NULL) |
| public.analysis_requests | analysis_requests_pkey | oui | 0 | CREATE UNIQUE INDEX analysis_requests_pkey ON public.analysis_requests USING btree (id) |
| public.analysis_requests | idx_analysis_requests_created_at |  | 0 | CREATE INDEX idx_analysis_requests_created_at ON public.analysis_requests USING btree (created_at DESC) |
| public.analysis_requests | idx_analysis_requests_status |  | 0 | CREATE INDEX idx_analysis_requests_status ON public.analysis_requests USING btree (status) |
| public.analysis_requests | idx_analysis_requests_user |  | 0 | CREATE INDEX idx_analysis_requests_user ON public.analysis_requests USING btree (user_id) |
| public.applications | applications_pkey | oui | 0 | CREATE UNIQUE INDEX applications_pkey ON public.applications USING btree (id) |
| public.applications | idx_applications_user |  | 0 | CREATE INDEX idx_applications_user ON public.applications USING btree (user_id) |
| public.chat_conversations | chat_conversations_pkey | oui | 0 | CREATE UNIQUE INDEX chat_conversations_pkey ON public.chat_conversations USING btree (id) |
| public.chat_conversations | idx_chat_conversations_user |  | 0 | CREATE INDEX idx_chat_conversations_user ON public.chat_conversations USING btree (user_id) |
| public.chat_messages | chat_messages_pkey | oui | 0 | CREATE UNIQUE INDEX chat_messages_pkey ON public.chat_messages USING btree (id) |
| public.chat_messages | idx_chat_messages_conversation |  | 0 | CREATE INDEX idx_chat_messages_conversation ON public.chat_messages USING btree (conversation_id) |
| public.formations | formations_pkey | oui | 0 | CREATE UNIQUE INDEX formations_pkey ON public.formations USING btree (id) |
| public.formations | idx_formations_user |  | 0 | CREATE INDEX idx_formations_user ON public.formations USING btree (user_id) |
| public.knowledge_base | idx_knowledge_base_category |  | 0 | CREATE INDEX idx_knowledge_base_category ON public.knowledge_base USING btree (category) |
| public.knowledge_base | idx_knowledge_base_doc_status |  | 0 | CREATE INDEX idx_knowledge_base_doc_status ON public.knowledge_base USING btree (user_id, doc_status) |
| public.knowledge_base | idx_knowledge_base_domain |  | 0 | CREATE INDEX idx_knowledge_base_domain ON public.knowledge_base USING btree (domain) |
| public.knowledge_base | idx_knowledge_base_fts |  | 0 | CREATE INDEX idx_knowledge_base_fts ON public.knowledge_base USING gin (to_tsvector('french'::regconfig, ((((COALESCE(title, ''::text) \|\| ' '::text) |
| public.knowledge_base | idx_knowledge_base_hash |  | 0 | CREATE INDEX idx_knowledge_base_hash ON public.knowledge_base USING btree (content_hash) |
| public.knowledge_base | idx_knowledge_base_keywords |  | 0 | CREATE INDEX idx_knowledge_base_keywords ON public.knowledge_base USING gin (keywords) |
| public.knowledge_base | idx_knowledge_base_tags |  | 0 | CREATE INDEX idx_knowledge_base_tags ON public.knowledge_base USING gin (tags) |
| public.knowledge_base | idx_knowledge_base_user |  | 0 | CREATE INDEX idx_knowledge_base_user ON public.knowledge_base USING btree (user_id) |
| public.knowledge_base | knowledge_base_pkey | oui | 0 | CREATE UNIQUE INDEX knowledge_base_pkey ON public.knowledge_base USING btree (id) |
| public.knowledge_domains | knowledge_domains_pkey | oui | 2 | CREATE UNIQUE INDEX knowledge_domains_pkey ON public.knowledge_domains USING btree (slug) |
| public.knowledge_versions | idx_knowledge_versions_entry |  | 1 | CREATE INDEX idx_knowledge_versions_entry ON public.knowledge_versions USING btree (entry_id, version DESC) |
| public.knowledge_versions | knowledge_versions_pkey | oui | 0 | CREATE UNIQUE INDEX knowledge_versions_pkey ON public.knowledge_versions USING btree (id) |
| public.modules_status | modules_status_pkey | oui | 0 | CREATE UNIQUE INDEX modules_status_pkey ON public.modules_status USING btree (id) |
| public.modules_status | modules_status_user_id_module_name_key | oui | 0 | CREATE UNIQUE INDEX modules_status_user_id_module_name_key ON public.modules_status USING btree (user_id, module_name) |
| public.profiles | profiles_pkey | oui | 0 | CREATE UNIQUE INDEX profiles_pkey ON public.profiles USING btree (id) |
| public.profiles | profiles_user_id_key | oui | 0 | CREATE UNIQUE INDEX profiles_user_id_key ON public.profiles USING btree (user_id) |
| public.system_logs | idx_system_logs_user_created |  | 0 | CREATE INDEX idx_system_logs_user_created ON public.system_logs USING btree (user_id, created_at) |
| public.system_logs | system_logs_pkey | oui | 0 | CREATE UNIQUE INDEX system_logs_pkey ON public.system_logs USING btree (id) |
| public.user_migrations | idx_user_migrations_schema |  | 0 | CREATE INDEX idx_user_migrations_schema ON public.user_migrations USING btree (schema_id) |
| public.user_migrations | user_migrations_pkey | oui | 0 | CREATE UNIQUE INDEX user_migrations_pkey ON public.user_migrations USING btree (id) |
| public.user_roles | user_roles_pkey | oui | 0 | CREATE UNIQUE INDEX user_roles_pkey ON public.user_roles USING btree (id) |
| public.user_roles | user_roles_user_id_role_key | oui | 0 | CREATE UNIQUE INDEX user_roles_user_id_role_key ON public.user_roles USING btree (user_id, role) |
| public.user_schemas | user_schemas_pkey | oui | 4 | CREATE UNIQUE INDEX user_schemas_pkey ON public.user_schemas USING btree (id) |
| public.user_schemas | user_schemas_user_id_table_name_key | oui | 0 | CREATE UNIQUE INDEX user_schemas_user_id_table_name_key ON public.user_schemas USING btree (user_id, table_name) |
| public.user_table_data | idx_user_table_data_schema |  | 0 | CREATE INDEX idx_user_table_data_schema ON public.user_table_data USING btree (schema_id) |
| public.user_table_data | user_table_data_pkey | oui | 0 | CREATE UNIQUE INDEX user_table_data_pkey ON public.user_table_data USING btree (id) |
| soulbah.actions | actions_idempotency | oui | 0 | CREATE UNIQUE INDEX actions_idempotency ON soulbah.actions USING btree (task_id, attempt, step_index) |
| soulbah.actions | actions_pkey | oui | 0 | CREATE UNIQUE INDEX actions_pkey ON soulbah.actions USING btree (id) |
| soulbah.actions | idx_actions_task |  | 1 | CREATE INDEX idx_actions_task ON soulbah.actions USING btree (task_id, attempt, step_index) |
| soulbah.agents | agents_pkey | oui | 0 | CREATE UNIQUE INDEX agents_pkey ON soulbah.agents USING btree (id) |
| soulbah.agents | idx_agents_busy |  | 0 | CREATE INDEX idx_agents_busy ON soulbah.agents USING btree (user_id) WHERE (status = 'BUSY'::text) |
| soulbah.agents | idx_agents_session |  | 0 | CREATE INDEX idx_agents_session ON soulbah.agents USING btree (session_id, status) |
| soulbah.artifacts | artifacts_pkey | oui | 0 | CREATE UNIQUE INDEX artifacts_pkey ON soulbah.artifacts USING btree (id) |
| soulbah.artifacts | artifacts_unique_per_user | oui | 0 | CREATE UNIQUE INDEX artifacts_unique_per_user ON soulbah.artifacts USING btree (user_id, sha256) |
| soulbah.artifacts | idx_artifacts_retention |  | 0 | CREATE INDEX idx_artifacts_retention ON soulbah.artifacts USING btree (retention_class, created_at) |
| soulbah.artifacts | idx_artifacts_task |  | 1 | CREATE INDEX idx_artifacts_task ON soulbah.artifacts USING btree (task_id) WHERE (task_id IS NOT NULL) |
| soulbah.audit_chain_head | audit_chain_head_pkey | oui | 12 | CREATE UNIQUE INDEX audit_chain_head_pkey ON soulbah.audit_chain_head USING btree (id) |
| soulbah.audit_logs | audit_logs_id_key | oui | 0 | CREATE UNIQUE INDEX audit_logs_id_key ON soulbah.audit_logs USING btree (id) |
| soulbah.audit_logs | audit_logs_pkey | oui | 4 | CREATE UNIQUE INDEX audit_logs_pkey ON soulbah.audit_logs USING btree (seq) |
| soulbah.audit_logs | idx_audit_logs_action |  | 0 | CREATE INDEX idx_audit_logs_action ON soulbah.audit_logs USING btree (action, seq) |
| soulbah.audit_logs | idx_audit_logs_session |  | 0 | CREATE INDEX idx_audit_logs_session ON soulbah.audit_logs USING btree (session_id, seq) WHERE (session_id IS NOT NULL) |
| soulbah.audit_logs | idx_audit_logs_task |  | 0 | CREATE INDEX idx_audit_logs_task ON soulbah.audit_logs USING btree (task_id, seq) WHERE (task_id IS NOT NULL) |
| soulbah.audit_logs | idx_audit_logs_user |  | 0 | CREATE INDEX idx_audit_logs_user ON soulbah.audit_logs USING btree (user_id, seq) WHERE (user_id IS NOT NULL) |
| soulbah.checkpoints | checkpoints_pkey | oui | 0 | CREATE UNIQUE INDEX checkpoints_pkey ON soulbah.checkpoints USING btree (id) |
| soulbah.checkpoints | checkpoints_unique | oui | 1 | CREATE UNIQUE INDEX checkpoints_unique ON soulbah.checkpoints USING btree (task_id, attempt, seq) |
| soulbah.evaluations | evaluations_once_per_attempt | oui | 1 | CREATE UNIQUE INDEX evaluations_once_per_attempt ON soulbah.evaluations USING btree (task_id, attempt) |
| soulbah.evaluations | evaluations_pkey | oui | 0 | CREATE UNIQUE INDEX evaluations_pkey ON soulbah.evaluations USING btree (id) |
| soulbah.knowledge_chunks | idx_knowledge_chunks_document |  | 1 | CREATE INDEX idx_knowledge_chunks_document ON soulbah.knowledge_chunks USING btree (document_id, chunk_index) |
| soulbah.knowledge_chunks | idx_knowledge_chunks_tsv |  | 0 | CREATE INDEX idx_knowledge_chunks_tsv ON soulbah.knowledge_chunks USING gin (tsv) |
| soulbah.knowledge_chunks | idx_knowledge_chunks_user |  | 0 | CREATE INDEX idx_knowledge_chunks_user ON soulbah.knowledge_chunks USING btree (user_id) |
| soulbah.knowledge_chunks | knowledge_chunks_pkey | oui | 0 | CREATE UNIQUE INDEX knowledge_chunks_pkey ON soulbah.knowledge_chunks USING btree (id) |
| soulbah.knowledge_chunks | knowledge_chunks_unique | oui | 0 | CREATE UNIQUE INDEX knowledge_chunks_unique ON soulbah.knowledge_chunks USING btree (document_id, chunk_index) |
| soulbah.messages | idx_messages_correlation |  | 0 | CREATE INDEX idx_messages_correlation ON soulbah.messages USING btree (correlation_id) WHERE (correlation_id IS NOT NULL) |
| soulbah.messages | idx_messages_pending_ack |  | 0 | CREATE INDEX idx_messages_pending_ack ON soulbah.messages USING btree (to_agent_id, created_at) WHERE (requires_ack AND (acked_at IS NULL)) |
| soulbah.messages | idx_messages_session |  | 0 | CREATE INDEX idx_messages_session ON soulbah.messages USING btree (session_id, created_at) |
| soulbah.messages | idx_messages_task |  | 1 | CREATE INDEX idx_messages_task ON soulbah.messages USING btree (task_id, created_at) WHERE (task_id IS NOT NULL) |
| soulbah.messages | messages_pkey | oui | 0 | CREATE UNIQUE INDEX messages_pkey ON soulbah.messages USING btree (id) |
| soulbah.permissions | idx_permissions_pending |  | 0 | CREATE INDEX idx_permissions_pending ON soulbah.permissions USING btree (user_id, created_at) WHERE (status = 'pending'::text) |
| soulbah.permissions | idx_permissions_session |  | 0 | CREATE INDEX idx_permissions_session ON soulbah.permissions USING btree (session_id, status) WHERE (session_id IS NOT NULL) |
| soulbah.permissions | idx_permissions_task |  | 1 | CREATE INDEX idx_permissions_task ON soulbah.permissions USING btree (task_id) WHERE (task_id IS NOT NULL) |
| soulbah.permissions | permissions_pkey | oui | 0 | CREATE UNIQUE INDEX permissions_pkey ON soulbah.permissions USING btree (id) |
| soulbah.recordings | idx_recordings_task |  | 1 | CREATE INDEX idx_recordings_task ON soulbah.recordings USING btree (task_id) WHERE (task_id IS NOT NULL) |
| soulbah.recordings | recordings_pkey | oui | 0 | CREATE UNIQUE INDEX recordings_pkey ON soulbah.recordings USING btree (id) |
| soulbah.resource_leases | idx_resource_leases_expires |  | 0 | CREATE INDEX idx_resource_leases_expires ON soulbah.resource_leases USING btree (expires_at) |
| soulbah.resource_leases | idx_resource_leases_holder |  | 1 | CREATE INDEX idx_resource_leases_holder ON soulbah.resource_leases USING btree (holder_task_id) |
| soulbah.resource_leases | resource_leases_pkey | oui | 0 | CREATE UNIQUE INDEX resource_leases_pkey ON soulbah.resource_leases USING btree (resource_key, holder_task_id) |
| soulbah.resource_leases | uq_resource_leases_exclusive | oui | 0 | CREATE UNIQUE INDEX uq_resource_leases_exclusive ON soulbah.resource_leases USING btree (resource_key) WHERE (mode = 'exclusive'::text) |
| soulbah.runtimes | idx_runtimes_user |  | 0 | CREATE INDEX idx_runtimes_user ON soulbah.runtimes USING btree (user_id, status) |
| soulbah.runtimes | runtimes_one_per_key | oui | 3 | CREATE UNIQUE INDEX runtimes_one_per_key ON soulbah.runtimes USING btree (agent_key_id) |
| soulbah.runtimes | runtimes_pkey | oui | 0 | CREATE UNIQUE INDEX runtimes_pkey ON soulbah.runtimes USING btree (id) |
| soulbah.schema_migration_runs | idx_schema_migration_runs_version |  | 0 | CREATE INDEX idx_schema_migration_runs_version ON soulbah.schema_migration_runs USING btree (version, id) |
| soulbah.schema_migration_runs | schema_migration_runs_pkey | oui | 0 | CREATE UNIQUE INDEX schema_migration_runs_pkey ON soulbah.schema_migration_runs USING btree (id) |
| soulbah.schema_migrations | schema_migrations_pkey | oui | 47 | CREATE UNIQUE INDEX schema_migrations_pkey ON soulbah.schema_migrations USING btree (version) |
| soulbah.sessions | idx_sessions_active |  | 0 | CREATE INDEX idx_sessions_active ON soulbah.sessions USING btree (status) WHERE (status = ANY (ARRAY['PLANNING'::text, 'AWAITING_APPROVAL'::text, 'RUN |
| soulbah.sessions | idx_sessions_user_status |  | 0 | CREATE INDEX idx_sessions_user_status ON soulbah.sessions USING btree (user_id, status, created_at DESC) |
| soulbah.sessions | sessions_pkey | oui | 20 | CREATE UNIQUE INDEX sessions_pkey ON soulbah.sessions USING btree (id) |
| soulbah.skills | idx_skills_status |  | 0 | CREATE INDEX idx_skills_status ON soulbah.skills USING btree (status, name) |
| soulbah.skills | skills_name_version | oui | 0 | CREATE UNIQUE INDEX skills_name_version ON soulbah.skills USING btree (name, version) |
| soulbah.skills | skills_pkey | oui | 0 | CREATE UNIQUE INDEX skills_pkey ON soulbah.skills USING btree (id) |
| soulbah.task_dependencies | idx_task_dependencies_reverse |  | 1 | CREATE INDEX idx_task_dependencies_reverse ON soulbah.task_dependencies USING btree (depends_on_task_id) |
| soulbah.task_dependencies | task_dependencies_pkey | oui | 1 | CREATE UNIQUE INDEX task_dependencies_pkey ON soulbah.task_dependencies USING btree (task_id, depends_on_task_id) |
| soulbah.tasks | idx_tasks_lease |  | 0 | CREATE INDEX idx_tasks_lease ON soulbah.tasks USING btree (lease_expires_at) WHERE (status = ANY (ARRAY['RUNNING'::text, 'WAITING'::text, 'VALIDATING' |
| soulbah.tasks | idx_tasks_parent |  | 1 | CREATE INDEX idx_tasks_parent ON soulbah.tasks USING btree (parent_task_id) WHERE (parent_task_id IS NOT NULL) |
| soulbah.tasks | idx_tasks_ready |  | 0 | CREATE INDEX idx_tasks_ready ON soulbah.tasks USING btree (priority, created_at) WHERE (status = 'READY'::text) |
| soulbah.tasks | idx_tasks_retrying |  | 0 | CREATE INDEX idx_tasks_retrying ON soulbah.tasks USING btree (next_attempt_at) WHERE (status = 'RETRYING'::text) |
| soulbah.tasks | idx_tasks_session_status |  | 0 | CREATE INDEX idx_tasks_session_status ON soulbah.tasks USING btree (session_id, status) |
| soulbah.tasks | idx_tasks_user_status |  | 0 | CREATE INDEX idx_tasks_user_status ON soulbah.tasks USING btree (user_id, status, created_at DESC) |
| soulbah.tasks | tasks_pkey | oui | 38 | CREATE UNIQUE INDEX tasks_pkey ON soulbah.tasks USING btree (id) |
| soulbah.tasks | uq_tasks_idempotency | oui | 0 | CREATE UNIQUE INDEX uq_tasks_idempotency ON soulbah.tasks USING btree (session_id, idempotency_key) WHERE (idempotency_key IS NOT NULL) |
| soulbah.tasks | uq_tasks_node_key | oui | 0 | CREATE UNIQUE INDEX uq_tasks_node_key ON soulbah.tasks USING btree (session_id, plan_version, node_key) WHERE (node_key IS NOT NULL) |
| soulbah.tool_calls | idx_tool_calls_session |  | 0 | CREATE INDEX idx_tool_calls_session ON soulbah.tool_calls USING btree (session_id, created_at) WHERE (session_id IS NOT NULL) |
| soulbah.tool_calls | idx_tool_calls_task |  | 1 | CREATE INDEX idx_tool_calls_task ON soulbah.tool_calls USING btree (task_id, created_at) WHERE (task_id IS NOT NULL) |
| soulbah.tool_calls | idx_tool_calls_user_day |  | 0 | CREATE INDEX idx_tool_calls_user_day ON soulbah.tool_calls USING btree (user_id, created_at) WHERE (kind = 'model'::text) |
| soulbah.tool_calls | tool_calls_pkey | oui | 0 | CREATE UNIQUE INDEX tool_calls_pkey ON soulbah.tool_calls USING btree (id) |
| soulbah.user_settings | user_settings_pkey | oui | 1 | CREATE UNIQUE INDEX user_settings_pkey ON soulbah.user_settings USING btree (user_id) |

## Vues et vues matérialisées

- soulbah.knowledge_documents (vue)
- soulbah.memories (vue)

## Fonctions (hors extensions)

| Fonction | Langage | SECURITY DEFINER | search_path | Fins de ligne CRLF |
|---|---|---|---|---|
| public.agent_tasks_keep_updated_at_on_control() | plpgsql |  | ['search_path=public'] |  |
| public.agent_tasks_set_updated_at() | plpgsql |  | ['search_path=public'] |  |
| public.handle_new_user() | plpgsql | **oui** | ['search_path=public'] | oui |
| public.has_role(_user_id uuid, _role app_role) | sql | **oui** | ['search_path=public'] | oui |
| public.is_admin() | sql | **oui** | ['search_path=""'] |  |
| public.rls_auto_enable() | plpgsql | **oui** | ['search_path=pg_catalog'] |  |
| public.update_updated_at_column() | plpgsql |  | ['search_path=public'] | oui |
| soulbah.audit_logs_before_insert() | plpgsql |  | ['search_path=soulbah, pg_temp'] |  |
| soulbah.audit_logs_immutable() | plpgsql |  |  |  |
| soulbah.audit_row_hash(p_prev text, p_id uuid, p_user uuid, p_session uuid, p_task uuid, p_actor text, p_action text, p_entity text, p_entity_id uuid, p_data jsonb, p_created timestamp with time zone) | sql |  |  |  |
| soulbah.is_json_array(p jsonb) | sql |  |  |  |
| soulbah.is_json_object(p jsonb) | sql |  |  |  |
| soulbah.is_security_level(p text) | sql |  |  |  |
| soulbah.schema_migration_runs_append_only() | plpgsql |  | ['search_path=soulbah, pg_temp'] | oui |
| soulbah.set_updated_at() | plpgsql |  | ['search_path=soulbah, pg_temp'] |  |
| soulbah.task_dependencies_check_cycle() | plpgsql |  | ['search_path=soulbah, pg_temp'] |  |
| soulbah.tasks_check_transition() | plpgsql |  | ['search_path=soulbah, pg_temp'] |  |
| soulbah.verify_audit_chain(OUT ok boolean, OUT checked bigint, OUT broken_at bigint) | plpgsql |  | ['search_path=soulbah, pg_temp'] |  |

Fonctions d'extensions installées dans un schéma applicatif : 0 (pgvector dans public).

## Triggers

- public.agent_tasks : `CREATE TRIGGER update_agent_tasks_updated_at BEFORE UPDATE ON agent_tasks FOR EACH ROW EXECUTE FUNCTION agent_tasks_set_updated_at()`
- public.agent_tasks : `CREATE TRIGGER update_agent_tasks_updated_at_control BEFORE UPDATE OF control ON agent_tasks FOR EACH ROW EXECUTE FUNCTION agent_tasks_keep_updated_at_on_control()`
- public.applications : `CREATE TRIGGER update_applications_updated_at BEFORE UPDATE ON applications FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`
- public.chat_conversations : `CREATE TRIGGER update_chat_conversations_updated_at BEFORE UPDATE ON chat_conversations FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`
- public.formations : `CREATE TRIGGER update_formations_updated_at BEFORE UPDATE ON formations FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`
- public.knowledge_base : `CREATE TRIGGER update_knowledge_base_updated_at BEFORE UPDATE ON knowledge_base FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`
- public.profiles : `CREATE TRIGGER update_profiles_updated_at BEFORE UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`
- public.user_schemas : `CREATE TRIGGER update_user_schemas_updated_at BEFORE UPDATE ON user_schemas FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`
- public.user_table_data : `CREATE TRIGGER update_user_table_data_updated_at BEFORE UPDATE ON user_table_data FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`
- soulbah.actions : `CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.actions FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at()`
- soulbah.agents : `CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.agents FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at()`
- soulbah.audit_logs : `CREATE TRIGGER chain_before_insert BEFORE INSERT ON soulbah.audit_logs FOR EACH ROW EXECUTE FUNCTION soulbah.audit_logs_before_insert()`
- soulbah.audit_logs : `CREATE TRIGGER immutable_rows BEFORE DELETE OR UPDATE ON soulbah.audit_logs FOR EACH ROW EXECUTE FUNCTION soulbah.audit_logs_immutable()`
- soulbah.audit_logs : `CREATE TRIGGER immutable_table BEFORE TRUNCATE ON soulbah.audit_logs FOR EACH STATEMENT EXECUTE FUNCTION soulbah.audit_logs_immutable()`
- soulbah.permissions : `CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.permissions FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at()`
- soulbah.runtimes : `CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.runtimes FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at()`
- soulbah.schema_migration_runs : `CREATE TRIGGER schema_migration_runs_no_truncate BEFORE TRUNCATE ON soulbah.schema_migration_runs FOR EACH STATEMENT EXECUTE FUNCTION soulbah.schema_migration_runs_append_only()`
- soulbah.schema_migration_runs : `CREATE TRIGGER schema_migration_runs_no_update BEFORE DELETE OR UPDATE ON soulbah.schema_migration_runs FOR EACH ROW EXECUTE FUNCTION soulbah.schema_migration_runs_append_only()`
- soulbah.sessions : `CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.sessions FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at()`
- soulbah.skills : `CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.skills FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at()`
- soulbah.task_dependencies : `CREATE TRIGGER check_cycle BEFORE INSERT OR UPDATE ON soulbah.task_dependencies FOR EACH ROW EXECUTE FUNCTION soulbah.task_dependencies_check_cycle()`
- soulbah.tasks : `CREATE TRIGGER check_transition BEFORE UPDATE OF status ON soulbah.tasks FOR EACH ROW EXECUTE FUNCTION soulbah.tasks_check_transition()`
- soulbah.tasks : `CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.tasks FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at()`
- soulbah.user_settings : `CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.user_settings FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at()`

Triggers d'événement : aucun.

## Policies (RLS)

| Table | Policy | Commande | Rôles | USING | WITH CHECK |
|---|---|---|---|---|---|
| public.agent_events | Users view own agent events | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.agent_keys | Users view own agent keys | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.agent_memory | Users delete own agent memory | DELETE | ['authenticated'] | (auth.uid() = user_id) |  |
| public.agent_memory | Users view own agent memory | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.agent_tasks | Users can view own tasks | SELECT | ['public'] | (auth.uid() = user_id) |  |
| public.analysis_requests | Users create own analysis requests | INSERT | ['authenticated'] |  | (auth.uid() = user_id) |
| public.analysis_requests | Users delete own analysis requests | DELETE | ['authenticated'] | (auth.uid() = user_id) |  |
| public.analysis_requests | Users update own analysis requests | UPDATE | ['authenticated'] | (auth.uid() = user_id) | (auth.uid() = user_id) |
| public.analysis_requests | Users view own analysis requests | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.applications | Users can create apps | INSERT | ['authenticated'] |  | (auth.uid() = user_id) |
| public.applications | Users can delete own apps | DELETE | ['authenticated'] | (auth.uid() = user_id) |  |
| public.applications | Users can update own apps | UPDATE | ['authenticated'] | (auth.uid() = user_id) |  |
| public.applications | Users can view own apps | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.chat_conversations | Users can create conversations | INSERT | ['public'] |  | (auth.uid() = user_id) |
| public.chat_conversations | Users can delete own conversations | DELETE | ['public'] | (auth.uid() = user_id) |  |
| public.chat_conversations | Users can update own conversations | UPDATE | ['public'] | (auth.uid() = user_id) |  |
| public.chat_conversations | Users can view own conversations | SELECT | ['public'] | (auth.uid() = user_id) |  |
| public.chat_messages | Users can create messages | INSERT | ['authenticated'] |  | ((auth.uid() = user_id) AND (EXISTS ( SELECT 1    FROM chat_conversations c   WHERE ((c.id = chat_messages.conversation_ |
| public.chat_messages | Users can delete own messages | DELETE | ['public'] | (auth.uid() = user_id) |  |
| public.chat_messages | Users can view own messages | SELECT | ['public'] | (auth.uid() = user_id) |  |
| public.formations | Users can create formations | INSERT | ['authenticated'] |  | (auth.uid() = user_id) |
| public.formations | Users can delete own formations | DELETE | ['authenticated'] | (auth.uid() = user_id) |  |
| public.formations | Users can update own formations | UPDATE | ['authenticated'] | (auth.uid() = user_id) |  |
| public.formations | Users can view own formations | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.knowledge_base | Users can view own knowledge | SELECT | ['public'] | (auth.uid() = user_id) |  |
| public.knowledge_domains | Anyone authenticated reads domains | SELECT | ['authenticated'] | true |  |
| public.knowledge_versions | Users create own knowledge versions | INSERT | ['authenticated'] |  | ((auth.uid() = user_id) AND (EXISTS ( SELECT 1    FROM knowledge_base kb   WHERE ((kb.id = knowledge_versions.entry_id)  |
| public.knowledge_versions | Users delete own knowledge versions | DELETE | ['authenticated'] | (auth.uid() = user_id) |  |
| public.knowledge_versions | Users view own knowledge versions | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.modules_status | Users can manage own modules | ALL | ['authenticated'] | (auth.uid() = user_id) |  |
| public.modules_status | Users can view own modules | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.profiles | Users can insert own profile | INSERT | ['authenticated'] |  | (auth.uid() = user_id) |
| public.profiles | Users can update own profile | UPDATE | ['authenticated'] | (auth.uid() = user_id) |  |
| public.profiles | Users can view own profile | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.system_logs | Users can insert own logs | INSERT | ['authenticated'] |  | (auth.uid() = user_id) |
| public.system_logs | Users can view own logs | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.user_migrations | Users can create migrations | INSERT | ['public'] |  | ((auth.uid() = user_id) AND (EXISTS ( SELECT 1    FROM user_schemas s   WHERE ((s.id = user_migrations.schema_id) AND (s |
| public.user_migrations | Users can view own migrations | SELECT | ['public'] | (auth.uid() = user_id) |  |
| public.user_roles | Admins can manage roles | ALL | ['authenticated'] | is_admin() |  |
| public.user_roles | Users can view own roles | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.user_schemas | Users can create schemas | INSERT | ['public'] |  | (auth.uid() = user_id) |
| public.user_schemas | Users can delete own schemas | DELETE | ['public'] | (auth.uid() = user_id) |  |
| public.user_schemas | Users can update own schemas | UPDATE | ['public'] | (auth.uid() = user_id) |  |
| public.user_schemas | Users can view own schemas | SELECT | ['public'] | (auth.uid() = user_id) |  |
| public.user_table_data | Users can delete own data | DELETE | ['public'] | (auth.uid() = user_id) |  |
| public.user_table_data | Users can insert own data | INSERT | ['public'] |  | ((auth.uid() = user_id) AND (EXISTS ( SELECT 1    FROM user_schemas s   WHERE ((s.id = user_table_data.schema_id) AND (s |
| public.user_table_data | Users can update own data | UPDATE | ['public'] | (auth.uid() = user_id) | ((auth.uid() = user_id) AND (EXISTS ( SELECT 1    FROM user_schemas s   WHERE ((s.id = user_table_data.schema_id) AND (s |
| public.user_table_data | Users can view own data | SELECT | ['public'] | (auth.uid() = user_id) |  |

## Rôles

| Rôle | Connexion | Superuser | BYPASSRLS | Membre de |
|---|---|---|---|---|
| anon |  |  |  |  |
| authenticated |  |  |  |  |
| dashboard_user |  |  |  |  |
| postgres | oui | **oui** | oui |  |
| service_role |  |  | oui |  |
| supabase_admin |  |  |  |  |
| supabase_auth_admin |  |  |  |  |

## Droits des rôles clients sur les tables applicatives

| Table | anon | authenticated | PUBLIC | service_role | soulbah_api |
|---|---|---|---|---|---|
| public.agent_events | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.agent_keys | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.agent_memory | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.agent_tasks | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.analysis_requests | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.applications | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.chat_conversations | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.chat_messages | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.formations | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.knowledge_base | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.knowledge_domains | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.knowledge_versions | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.modules_status | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.profiles | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.system_logs | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.user_migrations | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.user_roles | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.user_schemas | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.user_table_data | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| soulbah.actions |  |  |  |  |  |
| soulbah.agents |  |  |  |  |  |
| soulbah.artifacts |  |  |  |  |  |
| soulbah.audit_chain_head |  |  |  |  |  |
| soulbah.audit_logs |  |  |  |  |  |
| soulbah.checkpoints |  |  |  |  |  |
| soulbah.evaluations |  |  |  |  |  |
| soulbah.knowledge_chunks |  |  |  |  |  |
| soulbah.messages |  |  |  |  |  |
| soulbah.permissions |  |  |  |  |  |
| soulbah.recordings |  |  |  |  |  |
| soulbah.resource_leases |  |  |  |  |  |
| soulbah.runtimes |  |  |  |  |  |
| soulbah.schema_migration_runs |  |  |  |  |  |
| soulbah.schema_migrations |  |  |  |  |  |
| soulbah.sessions |  |  |  |  |  |
| soulbah.skills |  |  |  |  |  |
| soulbah.task_dependencies |  |  |  |  |  |
| soulbah.tasks |  |  |  |  |  |
| soulbah.tool_calls |  |  |  |  |  |
| soulbah.user_settings |  |  |  |  |  |

## Publications temps réel

Aucune.

## Historique des migrations

- `supabase_migrations.schema_migrations` : absent
- `soulbah.schema_migrations` : 32

## Requêtes les plus coûteuses (pg_stat_statements, normalisées)

Indisponible.

Connexions ouvertes au relevé : 1 ({'active': 1}) ; verrous en attente : 0.
