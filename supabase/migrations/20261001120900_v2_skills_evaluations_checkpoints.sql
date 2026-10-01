-- =============================================================================
-- V2 — 10/12 : skills versionnées, évaluations, checkpoints — audit §9.8, §9.9, §12.
-- Idempotente, additive.
-- =============================================================================

-- Skills : alimentée par le catalogue (shared/tools/catalog.json, LOT 2) et par les
-- procédures apprises (LOT 10). UNIQUE(name, version).
CREATE TABLE IF NOT EXISTS soulbah.skills (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text NOT NULL CONSTRAINT skills_name_format CHECK (name ~ '^[a-z][a-z0-9_]{0,39}$'),
  version         text NOT NULL CONSTRAINT skills_version_semver CHECK (version ~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'),
  -- catalog : outil du catalogue ; learned : procédure proposée (LOT 10/12, jamais promue sans approbation L3).
  source          text NOT NULL DEFAULT 'catalog' CONSTRAINT skills_source_check CHECK (source IN ('catalog', 'learned')),
  status          text NOT NULL DEFAULT 'active' CONSTRAINT skills_status_check CHECK (status IN ('proposed', 'active', 'deprecated', 'rejected')),
  security_level  text NOT NULL DEFAULT 'L1' CONSTRAINT skills_level_check CHECK (soulbah.is_security_level(security_level)),
  schema          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT skills_schema_object CHECK (soulbah.is_json_object(schema)),
  procedure       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT skills_procedure_object CHECK (soulbah.is_json_object(procedure)),
  permissions     jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT skills_permissions_object CHECK (soulbah.is_json_object(permissions)),
  examples        jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skills_examples_array CHECK (soulbah.is_json_array(examples)),
  known_errors    jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skills_known_errors_array CHECK (soulbah.is_json_array(known_errors)),
  tests           jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skills_tests_array CHECK (soulbah.is_json_array(tests)),
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skills_name_version UNIQUE (name, version)
);
ALTER TABLE soulbah.skills ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.skills;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.skills
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
CREATE INDEX IF NOT EXISTS idx_skills_status ON soulbah.skills (status, name);

-- Évaluations : résultat de la phase VALIDATING d'une tentative (critères DSL, preuves, verdict).
CREATE TABLE IF NOT EXISTS soulbah.evaluations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id         uuid NOT NULL REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  attempt         integer NOT NULL CONSTRAINT evaluations_attempt_positive CHECK (attempt >= 0),
  criteria        jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT evaluations_criteria_array CHECK (soulbah.is_json_array(criteria)),
  results         jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT evaluations_results_array CHECK (soulbah.is_json_array(results)),
  verdict         text NOT NULL CONSTRAINT evaluations_verdict_check CHECK (verdict IN ('success', 'partial', 'failure', 'abort', 'not_evaluable')),
  confidence      text NOT NULL DEFAULT 'none' CONSTRAINT evaluations_confidence_check CHECK (confidence IN ('high', 'medium', 'low', 'none')),
  evidence_ids    jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT evaluations_evidence_array CHECK (soulbah.is_json_array(evidence_ids)),
  -- Ce que le plan de contrôle a fait du verdict (contrat LOT 1 : action_taken).
  action_taken    text,
  evaluator       text NOT NULL DEFAULT 'rules' CONSTRAINT evaluations_evaluator_check CHECK (evaluator IN ('rules', 'llm', 'qa_reviewer', 'user')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  -- Une seule évaluation par tentative (VALIDATING durable, LOT 10).
  CONSTRAINT evaluations_once_per_attempt UNIQUE (task_id, attempt)
);
ALTER TABLE soulbah.evaluations ENABLE ROW LEVEL SECURITY;

-- Checkpoints : reprise depuis la dernière étape (§9.9) — curseur et variables d'une tentative.
CREATE TABLE IF NOT EXISTS soulbah.checkpoints (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id         uuid NOT NULL REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  attempt         integer NOT NULL CONSTRAINT checkpoints_attempt_positive CHECK (attempt >= 0),
  seq             integer NOT NULL CONSTRAINT checkpoints_seq_positive CHECK (seq >= 0),
  step_cursor     integer NOT NULL DEFAULT 0 CONSTRAINT checkpoints_cursor_positive CHECK (step_cursor >= 0),
  variables       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT checkpoints_variables_object CHECK (soulbah.is_json_object(variables)),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT checkpoints_unique UNIQUE (task_id, attempt, seq)
);
ALTER TABLE soulbah.checkpoints ENABLE ROW LEVEL SECURITY;
