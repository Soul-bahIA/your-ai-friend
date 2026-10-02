# Schema Drift Report (généré)

Base réelle : 18.1 · schémas applicatifs public, soulbah

Schéma attendu : 18.1 · schémas public, soulbah

| Écart | Nombre |
|---|---|
| `extra_column` | 23 |
| `extra_grant` | 23 |
| `extra_check_constraint` | 13 |
| `publications_missing` | 4 |
| `extra_index` | 3 |
| `extra_extension` | 2 |
| `extra_function` | 2 |
| `extra_primary_key` | 2 |
| `extra_trigger` | 2 |
| `missing_index` | 2 |
| `orphan_table` | 2 |
| `constraint_definition_mismatch` | 1 |

## constraint_definition_mismatch

- `public.agent_memory.agent_memory_validated_requires_proof` — definition : attendu "CHECK (status <> 'validated'::text OR validated_by IS NOT NULL OR metadata ? 'validated_by'::text OR jsonb_typeof(evidence_ids) = 'array'::text AND jsonb_array_length(evidence_ids) > 0)", réel "CHECK (status <> 'validated'::text OR validated_by IS NOT NULL OR metadata ? 'validated_by'::text OR jsonb_typeof(evidence_ids) = 'array'::text AND jsonb_array_length(evidence_ids) > 0) NOT VALID"

## extra_check_constraint

- `soulbah.schema_migration_runs.schema_migration_runs_action_check`
- `soulbah.schema_migration_runs.schema_migration_runs_checksum_format`
- `soulbah.schema_migration_runs.schema_migration_runs_details_object`
- `soulbah.schema_migration_runs.schema_migration_runs_execution_ms_check`
- `soulbah.schema_migration_runs.schema_migration_runs_status_check`
- `soulbah.schema_migration_runs.schema_migration_runs_version_format`
- `soulbah.schema_migrations.schema_migrations_checksum_format`
- `soulbah.schema_migrations.schema_migrations_execution_ms_check`
- `soulbah.schema_migrations.schema_migrations_name_length`
- `soulbah.schema_migrations.schema_migrations_rollback_check`
- `soulbah.schema_migrations.schema_migrations_source_check`
- `soulbah.schema_migrations.schema_migrations_status_check`
- `soulbah.schema_migrations.schema_migrations_version_format`

## extra_column

- `soulbah.schema_migration_runs.action`
- `soulbah.schema_migration_runs.app_commit`
- `soulbah.schema_migration_runs.checksum`
- `soulbah.schema_migration_runs.details`
- `soulbah.schema_migration_runs.error`
- `soulbah.schema_migration_runs.execution_ms`
- `soulbah.schema_migration_runs.id`
- `soulbah.schema_migration_runs.run_by`
- `soulbah.schema_migration_runs.started_at`
- `soulbah.schema_migration_runs.status`
- `soulbah.schema_migration_runs.version`
- `soulbah.schema_migrations.app_commit`
- `soulbah.schema_migrations.applied_by`
- `soulbah.schema_migrations.checksum`
- `soulbah.schema_migrations.executed_at`
- `soulbah.schema_migrations.execution_ms`
- `soulbah.schema_migrations.name`
- `soulbah.schema_migrations.notes`
- `soulbah.schema_migrations.recovery`
- `soulbah.schema_migrations.rollback`
- `soulbah.schema_migrations.source`
- `soulbah.schema_migrations.status`
- `soulbah.schema_migrations.version`

## extra_extension

- `pgcrypto`
- `uuid-ossp`

## extra_function

- `public.rls_auto_enable.`
- `soulbah.schema_migration_runs_append_only.`

## extra_grant

- `soulbah.schema_migration_runs.postgres DELETE`
- `soulbah.schema_migration_runs.postgres INSERT`
- `soulbah.schema_migration_runs.postgres MAINTAIN`
- `soulbah.schema_migration_runs.postgres REFERENCES`
- `soulbah.schema_migration_runs.postgres SELECT`
- `soulbah.schema_migration_runs.postgres TRIGGER`
- `soulbah.schema_migration_runs.postgres TRUNCATE`
- `soulbah.schema_migration_runs.postgres UPDATE`
- `soulbah.schema_migrations.postgres DELETE`
- `soulbah.schema_migrations.postgres INSERT`
- `soulbah.schema_migrations.postgres MAINTAIN`
- `soulbah.schema_migrations.postgres REFERENCES`
- `soulbah.schema_migrations.postgres SELECT`
- `soulbah.schema_migrations.postgres TRIGGER`
- `soulbah.schema_migrations.postgres TRUNCATE`
- `soulbah.schema_migrations.postgres UPDATE`
- `public.PUBLIC.EXECUTE rls_auto_enable()`
- `public.anon.EXECUTE rls_auto_enable()`
- `public.authenticated.EXECUTE rls_auto_enable()`
- `public.postgres.EXECUTE rls_auto_enable()`
- `public.service_role.EXECUTE rls_auto_enable()`
- `soulbah.PUBLIC.EXECUTE schema_migration_runs_append_only()`
- `soulbah.postgres.EXECUTE schema_migration_runs_append_only()`

## extra_index

- `soulbah.schema_migration_runs.idx_schema_migration_runs_version`
- `soulbah.schema_migration_runs.schema_migration_runs_pkey`
- `soulbah.schema_migrations.schema_migrations_pkey`

## extra_primary_key

- `soulbah.schema_migration_runs.schema_migration_runs_pkey`
- `soulbah.schema_migrations.schema_migrations_pkey`

## extra_trigger

- `soulbah.schema_migration_runs.schema_migration_runs_no_truncate`
- `soulbah.schema_migration_runs.schema_migration_runs_no_update`

## missing_index

- `idx_knowledge_base_embedding` — index HNSW attendu (migrations) absent de la base
- `idx_knowledge_chunks_hnsw_te3s` — index HNSW attendu (migrations) absent de la base

## orphan_table

- `soulbah.schema_migration_runs`
- `soulbah.schema_migrations`

## publications_missing

- `public.agent_events`
- `public.agent_tasks`
- `public.formations`
- `public.system_logs`
