-- Test de 20261002100000_db00_migration_history.sql (exécuté dans une transaction annulée).
DO $$
DECLARE
  r text;
BEGIN
  -- Objets présents, RLS activée
  IF to_regclass('soulbah.schema_migrations') IS NULL OR to_regclass('soulbah.schema_migration_runs') IS NULL THEN
    RAISE EXCEPTION 'tables d''historique absentes';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'soulbah.schema_migrations'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'soulbah.schema_migration_runs'::regclass) THEN
    RAISE EXCEPTION 'RLS non activée sur l''historique';
  END IF;

  -- Aucun droit pour les clients
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) AND (
         has_table_privilege(r, 'soulbah.schema_migrations', 'SELECT')
      OR has_table_privilege(r, 'soulbah.schema_migration_runs', 'SELECT')
      OR has_schema_privilege(r, 'soulbah', 'USAGE')) THEN
      RAISE EXCEPTION 'le rôle % a un accès à l''historique des migrations', r;
    END IF;
  END LOOP;

  -- Contraintes de forme
  BEGIN
    INSERT INTO soulbah.schema_migrations (version, name, checksum, source, status)
    VALUES ('2026', 'x', repeat('a', 64), 'repo', 'applied');
    RAISE EXCEPTION 'version mal formée acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO soulbah.schema_migrations (version, name, checksum, source, status)
    VALUES ('29991231000000', 'x', 'pas-un-sha256', 'repo', 'applied');
    RAISE EXCEPTION 'empreinte mal formée acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO soulbah.schema_migrations (version, name, checksum, source, status)
    VALUES ('29991231000000', 'x', repeat('a', 64), 'repo', 'failed');
    RAISE EXCEPTION 'statut inconnu accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- Journal des tentatives en ajout seul
  INSERT INTO soulbah.schema_migration_runs (version, action, status) VALUES ('29991231000000', 'verify', 'succeeded');
  BEGIN
    UPDATE soulbah.schema_migration_runs SET status = 'failed' WHERE version = '29991231000000';
    RAISE EXCEPTION 'UPDATE accepté sur le journal';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%ajout seul%' THEN RAISE; END IF;
  END;
  BEGIN
    DELETE FROM soulbah.schema_migration_runs WHERE version = '29991231000000';
    RAISE EXCEPTION 'DELETE accepté sur le journal';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%ajout seul%' THEN RAISE; END IF;
  END;
  BEGIN
    TRUNCATE soulbah.schema_migration_runs;
    RAISE EXCEPTION 'TRUNCATE accepté sur le journal';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%ajout seul%' THEN RAISE; END IF;
  END;
END $$;
