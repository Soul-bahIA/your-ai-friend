-- =============================================================================
-- DB LOT 15 — Index et performance : index couvrant de chaque clé étrangère encore sans index (relevé automatique
-- sur la base intégrée des lots 01 à 14, schémas public et soulbah : 23 clés), partiel sur les colonnes nullables.
-- Les index partiels des files (tâches READY, approbations pending, tâches RETRYING, baux) existent déjà en V2.
-- Tables de quelques lignes aujourd'hui : création dans la transaction, sans CONCURRENTLY (transaction=none à utiliser
-- le jour où une table est volumineuse).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002111600_db15_indexes_performance.down.sql
-- soulbah:transaction=single
-- Dépend de : tous les lots précédents (les index portent sur leurs tables).
-- =============================================================================

-- agent_memory_source_task_fk → soulbah.tasks
CREATE INDEX IF NOT EXISTS idx_agent_memory_source_task_id ON public.agent_memory (source_task_id) WHERE source_task_id IS NOT NULL;
-- chat_messages_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_chat_messages_user_id ON public.chat_messages (user_id);
-- knowledge_versions_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_knowledge_versions_user_id ON public.knowledge_versions (user_id);
-- user_migrations_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_user_migrations_user_id ON public.user_migrations (user_id);
-- user_table_data_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_user_table_data_user_id ON public.user_table_data (user_id);
-- actions_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_actions_user_id ON soulbah.actions (user_id);
-- agent_assignments_environment_name_fkey → soulbah.environments
CREATE INDEX IF NOT EXISTS idx_agent_assignments_environment_name ON soulbah.agent_assignments (environment_name);
-- agent_permissions_environment_name_fkey → soulbah.environments
CREATE INDEX IF NOT EXISTS idx_agent_permissions_environment_name ON soulbah.agent_permissions (environment_name);
-- agents_current_task_fk → soulbah.tasks
CREATE INDEX IF NOT EXISTS idx_agents_current_task_id ON soulbah.agents (current_task_id) WHERE current_task_id IS NOT NULL;
-- agents_runtime_id_fkey → soulbah.runtimes
CREATE INDEX IF NOT EXISTS idx_agents_runtime_id ON soulbah.agents (runtime_id) WHERE runtime_id IS NOT NULL;
-- agents_version_id_fkey → soulbah.agent_definition_versions
CREATE INDEX IF NOT EXISTS idx_agents_version_id ON soulbah.agents (version_id) WHERE version_id IS NOT NULL;
-- artifacts_session_id_fkey → soulbah.sessions
CREATE INDEX IF NOT EXISTS idx_artifacts_session_id ON soulbah.artifacts (session_id) WHERE session_id IS NOT NULL;
-- autonomy_rules_environment_name_fkey → soulbah.environments
CREATE INDEX IF NOT EXISTS idx_autonomy_rules_environment_name ON soulbah.autonomy_rules (environment_name);
-- evaluations_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_evaluations_user_id ON soulbah.evaluations (user_id);
-- messages_from_agent_id_fkey → soulbah.agents
CREATE INDEX IF NOT EXISTS idx_messages_from_agent_id ON soulbah.messages (from_agent_id) WHERE from_agent_id IS NOT NULL;
-- messages_reply_to_fkey → soulbah.messages
CREATE INDEX IF NOT EXISTS idx_messages_reply_to ON soulbah.messages (reply_to) WHERE reply_to IS NOT NULL;
-- permissions_action_id_fkey → soulbah.actions
CREATE INDEX IF NOT EXISTS idx_permissions_action_id ON soulbah.permissions (action_id) WHERE action_id IS NOT NULL;
-- permissions_decided_by_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_permissions_decided_by ON soulbah.permissions (decided_by) WHERE decided_by IS NOT NULL;
-- policy_rules_environment_name_fkey → soulbah.environments
CREATE INDEX IF NOT EXISTS idx_policy_rules_environment_name ON soulbah.policy_rules (environment_name) WHERE environment_name IS NOT NULL;
-- projects_owner_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_projects_owner_user_id ON soulbah.projects (owner_user_id) WHERE owner_user_id IS NOT NULL;
-- recordings_artifact_id_fkey → soulbah.artifacts
CREATE INDEX IF NOT EXISTS idx_recordings_artifact_id ON soulbah.recordings (artifact_id) WHERE artifact_id IS NOT NULL;
-- recordings_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_recordings_user_id ON soulbah.recordings (user_id);
-- tool_calls_action_id_fkey → soulbah.actions
CREATE INDEX IF NOT EXISTS idx_tool_calls_action_id ON soulbah.tool_calls (action_id) WHERE action_id IS NOT NULL;

-- Index V2 en double (mêmes colonnes qu'un index UNIQUE existant, relevé par le test de ce lot) : retirés, l'index
-- unique sert aux mêmes requêtes. Recréés à l'identique par le retour arrière.
DROP INDEX IF EXISTS soulbah.idx_actions_task;               -- doublon de actions_idempotency (task_id, attempt, step_index)
DROP INDEX IF EXISTS soulbah.idx_knowledge_chunks_document;  -- doublon de knowledge_chunks_unique (document_id, chunk_index)

-- Vérification : plus aucune clé étrangère de public ni de soulbah sans index en tête
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(c.conrelid::regclass::text || '(' || a.attname || ')', ', ' ORDER BY c.conrelid::regclass::text) INTO bad
    FROM pg_constraint c
    JOIN pg_namespace ns ON ns.oid = c.connamespace
    JOIN LATERAL unnest(c.conkey) WITH ORDINALITY k(attnum, ord) ON k.ord = 1
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
   WHERE c.contype = 'f' AND ns.nspname IN ('public', 'soulbah')
     AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.conrelid AND i.indkey[0] = k.attnum);
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'DB LOT 15 : clés étrangères encore sans index : %', bad; END IF;
END $$;
