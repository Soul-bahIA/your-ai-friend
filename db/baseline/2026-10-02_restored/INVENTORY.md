# Inventaire — base Supabase restaurée (2026-10-02)

Relevé le 2026-10-02T10:57:20+00:00 en lecture seule (`postgres.ntvwbafvjgzsjoumtcmb@aws-1-eu-central-1.pooler.supabase.com:5432/postgres`).

## Moteur

| Élément | Valeur |
|---|---|
| Version | PostgreSQL 17.6 |
| Base | postgres (14.7 Mo) |
| Encodage, collation | UTF8, en_US.UTF-8 |
| Fuseau | UTC |
| Empreinte du schéma (tout) | `21ed74474ddcf299b6ee043db339a2a0224ccf4f7ca925e8e5b289b30289c0ce` |
| Empreinte des schémas applicatifs | `af62842bdc1100b55eabc173e3542137710801fbbee1e756a38c87051c151225` |
| default_transaction_read_only | off |
| effective_cache_size | 98304 |
| idle_in_transaction_session_timeout | 0 |
| maintenance_work_mem | 65536 |
| max_connections | 60 |
| max_wal_size | 4096 |
| password_encryption | scram-sha-256 |
| random_page_cost | 1.1 |
| row_security | on |
| search_path | "\$user", public, extensions |
| shared_buffers | 32768 |
| statement_timeout | 120000 |
| wal_level | logical |
| work_mem | 3500 |

## Schémas

| Schéma | Géré par | Propriétaire | Empreinte |
|---|---|---|---|
| auth | Supabase / extension | supabase_admin | `878652ac35d428d5…` |
| extensions | Supabase / extension | postgres | `46c31a875bd13fd6…` |
| graphql | Supabase / extension | supabase_admin | `f2679c9b01eeb318…` |
| graphql_public | Supabase / extension | supabase_admin | `8d2bd9ca71c1d882…` |
| pgbouncer | Supabase / extension | pgbouncer | `65eb48a6bd8c52fd…` |
| public | Soulbah | pg_database_owner | `fc45b7729bf7f347…` |
| realtime | Supabase / extension | supabase_admin | `09fac8fce3d30f3c…` |
| storage | Supabase / extension | supabase_admin | `b04449c1e943d553…` |
| vault | Supabase / extension | supabase_admin | `16c700af9b272d74…` |

## Extensions

| Extension | Version | Schéma |
|---|---|---|
| pg_stat_statements | 1.11 | extensions |
| pgcrypto | 1.3 | extensions |
| plpgsql | 1.0 | pg_catalog |
| supabase_vault | 0.3.1 | vault |
| uuid-ossp | 1.1 | extensions |
| vector | 0.8.0 | public |

## Tables des schémas applicatifs

| Table | Lignes | Taille | RLS | Colonnes | Policies | Index |
|---|---|---|---|---|---|---|
| public.agent_events | 42 | 88 Ko | oui | 7 | 1 | 3 |
| public.agent_keys | 2 | 80 Ko | oui | 7 | 1 | 4 |
| public.agent_memory | 4 | 112 Ko | oui | 11 | 1 | 6 |
| public.agent_tasks | 14 | 752 Ko | oui | 14 | 4 | 3 |
| public.applications | 1 | 80 Ko | oui | 10 | 4 | 1 |
| public.chat_conversations | 9 | 32 Ko | oui | 5 | 4 | 1 |
| public.chat_messages | 32 | 48 Ko | oui | 6 | 3 | 2 |
| public.formations | 12 | 248 Ko | oui | 13 | 4 | 1 |
| public.knowledge_base | 1 | 208 Ko | oui | 20 | 4 | 8 |
| public.knowledge_domains | 15 | 32 Ko | oui | 4 | 1 | 1 |
| public.knowledge_versions | 0 | 48 Ko | oui | 7 | 3 | 2 |
| public.modules_status | 0 | 24 Ko | oui | 6 | 2 | 2 |
| public.profiles | 10 | 48 Ko | oui | 7 | 3 | 2 |
| public.system_logs | 59 | 72 Ko | oui | 7 | 2 | 1 |
| public.user_migrations | 0 | 16 Ko | oui | 6 | 2 | 1 |
| public.user_roles | 10 | 40 Ko | oui | 3 | 2 | 2 |
| public.user_schemas | 0 | 24 Ko | oui | 7 | 4 | 2 |
| public.user_table_data | 0 | 16 Ko | oui | 6 | 4 | 1 |

