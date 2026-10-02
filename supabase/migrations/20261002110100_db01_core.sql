-- =============================================================================
-- DB LOT 1 — Core : aides communes, environnements, réglages, état système, versions, santé, feature flags.
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110100_db01_core.down.sql (supprime les tables de ce lot ; les lots suivants en dépendent : les retirer d'abord)
-- soulbah:transaction=single
--
-- Idempotente et additive (docs/db/DB_MIGRATION_CONVENTIONS.md). Aucune table de ce lot n'est accessible
-- aux rôles clients : RLS activée sans policy, droits révoqués. Écrivain unique : node-api (soulbah_api).
-- =============================================================================

-- ---------------------------------------------------------------------------------------------
-- 1. Aides communes réutilisées par tous les lots
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION soulbah.append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'soulbah.% est en ajout seul (% refusé)', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'insufficient_privilege';
END $$;
COMMENT ON FUNCTION soulbah.append_only() IS 'Trigger : refuse UPDATE, DELETE et TRUNCATE (journaux, décisions, événements).';

-- §9 : vérifier la FORME d'une table existante au lieu de masquer une incompatibilité par IF NOT EXISTS.
-- p_columns : {"colonne": "type attendu (format_type)", …}. Lève une exception claire si une colonne manque
-- ou si son type diffère (comparaison insensible à la casse, « real[] » accepté pour « vector… » : pgvector
-- simulé sur les bases locales de test).
CREATE OR REPLACE FUNCTION soulbah.assert_table_shape(p_table regclass, p_columns jsonb)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  k text;
  expected text;
  actual text;
BEGIN
  IF p_columns IS NULL OR jsonb_typeof(p_columns) <> 'object' THEN
    RAISE EXCEPTION 'assert_table_shape(%) : objet JSON attendu', p_table;
  END IF;
  FOR k, expected IN SELECT key, value #>> '{}' FROM jsonb_each(p_columns) LOOP
    SELECT format_type(a.atttypid, a.atttypmod) INTO actual
      FROM pg_attribute a WHERE a.attrelid = p_table AND a.attname = k AND a.attnum > 0 AND NOT a.attisdropped;
    IF actual IS NULL THEN
      RAISE EXCEPTION 'table % : colonne « % » attendue (%), absente — structure incompatible, migration arrêtée',
        p_table, k, expected;
    END IF;
    IF lower(actual) <> lower(expected)
       AND NOT (lower(expected) LIKE 'vector%' AND lower(actual) = 'real[]') THEN
      RAISE EXCEPTION 'table % : colonne « % » de type %, attendu % — structure incompatible, migration arrêtée',
        p_table, k, actual, expected;
    END IF;
  END LOOP;
END $$;
COMMENT ON FUNCTION soulbah.assert_table_shape(regclass, jsonb) IS 'Vérifie colonnes et types d''une table existante (§9 : pas d''IF NOT EXISTS aveugle).';

CREATE OR REPLACE FUNCTION soulbah.is_environment(p text)
RETURNS boolean LANGUAGE sql IMMUTABLE
AS $$ SELECT p IN ('LOCAL', 'DEV', 'TEST', 'STAGING', 'PRODUCTION') $$;

CREATE OR REPLACE FUNCTION soulbah.is_autonomy_level(p text)
RETURNS boolean LANGUAGE sql IMMUTABLE
AS $$ SELECT p IN ('OBSERVE', 'ASSIST', 'LAB', 'SAFE_AUTO', 'ADVANCED_AUTO', 'PRODUCTION_GUARDED') $$;

CREATE OR REPLACE FUNCTION soulbah.is_severity(p text)
RETURNS boolean LANGUAGE sql IMMUTABLE
AS $$ SELECT p IN ('INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL') $$;

-- Trusted Core (§55, §113) : une transaction qui modifie une ligne « immutable » doit avoir posé
-- SET LOCAL soulbah.trusted_core = 'unlocked' — chemin réservé à l'autorité humaine habilitée dans node-api.
CREATE OR REPLACE FUNCTION soulbah.trusted_core_unlocked()
RETURNS boolean LANGUAGE sql STABLE
AS $$ SELECT coalesce(current_setting('soulbah.trusted_core', true), '') = 'unlocked' $$;

CREATE OR REPLACE FUNCTION soulbah.protect_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  IF (TG_OP = 'DELETE' AND OLD.immutable) OR (TG_OP = 'UPDATE' AND (OLD.immutable OR NEW.immutable)) THEN
    IF NOT soulbah.trusted_core_unlocked() THEN
      RAISE EXCEPTION 'soulbah.% : ligne protégée (Trusted Core) — modification refusée hors du chemin habilité',
        TG_TABLE_NAME USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION soulbah.protect_immutable() IS 'Trigger : les lignes immutable=true ne changent que sous soulbah.trusted_core = unlocked.';

-- Raison de changement portée par la transaction (SET LOCAL soulbah.change_reason = '…') pour les historiques.
CREATE OR REPLACE FUNCTION soulbah.change_reason()
RETURNS text LANGUAGE sql STABLE
AS $$ SELECT nullif(current_setting('soulbah.change_reason', true), '') $$;

CREATE OR REPLACE FUNCTION soulbah.change_actor()
RETURNS text LANGUAGE sql STABLE
AS $$ SELECT coalesce(nullif(current_setting('soulbah.actor', true), ''), current_user) $$;

-- ---------------------------------------------------------------------------------------------
-- 2. Environnements (§54 : une permission en DEV ne vaut jamais en PRODUCTION)
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.environments (
  name           text PRIMARY KEY CONSTRAINT environments_name_check CHECK (soulbah.is_environment(name)),
  rank           smallint NOT NULL CONSTRAINT environments_rank_check CHECK (rank BETWEEN 0 AND 9),
  is_production  boolean NOT NULL DEFAULT false,
  description    text NOT NULL DEFAULT '' CONSTRAINT environments_description_length CHECK (length(description) <= 500),
  created_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.environments IS 'Environnements cibles des actions et déploiements : LOCAL < DEV < TEST < STAGING < PRODUCTION.';
ALTER TABLE soulbah.environments ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.environments', '{"name": "text", "rank": "smallint", "is_production": "boolean"}');
INSERT INTO soulbah.environments (name, rank, is_production, description) VALUES
  ('LOCAL', 0, false, 'Poste du développeur : copies, essais, aucune donnée réelle'),
  ('DEV', 1, false, 'Développement partagé'),
  ('TEST', 2, false, 'Tests automatisés et bancs d''essai'),
  ('STAGING', 3, false, 'Préproduction : données proches de la production'),
  ('PRODUCTION', 4, true, 'Production : toute modification soumise aux politiques et garde-fous PDG')
ON CONFLICT (name) DO NOTHING;

-- ---------------------------------------------------------------------------------------------
-- 3. Réglages système, versionnés et historisés
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.system_settings (
  key          text PRIMARY KEY CONSTRAINT system_settings_key_format CHECK (key ~ '^[a-z][a-z0-9_.]{0,119}$'),
  value        jsonb NOT NULL,
  description  text NOT NULL DEFAULT '' CONSTRAINT system_settings_description_length CHECK (length(description) <= 1000),
  critical     boolean NOT NULL DEFAULT false,
  immutable    boolean NOT NULL DEFAULT false,
  version      integer NOT NULL DEFAULT 1 CONSTRAINT system_settings_version_positive CHECK (version >= 1),
  updated_by   text NOT NULL DEFAULT current_user,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.system_settings IS 'Réglages de Soulbah (clé → valeur JSON), versionnés ; critical = confirmation renforcée ; immutable = Trusted Core.';
ALTER TABLE soulbah.system_settings ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.system_settings', '{"key": "text", "value": "jsonb", "immutable": "boolean", "version": "integer"}');

CREATE TABLE IF NOT EXISTS soulbah.system_settings_history (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  key         text NOT NULL,
  old_value   jsonb,
  new_value   jsonb,
  version     integer NOT NULL,
  changed_by  text NOT NULL,
  reason      text,
  changed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.system_settings_history IS 'Historique des réglages (ajout seul) : ancien, nouveau, auteur, justification.';
ALTER TABLE soulbah.system_settings_history ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_system_settings_history_key ON soulbah.system_settings_history (key, id);
DROP TRIGGER IF EXISTS system_settings_history_append_only ON soulbah.system_settings_history;
CREATE TRIGGER system_settings_history_append_only
  BEFORE UPDATE OR DELETE ON soulbah.system_settings_history FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS system_settings_history_no_truncate ON soulbah.system_settings_history;
CREATE TRIGGER system_settings_history_no_truncate
  BEFORE TRUNCATE ON soulbah.system_settings_history FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE OR REPLACE FUNCTION soulbah.system_settings_track()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.value IS DISTINCT FROM OLD.value OR NEW.immutable IS DISTINCT FROM OLD.immutable
       OR NEW.critical IS DISTINCT FROM OLD.critical THEN
      NEW.version := OLD.version + 1;
      NEW.updated_at := now();
      NEW.updated_by := soulbah.change_actor();
      INSERT INTO soulbah.system_settings_history (key, old_value, new_value, version, changed_by, reason)
      VALUES (OLD.key, OLD.value, NEW.value, NEW.version, NEW.updated_by, soulbah.change_reason());
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'INSERT' THEN
    INSERT INTO soulbah.system_settings_history (key, old_value, new_value, version, changed_by, reason)
    VALUES (NEW.key, NULL, NEW.value, NEW.version, soulbah.change_actor(), soulbah.change_reason());
    RETURN NEW;
  END IF;
  INSERT INTO soulbah.system_settings_history (key, old_value, new_value, version, changed_by, reason)
  VALUES (OLD.key, OLD.value, NULL, OLD.version + 1, soulbah.change_actor(), soulbah.change_reason());
  RETURN OLD;
END $$;
DROP TRIGGER IF EXISTS system_settings_protect ON soulbah.system_settings;
CREATE TRIGGER system_settings_protect
  BEFORE UPDATE OR DELETE ON soulbah.system_settings FOR EACH ROW EXECUTE FUNCTION soulbah.protect_immutable();
DROP TRIGGER IF EXISTS system_settings_track ON soulbah.system_settings;
CREATE TRIGGER system_settings_track
  BEFORE INSERT OR UPDATE OR DELETE ON soulbah.system_settings FOR EACH ROW EXECUTE FUNCTION soulbah.system_settings_track();

-- ---------------------------------------------------------------------------------------------
-- 4. État système : STOP SOULBAH, SAFE MODE, interrupteurs maîtres (§48-54, §96-97) — une seule ligne
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.system_state (
  id                    smallint PRIMARY KEY CONSTRAINT system_state_single CHECK (id = 1),
  emergency_stop        boolean NOT NULL DEFAULT false,
  emergency_stop_reason text,
  emergency_stop_at     timestamptz,
  safe_mode             boolean NOT NULL DEFAULT false,
  safe_mode_reason      text,
  internet_allowed      boolean NOT NULL DEFAULT false,
  external_ai_allowed   boolean NOT NULL DEFAULT false,
  computer_control      boolean NOT NULL DEFAULT true,
  memory_write          boolean NOT NULL DEFAULT true,
  production_changes    text NOT NULL DEFAULT 'OFF'
                        CONSTRAINT system_state_production_check CHECK (production_changes IN ('OFF', 'APPROVAL_REQUIRED', 'LIMITED_AUTO')),
  self_improvement      text NOT NULL DEFAULT 'OFF'
                        CONSTRAINT system_state_self_improvement_check CHECK (self_improvement IN ('OFF', 'PROPOSE_ONLY', 'LAB_AUTO', 'SAFE_AUTO')),
  security_autopilot    text NOT NULL DEFAULT 'OFF'
                        CONSTRAINT system_state_autopilot_check CHECK (security_autopilot IN ('OFF', 'MONITOR', 'FIX_IN_LAB', 'FIX_AND_TEST', 'SAFE_AUTO')),
  migrations            text NOT NULL DEFAULT 'PREPARE_ONLY'
                        CONSTRAINT system_state_migrations_check CHECK (migrations IN ('OFF', 'PREPARE_ONLY', 'AUTO_DEV', 'AUTO_TEST', 'AUTO_STAGING')),
  version               integer NOT NULL DEFAULT 1,
  updated_by            text NOT NULL DEFAULT current_user,
  updated_at            timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.system_state IS 'Interrupteurs maîtres du PDG (une ligne) : arrêt d''urgence, SAFE MODE, Internet, IA externes, production, auto-amélioration, Security Autopilot, migrations.';
ALTER TABLE soulbah.system_state ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.system_state', '{"emergency_stop": "boolean", "safe_mode": "boolean", "migrations": "text", "version": "integer"}');
INSERT INTO soulbah.system_state (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS soulbah.system_state_history (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  version     integer NOT NULL,
  old_state   jsonb,
  new_state   jsonb NOT NULL,
  changed_by  text NOT NULL,
  reason      text,
  changed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.system_state_history IS 'Chaque changement des interrupteurs maîtres (ajout seul).';
ALTER TABLE soulbah.system_state_history ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS system_state_history_append_only ON soulbah.system_state_history;
CREATE TRIGGER system_state_history_append_only
  BEFORE UPDATE OR DELETE ON soulbah.system_state_history FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS system_state_history_no_truncate ON soulbah.system_state_history;
CREATE TRIGGER system_state_history_no_truncate
  BEFORE TRUNCATE ON soulbah.system_state_history FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE OR REPLACE FUNCTION soulbah.system_state_track()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'soulbah.system_state : la ligne unique ne se supprime pas' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    NEW.version := OLD.version + 1;
    NEW.updated_at := now();
    NEW.updated_by := soulbah.change_actor();
    IF NEW.emergency_stop AND NOT OLD.emergency_stop THEN NEW.emergency_stop_at := now(); END IF;
    INSERT INTO soulbah.system_state_history (version, old_state, new_state, changed_by, reason)
    VALUES (NEW.version, to_jsonb(OLD), to_jsonb(NEW), NEW.updated_by, soulbah.change_reason());
    RETURN NEW;
  END IF;
  INSERT INTO soulbah.system_state_history (version, old_state, new_state, changed_by, reason)
  VALUES (NEW.version, NULL, to_jsonb(NEW), soulbah.change_actor(), soulbah.change_reason());
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS system_state_track ON soulbah.system_state;
CREATE TRIGGER system_state_track
  BEFORE INSERT OR UPDATE OR DELETE ON soulbah.system_state FOR EACH ROW EXECUTE FUNCTION soulbah.system_state_track();

-- Lecture rapide par les services (scheduler, gestionnaire de migrations, passerelle d'outils).
CREATE OR REPLACE FUNCTION soulbah.writes_allowed()
RETURNS boolean LANGUAGE sql STABLE
AS $$ SELECT NOT (emergency_stop OR safe_mode) FROM soulbah.system_state WHERE id = 1 $$;
COMMENT ON FUNCTION soulbah.writes_allowed() IS 'false si STOP SOULBAH ou SAFE MODE : les agents ne modifient rien (§96-97).';

-- ---------------------------------------------------------------------------------------------
-- 5. Versions des composants (§28 rollback : version précédente, configuration, benchmark, diff, date, raison)
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.system_versions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  component        text NOT NULL CONSTRAINT system_versions_component_format CHECK (component ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  version          text NOT NULL CONSTRAINT system_versions_version_length CHECK (length(version) BETWEEN 1 AND 100),
  app_commit       text,
  previous_version text,
  status           text NOT NULL DEFAULT 'active' CONSTRAINT system_versions_status_check CHECK (status IN ('candidate', 'active', 'rolled_back', 'retired')),
  config           jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT system_versions_config_object CHECK (soulbah.is_json_object(config)),
  rollback_info    jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT system_versions_rollback_object CHECK (soulbah.is_json_object(rollback_info)),
  reason           text,
  activated_by     text,
  activated_at     timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT system_versions_unique UNIQUE (component, version)
);
COMMENT ON TABLE soulbah.system_versions IS 'Versions actives et passées de chaque composant (agents, prompts, routeur, outils) avec informations de retour arrière.';
ALTER TABLE soulbah.system_versions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_system_versions_component ON soulbah.system_versions (component, status);

-- ---------------------------------------------------------------------------------------------
-- 6. Santé courante par composant (l'historique est au DB LOT 14)
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.system_health (
  component   text PRIMARY KEY CONSTRAINT system_health_component_format CHECK (component ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  status      text NOT NULL DEFAULT 'unknown' CONSTRAINT system_health_status_check CHECK (status IN ('healthy', 'degraded', 'down', 'unknown')),
  detail      jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT system_health_detail_object CHECK (soulbah.is_json_object(detail)),
  checked_at  timestamptz,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.system_health IS 'Dernier état connu de chaque composant : core, db, orchestrator, model_router, memory, knowledge, security, workers, internet.';
ALTER TABLE soulbah.system_health ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS system_health_set_updated_at ON soulbah.system_health;
CREATE TRIGGER system_health_set_updated_at BEFORE UPDATE ON soulbah.system_health FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- ---------------------------------------------------------------------------------------------
-- 7. Feature flags, historisés
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.feature_flags (
  key          text PRIMARY KEY CONSTRAINT feature_flags_key_format CHECK (key ~ '^[a-z][a-z0-9_.]{0,119}$'),
  enabled      boolean NOT NULL DEFAULT false,
  description  text NOT NULL DEFAULT '' CONSTRAINT feature_flags_description_length CHECK (length(description) <= 1000),
  scope        text NOT NULL DEFAULT 'global' CONSTRAINT feature_flags_scope_check CHECK (scope IN ('global', 'user', 'project', 'agent')),
  rollout      jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT feature_flags_rollout_object CHECK (soulbah.is_json_object(rollout)),
  immutable    boolean NOT NULL DEFAULT false,
  version      integer NOT NULL DEFAULT 1,
  updated_by   text NOT NULL DEFAULT current_user,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.feature_flags IS 'Fonctions activables (globales ou par utilisateur, projet, agent), versionnées.';
ALTER TABLE soulbah.feature_flags ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.feature_flags_history (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  key         text NOT NULL,
  old_state   jsonb,
  new_state   jsonb,
  version     integer NOT NULL,
  changed_by  text NOT NULL,
  reason      text,
  changed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.feature_flags_history IS 'Historique des feature flags (ajout seul).';
ALTER TABLE soulbah.feature_flags_history ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS feature_flags_history_append_only ON soulbah.feature_flags_history;
CREATE TRIGGER feature_flags_history_append_only
  BEFORE UPDATE OR DELETE ON soulbah.feature_flags_history FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS feature_flags_history_no_truncate ON soulbah.feature_flags_history;
CREATE TRIGGER feature_flags_history_no_truncate
  BEFORE TRUNCATE ON soulbah.feature_flags_history FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE OR REPLACE FUNCTION soulbah.feature_flags_track()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    NEW.version := OLD.version + 1;
    NEW.updated_at := now();
    NEW.updated_by := soulbah.change_actor();
    INSERT INTO soulbah.feature_flags_history (key, old_state, new_state, version, changed_by, reason)
    VALUES (OLD.key, to_jsonb(OLD), to_jsonb(NEW), NEW.version, NEW.updated_by, soulbah.change_reason());
    RETURN NEW;
  ELSIF TG_OP = 'INSERT' THEN
    INSERT INTO soulbah.feature_flags_history (key, old_state, new_state, version, changed_by, reason)
    VALUES (NEW.key, NULL, to_jsonb(NEW), NEW.version, soulbah.change_actor(), soulbah.change_reason());
    RETURN NEW;
  END IF;
  INSERT INTO soulbah.feature_flags_history (key, old_state, new_state, version, changed_by, reason)
  VALUES (OLD.key, to_jsonb(OLD), NULL, OLD.version + 1, soulbah.change_actor(), soulbah.change_reason());
  RETURN OLD;
END $$;
DROP TRIGGER IF EXISTS feature_flags_protect ON soulbah.feature_flags;
CREATE TRIGGER feature_flags_protect
  BEFORE UPDATE OR DELETE ON soulbah.feature_flags FOR EACH ROW EXECUTE FUNCTION soulbah.protect_immutable();
DROP TRIGGER IF EXISTS feature_flags_track ON soulbah.feature_flags;
CREATE TRIGGER feature_flags_track
  BEFORE INSERT OR UPDATE OR DELETE ON soulbah.feature_flags FOR EACH ROW EXECUTE FUNCTION soulbah.feature_flags_track();

-- ---------------------------------------------------------------------------------------------
-- 8. Aucun droit client sur les objets de ce lot
-- ---------------------------------------------------------------------------------------------
DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON soulbah.environments, soulbah.system_settings, soulbah.system_settings_history, soulbah.system_state,
    soulbah.system_state_history, soulbah.system_versions, soulbah.system_health, soulbah.feature_flags,
    soulbah.feature_flags_history FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.environments, soulbah.system_settings, soulbah.system_settings_history, '
                     'soulbah.system_state, soulbah.system_state_history, soulbah.system_versions, soulbah.system_health, '
                     'soulbah.feature_flags, soulbah.feature_flags_history FROM %I', r);
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.append_only(), soulbah.assert_table_shape(regclass, jsonb), '
                     'soulbah.protect_immutable(), soulbah.trusted_core_unlocked(), soulbah.writes_allowed(), '
                     'soulbah.change_reason(), soulbah.change_actor(), soulbah.system_settings_track(), '
                     'soulbah.system_state_track(), soulbah.feature_flags_track() FROM %I', r);
    END IF;
  END LOOP;
END $$;
