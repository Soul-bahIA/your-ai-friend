-- =============================================================================
-- V2 — 3/12 : agents (rôles instanciés dans une session), runtimes (PC exécutants) et
-- extension de public.agent_keys — audit §9.2, §9.6, §12.
-- Idempotente, additive.
-- =============================================================================

-- agent_keys : une clé = un PC (V1) ou un runtime V2 (kind), avec portées, expiration et
-- capacités annoncées (slots, écran, téléphone, navigateur…).
ALTER TABLE public.agent_keys
  ADD COLUMN IF NOT EXISTS kind          text NOT NULL DEFAULT 'agent',
  ADD COLUMN IF NOT EXISTS scopes        jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS expires_at    timestamptz,
  ADD COLUMN IF NOT EXISTS capabilities  jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS last_seen_at  timestamptz;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_keys_kind_check'
                   AND conrelid = 'public.agent_keys'::regclass) THEN
    ALTER TABLE public.agent_keys ADD CONSTRAINT agent_keys_kind_check
      CHECK (kind IN ('agent', 'runtime')) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_keys_scopes_array'
                   AND conrelid = 'public.agent_keys'::regclass) THEN
    ALTER TABLE public.agent_keys ADD CONSTRAINT agent_keys_scopes_array
      CHECK (soulbah.is_json_array(scopes)) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_keys_capabilities_object'
                   AND conrelid = 'public.agent_keys'::regclass) THEN
    ALTER TABLE public.agent_keys ADD CONSTRAINT agent_keys_capabilities_object
      CHECK (soulbah.is_json_object(capabilities)) NOT VALID;
  END IF;
END $$;
DO $$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY ARRAY['agent_keys_kind_check', 'agent_keys_scopes_array', 'agent_keys_capabilities_object'] LOOP
    BEGIN
      EXECUTE format('ALTER TABLE public.agent_keys VALIDATE CONSTRAINT %I', c);
    EXCEPTION WHEN check_violation THEN
      RAISE NOTICE 'Contrainte % non validée : des lignes existantes la violent', c;
    END;
  END LOOP;
END $$;

-- Runtimes : processus superviseur d'un PC (LOT 8), lié à une clé agent.
CREATE TABLE IF NOT EXISTS soulbah.runtimes (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  agent_key_id   uuid NOT NULL REFERENCES public.agent_keys(id) ON DELETE CASCADE,
  hostname       text,
  version        text,
  -- Capacité du PC (SOULBAH_MAX_SLOTS), bornée comme les autres plafonds (§9.6).
  max_slots      integer NOT NULL DEFAULT 6 CONSTRAINT runtimes_max_slots_range CHECK (max_slots BETWEEN 1 AND 32),
  capabilities   jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT runtimes_capabilities_object CHECK (soulbah.is_json_object(capabilities)),
  status         text NOT NULL DEFAULT 'offline'
                 CONSTRAINT runtimes_status_check CHECK (status IN ('online', 'draining', 'offline')),
  lease_owner    text,
  last_seen_at   timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT runtimes_one_per_key UNIQUE (agent_key_id)
);
ALTER TABLE soulbah.runtimes ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.runtimes;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.runtimes
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
CREATE INDEX IF NOT EXISTS idx_runtimes_user ON soulbah.runtimes (user_id, status);

-- Agents : un rôle instancié dans une session (desktop_operator, coder, researcher, qa_reviewer…).
-- current_task_id est ajouté par 4/12 (la table tasks n'existe pas encore).
CREATE TABLE IF NOT EXISTS soulbah.agents (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id     uuid NOT NULL REFERENCES soulbah.sessions(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role           text NOT NULL CONSTRAINT agents_role_format CHECK (role ~ '^[a-z][a-z0-9_]{0,63}$'),
  role_version   text NOT NULL DEFAULT '1.0.0',
  name           text,
  status         text NOT NULL DEFAULT 'IDLE'
                 CONSTRAINT agents_status_check CHECK (status IN ('IDLE', 'BUSY', 'WAITING', 'STOPPED', 'FAILED')),
  runtime_id     uuid REFERENCES soulbah.runtimes(id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE soulbah.agents ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.agents;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.agents
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
CREATE INDEX IF NOT EXISTS idx_agents_session ON soulbah.agents (session_id, status);
-- Compteur « x/6 » : agents BUSY par utilisateur (§9.6).
CREATE INDEX IF NOT EXISTS idx_agents_busy ON soulbah.agents (user_id) WHERE status = 'BUSY';
