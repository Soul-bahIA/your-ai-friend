-- =============================================================================
-- V2 — 2/12 : réglages utilisateur et sessions (missions) — audit §9.4, §9.6, §12.
-- Idempotente, additive.
-- =============================================================================

-- Réglages par utilisateur (page Paramètres). max_parallel_agents : CHECK 1–32 (§9.6).
CREATE TABLE IF NOT EXISTS soulbah.user_settings (
  user_id              uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  max_parallel_agents  integer NOT NULL DEFAULT 6
                       CONSTRAINT user_settings_max_parallel_range CHECK (max_parallel_agents BETWEEN 1 AND 32),
  -- Plafond de niveau de sécurité autorisé sans approbation par action (L0–L3).
  max_security_level   text NOT NULL DEFAULT 'L2'
                       CONSTRAINT user_settings_level_check CHECK (soulbah.is_security_level(max_security_level)),
  -- Budget quotidien (USD) des appels de modèles ; NULL = illimité.
  daily_budget_usd     numeric(12, 4) CONSTRAINT user_settings_budget_positive CHECK (daily_budget_usd IS NULL OR daily_budget_usd >= 0),
  settings             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT user_settings_settings_object CHECK (soulbah.is_json_object(settings)),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE soulbah.user_settings ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.user_settings;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.user_settings
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- Sessions : une mission = un objectif, un plan (DAG) versionné, un cycle
-- DRAFT → PLANNING → AWAITING_APPROVAL → RUNNING/PAUSED → COMPLETED | FAILED | CANCELLED (§9.3).
CREATE TABLE IF NOT EXISTS soulbah.sessions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  goal                 text NOT NULL CONSTRAINT sessions_goal_length CHECK (length(goal) BETWEEN 1 AND 4000),
  status               text NOT NULL DEFAULT 'DRAFT'
                       CONSTRAINT sessions_status_check CHECK (status IN
                         ('DRAFT', 'PLANNING', 'AWAITING_APPROVAL', 'RUNNING', 'PAUSED', 'COMPLETED', 'FAILED', 'CANCELLED')),
  -- Environnement d'exécution (PC ciblé, workspace, variables non secrètes…).
  environment          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT sessions_environment_object CHECK (soulbah.is_json_object(environment)),
  max_security_level   text NOT NULL DEFAULT 'L2'
                       CONSTRAINT sessions_level_check CHECK (soulbah.is_security_level(max_security_level)),
  -- Surcharge par mission du parallélisme (NULL = réglage utilisateur / global).
  max_parallel_agents  integer CONSTRAINT sessions_max_parallel_range CHECK (max_parallel_agents IS NULL OR max_parallel_agents BETWEEN 1 AND 32),
  budget_usd           numeric(12, 4) CONSTRAINT sessions_budget_positive CHECK (budget_usd IS NULL OR budget_usd >= 0),
  spent_usd            numeric(12, 4) NOT NULL DEFAULT 0 CONSTRAINT sessions_spent_positive CHECK (spent_usd >= 0),
  plan                 jsonb,
  plan_version         integer NOT NULL DEFAULT 0 CONSTRAINT sessions_plan_version_positive CHECK (plan_version >= 0),
  -- Session simulée (dry-run) : n'écrit jamais de mémoire, jamais COMPLETED « pour de vrai » (§9.8).
  simulated            boolean NOT NULL DEFAULT false,
  error                text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  started_at           timestamptz,
  finished_at          timestamptz
);
ALTER TABLE soulbah.sessions ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.sessions;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.sessions
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
CREATE INDEX IF NOT EXISTS idx_sessions_user_status ON soulbah.sessions (user_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_active ON soulbah.sessions (status)
  WHERE status IN ('PLANNING', 'AWAITING_APPROVAL', 'RUNNING', 'PAUSED');