Tables des schémas gérés (jamais modifiées par Soulbah) : auth 27, realtime 15, storage 8, vault 1.

Volumes des schémas gérés (comptes) : auth.identities 10, auth.mfa_amr_claims 45, auth.one_time_tokens 2, auth.refresh_tokens 91, auth.schema_migrations 82, auth.sessions 45, auth.users 10, storage.migrations 73.

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
| public.agent_memory | id | uuid | oui | gen_random_uuid() |
| public.agent_memory | user_id | uuid | oui |  |
| public.agent_memory | type | text | oui |  |
| public.agent_memory | goal | text | oui |  |
| public.agent_memory | content | text | oui |  |
| public.agent_memory | metadata | jsonb | oui | '{}'::jsonb |
| public.agent_memory | created_at | timestamp with time zone | oui | now() |
| public.agent_memory | level | text | oui | 'workflow'::text |
| public.agent_memory | status | text | oui | 'validated'::text |
| public.agent_memory | project_id | uuid |  |  |
| public.agent_memory | updated_at | timestamp with time zone | oui | now() |
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
| public.knowledge_base | embedding | vector(1536) |  |  |
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

## Contraintes (PK, FK, UNIQUE, CHECK)

| Table | Nom | Type | Validée | Définition |
|---|---|---|---|---|
| public.agent_events | agent_events_pkey | PK | oui | PRIMARY KEY (id) |
| public.agent_keys | agent_keys_key_hash_key | UNIQUE | oui | UNIQUE (key_hash) |
| public.agent_keys | agent_keys_pkey | PK | oui | PRIMARY KEY (id) |
| public.agent_keys | agent_keys_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.agent_memory | agent_memory_pkey | PK | oui | PRIMARY KEY (id) |
| public.agent_memory | agent_memory_type_check | CHECK | oui | CHECK (type = ANY (ARRAY['error'::text, 'solution'::text, 'practice'::text])) |
| public.agent_memory | agent_memory_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.agent_tasks | agent_tasks_pkey | PK | oui | PRIMARY KEY (id) |
| public.applications | applications_pkey | PK | oui | PRIMARY KEY (id) |
| public.applications | applications_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.chat_conversations | chat_conversations_pkey | PK | oui | PRIMARY KEY (id) |
| public.chat_messages | chat_messages_conversation_id_fkey | FK | oui | FOREIGN KEY (conversation_id) REFERENCES chat_conversations(id) ON DELETE CASCADE |
| public.chat_messages | chat_messages_pkey | PK | oui | PRIMARY KEY (id) |
| public.chat_messages | chat_messages_role_check | CHECK | oui | CHECK (role = ANY (ARRAY['user'::text, 'assistant'::text, 'system'::text])) |
| public.formations | formations_pkey | PK | oui | PRIMARY KEY (id) |
| public.formations | formations_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.knowledge_base | knowledge_base_confidence_range | CHECK | oui | CHECK (confidence >= 0::double precision AND confidence <= 1::double precision) |
| public.knowledge_base | knowledge_base_pkey | PK | oui | PRIMARY KEY (id) |
| public.knowledge_domains | knowledge_domains_pkey | PK | oui | PRIMARY KEY (slug) |
| public.knowledge_versions | knowledge_versions_entry_id_fkey | FK | oui | FOREIGN KEY (entry_id) REFERENCES knowledge_base(id) ON DELETE CASCADE |
| public.knowledge_versions | knowledge_versions_pkey | PK | oui | PRIMARY KEY (id) |
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
| public.user_roles | user_roles_pkey | PK | oui | PRIMARY KEY (id) |
| public.user_roles | user_roles_user_id_fkey | FK | oui | FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE |
| public.user_roles | user_roles_user_id_role_key | UNIQUE | oui | UNIQUE (user_id, role) |
| public.user_schemas | user_schemas_pkey | PK | oui | PRIMARY KEY (id) |
| public.user_schemas | user_schemas_user_id_table_name_key | UNIQUE | oui | UNIQUE (user_id, table_name) |
| public.user_table_data | user_table_data_pkey | PK | oui | PRIMARY KEY (id) |
| public.user_table_data | user_table_data_schema_id_fkey | FK | oui | FOREIGN KEY (schema_id) REFERENCES user_schemas(id) ON DELETE CASCADE |

