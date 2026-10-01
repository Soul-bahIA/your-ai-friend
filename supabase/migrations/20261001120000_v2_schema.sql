-- =============================================================================
-- V2 — 1/12 : schéma `soulbah` (LOT 4, audit §9, §12).
-- Migration IDEMPOTENTE et ADDITIVE (rien n'est supprimé ni renommé ; public.* intact).
--
-- Le schéma `soulbah` est le plan de contrôle V2 : node-api en est le SEUL écrivain
-- (connexion privilégiée, rôle soulbah_api). Il n'est jamais exposé à PostgREST ni aux
-- clients : tout droit est révoqué pour PUBLIC, anon et authenticated, et aucune policy
-- n'ouvre l'accès (RLS activée sur chaque table, sans policy = refus).
-- Supabase : NE PAS ajouter `soulbah` aux « Exposed schemas » de l'API.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS soulbah;
COMMENT ON SCHEMA soulbah IS
  'Soulbah IA V2 — plan de contrôle (sessions, tâches, messages, preuves, audit). Écrit par node-api uniquement ; jamais exposé à PostgREST.';

REVOKE ALL ON SCHEMA soulbah FROM PUBLIC;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON SCHEMA soulbah FROM %I', r);
      -- Objets futurs créés par le rôle courant : aucun droit par défaut pour les clients.
      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah REVOKE ALL ON TABLES FROM %I', r);
      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah REVOKE ALL ON SEQUENCES FROM %I', r);
      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah REVOKE ALL ON FUNCTIONS FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- Horodatage de modification (même rôle que public.update_updated_at_column, propre au schéma).
CREATE OR REPLACE FUNCTION soulbah.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Niveaux de sécurité (audit §9.10) et aides de validation réutilisées par les CHECK.
CREATE OR REPLACE FUNCTION soulbah.is_security_level(p text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$ SELECT p IN ('L0', 'L1', 'L2', 'L3') $$;

CREATE OR REPLACE FUNCTION soulbah.is_json_array(p jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$ SELECT p IS NOT NULL AND jsonb_typeof(p) = 'array' $$;

CREATE OR REPLACE FUNCTION soulbah.is_json_object(p jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$ SELECT p IS NOT NULL AND jsonb_typeof(p) = 'object' $$;
