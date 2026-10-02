-- =============================================================================
-- DB LOT 12 — Missions, checkpoints, contexte, contrôle de l'ordinateur.
-- REUSE + EXTEND : soulbah.sessions (= missions), soulbah.tasks, soulbah.checkpoints ; NEW : session_checkpoints,
-- context_builds / context_sources / context_items / context_metrics, computer_sessions / computer_observations /
-- computer_permissions ; vue computer_actions sur soulbah.actions (outils bureau, écran, clavier, souris, téléphone).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002111300_db12_missions_checkpoints.down.sql (les colonnes ajoutées aux tables V2 sont retirées)
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03, db09 (tools), db10 (model_versions).
-- =============================================================================

-- 1. Missions = sessions V2, étendues ----------------------------------------------------------------------------
SELECT soulbah.assert_table_shape('soulbah.sessions', '{"goal": "text", "status": "text", "plan": "jsonb", "simulated": "boolean"}');
ALTER TABLE soulbah.sessions
  ADD COLUMN IF NOT EXISTS project_id         uuid REFERENCES soulbah.projects(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS environment_name   text REFERENCES soulbah.environments(name),
  ADD COLUMN IF NOT EXISTS autonomy_level     text,
  ADD COLUMN IF NOT EXISTS mission_kind       text NOT NULL DEFAULT 'order',
  ADD COLUMN IF NOT EXISTS parent_session_id  uuid REFERENCES soulbah.sessions(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS result             text,
  ADD COLUMN IF NOT EXISTS result_summary     text NOT NULL DEFAULT '';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sessions_autonomy_level_check') THEN
    ALTER TABLE soulbah.sessions ADD CONSTRAINT sessions_autonomy_level_check CHECK (autonomy_level IS NULL OR soulbah.is_autonomy_level(autonomy_level));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sessions_mission_kind_check') THEN
    ALTER TABLE soulbah.sessions ADD CONSTRAINT sessions_mission_kind_check
      CHECK (mission_kind IN ('order', 'maintenance', 'research', 'security', 'migration', 'improvement', 'computer_control', 'other'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sessions_result_check') THEN
    ALTER TABLE soulbah.sessions ADD CONSTRAINT sessions_result_check CHECK (result IS NULL OR result IN ('success', 'partial', 'failure', 'cancelled'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sessions_result_summary_length') THEN
    ALTER TABLE soulbah.sessions ADD CONSTRAINT sessions_result_summary_length CHECK (length(result_summary) <= 8000);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sessions_not_own_parent') THEN
    ALTER TABLE soulbah.sessions ADD CONSTRAINT sessions_not_own_parent CHECK (parent_session_id IS NULL OR parent_session_id <> id);
  END IF;
  -- Une mission terminée porte un résultat ; une mission simulée n'est jamais un succès (§9.8).
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sessions_completed_has_result') THEN
    ALTER TABLE soulbah.sessions ADD CONSTRAINT sessions_completed_has_result CHECK (status NOT IN ('COMPLETED', 'FAILED', 'CANCELLED') OR result IS NOT NULL) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sessions_simulated_never_success') THEN
    ALTER TABLE soulbah.sessions ADD CONSTRAINT sessions_simulated_never_success CHECK (NOT (simulated AND result = 'success'));
  END IF;
END $$;
COMMENT ON COLUMN soulbah.sessions.result IS 'Résultat de la mission une fois terminée (success, partial, failure, cancelled) ; contrainte NOT VALID sur l''existant : les sessions terminées avant ce lot n''ont pas de résultat.';
CREATE INDEX IF NOT EXISTS idx_sessions_project ON soulbah.sessions (project_id, created_at DESC) WHERE project_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sessions_environment ON soulbah.sessions (environment_name) WHERE environment_name IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sessions_parent ON soulbah.sessions (parent_session_id) WHERE parent_session_id IS NOT NULL;
-- Résultat par défaut des sessions déjà terminées sans résultat : déduit du statut, jamais « success » (pas de preuve).
UPDATE soulbah.sessions SET result = CASE status WHEN 'FAILED' THEN 'failure' WHEN 'CANCELLED' THEN 'cancelled' ELSE 'partial' END,
                            result_summary = 'Résultat déduit du statut lors du DB LOT 12 (session terminée avant la tenue des résultats).'
 WHERE status IN ('COMPLETED', 'FAILED', 'CANCELLED') AND result IS NULL;
ALTER TABLE soulbah.sessions VALIDATE CONSTRAINT sessions_completed_has_result;

-- Les sessions COMPLETED / FAILED / CANCELLED héritent du résultat ; node-api posera result à l'avenir.
CREATE OR REPLACE FUNCTION soulbah.sessions_default_result()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.status IN ('COMPLETED', 'FAILED', 'CANCELLED') AND NEW.result IS NULL THEN
    NEW.result := CASE NEW.status WHEN 'FAILED' THEN 'failure' WHEN 'CANCELLED' THEN 'cancelled' WHEN 'COMPLETED' THEN CASE WHEN NEW.simulated THEN 'partial' ELSE 'success' END END;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS sessions_default_result ON soulbah.sessions;
CREATE TRIGGER sessions_default_result BEFORE INSERT OR UPDATE OF status ON soulbah.sessions FOR EACH ROW EXECUTE FUNCTION soulbah.sessions_default_result();

SELECT soulbah.assert_table_shape('soulbah.tasks', '{"session_id": "uuid", "status": "text", "spec": "jsonb"}');
ALTER TABLE soulbah.tasks ADD COLUMN IF NOT EXISTS project_id uuid REFERENCES soulbah.projects(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_project ON soulbah.tasks (project_id) WHERE project_id IS NOT NULL;

-- 2. Checkpoints (§61-62) --------------------------------------------------------------------------------------
SELECT soulbah.assert_table_shape('soulbah.checkpoints', '{"task_id": "uuid", "attempt": "integer", "seq": "integer", "step_cursor": "integer"}');
ALTER TABLE soulbah.checkpoints
  ADD COLUMN IF NOT EXISTS label              text,
  ADD COLUMN IF NOT EXISTS kind               text NOT NULL DEFAULT 'step',
  ADD COLUMN IF NOT EXISTS state_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS resumable          boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS created_by         text NOT NULL DEFAULT current_user;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'checkpoints_kind_check') THEN
    ALTER TABLE soulbah.checkpoints ADD CONSTRAINT checkpoints_kind_check CHECK (kind IN ('step', 'milestone', 'before_risky_action', 'after_risky_action', 'manual'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'checkpoints_label_length') THEN
    ALTER TABLE soulbah.checkpoints ADD CONSTRAINT checkpoints_label_length CHECK (label IS NULL OR length(label) <= 300);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_checkpoints_state_artifact ON soulbah.checkpoints (state_artifact_id);

CREATE TABLE IF NOT EXISTS soulbah.session_checkpoints (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id         uuid NOT NULL REFERENCES soulbah.sessions(id) ON DELETE CASCADE,
  seq                integer NOT NULL CONSTRAINT session_checkpoints_seq_positive CHECK (seq >= 0),
  label              text NOT NULL DEFAULT '' CONSTRAINT session_checkpoints_label_length CHECK (length(label) <= 300),
  kind               text NOT NULL DEFAULT 'milestone' CONSTRAINT session_checkpoints_kind_check CHECK (kind IN ('milestone', 'before_risky_action', 'after_risky_action', 'pause', 'manual')),
  plan_version       integer CONSTRAINT session_checkpoints_plan_version_positive CHECK (plan_version IS NULL OR plan_version >= 0),
  state              jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT session_checkpoints_state_object CHECK (soulbah.is_json_object(state)),
  state_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  resumable          boolean NOT NULL DEFAULT true,
  created_by         text NOT NULL DEFAULT current_user,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT session_checkpoints_unique UNIQUE (session_id, seq)
);
COMMENT ON TABLE soulbah.session_checkpoints IS 'État d''une mission entre deux tâches (tâches faites, variables, version du plan) pour reprendre là où elle s''est arrêtée ; l''état volumineux va en artefact.';
ALTER TABLE soulbah.session_checkpoints ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_session_checkpoints_artifact ON soulbah.session_checkpoints (state_artifact_id);

-- 3. Contexte (§67-69 : ce qu'un agent a reçu, d'où, à quel coût) ----------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.context_builds (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id           uuid REFERENCES soulbah.sessions(id) ON DELETE CASCADE,
  task_id              uuid REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  agent_definition_id  uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  model_version_id     uuid REFERENCES soulbah.model_versions(id) ON DELETE SET NULL,
  purpose              text NOT NULL DEFAULT '' CONSTRAINT context_builds_purpose_length CHECK (length(purpose) <= 1000),
  strategy             text NOT NULL DEFAULT 'default' CONSTRAINT context_builds_strategy_length CHECK (length(strategy) BETWEEN 1 AND 60),
  token_budget         integer CONSTRAINT context_builds_budget_positive CHECK (token_budget IS NULL OR token_budget >= 0),
  tokens_used          integer CONSTRAINT context_builds_used_positive CHECK (tokens_used IS NULL OR tokens_used >= 0),
  status               text NOT NULL DEFAULT 'built' CONSTRAINT context_builds_status_check CHECK (status IN ('built', 'truncated', 'failed')),
  duration_ms          integer CONSTRAINT context_builds_duration_positive CHECK (duration_ms IS NULL OR duration_ms >= 0),
  built_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT context_builds_scope CHECK (session_id IS NOT NULL OR task_id IS NOT NULL)
);
COMMENT ON TABLE soulbah.context_builds IS 'Construction du contexte d''un appel de modèle : budget et jetons consommés, stratégie, troncature.';
ALTER TABLE soulbah.context_builds ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_context_builds_session ON soulbah.context_builds (session_id, built_at DESC);
CREATE INDEX IF NOT EXISTS idx_context_builds_task ON soulbah.context_builds (task_id);
CREATE INDEX IF NOT EXISTS idx_context_builds_agent ON soulbah.context_builds (agent_definition_id);
CREATE INDEX IF NOT EXISTS idx_context_builds_model ON soulbah.context_builds (model_version_id);

CREATE TABLE IF NOT EXISTS soulbah.context_sources (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  build_id    uuid NOT NULL REFERENCES soulbah.context_builds(id) ON DELETE CASCADE,
  kind        text NOT NULL CONSTRAINT context_sources_kind_check CHECK (kind IN (
                'memory_item', 'knowledge_chunk', 'code_file', 'code_symbol', 'project_brain_document', 'db_table', 'api_endpoint', 'user_flow',
                'incident', 'security_pattern', 'skill', 'tool', 'message', 'artifact', 'task_result', 'policy', 'other')),
  source_id   uuid,
  source_ref  text CONSTRAINT context_sources_ref_length CHECK (source_ref IS NULL OR length(source_ref) <= 500),
  score       real CONSTRAINT context_sources_score_range CHECK (score IS NULL OR (score >= 0 AND score <= 1)),
  tokens      integer CONSTRAINT context_sources_tokens_positive CHECK (tokens IS NULL OR tokens >= 0),
  included    boolean NOT NULL DEFAULT true,
  reason      text NOT NULL DEFAULT '' CONSTRAINT context_sources_reason_length CHECK (length(reason) <= 500),
  position    integer CONSTRAINT context_sources_position_positive CHECK (position IS NULL OR position >= 0),
  CONSTRAINT context_sources_target CHECK (source_id IS NOT NULL OR source_ref IS NOT NULL)
);
COMMENT ON TABLE soulbah.context_sources IS 'Sources candidates d''un contexte (mémoire, connaissance, code, cerveau projet, base, API…) : score, jetons, retenue ou non, raison.';
ALTER TABLE soulbah.context_sources ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_context_sources_build ON soulbah.context_sources (build_id, included);
CREATE INDEX IF NOT EXISTS idx_context_sources_source ON soulbah.context_sources (kind, source_id);

CREATE TABLE IF NOT EXISTS soulbah.context_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  build_id      uuid NOT NULL REFERENCES soulbah.context_builds(id) ON DELETE CASCADE,
  position      integer NOT NULL CONSTRAINT context_items_position_positive CHECK (position >= 0),
  role          text NOT NULL CONSTRAINT context_items_role_check CHECK (role IN ('system', 'user', 'assistant', 'tool')),
  kind          text NOT NULL DEFAULT 'text' CONSTRAINT context_items_kind_length CHECK (length(kind) BETWEEN 1 AND 40),
  tokens        integer CONSTRAINT context_items_tokens_positive CHECK (tokens IS NULL OR tokens >= 0),
  content_hash  text CONSTRAINT context_items_hash_format CHECK (content_hash IS NULL OR content_hash ~ '^[0-9a-f]{64}$'),
  source_id     uuid REFERENCES soulbah.context_sources(id) ON DELETE SET NULL,
  redacted      boolean NOT NULL DEFAULT false,
  CONSTRAINT context_items_unique UNIQUE (build_id, position)
);
COMMENT ON TABLE soulbah.context_items IS 'Éléments effectivement envoyés (rôle, jetons, empreinte du contenu, source) — le contenu lui-même n''est pas dupliqué ici.';
ALTER TABLE soulbah.context_items ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_context_items_source ON soulbah.context_items (source_id);

CREATE TABLE IF NOT EXISTS soulbah.context_metrics (
  build_id            uuid PRIMARY KEY REFERENCES soulbah.context_builds(id) ON DELETE CASCADE,
  candidates          integer NOT NULL DEFAULT 0 CONSTRAINT context_metrics_candidates_positive CHECK (candidates >= 0),
  included            integer NOT NULL DEFAULT 0 CONSTRAINT context_metrics_included_positive CHECK (included >= 0),
  duplicates_removed  integer NOT NULL DEFAULT 0 CONSTRAINT context_metrics_duplicates_positive CHECK (duplicates_removed >= 0),
  secrets_redacted    integer NOT NULL DEFAULT 0 CONSTRAINT context_metrics_secrets_positive CHECK (secrets_redacted >= 0),
  truncation_ratio    real CONSTRAINT context_metrics_truncation_range CHECK (truncation_ratio IS NULL OR (truncation_ratio >= 0 AND truncation_ratio <= 1)),
  relevance_estimate  real CONSTRAINT context_metrics_relevance_range CHECK (relevance_estimate IS NULL OR (relevance_estimate >= 0 AND relevance_estimate <= 1)),
  outcome             text NOT NULL DEFAULT 'unknown' CONSTRAINT context_metrics_outcome_check CHECK (outcome IN ('unknown', 'useful', 'insufficient', 'noisy')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT context_metrics_included_bounded CHECK (included <= candidates)
);
COMMENT ON TABLE soulbah.context_metrics IS 'Mesures d''une construction de contexte (candidats, retenus, doublons, secrets masqués, troncature) et utilité constatée a posteriori.';
ALTER TABLE soulbah.context_metrics ENABLE ROW LEVEL SECURITY;

-- 4. Contrôle de l'ordinateur et du téléphone (§63-66) ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.computer_sessions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id        uuid REFERENCES soulbah.sessions(id) ON DELETE SET NULL,
  task_id           uuid REFERENCES soulbah.tasks(id) ON DELETE SET NULL,
  runtime_id        uuid REFERENCES soulbah.runtimes(id) ON DELETE SET NULL,
  kind              text NOT NULL CONSTRAINT computer_sessions_kind_check CHECK (kind IN ('desktop', 'phone', 'browser', 'terminal')),
  device_ref        text CONSTRAINT computer_sessions_device_length CHECK (device_ref IS NULL OR length(device_ref) <= 200),
  status            text NOT NULL DEFAULT 'active' CONSTRAINT computer_sessions_status_check CHECK (status IN ('active', 'paused', 'ended', 'aborted')),
  started_by        text NOT NULL DEFAULT current_user,
  started_at        timestamptz NOT NULL DEFAULT now(),
  ended_at          timestamptz,
  recording_id      uuid REFERENCES soulbah.recordings(id) ON DELETE SET NULL,
  actions_count     integer NOT NULL DEFAULT 0 CONSTRAINT computer_sessions_actions_positive CHECK (actions_count >= 0),
  summary           text NOT NULL DEFAULT '' CONSTRAINT computer_sessions_summary_length CHECK (length(summary) <= 4000),
  CONSTRAINT computer_sessions_ended_dated CHECK (status NOT IN ('ended', 'aborted') OR ended_at IS NOT NULL)
);
COMMENT ON TABLE soulbah.computer_sessions IS 'Sessions de contrôle d''un bureau, d''un téléphone, d''un navigateur ou d''un terminal : qui, quand, enregistrement vidéo lié.';
ALTER TABLE soulbah.computer_sessions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_computer_sessions_session ON soulbah.computer_sessions (session_id);
CREATE INDEX IF NOT EXISTS idx_computer_sessions_task ON soulbah.computer_sessions (task_id);
CREATE INDEX IF NOT EXISTS idx_computer_sessions_runtime ON soulbah.computer_sessions (runtime_id);
CREATE INDEX IF NOT EXISTS idx_computer_sessions_recording ON soulbah.computer_sessions (recording_id);
CREATE INDEX IF NOT EXISTS idx_computer_sessions_active ON soulbah.computer_sessions (started_at DESC) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS soulbah.computer_permissions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  computer_session_id  uuid NOT NULL REFERENCES soulbah.computer_sessions(id) ON DELETE CASCADE,
  scope                text NOT NULL CONSTRAINT computer_permissions_scope_check CHECK (scope IN (
                         'screen_read', 'input', 'clipboard', 'files', 'apps', 'network', 'phone_tap', 'phone_calls', 'sms', 'payments', 'credentials')),
  decision             text NOT NULL CONSTRAINT computer_permissions_decision_check CHECK (decision IN ('allow', 'deny')),
  granted_by           text,
  granted_at           timestamptz,
  expires_at           timestamptz,
  revoked_at           timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT computer_permissions_unique UNIQUE (computer_session_id, scope),
  CONSTRAINT computer_permissions_allow_signed CHECK (decision <> 'allow' OR (granted_by IS NOT NULL AND granted_at IS NOT NULL)),
  -- Appels, SMS, paiements et identifiants : jamais sans autorisation humaine explicite (§64-65).
  CONSTRAINT computer_permissions_sensitive_human CHECK (decision <> 'allow' OR scope NOT IN ('phone_calls', 'sms', 'payments', 'credentials') OR granted_by LIKE 'user:%')
);
COMMENT ON TABLE soulbah.computer_permissions IS 'Permissions d''une session de contrôle par périmètre ; les périmètres sensibles (appels, SMS, paiements, identifiants) exigent un humain.';
ALTER TABLE soulbah.computer_permissions ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.computer_observations (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  computer_session_id  uuid NOT NULL REFERENCES soulbah.computer_sessions(id) ON DELETE CASCADE,
  action_id            uuid REFERENCES soulbah.actions(id) ON DELETE SET NULL,
  kind                 text NOT NULL CONSTRAINT computer_observations_kind_check CHECK (kind IN (
                         'screenshot', 'ocr', 'ui_snapshot', 'window_list', 'clipboard', 'file_list', 'log', 'audio', 'phone_screen', 'other')),
  artifact_id          uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  sensitivity          text NOT NULL DEFAULT 'none' CONSTRAINT computer_observations_sensitivity_check CHECK (sensitivity IN ('none', 'internal', 'pii', 'credentials', 'financial', 'health')),
  retention_class      text NOT NULL DEFAULT 'task' CONSTRAINT computer_observations_retention_check CHECK (retention_class IN ('ephemeral', 'task', 'session', 'permanent')),
  redacted             boolean NOT NULL DEFAULT false,
  summary              text NOT NULL DEFAULT '' CONSTRAINT computer_observations_summary_length CHECK (length(summary) <= 2000),
  metadata             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT computer_observations_metadata_object CHECK (soulbah.is_json_object(metadata)),
  observed_at          timestamptz NOT NULL DEFAULT now(),
  -- Observations sensibles : rétention éphémère obligatoire (§65 : mots de passe, jetons, banque, données personnelles).
  CONSTRAINT computer_observations_sensitive_retention CHECK (sensitivity IN ('none', 'internal') OR retention_class = 'ephemeral')
);
COMMENT ON TABLE soulbah.computer_observations IS 'Ce que Soulbah a vu (captures, OCR, arbre d''interface, presse-papiers…) : artefact, sensibilité, rétention stricte si sensible.';
ALTER TABLE soulbah.computer_observations ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_computer_observations_session ON soulbah.computer_observations (computer_session_id, observed_at);
CREATE INDEX IF NOT EXISTS idx_computer_observations_action ON soulbah.computer_observations (action_id);
CREATE INDEX IF NOT EXISTS idx_computer_observations_artifact ON soulbah.computer_observations (artifact_id);
CREATE INDEX IF NOT EXISTS idx_computer_observations_sensitive ON soulbah.computer_observations (observed_at) WHERE sensitivity NOT IN ('none', 'internal');

-- Vue : actions de contrôle (outils des catégories bureau et téléphone du registre, synchronisé depuis shared/tools/catalog.json).
CREATE OR REPLACE VIEW soulbah.computer_actions AS
  SELECT a.id, a.task_id, a.user_id, a.attempt, a.step_index, a.tool, t.category AS tool_category, a.params, a.security_level, a.status,
         a.evidence, a.evidence_confidence, a.simulated, a.error, a.started_at, a.finished_at, a.created_at
    FROM soulbah.actions a JOIN soulbah.tools t ON t.name = a.tool
   WHERE t.category IN ('mouse', 'keyboard', 'screen', 'window', 'app_launch', 'phone', 'video', 'voice');
COMMENT ON VIEW soulbah.computer_actions IS 'Actions de contrôle de l''ordinateur ou du téléphone (vue sur soulbah.actions filtrée par la catégorie de l''outil).';

-- 5. Droits ------------------------------------------------------------------------------------------------------
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['session_checkpoints', 'context_builds', 'context_sources', 'context_items', 'context_metrics', 'computer_sessions',
                           'computer_permissions', 'computer_observations', 'computer_actions'] LOOP
    EXECUTE format('REVOKE ALL ON soulbah.%I FROM PUBLIC', t);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON soulbah.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.sessions_default_result() FROM %I', r);
    END IF;
  END LOOP;
END $$;