## Index

| Table | Index | Unique | Lectures (idx_scan) | Définition |
|---|---|---|---|---|
| public.agent_events | agent_events_pkey | oui | 0 | CREATE UNIQUE INDEX agent_events_pkey ON public.agent_events USING btree (id) |
| public.agent_events | idx_agent_events_task |  | 0 | CREATE INDEX idx_agent_events_task ON public.agent_events USING btree (task_id, created_at) |
| public.agent_events | idx_agent_events_user |  | 0 | CREATE INDEX idx_agent_events_user ON public.agent_events USING btree (user_id, created_at DESC) |
| public.agent_keys | agent_keys_key_hash_key | oui | 0 | CREATE UNIQUE INDEX agent_keys_key_hash_key ON public.agent_keys USING btree (key_hash) |
| public.agent_keys | agent_keys_pkey | oui | 0 | CREATE UNIQUE INDEX agent_keys_pkey ON public.agent_keys USING btree (id) |
| public.agent_keys | idx_agent_keys_hash |  | 0 | CREATE INDEX idx_agent_keys_hash ON public.agent_keys USING btree (key_hash) |
| public.agent_keys | idx_agent_keys_user |  | 0 | CREATE INDEX idx_agent_keys_user ON public.agent_keys USING btree (user_id) |
| public.agent_memory | agent_memory_pkey | oui | 0 | CREATE UNIQUE INDEX agent_memory_pkey ON public.agent_memory USING btree (id) |
| public.agent_memory | idx_agent_memory_goal_trgm |  | 0 | CREATE INDEX idx_agent_memory_goal_trgm ON public.agent_memory USING btree (user_id, goal) |
| public.agent_memory | idx_agent_memory_level |  | 0 | CREATE INDEX idx_agent_memory_level ON public.agent_memory USING btree (user_id, level) |
| public.agent_memory | idx_agent_memory_status |  | 0 | CREATE INDEX idx_agent_memory_status ON public.agent_memory USING btree (user_id, status) |
| public.agent_memory | idx_agent_memory_type |  | 0 | CREATE INDEX idx_agent_memory_type ON public.agent_memory USING btree (user_id, type) |
| public.agent_memory | idx_agent_memory_user |  | 0 | CREATE INDEX idx_agent_memory_user ON public.agent_memory USING btree (user_id, created_at DESC) |
| public.agent_tasks | agent_tasks_pkey | oui | 0 | CREATE UNIQUE INDEX agent_tasks_pkey ON public.agent_tasks USING btree (id) |
| public.agent_tasks | idx_agent_tasks_status |  | 0 | CREATE INDEX idx_agent_tasks_status ON public.agent_tasks USING btree (status, priority, created_at) |
| public.agent_tasks | idx_agent_tasks_user_status |  | 5 | CREATE INDEX idx_agent_tasks_user_status ON public.agent_tasks USING btree (user_id, status) |
| public.applications | applications_pkey | oui | 0 | CREATE UNIQUE INDEX applications_pkey ON public.applications USING btree (id) |
| public.chat_conversations | chat_conversations_pkey | oui | 0 | CREATE UNIQUE INDEX chat_conversations_pkey ON public.chat_conversations USING btree (id) |
| public.chat_messages | chat_messages_pkey | oui | 0 | CREATE UNIQUE INDEX chat_messages_pkey ON public.chat_messages USING btree (id) |
| public.chat_messages | idx_chat_messages_conversation |  | 0 | CREATE INDEX idx_chat_messages_conversation ON public.chat_messages USING btree (conversation_id) |
| public.formations | formations_pkey | oui | 0 | CREATE UNIQUE INDEX formations_pkey ON public.formations USING btree (id) |
| public.knowledge_base | idx_knowledge_base_category |  | 0 | CREATE INDEX idx_knowledge_base_category ON public.knowledge_base USING btree (category) |
| public.knowledge_base | idx_knowledge_base_domain |  | 0 | CREATE INDEX idx_knowledge_base_domain ON public.knowledge_base USING btree (domain) |
| public.knowledge_base | idx_knowledge_base_embedding |  | 0 | CREATE INDEX idx_knowledge_base_embedding ON public.knowledge_base USING hnsw (embedding vector_cosine_ops) |
| public.knowledge_base | idx_knowledge_base_fts |  | 0 | CREATE INDEX idx_knowledge_base_fts ON public.knowledge_base USING gin (to_tsvector('french'::regconfig, ((((COALESCE(title, ''::text) \|\| ' '::text) |
| public.knowledge_base | idx_knowledge_base_hash |  | 0 | CREATE INDEX idx_knowledge_base_hash ON public.knowledge_base USING btree (content_hash) |
| public.knowledge_base | idx_knowledge_base_keywords |  | 0 | CREATE INDEX idx_knowledge_base_keywords ON public.knowledge_base USING gin (keywords) |
| public.knowledge_base | idx_knowledge_base_tags |  | 0 | CREATE INDEX idx_knowledge_base_tags ON public.knowledge_base USING gin (tags) |
| public.knowledge_base | knowledge_base_pkey | oui | 0 | CREATE UNIQUE INDEX knowledge_base_pkey ON public.knowledge_base USING btree (id) |
| public.knowledge_domains | knowledge_domains_pkey | oui | 0 | CREATE UNIQUE INDEX knowledge_domains_pkey ON public.knowledge_domains USING btree (slug) |
| public.knowledge_versions | idx_knowledge_versions_entry |  | 0 | CREATE INDEX idx_knowledge_versions_entry ON public.knowledge_versions USING btree (entry_id, version DESC) |
| public.knowledge_versions | knowledge_versions_pkey | oui | 0 | CREATE UNIQUE INDEX knowledge_versions_pkey ON public.knowledge_versions USING btree (id) |
| public.modules_status | modules_status_pkey | oui | 0 | CREATE UNIQUE INDEX modules_status_pkey ON public.modules_status USING btree (id) |
| public.modules_status | modules_status_user_id_module_name_key | oui | 0 | CREATE UNIQUE INDEX modules_status_user_id_module_name_key ON public.modules_status USING btree (user_id, module_name) |
| public.profiles | profiles_pkey | oui | 0 | CREATE UNIQUE INDEX profiles_pkey ON public.profiles USING btree (id) |
| public.profiles | profiles_user_id_key | oui | 0 | CREATE UNIQUE INDEX profiles_user_id_key ON public.profiles USING btree (user_id) |
| public.system_logs | system_logs_pkey | oui | 0 | CREATE UNIQUE INDEX system_logs_pkey ON public.system_logs USING btree (id) |
| public.user_migrations | user_migrations_pkey | oui | 0 | CREATE UNIQUE INDEX user_migrations_pkey ON public.user_migrations USING btree (id) |
| public.user_roles | user_roles_pkey | oui | 0 | CREATE UNIQUE INDEX user_roles_pkey ON public.user_roles USING btree (id) |
| public.user_roles | user_roles_user_id_role_key | oui | 0 | CREATE UNIQUE INDEX user_roles_user_id_role_key ON public.user_roles USING btree (user_id, role) |
| public.user_schemas | user_schemas_pkey | oui | 0 | CREATE UNIQUE INDEX user_schemas_pkey ON public.user_schemas USING btree (id) |
| public.user_schemas | user_schemas_user_id_table_name_key | oui | 0 | CREATE UNIQUE INDEX user_schemas_user_id_table_name_key ON public.user_schemas USING btree (user_id, table_name) |
| public.user_table_data | user_table_data_pkey | oui | 0 | CREATE UNIQUE INDEX user_table_data_pkey ON public.user_table_data USING btree (id) |

## Vues et vues matérialisées

Aucune.

## Fonctions (hors extensions)

| Fonction | Langage | SECURITY DEFINER | search_path | Fins de ligne CRLF |
|---|---|---|---|---|
| public.handle_new_user() | plpgsql | **oui** | ['search_path=public'] | oui |
| public.has_role(_user_id uuid, _role app_role) | sql | **oui** | ['search_path=public'] | oui |
| public.rls_auto_enable() | plpgsql | **oui** | ['search_path=pg_catalog'] |  |
| public.update_updated_at_column() | plpgsql |  | ['search_path=public'] | oui |

Fonctions d'extensions installées dans un schéma applicatif : 118 (pgvector dans public).

## Triggers

- public.agent_tasks : `CREATE TRIGGER update_agent_tasks_updated_at BEFORE UPDATE ON agent_tasks FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`
- public.applications : `CREATE TRIGGER update_applications_updated_at BEFORE UPDATE ON applications FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`
- public.chat_conversations : `CREATE TRIGGER update_chat_conversations_updated_at BEFORE UPDATE ON chat_conversations FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`
- public.formations : `CREATE TRIGGER update_formations_updated_at BEFORE UPDATE ON formations FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`
- public.knowledge_base : `CREATE TRIGGER update_knowledge_base_updated_at BEFORE UPDATE ON knowledge_base FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`
- public.profiles : `CREATE TRIGGER update_profiles_updated_at BEFORE UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`
- public.user_schemas : `CREATE TRIGGER update_user_schemas_updated_at BEFORE UPDATE ON user_schemas FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`
- public.user_table_data : `CREATE TRIGGER update_user_table_data_updated_at BEFORE UPDATE ON user_table_data FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()`

Triggers d'événement : ensure_rls → rls_auto_enable(), issue_graphql_placeholder → set_graphql_placeholder(), issue_pg_cron_access → grant_pg_cron_access(), issue_pg_graphql_access → grant_pg_graphql_access(), issue_pg_net_access → grant_pg_net_access(), pgrst_ddl_watch → pgrst_ddl_watch(), pgrst_drop_watch → pgrst_drop_watch().

## Policies (RLS)

| Table | Policy | Commande | Rôles | USING | WITH CHECK |
|---|---|---|---|---|---|
| public.agent_events | Users view own agent events | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.agent_keys | Users manage own agent keys | ALL | ['authenticated'] | (auth.uid() = user_id) | (auth.uid() = user_id) |
| public.agent_memory | Users manage own agent memory | ALL | ['authenticated'] | (auth.uid() = user_id) | (auth.uid() = user_id) |
| public.agent_tasks | Users can create tasks | INSERT | ['public'] |  | (auth.uid() = user_id) |
| public.agent_tasks | Users can delete own tasks | DELETE | ['public'] | (auth.uid() = user_id) |  |
| public.agent_tasks | Users can update own tasks | UPDATE | ['public'] | (auth.uid() = user_id) |  |
| public.agent_tasks | Users can view own tasks | SELECT | ['public'] | (auth.uid() = user_id) |  |
| public.applications | Users can create apps | INSERT | ['authenticated'] |  | (auth.uid() = user_id) |
| public.applications | Users can delete own apps | DELETE | ['authenticated'] | (auth.uid() = user_id) |  |
| public.applications | Users can update own apps | UPDATE | ['authenticated'] | (auth.uid() = user_id) |  |
| public.applications | Users can view own apps | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.chat_conversations | Users can create conversations | INSERT | ['public'] |  | (auth.uid() = user_id) |
| public.chat_conversations | Users can delete own conversations | DELETE | ['public'] | (auth.uid() = user_id) |  |
| public.chat_conversations | Users can update own conversations | UPDATE | ['public'] | (auth.uid() = user_id) |  |
| public.chat_conversations | Users can view own conversations | SELECT | ['public'] | (auth.uid() = user_id) |  |
| public.chat_messages | Users can create messages | INSERT | ['public'] |  | (auth.uid() = user_id) |
| public.chat_messages | Users can delete own messages | DELETE | ['public'] | (auth.uid() = user_id) |  |
| public.chat_messages | Users can view own messages | SELECT | ['public'] | (auth.uid() = user_id) |  |
| public.formations | Users can create formations | INSERT | ['authenticated'] |  | (auth.uid() = user_id) |
| public.formations | Users can delete own formations | DELETE | ['authenticated'] | (auth.uid() = user_id) |  |
| public.formations | Users can update own formations | UPDATE | ['authenticated'] | (auth.uid() = user_id) |  |
| public.formations | Users can view own formations | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.knowledge_base | Users can create knowledge | INSERT | ['public'] |  | (auth.uid() = user_id) |
| public.knowledge_base | Users can delete own knowledge | DELETE | ['public'] | (auth.uid() = user_id) |  |
| public.knowledge_base | Users can update own knowledge | UPDATE | ['public'] | (auth.uid() = user_id) |  |
| public.knowledge_base | Users can view own knowledge | SELECT | ['public'] | (auth.uid() = user_id) |  |
| public.knowledge_domains | Anyone authenticated reads domains | SELECT | ['authenticated'] | true |  |
| public.knowledge_versions | Users create own knowledge versions | INSERT | ['authenticated'] |  | (auth.uid() = user_id) |
| public.knowledge_versions | Users delete own knowledge versions | DELETE | ['authenticated'] | (auth.uid() = user_id) |  |
| public.knowledge_versions | Users view own knowledge versions | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.modules_status | Users can manage own modules | ALL | ['authenticated'] | (auth.uid() = user_id) |  |
| public.modules_status | Users can view own modules | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.profiles | Users can insert own profile | INSERT | ['authenticated'] |  | (auth.uid() = user_id) |
| public.profiles | Users can update own profile | UPDATE | ['authenticated'] | (auth.uid() = user_id) |  |
| public.profiles | Users can view all profiles | SELECT | ['authenticated'] | true |  |
| public.system_logs | Users can insert own logs | INSERT | ['authenticated'] |  | (auth.uid() = user_id) |
| public.system_logs | Users can view own logs | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.user_migrations | Users can create migrations | INSERT | ['public'] |  | (auth.uid() = user_id) |
| public.user_migrations | Users can view own migrations | SELECT | ['public'] | (auth.uid() = user_id) |  |
| public.user_roles | Admins can manage roles | ALL | ['authenticated'] | has_role(auth.uid(), 'admin'::app_role) |  |
| public.user_roles | Users can view own roles | SELECT | ['authenticated'] | (auth.uid() = user_id) |  |
| public.user_schemas | Users can create schemas | INSERT | ['public'] |  | (auth.uid() = user_id) |
| public.user_schemas | Users can delete own schemas | DELETE | ['public'] | (auth.uid() = user_id) |  |
| public.user_schemas | Users can update own schemas | UPDATE | ['public'] | (auth.uid() = user_id) |  |
| public.user_schemas | Users can view own schemas | SELECT | ['public'] | (auth.uid() = user_id) |  |
| public.user_table_data | Users can delete own data | DELETE | ['public'] | (auth.uid() = user_id) |  |
| public.user_table_data | Users can insert own data | INSERT | ['public'] |  | (auth.uid() = user_id) |
| public.user_table_data | Users can update own data | UPDATE | ['public'] | (auth.uid() = user_id) |  |
| public.user_table_data | Users can view own data | SELECT | ['public'] | (auth.uid() = user_id) |  |

## Rôles

| Rôle | Connexion | Superuser | BYPASSRLS | Membre de |
|---|---|---|---|---|
| anon |  |  |  |  |
| authenticated |  |  |  |  |
| authenticator | oui |  |  | anon, authenticated, service_role |
| dashboard_user |  |  |  |  |
| pgbouncer | oui |  |  |  |
| postgres | oui |  | oui | anon, authenticated, authenticator, pg_create_subscription, pg_monitor, pg_read_ |
| service_role |  |  | oui |  |
| supabase_admin | oui | **oui** | oui |  |
| supabase_auth_admin | oui |  |  |  |
| supabase_etl_admin | oui |  | oui | pg_monitor, pg_read_all_data, supabase_privileged_role |
| supabase_privileged_role |  |  |  |  |
| supabase_read_only_user | oui |  | oui | pg_monitor, pg_read_all_data |
| supabase_realtime_admin |  |  |  |  |
| supabase_replication_admin | oui |  |  |  |
| supabase_storage_admin | oui |  |  | authenticator |

## Droits des rôles clients sur les tables applicatives

| Table | anon | authenticated | PUBLIC | service_role | soulbah_api |
|---|---|---|---|---|---|
| public.agent_events | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.agent_keys | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.agent_memory | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
| public.agent_tasks | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  | DEL,INS,MAI,REF,SEL,TRI,TRU,UPD |  |
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

## Publications temps réel

- supabase_realtime : public.formations
- supabase_realtime : public.system_logs
- supabase_realtime : public.agent_tasks
- supabase_realtime : public.agent_events

## Historique des migrations

- `supabase_migrations.schema_migrations` : absent
- `soulbah.schema_migrations` : absent

État réel déduit des objets (`migration_state.json`) :

| Migration | Verdict | Objets présents | Absents | Différents |
|---|---|---|---|---|
| 20260218031213_fc7d9650-ca05-4801-a5f5-67d083ff843d.sql | APPLIED | 305 | 0 | 0 |
| 20260218041438_db569e91-d5f0-4b0d-88e0-872ff733fd0a.sql | APPLIED | 143 | 0 | 0 |
| 20260218121217_e64522cf-01fb-446a-901b-f30e6194531b.sql | APPLIED | 140 | 0 | 0 |
| 20260218152103_e6ec4c1b-542d-4f94-866b-6d4012de265a.sql | APPLIED | 55 | 0 | 0 |
| 20260703000000_agent_keys.sql | APPLIED | 47 | 0 | 0 |
| 20260704000000_agent_memory.sql | APPLIED | 48 | 0 | 0 |
| 20260704120000_formation_video_url.sql | APPLIED | 1 | 0 | 0 |
| 20260704130000_agent_allowed_dirs.sql | APPLIED | 1 | 0 | 0 |
| 20260706000000_knowledge_base_pro.sql | APPLIED | 102 | 0 | 0 |
| 20260706100000_formation_curriculum.sql | APPLIED | 1 | 0 | 0 |
| 20260706110000_formation_pdf_url.sql | APPLIED | 1 | 0 | 0 |
| 20260706120000_agent_memory_levels.sql | APPLIED | 6 | 0 | 0 |
| 20260706130000_agent_events.sql | APPLIED | 47 | 0 | 0 |
| 20260706140000_formations_realtime.sql | APPLIED | 1 | 0 | 0 |
| 20260706150000_knowledge_embeddings.sql | APPLIED | 1 | 0 | 0 |
| 20260707000000_agent_tasks_requeue.sql | APPLIED | 1 | 0 | 0 |
| 20261001000000_hardening.sql | NOT_APPLIED | 0 | 84 | 0 |
| 20261001090000_lot1_fixes.sql | NOT_APPLIED | 0 | 31 | 0 |
| 20261001100000_lot1_verif.sql | PARTIAL | 1 | 12 | 0 |
| 20261001120000_v2_schema.sql | NOT_APPLIED | 0 | 13 | 0 |
| 20261001120100_v2_users_sessions.sql | NOT_APPLIED | 0 | 64 | 0 |
| 20261001120200_v2_agents_runtimes.sql | NOT_APPLIED | 0 | 69 | 0 |
| 20261001120300_v2_tasks.sql | NOT_APPLIED | 0 | 77 | 0 |
| 20261001120400_v2_task_dependencies.sql | NOT_APPLIED | 0 | 24 | 0 |
| 20261001120500_v2_messages.sql | NOT_APPLIED | 0 | 37 | 0 |
| 20261001120600_v2_actions_tool_calls.sql | NOT_APPLIED | 0 | 90 | 0 |
| 20261001120700_v2_knowledge.sql | NOT_APPLIED | 0 | 69 | 0 |
| 20261001120800_v2_memory.sql | NOT_APPLIED | 0 | 48 | 0 |
| 20261001120900_v2_skills_evaluations_checkpoints.sql | NOT_APPLIED | 0 | 101 | 0 |
| 20261001121000_v2_artifacts_recordings_permissions_leases.sql | NOT_APPLIED | 0 | 136 | 0 |
| 20261001121100_v2_audit.sql | NOT_APPLIED | 0 | 66 | 0 |

## Requêtes les plus coûteuses (pg_stat_statements, normalisées)

- 1352 appels, 25745.6 ms au total, 19.04 ms en moyenne : `SELECT wal->>$5 as type, wal->>$6 as schema, wal->>$7 as table, COALESCE(wal->>$8, $9) as columns, COALESCE(wal->>$10, $11) as record, COALESCE(wal->>$12, $13) as old_record, wal->>$14 as commit_times`
- 16 appels, 3745.1 ms au total, 234.07 ms en moyenne : `SELECT name FROM pg_timezone_names`
- 1 appels, 1135.5 ms au total, 1135.5 ms en moyenne : `SELECT e.name, n.nspname AS schema, e.default_version, x.extversion AS installed_version, e.comment, ev.schema AS default_version_schema FROM pg_available_extensions e LEFT JOIN pg_extension x ON e.na`
- 16 appels, 325.4 ms au total, 20.34 ms en moyenne : `WITH -- Recursively get the base types of domains base_types AS ( WITH RECURSIVE recurse AS ( SELECT oid, typbasetype, typnamespace AS base_namespace, COALESCE(NULLIF(typbasetype, $3), oid) AS base_ty`
- 3 appels, 300.8 ms au total, 100.28 ms en moyenne : `SELECT coalesce(json_agg(json_build_object( $1, n.nspname, $2, p.proname, $3, p.prokind, $4, pg_get_function_identity_arguments(p.oid), $5, pg_get_function_result(p.oid), $6, l.lanname, $7, p.prosecde`
- 6 appels, 237.8 ms au total, 39.63 ms en moyenne : `SELECT coalesce(json_agg(json_build_object($1, name, $2, default_version, $3, installed_version) ORDER BY name), $4) FROM pg_available_extensions WHERE name IN ($5,$6,$7,$8,$9, $10,$11,$12,$13,$14,$15`
- 16 appels, 205.5 ms au total, 12.84 ms en moyenne : `WITH -- Recursively get the base types of domains base_types AS ( WITH RECURSIVE recurse AS ( SELECT oid, typbasetype, typnamespace AS base_namespace, COALESCE(NULLIF(typbasetype, $2), oid) AS base_ty`
- 6 appels, 148.2 ms au total, 24.7 ms en moyenne : `SELECT coalesce(json_agg(json_build_object( $1, n.nspname, $2, t.relname, $3, i.relname, $4, pg_get_indexdef(x.indexrelid), $5, x.indisunique, $6, x.indisprimary, $7, x.indisvalid, $8, x.indisready, $`
- 1 appels, 110.7 ms au total, 110.72 ms en moyenne : `with f as ( -- CTE with sane arg_modes, arg_names, and arg_types. -- All three are always of the same length. -- All three include all args, including OUT and TABLE args. with functions as ( select *,`
- 5 appels, 106.5 ms au total, 21.31 ms en moyenne : `SELECT coalesce(json_agg(json_build_object($1, n.nspname, $2, c.relname, $3, (xpath($4, query_to_xml(format($5, n.nspname, c.relname), $6, $7, $8)))[$9]::text::bigint) ORDER BY n.nspname, c.relname), `
- 6 appels, 96.6 ms au total, 16.09 ms en moyenne : `SELECT coalesce(json_agg(json_build_object( $1, n.nspname, $2, c.relname, $3, c.relkind, $4, pg_get_userbyid(c.relowner), $5, c.relrowsecurity, $6, c.relforcerowsecurity, $7, c.relpersistence, $8, c.r`
- 1 appels, 95.1 ms au total, 95.1 ms en moyenne : `SELECT coalesce(json_agg(json_build_object( $1, n.nspname, $2, p.proname, $3, p.prokind, $4, pg_get_function_identity_arguments(p.oid), $5, pg_get_function_result(p.oid), $6, l.lanname, $7, p.prosecde`
- 5 appels, 87.2 ms au total, 17.43 ms en moyenne : `SELECT coalesce(json_agg(q), $1) FROM ( SELECT json_build_object($2, calls, $3, round(total_exec_time::numeric, $4), $5, round(mean_exec_time::numeric, $6), $7, rows, $8, left(regexp_replace(query, $9`
- 1 appels, 85.4 ms au total, 85.44 ms en moyenne : `SELECT case when pg_is_in_recovery() then $2 else (pg_walfile_name_offset(lsn)).file_name end, lsn::text, pg_is_in_recovery() FROM pg_backup_start($1, $3) lsn`
- 1 appels, 83.4 ms au total, 83.35 ms en moyenne : `SELECT coalesce(json_agg(json_build_object( $1, n.nspname, $2, p.proname, $3, p.prokind, $4, pg_get_function_identity_arguments(p.oid), $5, pg_get_function_result(p.oid), $6, l.lanname, $7, p.prosecde`

Connexions ouvertes au relevé : 7 ({'active': 1, 'idle': 5, 'null': 1}) ; verrous en attente : 0.
