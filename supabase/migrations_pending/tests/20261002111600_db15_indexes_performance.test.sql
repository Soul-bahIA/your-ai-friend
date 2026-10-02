-- Test de 20261002111600_db15_indexes_performance.sql
DO $$
DECLARE bad text; r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES ('public', 'idx_agent_memory_source_task_id'), ('public', 'idx_chat_messages_user_id'), ('public', 'idx_knowledge_versions_user_id'), ('public', 'idx_user_migrations_user_id'), ('public', 'idx_user_table_data_user_id'), ('soulbah', 'idx_actions_user_id'), ('soulbah', 'idx_agent_assignments_environment_name'), ('soulbah', 'idx_agent_permissions_environment_name'), ('soulbah', 'idx_agents_current_task_id'), ('soulbah', 'idx_agents_runtime_id'), ('soulbah', 'idx_agents_version_id'), ('soulbah', 'idx_artifacts_session_id'), ('soulbah', 'idx_autonomy_rules_environment_name'), ('soulbah', 'idx_evaluations_user_id'), ('soulbah', 'idx_messages_from_agent_id'), ('soulbah', 'idx_messages_reply_to'), ('soulbah', 'idx_permissions_action_id'), ('soulbah', 'idx_permissions_decided_by'), ('soulbah', 'idx_policy_rules_environment_name'), ('soulbah', 'idx_projects_owner_user_id'), ('soulbah', 'idx_recordings_artifact_id'), ('soulbah', 'idx_recordings_user_id'), ('soulbah', 'idx_tool_calls_action_id')) AS v(s, i) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = r.s AND indexname = r.i) THEN RAISE EXCEPTION 'index absent : %.%', r.s, r.i; END IF;
  END LOOP;
  SELECT string_agg(c.conrelid::regclass::text || '(' || a.attname || ')', ', ') INTO bad
    FROM pg_constraint c JOIN pg_namespace ns ON ns.oid = c.connamespace
    JOIN LATERAL unnest(c.conkey) WITH ORDINALITY k(attnum, ord) ON k.ord = 1
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
   WHERE c.contype = 'f' AND ns.nspname IN ('public', 'soulbah')
     AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.conrelid AND i.indkey[0] = k.attnum);
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'FK sans index : %', bad; END IF;
  -- Aucun index en double (même table, mêmes colonnes, même prédicat)
  SELECT string_agg(a.indexrelid::regclass::text || ' = ' || b.indexrelid::regclass::text, ', ') INTO bad
    FROM pg_index a JOIN pg_index b ON a.indrelid = b.indrelid AND a.indexrelid < b.indexrelid
     AND a.indkey::text = b.indkey::text AND COALESCE(pg_get_expr(a.indpred, a.indrelid), '') = COALESCE(pg_get_expr(b.indpred, b.indrelid), '')
    JOIN pg_class c ON c.oid = a.indrelid JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname IN ('public', 'soulbah');
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'index en double : %', bad; END IF;
END $$;
