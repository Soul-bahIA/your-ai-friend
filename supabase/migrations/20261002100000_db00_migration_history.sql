-- =============================================================================
-- DB LOT 0b — Historique des migrations Soulbah (§8 MIGRATION HISTORY, §78 MIGRATION LOCK).
-- soulbah:rollback=PARTIAL
-- soulbah:recovery=20261002100000_db00_migration_history.down.sql supprime les deux tables : aucune donnée métier, mais l'historique enregistré est perdu (l'exporter avant).
-- soulbah:transaction=single
--
-- Idempotente et additive. Prépare la tenue d'un historique AVANT d'appliquer quoi que ce soit d'autre :
--   * soulbah.schema_migrations     : une ligne par migration (dernier état connu), empreinte SHA-256 du
--                                     fichier (fins de ligne normalisées en LF), durée, statut, auteur, commit,
--                                     possibilité de retour arrière (YES / PARTIAL / NO) et plan de reprise ;
--   * soulbah.schema_migration_runs : chaque tentative (application, mise en baseline, retour arrière,
--                                     vérification), réussie ou non, en AJOUT SEUL (UPDATE, DELETE et TRUNCATE
--                                     refusés par trigger) : un échec reste visible même si sa transaction a été
--                                     annulée (le gestionnaire l'écrit dans une transaction séparée).
-- Le verrou contre deux migrations concurrentes est un verrou consultatif de transaction pris par le
-- gestionnaire (scripts/db/migrate.py) : pg_advisory_xact_lock(hashtext('soulbah.schema_migrations')).
--
-- Le schéma soulbah est créé ici s'il n'existe pas encore (base restaurée sans V2) avec les mêmes
-- protections que la migration V2 1/12 (20261001120000_v2_schema.sql), qui reste compatible (IF NOT EXISTS).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS soulbah;
REVOKE ALL ON SCHEMA soulbah FROM PUBLIC;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON SCHEMA soulbah FROM %I', r);
    END IF;
  END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS soulbah.schema_migrations (
  version         text PRIMARY KEY CONSTRAINT schema_migrations_version_format CHECK (version ~ '^[0-9]{14}$'),
  name            text NOT NULL CONSTRAINT schema_migrations_name_length CHECK (length(name) BETWEEN 1 AND 200),
  checksum        text NOT NULL CONSTRAINT schema_migrations_checksum_format CHECK (checksum ~ '^[0-9a-f]{64}$'),
  source          text NOT NULL CONSTRAINT schema_migrations_source_check CHECK (source IN ('repo', 'pending', 'manual')),
  status          text NOT NULL CONSTRAINT schema_migrations_status_check
                    CHECK (status IN ('applied', 'baselined', 'rolled_back')),
  rollback        text NOT NULL DEFAULT 'NO' CONSTRAINT schema_migrations_rollback_check
                    CHECK (rollback IN ('YES', 'PARTIAL', 'NO')),
  recovery        text,
  executed_at     timestamptz NOT NULL DEFAULT now(),
  execution_ms    integer CONSTRAINT schema_migrations_execution_ms_check CHECK (execution_ms >= 0),
  applied_by      text NOT NULL DEFAULT current_user,
  app_commit      text,
  notes           text
);
COMMENT ON TABLE soulbah.schema_migrations IS
  'Soulbah DB LOT 0b : état de chaque migration (empreinte, durée, statut, retour arrière). Écrit par scripts/db/migrate.py.';
ALTER TABLE soulbah.schema_migrations ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.schema_migration_runs (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  version         text NOT NULL CONSTRAINT schema_migration_runs_version_format CHECK (version ~ '^[0-9]{14}$'),
  action          text NOT NULL CONSTRAINT schema_migration_runs_action_check
                    CHECK (action IN ('apply', 'baseline', 'rollback', 'verify')),
  status          text NOT NULL CONSTRAINT schema_migration_runs_status_check
                    CHECK (status IN ('succeeded', 'failed', 'skipped')),
  checksum        text CONSTRAINT schema_migration_runs_checksum_format CHECK (checksum IS NULL OR checksum ~ '^[0-9a-f]{64}$'),
  started_at      timestamptz NOT NULL DEFAULT now(),
  execution_ms    integer CONSTRAINT schema_migration_runs_execution_ms_check CHECK (execution_ms IS NULL OR execution_ms >= 0),
  error           text,
  run_by          text NOT NULL DEFAULT current_user,
  app_commit      text,
  details         jsonb NOT NULL DEFAULT '{}'::jsonb
                    CONSTRAINT schema_migration_runs_details_object CHECK (jsonb_typeof(details) = 'object')
);
COMMENT ON TABLE soulbah.schema_migration_runs IS
  'Soulbah DB LOT 0b : chaque tentative de migration, en ajout seul (UPDATE, DELETE, TRUNCATE refusés).';
ALTER TABLE soulbah.schema_migration_runs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_schema_migration_runs_version ON soulbah.schema_migration_runs (version, id);

CREATE OR REPLACE FUNCTION soulbah.schema_migration_runs_append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'soulbah.schema_migration_runs est en ajout seul (% refusé)', TG_OP;
END $$;

DROP TRIGGER IF EXISTS schema_migration_runs_no_update ON soulbah.schema_migration_runs;
CREATE TRIGGER schema_migration_runs_no_update
  BEFORE UPDATE OR DELETE ON soulbah.schema_migration_runs
  FOR EACH ROW EXECUTE FUNCTION soulbah.schema_migration_runs_append_only();
DROP TRIGGER IF EXISTS schema_migration_runs_no_truncate ON soulbah.schema_migration_runs;
CREATE TRIGGER schema_migration_runs_no_truncate
  BEFORE TRUNCATE ON soulbah.schema_migration_runs
  FOR EACH STATEMENT EXECUTE FUNCTION soulbah.schema_migration_runs_append_only();

-- Aucun accès client : ni PostgREST ni anon/authenticated.
REVOKE ALL ON soulbah.schema_migrations, soulbah.schema_migration_runs FROM PUBLIC;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.schema_migrations, soulbah.schema_migration_runs FROM %I', r);
    END IF;
  END LOOP;
END $$;
