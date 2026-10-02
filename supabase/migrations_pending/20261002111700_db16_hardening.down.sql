-- Retour arrière (partiel) de 20261002111700_db16_hardening.sql : rend EXECUTE à PUBLIC sur les fonctions de soulbah
-- (état par défaut de PostgreSQL), rend à anon et authenticated les droits retirés sur public, retire les privilèges par
-- défaut ajoutés. Les vérifications n'avaient rien créé. Les droits de soulbah_api sur les objets existants sont laissés
-- (ils viennent aussi de scripts/sql/soulbah_api_grants.sql).
DO $$
DECLARE r text; privs text;
BEGIN
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA soulbah TO PUBLIC;
  privs := 'TRUNCATE, TRIGGER, REFERENCES' || CASE WHEN current_setting('server_version_num')::int >= 170000 THEN ', MAINTAIN' ELSE '' END;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('GRANT %s ON ALL TABLES IN SCHEMA public TO %I', privs, r);
      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT %s ON TABLES TO %I', privs, r);
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'soulbah_api') THEN
    ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM soulbah_api;
    ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah REVOKE USAGE, SELECT ON SEQUENCES FROM soulbah_api;
    ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah REVOKE EXECUTE ON FUNCTIONS FROM soulbah_api;
  END IF;
END $$;
DELETE FROM soulbah.system_versions WHERE component = 'database.schema' AND version = '2026-10-02.lots-01-16';
-- Les commentaires ajoutés aux objets V2 sont retirés (état d'avant le lot).
COMMENT ON TABLE soulbah.actions IS NULL;
COMMENT ON TABLE soulbah.agents IS NULL;
COMMENT ON TABLE soulbah.artifacts IS NULL;
COMMENT ON TABLE soulbah.audit_chain_head IS NULL;
COMMENT ON TABLE soulbah.audit_logs IS NULL;
COMMENT ON TABLE soulbah.checkpoints IS NULL;
COMMENT ON TABLE soulbah.evaluations IS NULL;
COMMENT ON TABLE soulbah.knowledge_chunks IS NULL;
COMMENT ON TABLE soulbah.messages IS NULL;
COMMENT ON TABLE soulbah.permissions IS NULL;
COMMENT ON TABLE soulbah.recordings IS NULL;
COMMENT ON TABLE soulbah.resource_leases IS NULL;
COMMENT ON TABLE soulbah.runtimes IS NULL;
COMMENT ON TABLE soulbah.sessions IS NULL;
COMMENT ON TABLE soulbah.skills IS NULL;
COMMENT ON TABLE soulbah.task_dependencies IS NULL;
COMMENT ON TABLE soulbah.tasks IS NULL;
COMMENT ON TABLE soulbah.tool_calls IS NULL;
COMMENT ON TABLE soulbah.user_settings IS NULL;
COMMENT ON VIEW soulbah.knowledge_documents IS NULL;
COMMENT ON VIEW soulbah.memories IS NULL;
