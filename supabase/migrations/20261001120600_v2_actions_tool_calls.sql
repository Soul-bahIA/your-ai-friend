-- =============================================================================
-- V2 — 7/12 : actions (états planned → verified, idempotence) et appels d'outils / de
-- modèles (métrage) — audit §9.4, §9.8, §12. public.agent_events reste la télémétrie V1.
-- Idempotente, additive.
-- =============================================================================

-- Une action = une étape d'une tentative. Clé d'idempotence task_id:attempt:step_index (§9.8).
CREATE TABLE IF NOT EXISTS soulbah.actions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id              uuid NOT NULL REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  user_id              uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  attempt              integer NOT NULL CONSTRAINT actions_attempt_positive CHECK (attempt >= 0),
  step_index           integer NOT NULL CONSTRAINT actions_step_positive CHECK (step_index >= 0),
  -- Outil du catalogue (shared/tools/catalog.json) et paramètres (secrets déjà masqués).
  tool                 text NOT NULL CONSTRAINT actions_tool_format CHECK (tool ~ '^[a-z][a-z0-9_]{0,39}$'),
  params               jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT actions_params_object CHECK (soulbah.is_json_object(params)),
  security_level       text NOT NULL DEFAULT 'L1' CONSTRAINT actions_level_check CHECK (soulbah.is_security_level(security_level)),
  status               text NOT NULL DEFAULT 'planned'
                       CONSTRAINT actions_status_check CHECK (status IN
                         ('planned', 'attempted', 'executed', 'verified', 'failed', 'skipped', 'simulated')),
  -- Preuves typées (§9.8) : [{"kind":"exit_code","confidence":"high","value":0,"artifact_id":…}].
  evidence             jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT actions_evidence_array CHECK (soulbah.is_json_array(evidence)),
  evidence_confidence  text CONSTRAINT actions_confidence_check CHECK (evidence_confidence IS NULL OR evidence_confidence IN ('high', 'medium', 'low', 'none')),
  simulated            boolean NOT NULL DEFAULT false,
  error                text,
  started_at           timestamptz,
  finished_at          timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT actions_idempotency UNIQUE (task_id, attempt, step_index),
  -- Un dry-run ne devient jamais « vérifié » (§9.4 états d'une action).
  CONSTRAINT actions_simulated_never_verified CHECK (NOT (simulated AND status = 'verified')),
  CONSTRAINT actions_simulated_status CHECK (status <> 'simulated' OR simulated)
);
ALTER TABLE soulbah.actions ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.actions;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.actions
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
CREATE INDEX IF NOT EXISTS idx_actions_task ON soulbah.actions (task_id, attempt, step_index);

-- Métrage de chaque appel d'outil (exit_code) ou de modèle (jetons, coût, fournisseur) :
-- alimenté par node-api à partir de l'en-tête x-llm-usage de python-ia (LOT 5) et des
-- rapports d'actions du runtime (LOT 9).
CREATE TABLE IF NOT EXISTS soulbah.tool_calls (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  session_id      uuid REFERENCES soulbah.sessions(id) ON DELETE SET NULL,
  task_id         uuid REFERENCES soulbah.tasks(id) ON DELETE SET NULL,
  action_id       uuid REFERENCES soulbah.actions(id) ON DELETE SET NULL,
  kind            text NOT NULL CONSTRAINT tool_calls_kind_check CHECK (kind IN ('tool', 'model')),
  -- Outil (nom du catalogue) ou rôle/tâche du modèle (planner, evaluator, vision, chat…).
  name            text NOT NULL CONSTRAINT tool_calls_name_length CHECK (length(name) BETWEEN 1 AND 120),
  provider        text,
  model           text,
  status          text NOT NULL DEFAULT 'ok' CONSTRAINT tool_calls_status_check CHECK (status IN ('ok', 'error', 'timeout', 'refused')),
  exit_code       integer,
  http_status     integer CONSTRAINT tool_calls_http_status_range CHECK (http_status IS NULL OR http_status BETWEEN 100 AND 599),
  input_tokens    integer CONSTRAINT tool_calls_in_positive CHECK (input_tokens IS NULL OR input_tokens >= 0),
  output_tokens   integer CONSTRAINT tool_calls_out_positive CHECK (output_tokens IS NULL OR output_tokens >= 0),
  cost_usd        numeric(12, 6) CONSTRAINT tool_calls_cost_positive CHECK (cost_usd IS NULL OR cost_usd >= 0),
  latency_ms      integer CONSTRAINT tool_calls_latency_positive CHECK (latency_ms IS NULL OR latency_ms >= 0),
  error           text,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT tool_calls_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE soulbah.tool_calls ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_tool_calls_session ON soulbah.tool_calls (session_id, created_at) WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tool_calls_task ON soulbah.tool_calls (task_id, created_at) WHERE task_id IS NOT NULL;
-- Budgets : coût par utilisateur et par jour (LOT 5 / LOT 6).
CREATE INDEX IF NOT EXISTS idx_tool_calls_user_day ON soulbah.tool_calls (user_id, created_at) WHERE kind = 'model';
