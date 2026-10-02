-- =============================================================================
-- DB LOT 13 — Auto-amélioration contrôlée : candidats, expériences (mode ombre, benchmark, canari), mesures adossées
-- aux exécutions de benchmark, approbations (ajout seul, humaines pour déployer), déploiements avec version précédente
-- et retour arrière — liés aux versions système (db01) et bloqués tant que system_state.self_improvement = OFF.
-- soulbah:rollback=YES
-- soulbah:recovery=20261002111400_db13_self_improvement.down.sql
-- soulbah:transaction=single
-- Dépend de : db01 (system_versions, system_state), db10 (benchmark_runs).
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.improvement_candidates (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key               text NOT NULL UNIQUE CONSTRAINT improvement_candidates_key_format CHECK (key ~ '^[a-z][a-z0-9_.-]{0,119}$'),
  kind              text NOT NULL CONSTRAINT improvement_candidates_kind_check CHECK (kind IN ('prompt', 'skill', 'tool', 'routing', 'config', 'policy', 'model', 'planner', 'code', 'memory', 'other')),
  title             text NOT NULL CONSTRAINT improvement_candidates_title_length CHECK (length(title) BETWEEN 1 AND 300),
  description       text NOT NULL DEFAULT '' CONSTRAINT improvement_candidates_description_length CHECK (length(description) <= 8000),
  rationale         text NOT NULL DEFAULT '' CONSTRAINT improvement_candidates_rationale_length CHECK (length(rationale) <= 8000),
  source            text NOT NULL CONSTRAINT improvement_candidates_source_check CHECK (source IN ('failure_analysis', 'benchmark', 'watchdog', 'peer_review', 'research', 'human', 'shadow_run')),
  target_component  text NOT NULL CONSTRAINT improvement_candidates_component_format CHECK (target_component ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  target_ref        text CONSTRAINT improvement_candidates_target_ref_length CHECK (target_ref IS NULL OR length(target_ref) <= 500),
  evidence          jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT improvement_candidates_evidence_array CHECK (soulbah.is_json_array(evidence)),
  expected_gain     text NOT NULL DEFAULT '' CONSTRAINT improvement_candidates_gain_length CHECK (length(expected_gain) <= 2000),
  risk              text NOT NULL DEFAULT 'MEDIUM' CONSTRAINT improvement_candidates_risk_check CHECK (soulbah.is_severity(risk)),
  proposed_by       text NOT NULL DEFAULT current_user CONSTRAINT improvement_candidates_proposed_by_length CHECK (length(proposed_by) BETWEEN 1 AND 200),
  status            text NOT NULL DEFAULT 'proposed' CONSTRAINT improvement_candidates_status_check CHECK (status IN (
                      'proposed', 'experimenting', 'evaluated', 'approved', 'deployed', 'rolled_back', 'rejected')),
  decided_by        text,
  decided_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT improvement_candidates_decided CHECK (status NOT IN ('approved', 'rejected') OR (decided_by IS NOT NULL AND decided_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.improvement_candidates IS 'Améliorations candidates (prompt, compétence, outil, routage, configuration, politique, modèle, planificateur…) : origine, preuves, gain attendu, risque, décision.';
ALTER TABLE soulbah.improvement_candidates ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.improvement_candidates', '{"key": "text", "kind": "text", "status": "text", "risk": "text"}');
CREATE INDEX IF NOT EXISTS idx_improvement_candidates_status ON soulbah.improvement_candidates (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_improvement_candidates_component ON soulbah.improvement_candidates (target_component);
DROP TRIGGER IF EXISTS improvement_candidates_set_updated_at ON soulbah.improvement_candidates;
CREATE TRIGGER improvement_candidates_set_updated_at BEFORE UPDATE ON soulbah.improvement_candidates FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.improvement_experiments (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id         uuid NOT NULL REFERENCES soulbah.improvement_candidates(id) ON DELETE CASCADE,
  name                 text NOT NULL CONSTRAINT improvement_experiments_name_length CHECK (length(name) BETWEEN 1 AND 200),
  hypothesis           text NOT NULL DEFAULT '' CONSTRAINT improvement_experiments_hypothesis_length CHECK (length(hypothesis) <= 4000),
  method               text NOT NULL CONSTRAINT improvement_experiments_method_check CHECK (method IN ('offline_eval', 'benchmark', 'shadow', 'ab_test', 'canary', 'replay')),
  environment_name     text NOT NULL DEFAULT 'LOCAL' REFERENCES soulbah.environments(name),
  baseline_version_id  uuid REFERENCES soulbah.system_versions(id) ON DELETE SET NULL,
  status               text NOT NULL DEFAULT 'planned' CONSTRAINT improvement_experiments_status_check CHECK (status IN ('planned', 'running', 'completed', 'failed', 'cancelled')),
  result               jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT improvement_experiments_result_object CHECK (soulbah.is_json_object(result)),
  conclusion           text NOT NULL DEFAULT '' CONSTRAINT improvement_experiments_conclusion_length CHECK (length(conclusion) <= 4000),
  created_by           text NOT NULL DEFAULT current_user,
  started_at           timestamptz,
  finished_at          timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT improvement_experiments_unique UNIQUE (candidate_id, name),
  -- Les expériences ne se mènent jamais en production (§ Self-improvement : laboratoire, ombre, benchmarks).
  CONSTRAINT improvement_experiments_not_production CHECK (environment_name <> 'PRODUCTION'),
  CONSTRAINT improvement_experiments_completed_dated CHECK (status <> 'completed' OR finished_at IS NOT NULL)
);
COMMENT ON TABLE soulbah.improvement_experiments IS 'Expériences d''un candidat (évaluation hors ligne, benchmark, ombre, A/B, canari, rejeu) — jamais en PRODUCTION.';
ALTER TABLE soulbah.improvement_experiments ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_improvement_experiments_baseline ON soulbah.improvement_experiments (baseline_version_id);
CREATE INDEX IF NOT EXISTS idx_improvement_experiments_environment ON soulbah.improvement_experiments (environment_name);

CREATE TABLE IF NOT EXISTS soulbah.improvement_benchmarks (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  experiment_id     uuid NOT NULL REFERENCES soulbah.improvement_experiments(id) ON DELETE CASCADE,
  benchmark_run_id  uuid NOT NULL REFERENCES soulbah.benchmark_runs(id) ON DELETE RESTRICT,
  role              text NOT NULL CONSTRAINT improvement_benchmarks_role_check CHECK (role IN ('baseline', 'candidate')),
  score             numeric(10, 4) NOT NULL CONSTRAINT improvement_benchmarks_score_positive CHECK (score >= 0),
  score_max         numeric(10, 4) NOT NULL CONSTRAINT improvement_benchmarks_score_max_positive CHECK (score_max > 0),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT improvement_benchmarks_unique UNIQUE (experiment_id, benchmark_run_id),
  CONSTRAINT improvement_benchmarks_bounded CHECK (score <= score_max)
);
COMMENT ON TABLE soulbah.improvement_benchmarks IS 'Mesures d''une expérience, toujours adossées à une exécution de benchmark (référence ou candidat).';
ALTER TABLE soulbah.improvement_benchmarks ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_improvement_benchmarks_run ON soulbah.improvement_benchmarks (benchmark_run_id);

CREATE TABLE IF NOT EXISTS soulbah.improvement_approvals (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  candidate_id   uuid NOT NULL REFERENCES soulbah.improvement_candidates(id) ON DELETE RESTRICT,
  experiment_id  uuid REFERENCES soulbah.improvement_experiments(id) ON DELETE RESTRICT,
  decision       text NOT NULL CONSTRAINT improvement_approvals_decision_check CHECK (decision IN ('approved', 'rejected', 'deferred', 'revoked')),
  decider_kind   text NOT NULL CONSTRAINT improvement_approvals_decider_kind_check CHECK (decider_kind IN ('human', 'agent', 'system')),
  decided_by     text NOT NULL CONSTRAINT improvement_approvals_decided_by_length CHECK (length(decided_by) BETWEEN 1 AND 200),
  rationale      text NOT NULL DEFAULT '' CONSTRAINT improvement_approvals_rationale_length CHECK (length(rationale) <= 4000),
  conditions     jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT improvement_approvals_conditions_object CHECK (soulbah.is_json_object(conditions)),
  decided_at     timestamptz NOT NULL DEFAULT now(),
  -- Seul un humain approuve ou révoque ; un agent peut rejeter ou différer.
  CONSTRAINT improvement_approvals_human CHECK (decision NOT IN ('approved', 'revoked') OR decider_kind = 'human')
);
COMMENT ON TABLE soulbah.improvement_approvals IS 'Décisions sur un candidat (ajout seul) ; approuver ou révoquer est réservé à un humain.';
ALTER TABLE soulbah.improvement_approvals ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_improvement_approvals_candidate ON soulbah.improvement_approvals (candidate_id, id);
CREATE INDEX IF NOT EXISTS idx_improvement_approvals_experiment ON soulbah.improvement_approvals (experiment_id);
DROP TRIGGER IF EXISTS improvement_approvals_append_only ON soulbah.improvement_approvals;
CREATE TRIGGER improvement_approvals_append_only BEFORE UPDATE OR DELETE ON soulbah.improvement_approvals FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS improvement_approvals_no_truncate ON soulbah.improvement_approvals;
CREATE TRIGGER improvement_approvals_no_truncate BEFORE TRUNCATE ON soulbah.improvement_approvals FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE TABLE IF NOT EXISTS soulbah.improvement_deployments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id      uuid NOT NULL REFERENCES soulbah.improvement_candidates(id) ON DELETE RESTRICT,
  approval_id       bigint NOT NULL REFERENCES soulbah.improvement_approvals(id) ON DELETE RESTRICT,
  environment_name  text NOT NULL REFERENCES soulbah.environments(name),
  component         text NOT NULL CONSTRAINT improvement_deployments_component_format CHECK (component ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  from_version_id   uuid REFERENCES soulbah.system_versions(id) ON DELETE SET NULL,
  to_version_id     uuid NOT NULL REFERENCES soulbah.system_versions(id) ON DELETE RESTRICT,
  status            text NOT NULL DEFAULT 'pending' CONSTRAINT improvement_deployments_status_check CHECK (status IN ('pending', 'deployed', 'verified', 'rolled_back', 'failed')),
  deployed_by       text,
  deployed_at       timestamptz,
  verified_by       text,
  verified_at       timestamptz,
  rolled_back_at    timestamptz,
  rollback_reason   text CONSTRAINT improvement_deployments_rollback_reason_length CHECK (rollback_reason IS NULL OR length(rollback_reason) <= 4000),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT improvement_deployments_versions_differ CHECK (from_version_id IS NULL OR from_version_id <> to_version_id),
  CONSTRAINT improvement_deployments_deployed_signed CHECK (status NOT IN ('deployed', 'verified') OR (deployed_by IS NOT NULL AND deployed_at IS NOT NULL)),
  CONSTRAINT improvement_deployments_verified_signed CHECK (status <> 'verified' OR (verified_by IS NOT NULL AND verified_at IS NOT NULL)),
  CONSTRAINT improvement_deployments_rollback_reasoned CHECK (status <> 'rolled_back' OR (rolled_back_at IS NOT NULL AND rollback_reason IS NOT NULL))
);
COMMENT ON TABLE soulbah.improvement_deployments IS 'Déploiement d''une amélioration approuvée : version précédente conservée (retour arrière), signatures, motif de retour.';
ALTER TABLE soulbah.improvement_deployments ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_improvement_deployments_candidate ON soulbah.improvement_deployments (candidate_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_improvement_deployments_approval ON soulbah.improvement_deployments (approval_id);
CREATE INDEX IF NOT EXISTS idx_improvement_deployments_environment ON soulbah.improvement_deployments (environment_name);
CREATE INDEX IF NOT EXISTS idx_improvement_deployments_from ON soulbah.improvement_deployments (from_version_id);
CREATE INDEX IF NOT EXISTS idx_improvement_deployments_to ON soulbah.improvement_deployments (to_version_id);
DROP TRIGGER IF EXISTS improvement_deployments_set_updated_at ON soulbah.improvement_deployments;
CREATE TRIGGER improvement_deployments_set_updated_at BEFORE UPDATE ON soulbah.improvement_deployments FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- Garde : déployer exige une approbation « approved » non révoquée du même candidat, un candidat approuvé ou déjà
-- déployé, l'auto-amélioration autorisée dans system_state, et jamais PRODUCTION sans production_changes activé.
CREATE OR REPLACE FUNCTION soulbah.improvement_deployments_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
DECLARE st soulbah.system_state%ROWTYPE; ap soulbah.improvement_approvals%ROWTYPE;
BEGIN
  SELECT * INTO ap FROM soulbah.improvement_approvals WHERE id = NEW.approval_id;
  IF ap.candidate_id IS DISTINCT FROM NEW.candidate_id OR ap.decision <> 'approved' THEN
    RAISE EXCEPTION 'soulbah.improvement_deployments : approbation absente, refusée ou d''un autre candidat' USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM soulbah.improvement_approvals r WHERE r.candidate_id = NEW.candidate_id AND r.decision = 'revoked' AND r.id > ap.id) THEN
    RAISE EXCEPTION 'soulbah.improvement_deployments : approbation révoquée' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.status IN ('deployed', 'verified') AND (TG_OP = 'INSERT' OR OLD.status NOT IN ('deployed', 'verified')) THEN
    IF NOT EXISTS (SELECT 1 FROM soulbah.improvement_candidates c WHERE c.id = NEW.candidate_id AND c.status IN ('approved', 'deployed')) THEN
      RAISE EXCEPTION 'soulbah.improvement_deployments : le candidat n''est pas approuvé' USING ERRCODE = 'check_violation';
    END IF;
    SELECT * INTO st FROM soulbah.system_state WHERE id = 1;
    IF st.self_improvement = 'OFF' OR st.safe_mode OR st.emergency_stop THEN
      RAISE EXCEPTION 'soulbah.improvement_deployments : auto-amélioration désactivée (system_state.self_improvement = %, safe_mode = %, emergency_stop = %)',
        st.self_improvement, st.safe_mode, st.emergency_stop USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.environment_name = 'PRODUCTION' AND st.production_changes = 'OFF' THEN
      RAISE EXCEPTION 'soulbah.improvement_deployments : changements de production désactivés (system_state.production_changes = OFF)' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS improvement_deployments_guard ON soulbah.improvement_deployments;
CREATE TRIGGER improvement_deployments_guard BEFORE INSERT OR UPDATE ON soulbah.improvement_deployments FOR EACH ROW EXECUTE FUNCTION soulbah.improvement_deployments_guard();

DO $$
DECLARE r text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['improvement_candidates', 'improvement_experiments', 'improvement_benchmarks', 'improvement_approvals', 'improvement_deployments'] LOOP
    EXECUTE format('REVOKE ALL ON soulbah.%I FROM PUBLIC', t);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON soulbah.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.improvement_deployments_guard() FROM %I', r);
    END IF;
  END LOOP;
END $$;
