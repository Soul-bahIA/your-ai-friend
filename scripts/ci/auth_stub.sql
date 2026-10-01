-- =============================================================================
-- Stub minimal de Supabase pour appliquer supabase/migrations/ sur un Postgres NU
-- (job CI `db`, PG local jetable). À NE JAMAIS exécuter sur un projet Supabase réel.
-- Idempotent : peut être rejoué.
--
-- Reproduit uniquement ce que les migrations et les tests de policies utilisent :
--   * rôles anon / authenticated / service_role (NOLOGIN) ;
--   * schéma auth, table auth.users (colonnes lues par handle_new_user) ;
--   * auth.uid() : lit le `sub` du JWT comme Supabase (request.jwt.claim.sub ou
--     request.jwt.claims) → un test fixe l'utilisateur avec
--       SELECT set_config('request.jwt.claims', '{"sub":"<uuid>"}', true);
--   * publication supabase_realtime ;
--   * privilèges par défaut de Supabase sur le schéma public (sinon SET ROLE
--     authenticated ne pourrait rien lire et la RLS ne serait pas testée).
-- =============================================================================

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOINHERIT', r);
    END IF;
  END LOOP;
END $$;

-- service_role contourne la RLS, comme sur Supabase.
ALTER ROLE service_role BYPASSRLS;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS extensions;

CREATE TABLE IF NOT EXISTS auth.users (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email              text,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

GRANT USAGE ON SCHEMA auth       TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END $$;
