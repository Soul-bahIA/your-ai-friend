-- =============================================================================
-- DB LOT 11 — Sécurité et Digital Immune System : motifs (sécurité et bugs), constats, incidents (toutes natures,
-- vue security_incidents), événements / actions / preuves / décisions / étapes de reprise, correctifs, tests de
-- régression, règles de détection, vues SOC, vue audit_events sur soulbah.audit_logs.
-- soulbah:rollback=YES
-- soulbah:recovery=20261002111200_db11_security_immune.down.sql (les constats et incidents enregistrés seraient perdus)
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03 (agent_quarantines), db07 (project_commits.incident_id).
-- =============================================================================

-- 1. Motifs ----------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.security_patterns (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key                text NOT NULL UNIQUE CONSTRAINT security_patterns_key_format CHECK (key ~ '^[a-z][a-z0-9_.-]{0,119}$'),
  pattern_kind       text NOT NULL CONSTRAINT security_patterns_kind_check CHECK (pattern_kind IN ('security', 'bug')),
  category           text NOT NULL CONSTRAINT security_patterns_category_check CHECK (category IN (
                       'injection', 'auth', 'authorization', 'rls', 'secrets', 'input_validation', 'race', 'data_loss', 'config',
                       'dependency', 'performance', 'logic', 'resource_leak', 'error_handling', 'concurrency', 'crypto', 'other')),
  title              text NOT NULL CONSTRAINT security_patterns_title_length CHECK (length(title) BETWEEN 1 AND 300),
  signature          text NOT NULL DEFAULT '' CONSTRAINT security_patterns_signature_length CHECK (length(signature) <= 4000),
  conditions         jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT security_patterns_conditions_object CHECK (soulbah.is_json_object(conditions)),
  root_cause         text NOT NULL DEFAULT '' CONSTRAINT security_patterns_root_cause_length CHECK (length(root_cause) <= 4000),
  fix_strategy       text NOT NULL DEFAULT '' CONSTRAINT security_patterns_fix_length CHECK (length(fix_strategy) <= 4000),
  test_strategy      text NOT NULL DEFAULT '' CONSTRAINT security_patterns_test_length CHECK (length(test_strategy) <= 4000),
  severity           text NOT NULL DEFAULT 'MEDIUM' CONSTRAINT security_patterns_severity_check CHECK (soulbah.is_severity(severity)),
  projects_affected  jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT security_patterns_projects_array CHECK (soulbah.is_json_array(projects_affected)),
  occurrences        integer NOT NULL DEFAULT 0 CONSTRAINT security_patterns_occurrences_positive CHECK (occurrences >= 0),
  first_seen_at      timestamptz,
  last_seen_at       timestamptz,
  source             text NOT NULL DEFAULT 'human' CONSTRAINT security_patterns_source_check CHECK (source IN ('human', 'learned', 'research', 'imported')),
  status             text NOT NULL DEFAULT 'draft' CONSTRAINT security_patterns_status_check CHECK (status IN ('draft', 'active', 'retired')),
  created_by         text NOT NULL DEFAULT current_user,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.security_patterns IS 'Mémoire immunitaire : motifs de vulnérabilités (security) et de bugs (bug) — signature, conditions, cause racine, correctif, test, projets touchés, première/dernière observation.';
ALTER TABLE soulbah.security_patterns ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.security_patterns', '{"key": "text", "pattern_kind": "text", "severity": "text", "occurrences": "integer"}');
CREATE INDEX IF NOT EXISTS idx_security_patterns_kind ON soulbah.security_patterns (pattern_kind, category) WHERE status = 'active';
DROP TRIGGER IF EXISTS security_patterns_set_updated_at ON soulbah.security_patterns;
CREATE TRIGGER security_patterns_set_updated_at BEFORE UPDATE ON soulbah.security_patterns FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- 2. Incidents (toutes natures) ---------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.incidents (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind                    text NOT NULL CONSTRAINT incidents_kind_check CHECK (kind IN ('security', 'reliability', 'performance', 'data', 'availability', 'agent_behaviour')),
  severity                text NOT NULL CONSTRAINT incidents_severity_check CHECK (soulbah.is_severity(severity)),
  title                   text NOT NULL CONSTRAINT incidents_title_length CHECK (length(title) BETWEEN 1 AND 300),
  summary                 text NOT NULL DEFAULT '' CONSTRAINT incidents_summary_length CHECK (length(summary) <= 8000),
  project_id              uuid REFERENCES soulbah.projects(id) ON DELETE RESTRICT,
  environment_name        text REFERENCES soulbah.environments(name),
  status                  text NOT NULL DEFAULT 'OPEN' CONSTRAINT incidents_status_check CHECK (status IN ('OPEN', 'CONTAINED', 'MITIGATED', 'RESOLVED', 'POSTMORTEM', 'CLOSED')),
  detected_by             text NOT NULL DEFAULT current_user CONSTRAINT incidents_detected_by_length CHECK (length(detected_by) BETWEEN 1 AND 200),
  detected_at             timestamptz NOT NULL DEFAULT now(),
  contained_at            timestamptz,
  resolved_at             timestamptz,
  closed_at               timestamptz,
  closed_by               text,
  root_cause              text NOT NULL DEFAULT '' CONSTRAINT incidents_root_cause_length CHECK (length(root_cause) <= 8000),
  impact                  text NOT NULL DEFAULT '' CONSTRAINT incidents_impact_length CHECK (length(impact) <= 4000),
  postmortem_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT incidents_closed_signed CHECK (status <> 'CLOSED' OR (closed_by IS NOT NULL AND closed_at IS NOT NULL)),
  CONSTRAINT incidents_resolved_dated CHECK (status NOT IN ('RESOLVED', 'POSTMORTEM', 'CLOSED') OR resolved_at IS NOT NULL)
);
COMMENT ON TABLE soulbah.incidents IS 'Incidents de toutes natures (sécurité, fiabilité, performance, données, disponibilité, comportement d''agent) ; la vue security_incidents en filtre la nature sécurité.';
ALTER TABLE soulbah.incidents ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.incidents', '{"kind": "text", "severity": "text", "status": "text", "closed_by": "text"}');
CREATE INDEX IF NOT EXISTS idx_incidents_open ON soulbah.incidents (severity, detected_at DESC) WHERE status NOT IN ('RESOLVED', 'POSTMORTEM', 'CLOSED');
CREATE INDEX IF NOT EXISTS idx_incidents_project ON soulbah.incidents (project_id);
CREATE INDEX IF NOT EXISTS idx_incidents_environment ON soulbah.incidents (environment_name);
CREATE INDEX IF NOT EXISTS idx_incidents_postmortem ON soulbah.incidents (postmortem_artifact_id);
DROP TRIGGER IF EXISTS incidents_set_updated_at ON soulbah.incidents;
CREATE TRIGGER incidents_set_updated_at BEFORE UPDATE ON soulbah.incidents FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE OR REPLACE VIEW soulbah.security_incidents AS
  SELECT * FROM soulbah.incidents WHERE kind = 'security';
COMMENT ON VIEW soulbah.security_incidents IS 'Incidents de nature sécurité (vue sur soulbah.incidents).';

-- 3. Constats ----------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.security_findings (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fingerprint             text NOT NULL UNIQUE CONSTRAINT security_findings_fingerprint_format CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
  project_id              uuid REFERENCES soulbah.projects(id) ON DELETE RESTRICT,
  repository_id           uuid,
  environment_name        text REFERENCES soulbah.environments(name),
  pattern_id              uuid REFERENCES soulbah.security_patterns(id) ON DELETE SET NULL,
  incident_id             uuid REFERENCES soulbah.incidents(id) ON DELETE SET NULL,
  kind                    text NOT NULL CONSTRAINT security_findings_kind_check CHECK (kind IN ('vulnerability', 'bug', 'misconfiguration', 'dependency', 'data_exposure', 'policy_violation', 'performance')),
  severity                text NOT NULL CONSTRAINT security_findings_severity_check CHECK (soulbah.is_severity(severity)),
  severity_justification  text NOT NULL DEFAULT '' CONSTRAINT security_findings_justification_length CHECK (length(severity_justification) <= 4000),
  confidence              real NOT NULL DEFAULT 0.5 CONSTRAINT security_findings_confidence_range CHECK (confidence >= 0 AND confidence <= 1),
  title                   text NOT NULL CONSTRAINT security_findings_title_length CHECK (length(title) BETWEEN 1 AND 300),
  description             text NOT NULL DEFAULT '' CONSTRAINT security_findings_description_length CHECK (length(description) <= 8000),
  location                jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT security_findings_location_object CHECK (soulbah.is_json_object(location)),
  evidence                jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT security_findings_evidence_array CHECK (soulbah.is_json_array(evidence)),
  status                  text NOT NULL DEFAULT 'DETECTED' CONSTRAINT security_findings_status_check CHECK (status IN (
                            'DETECTED', 'TRIAGED', 'CONFIRMED', 'FALSE_POSITIVE', 'FIX_PROPOSED', 'FIX_APPLIED', 'VERIFIED', 'WONT_FIX', 'REOPENED')),
  detected_by             text NOT NULL DEFAULT current_user CONSTRAINT security_findings_detected_by_length CHECK (length(detected_by) BETWEEN 1 AND 200),
  detected_at             timestamptz NOT NULL DEFAULT now(),
  triaged_by              text,
  triaged_at              timestamptz,
  verified_by             text,
  verified_at             timestamptz,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  -- Une sévérité haute se justifie ; « vérifié » est signé ; la confiance n'est pas une preuve (§ Intelligence Lab).
  CONSTRAINT security_findings_high_justified CHECK (severity NOT IN ('HIGH', 'CRITICAL') OR length(severity_justification) >= 20),
  CONSTRAINT security_findings_verified_signed CHECK (status <> 'VERIFIED' OR (verified_by IS NOT NULL AND verified_at IS NOT NULL)),
  CONSTRAINT security_findings_triaged_signed CHECK (status IN ('DETECTED', 'REOPENED') OR (triaged_by IS NOT NULL AND triaged_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.security_findings IS 'Constats dédoublonnés par empreinte : sévérité justifiée, confiance (≠ preuve), preuves, cycle DETECTED → TRIAGED → CONFIRMED → FIX_PROPOSED → FIX_APPLIED → VERIFIED (signé).';
ALTER TABLE soulbah.security_findings ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.security_findings', '{"fingerprint": "text", "severity": "text", "confidence": "real", "status": "text"}');
CREATE INDEX IF NOT EXISTS idx_security_findings_open ON soulbah.security_findings (severity, detected_at DESC) WHERE status NOT IN ('FALSE_POSITIVE', 'VERIFIED', 'WONT_FIX');
CREATE INDEX IF NOT EXISTS idx_security_findings_project ON soulbah.security_findings (project_id, status);
CREATE INDEX IF NOT EXISTS idx_security_findings_pattern ON soulbah.security_findings (pattern_id);
CREATE INDEX IF NOT EXISTS idx_security_findings_incident ON soulbah.security_findings (incident_id);
CREATE INDEX IF NOT EXISTS idx_security_findings_environment ON soulbah.security_findings (environment_name);
CREATE INDEX IF NOT EXISTS idx_security_findings_repository ON soulbah.security_findings (repository_id);
DROP TRIGGER IF EXISTS security_findings_set_updated_at ON soulbah.security_findings;
CREATE TRIGGER security_findings_set_updated_at BEFORE UPDATE ON soulbah.security_findings FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- Statistiques du motif tenues par les constats (occurrences, première et dernière observation).
CREATE OR REPLACE FUNCTION soulbah.security_findings_pattern_stats()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.pattern_id IS NOT NULL AND (TG_OP = 'INSERT' OR OLD.pattern_id IS DISTINCT FROM NEW.pattern_id) THEN
    UPDATE soulbah.security_patterns p
       SET occurrences = p.occurrences + 1,
           first_seen_at = LEAST(COALESCE(p.first_seen_at, NEW.detected_at), NEW.detected_at),
           last_seen_at = GREATEST(COALESCE(p.last_seen_at, NEW.detected_at), NEW.detected_at),
           projects_affected = CASE WHEN NEW.project_id IS NULL OR p.projects_affected ? NEW.project_id::text THEN p.projects_affected
                                    ELSE p.projects_affected || to_jsonb(NEW.project_id::text) END
     WHERE p.id = NEW.pattern_id;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS security_findings_pattern_stats ON soulbah.security_findings;
CREATE TRIGGER security_findings_pattern_stats AFTER INSERT OR UPDATE OF pattern_id ON soulbah.security_findings FOR EACH ROW EXECUTE FUNCTION soulbah.security_findings_pattern_stats();

-- 4. Vie d'un incident --------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.incident_events (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  incident_id  uuid NOT NULL REFERENCES soulbah.incidents(id) ON DELETE RESTRICT,
  kind         text NOT NULL CONSTRAINT incident_events_kind_check CHECK (kind IN (
                 'detected', 'triaged', 'escalated', 'contained', 'mitigated', 'resolved', 'reopened', 'closed', 'note', 'action', 'evidence', 'decision', 'status_change')),
  actor        text NOT NULL DEFAULT current_user CONSTRAINT incident_events_actor_length CHECK (length(actor) BETWEEN 1 AND 200),
  message      text NOT NULL DEFAULT '' CONSTRAINT incident_events_message_length CHECK (length(message) <= 4000),
  detail       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT incident_events_detail_object CHECK (soulbah.is_json_object(detail)),
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.incident_events IS 'Chronologie d''un incident (ajout seul).';
ALTER TABLE soulbah.incident_events ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_incident_events_incident ON soulbah.incident_events (incident_id, id);
DROP TRIGGER IF EXISTS incident_events_append_only ON soulbah.incident_events;
CREATE TRIGGER incident_events_append_only BEFORE UPDATE OR DELETE ON soulbah.incident_events FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS incident_events_no_truncate ON soulbah.incident_events;
CREATE TRIGGER incident_events_no_truncate BEFORE TRUNCATE ON soulbah.incident_events FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

-- Chaque changement de statut d'un incident est journalisé automatiquement.
CREATE OR REPLACE FUNCTION soulbah.incidents_log_status()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO soulbah.incident_events (incident_id, kind, actor, message, detail)
    VALUES (NEW.id, 'detected', NEW.detected_by, NEW.title, jsonb_build_object('severity', NEW.severity, 'kind', NEW.kind));
  ELSIF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO soulbah.incident_events (incident_id, kind, actor, message, detail)
    VALUES (NEW.id, 'status_change', COALESCE(soulbah.change_actor(), current_user), COALESCE(soulbah.change_reason(), ''),
            jsonb_build_object('from', OLD.status, 'to', NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS incidents_log_status ON soulbah.incidents;
CREATE TRIGGER incidents_log_status AFTER INSERT OR UPDATE OF status ON soulbah.incidents FOR EACH ROW EXECUTE FUNCTION soulbah.incidents_log_status();

CREATE TABLE IF NOT EXISTS soulbah.incident_actions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id        uuid NOT NULL REFERENCES soulbah.incidents(id) ON DELETE RESTRICT,
  kind               text NOT NULL CONSTRAINT incident_actions_kind_check CHECK (kind IN (
                       'investigate', 'isolate', 'block', 'rotate_secret', 'quarantine_agent', 'rollback', 'patch', 'restore', 'notify', 'monitor', 'other')),
  description        text NOT NULL CONSTRAINT incident_actions_description_length CHECK (length(description) BETWEEN 1 AND 4000),
  requires_approval  boolean NOT NULL DEFAULT true,
  status             text NOT NULL DEFAULT 'planned' CONSTRAINT incident_actions_status_check CHECK (status IN ('planned', 'approved', 'executing', 'executed', 'failed', 'cancelled')),
  approved_by        text,
  approved_at        timestamptz,
  executed_by        text,
  executed_at        timestamptz,
  task_id            uuid,
  result             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT incident_actions_result_object CHECK (soulbah.is_json_object(result)),
  created_by         text NOT NULL DEFAULT current_user,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  -- Une action qui exige une approbation ne s'exécute pas sans elle ; une action exécutée est signée.
  CONSTRAINT incident_actions_approval CHECK (status NOT IN ('executing', 'executed') OR NOT requires_approval OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
  CONSTRAINT incident_actions_executed_signed CHECK (status <> 'executed' OR (executed_by IS NOT NULL AND executed_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.incident_actions IS 'Actions de réponse (isoler, bloquer, faire tourner un secret, mettre un agent en quarantaine, revenir en arrière, corriger…) : approbation requise par défaut.';
ALTER TABLE soulbah.incident_actions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_incident_actions_incident ON soulbah.incident_actions (incident_id, status);
CREATE INDEX IF NOT EXISTS idx_incident_actions_task ON soulbah.incident_actions (task_id);
DROP TRIGGER IF EXISTS incident_actions_set_updated_at ON soulbah.incident_actions;
CREATE TRIGGER incident_actions_set_updated_at BEFORE UPDATE ON soulbah.incident_actions FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.incident_evidence (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  incident_id  uuid NOT NULL REFERENCES soulbah.incidents(id) ON DELETE RESTRICT,
  finding_id   uuid REFERENCES soulbah.security_findings(id) ON DELETE RESTRICT,
  kind         text NOT NULL CONSTRAINT incident_evidence_kind_check CHECK (kind IN ('log', 'screenshot', 'diff', 'query', 'report', 'metric', 'artifact', 'testimony', 'other')),
  artifact_id  uuid,
  sha256       text CONSTRAINT incident_evidence_sha256_format CHECK (sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$'),
  description  text NOT NULL CONSTRAINT incident_evidence_description_length CHECK (length(description) BETWEEN 1 AND 4000),
  detail       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT incident_evidence_detail_object CHECK (soulbah.is_json_object(detail)),
  created_by   text NOT NULL DEFAULT current_user,
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.incident_evidence IS 'Preuves d''un incident (ajout seul) : artefact par identifiant et empreinte, jamais le contenu.';
ALTER TABLE soulbah.incident_evidence ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_incident_evidence_incident ON soulbah.incident_evidence (incident_id, id);
CREATE INDEX IF NOT EXISTS idx_incident_evidence_finding ON soulbah.incident_evidence (finding_id);
CREATE INDEX IF NOT EXISTS idx_incident_evidence_artifact ON soulbah.incident_evidence (artifact_id);
DROP TRIGGER IF EXISTS incident_evidence_append_only ON soulbah.incident_evidence;
CREATE TRIGGER incident_evidence_append_only BEFORE UPDATE OR DELETE ON soulbah.incident_evidence FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS incident_evidence_no_truncate ON soulbah.incident_evidence;
CREATE TRIGGER incident_evidence_no_truncate BEFORE TRUNCATE ON soulbah.incident_evidence FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE TABLE IF NOT EXISTS soulbah.incident_decisions (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  incident_id     uuid NOT NULL REFERENCES soulbah.incidents(id) ON DELETE RESTRICT,
  decision        text NOT NULL CONSTRAINT incident_decisions_decision_length CHECK (length(decision) BETWEEN 1 AND 4000),
  rationale       text NOT NULL DEFAULT '' CONSTRAINT incident_decisions_rationale_length CHECK (length(rationale) <= 8000),
  decider_kind    text NOT NULL CONSTRAINT incident_decisions_decider_kind_check CHECK (decider_kind IN ('human', 'agent', 'system')),
  decided_by      text NOT NULL CONSTRAINT incident_decisions_decided_by_length CHECK (length(decided_by) BETWEEN 1 AND 200),
  autonomy_level  text CONSTRAINT incident_decisions_autonomy_check CHECK (autonomy_level IS NULL OR soulbah.is_autonomy_level(autonomy_level)),
  decided_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.incident_decisions IS 'Décisions prises pendant un incident (ajout seul) : qui a décidé (humain, agent, système) et sous quel niveau d''autonomie.';
ALTER TABLE soulbah.incident_decisions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_incident_decisions_incident ON soulbah.incident_decisions (incident_id, id);
DROP TRIGGER IF EXISTS incident_decisions_append_only ON soulbah.incident_decisions;
CREATE TRIGGER incident_decisions_append_only BEFORE UPDATE OR DELETE ON soulbah.incident_decisions FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS incident_decisions_no_truncate ON soulbah.incident_decisions;
CREATE TRIGGER incident_decisions_no_truncate BEFORE TRUNCATE ON soulbah.incident_decisions FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE TABLE IF NOT EXISTS soulbah.incident_recovery_steps (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id  uuid NOT NULL REFERENCES soulbah.incidents(id) ON DELETE RESTRICT,
  position     integer NOT NULL CONSTRAINT incident_recovery_steps_position_positive CHECK (position >= 1),
  description  text NOT NULL CONSTRAINT incident_recovery_steps_description_length CHECK (length(description) BETWEEN 1 AND 4000),
  status       text NOT NULL DEFAULT 'pending' CONSTRAINT incident_recovery_steps_status_check CHECK (status IN ('pending', 'in_progress', 'done', 'failed', 'skipped')),
  done_by      text,
  done_at      timestamptz,
  evidence     jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT incident_recovery_steps_evidence_array CHECK (soulbah.is_json_array(evidence)),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT incident_recovery_steps_unique UNIQUE (incident_id, position),
  CONSTRAINT incident_recovery_steps_done_signed CHECK (status <> 'done' OR (done_by IS NOT NULL AND done_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.incident_recovery_steps IS 'Plan de reprise ordonné d''un incident, chaque étape signée avec ses preuves.';
ALTER TABLE soulbah.incident_recovery_steps ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS incident_recovery_steps_set_updated_at ON soulbah.incident_recovery_steps;
CREATE TRIGGER incident_recovery_steps_set_updated_at BEFORE UPDATE ON soulbah.incident_recovery_steps FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- 5. Correctifs, tests de régression, règles de détection ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.security_fixes (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  finding_id        uuid NOT NULL REFERENCES soulbah.security_findings(id) ON DELETE RESTRICT,
  incident_id       uuid REFERENCES soulbah.incidents(id) ON DELETE SET NULL,
  environment_name  text REFERENCES soulbah.environments(name),
  change_kind       text NOT NULL CONSTRAINT security_fixes_change_kind_check CHECK (change_kind IN ('code', 'config', 'database', 'policy', 'dependency', 'infrastructure', 'documentation')),
  description       text NOT NULL CONSTRAINT security_fixes_description_length CHECK (length(description) BETWEEN 1 AND 8000),
  commit_id         uuid REFERENCES soulbah.project_commits(id) ON DELETE SET NULL,
  diff_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  status            text NOT NULL DEFAULT 'proposed' CONSTRAINT security_fixes_status_check CHECK (status IN ('proposed', 'approved', 'applied', 'verified', 'reverted', 'rejected')),
  proposed_by       text NOT NULL DEFAULT current_user,
  approved_by       text,
  approved_at       timestamptz,
  applied_by        text,
  applied_at        timestamptz,
  verified_by       text,
  verified_at       timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  -- Appliquer un correctif en PRODUCTION exige une approbation ; « vérifié » est signé.
  CONSTRAINT security_fixes_production_approved CHECK (status NOT IN ('applied', 'verified') OR environment_name IS DISTINCT FROM 'PRODUCTION' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
  CONSTRAINT security_fixes_applied_signed CHECK (status NOT IN ('applied', 'verified') OR (applied_by IS NOT NULL AND applied_at IS NOT NULL)),
  CONSTRAINT security_fixes_verified_signed CHECK (status <> 'verified' OR (verified_by IS NOT NULL AND verified_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.security_fixes IS 'Correctifs d''un constat : nature du changement, commit ou diff, cycle proposé → approuvé → appliqué → vérifié ; la production exige une approbation.';
ALTER TABLE soulbah.security_fixes ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_security_fixes_finding ON soulbah.security_fixes (finding_id, status);
CREATE INDEX IF NOT EXISTS idx_security_fixes_incident ON soulbah.security_fixes (incident_id);
CREATE INDEX IF NOT EXISTS idx_security_fixes_commit ON soulbah.security_fixes (commit_id);
CREATE INDEX IF NOT EXISTS idx_security_fixes_diff ON soulbah.security_fixes (diff_artifact_id);
CREATE INDEX IF NOT EXISTS idx_security_fixes_environment ON soulbah.security_fixes (environment_name);
CREATE INDEX IF NOT EXISTS idx_security_fixes_recent ON soulbah.security_fixes (applied_at DESC) WHERE applied_at IS NOT NULL;
DROP TRIGGER IF EXISTS security_fixes_set_updated_at ON soulbah.security_fixes;
CREATE TRIGGER security_fixes_set_updated_at BEFORE UPDATE ON soulbah.security_fixes FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.security_regression_tests (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id   uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE RESTRICT,
  finding_id   uuid REFERENCES soulbah.security_findings(id) ON DELETE SET NULL,
  pattern_id   uuid REFERENCES soulbah.security_patterns(id) ON DELETE SET NULL,
  fix_id       uuid REFERENCES soulbah.security_fixes(id) ON DELETE SET NULL,
  name         text NOT NULL CONSTRAINT security_regression_tests_name_length CHECK (length(name) BETWEEN 1 AND 300),
  kind         text NOT NULL DEFAULT 'integration' CONSTRAINT security_regression_tests_kind_check CHECK (kind IN ('unit', 'integration', 'e2e', 'sql', 'policy', 'static')),
  location     text NOT NULL DEFAULT '' CONSTRAINT security_regression_tests_location_length CHECK (length(location) <= 1000),
  status       text NOT NULL DEFAULT 'active' CONSTRAINT security_regression_tests_status_check CHECK (status IN ('active', 'retired')),
  last_result  text NOT NULL DEFAULT 'unknown' CONSTRAINT security_regression_tests_result_check CHECK (last_result IN ('unknown', 'passed', 'failed')),
  last_run_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT security_regression_tests_unique UNIQUE (project_id, name)
);
COMMENT ON TABLE soulbah.security_regression_tests IS 'Tests qui empêchent le retour d''un constat ou d''un motif (emplacement, dernier résultat).';
ALTER TABLE soulbah.security_regression_tests ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_security_regression_tests_finding ON soulbah.security_regression_tests (finding_id);
CREATE INDEX IF NOT EXISTS idx_security_regression_tests_pattern ON soulbah.security_regression_tests (pattern_id);
CREATE INDEX IF NOT EXISTS idx_security_regression_tests_fix ON soulbah.security_regression_tests (fix_id);
CREATE INDEX IF NOT EXISTS idx_security_regression_tests_failed ON soulbah.security_regression_tests (project_id) WHERE last_result = 'failed' AND status = 'active';
DROP TRIGGER IF EXISTS security_regression_tests_set_updated_at ON soulbah.security_regression_tests;
CREATE TRIGGER security_regression_tests_set_updated_at BEFORE UPDATE ON soulbah.security_regression_tests FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.security_detection_rules (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key                   text NOT NULL UNIQUE CONSTRAINT security_detection_rules_key_format CHECK (key ~ '^[a-z][a-z0-9_.-]{0,119}$'),
  pattern_id            uuid REFERENCES soulbah.security_patterns(id) ON DELETE SET NULL,
  kind                  text NOT NULL CONSTRAINT security_detection_rules_kind_check CHECK (kind IN ('static', 'runtime', 'database', 'log', 'network', 'agent_behaviour')),
  target                text NOT NULL DEFAULT '' CONSTRAINT security_detection_rules_target_length CHECK (length(target) <= 500),
  rule                  jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT security_detection_rules_rule_object CHECK (soulbah.is_json_object(rule)),
  severity              text NOT NULL DEFAULT 'MEDIUM' CONSTRAINT security_detection_rules_severity_check CHECK (soulbah.is_severity(severity)),
  enabled               boolean NOT NULL DEFAULT true,
  true_positive_count   integer NOT NULL DEFAULT 0 CONSTRAINT security_detection_rules_tp_positive CHECK (true_positive_count >= 0),
  false_positive_count  integer NOT NULL DEFAULT 0 CONSTRAINT security_detection_rules_fp_positive CHECK (false_positive_count >= 0),
  created_by            text NOT NULL DEFAULT current_user,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.security_detection_rules IS 'Règles de détection (statique, exécution, base, journaux, réseau, comportement d''agent) avec comptes de vrais et faux positifs.';
ALTER TABLE soulbah.security_detection_rules ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_security_detection_rules_pattern ON soulbah.security_detection_rules (pattern_id);
DROP TRIGGER IF EXISTS security_detection_rules_set_updated_at ON soulbah.security_detection_rules;
CREATE TRIGGER security_detection_rules_set_updated_at BEFORE UPDATE ON soulbah.security_detection_rules FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- 6. Liens avec les lots précédents --------------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'project_commits_incident_fkey') THEN
    ALTER TABLE soulbah.project_commits ADD CONSTRAINT project_commits_incident_fkey
      FOREIGN KEY (incident_id) REFERENCES soulbah.incidents(id) ON DELETE RESTRICT;
  END IF;
END $$;
ALTER TABLE soulbah.agent_quarantines ADD COLUMN IF NOT EXISTS incident_id uuid REFERENCES soulbah.incidents(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_agent_quarantines_incident ON soulbah.agent_quarantines (incident_id);

-- 7. Vues SOC (§57) — sur les tables réelles, jamais de chiffres calculés ailleurs -----------------------------------
CREATE OR REPLACE VIEW soulbah.v_soc_active_incidents AS
  SELECT i.id, i.kind, i.severity, i.title, i.status, i.project_id, p.slug AS project_slug, i.environment_name, i.detected_at, i.detected_by,
         (SELECT count(*) FROM soulbah.incident_actions a WHERE a.incident_id = i.id AND a.status IN ('planned', 'approved', 'executing')) AS pending_actions,
         (SELECT count(*) FROM soulbah.incident_evidence e WHERE e.incident_id = i.id) AS evidence_count,
         (SELECT max(ev.created_at) FROM soulbah.incident_events ev WHERE ev.incident_id = i.id) AS last_event_at
    FROM soulbah.incidents i LEFT JOIN soulbah.projects p ON p.id = i.project_id
   WHERE i.status NOT IN ('RESOLVED', 'POSTMORTEM', 'CLOSED');
COMMENT ON VIEW soulbah.v_soc_active_incidents IS 'SOC : incidents ouverts, contenus ou atténués, avec actions en attente et preuves.';

CREATE OR REPLACE VIEW soulbah.v_soc_open_findings AS
  SELECT f.id, f.kind, f.severity, f.confidence, f.title, f.status, f.project_id, p.slug AS project_slug, f.environment_name, f.pattern_id, f.incident_id, f.detected_at, f.detected_by
    FROM soulbah.security_findings f LEFT JOIN soulbah.projects p ON p.id = f.project_id
   WHERE f.status NOT IN ('FALSE_POSITIVE', 'VERIFIED', 'WONT_FIX');
COMMENT ON VIEW soulbah.v_soc_open_findings IS 'SOC : constats non clos (ni faux positif, ni vérifié, ni refusé).';

CREATE OR REPLACE VIEW soulbah.v_soc_critical_findings AS
  SELECT * FROM soulbah.v_soc_open_findings WHERE severity IN ('HIGH', 'CRITICAL');
COMMENT ON VIEW soulbah.v_soc_critical_findings IS 'SOC : constats ouverts de sévérité HIGH ou CRITICAL.';

CREATE OR REPLACE VIEW soulbah.v_soc_quarantined_agents AS
  SELECT q.id AS quarantine_id, d.id AS definition_id, d.name AS agent_name, d.display_name, q.reason, q.created_by, q.created_at, q.event_id, q.incident_id
    FROM soulbah.agent_quarantines q JOIN soulbah.agent_definitions d ON d.id = q.definition_id
   WHERE q.status = 'active';
COMMENT ON VIEW soulbah.v_soc_quarantined_agents IS 'SOC : agents actuellement en quarantaine et motif.';

CREATE OR REPLACE VIEW soulbah.v_soc_recent_fixes AS
  SELECT x.id, x.finding_id, f.title AS finding_title, f.severity, x.change_kind, x.status, x.environment_name, x.proposed_by, x.approved_by, x.applied_by, x.applied_at, x.verified_at, x.commit_id
    FROM soulbah.security_fixes x JOIN soulbah.security_findings f ON f.id = x.finding_id
   WHERE x.updated_at >= now() - interval '30 days';
COMMENT ON VIEW soulbah.v_soc_recent_fixes IS 'SOC : correctifs touchés dans les 30 derniers jours.';

CREATE OR REPLACE VIEW soulbah.v_soc_regressions AS
  SELECT t.id, t.project_id, p.slug AS project_slug, t.name, t.kind, t.location, t.finding_id, t.pattern_id, t.last_run_at
    FROM soulbah.security_regression_tests t LEFT JOIN soulbah.projects p ON p.id = t.project_id
   WHERE t.status = 'active' AND t.last_result = 'failed';
COMMENT ON VIEW soulbah.v_soc_regressions IS 'SOC : tests de régression actifs dont le dernier résultat est un échec (un constat revient).';

CREATE OR REPLACE VIEW soulbah.v_soc_coverage AS
  SELECT p.id AS project_id, p.slug AS project_slug,
         (SELECT count(*) FROM soulbah.security_findings f WHERE f.project_id = p.id) AS findings_total,
         (SELECT count(*) FROM soulbah.security_findings f WHERE f.project_id = p.id AND f.status NOT IN ('FALSE_POSITIVE', 'VERIFIED', 'WONT_FIX')) AS findings_open,
         (SELECT count(*) FROM soulbah.security_findings f WHERE f.project_id = p.id AND f.status = 'VERIFIED') AS findings_verified,
         (SELECT count(*) FROM soulbah.incidents i WHERE i.project_id = p.id AND i.status NOT IN ('RESOLVED', 'POSTMORTEM', 'CLOSED')) AS incidents_open,
         (SELECT count(*) FROM soulbah.security_regression_tests t WHERE t.project_id = p.id AND t.status = 'active') AS regression_tests_active,
         (SELECT count(*) FROM soulbah.security_patterns sp WHERE sp.status = 'active' AND sp.projects_affected ? p.id::text) AS patterns_seen,
         (SELECT max(f.detected_at) FROM soulbah.security_findings f WHERE f.project_id = p.id) AS last_finding_at
    FROM soulbah.projects p;
COMMENT ON VIEW soulbah.v_soc_coverage IS 'SOC : par projet, constats (total, ouverts, vérifiés), incidents ouverts, tests de régression actifs, motifs observés — des comptes, pas des scores.';

-- 8. audit_events : lecture structurée du journal d'audit existant (décision transversale : pas de seconde table) -------
CREATE OR REPLACE VIEW soulbah.audit_events AS
  SELECT a.seq, a.id, a.created_at, a.actor,
         split_part(a.actor, ':', 1) AS actor_kind,
         a.action, split_part(a.action, '.', 1) AS category,
         a.entity, a.entity_id, a.user_id, a.session_id, a.task_id,
         a.data ->> 'effect' AS effect, a.data ->> 'reason' AS reason, a.data ->> 'from' AS from_state, a.data ->> 'to' AS to_state,
         a.data, a.prev_hash, a.row_hash
    FROM soulbah.audit_logs a;
COMMENT ON VIEW soulbah.audit_events IS 'Événements d''audit : vue typée sur soulbah.audit_logs (chaîne de hachage conservée) — catégorie, acteur, effet, raison, transition.';

-- 9. Droits ------------------------------------------------------------------------------------------------------
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['security_patterns', 'incidents', 'security_incidents', 'security_findings', 'incident_events', 'incident_actions', 'incident_evidence',
                           'incident_decisions', 'incident_recovery_steps', 'security_fixes', 'security_regression_tests', 'security_detection_rules',
                           'v_soc_active_incidents', 'v_soc_open_findings', 'v_soc_critical_findings', 'v_soc_quarantined_agents', 'v_soc_recent_fixes',
                           'v_soc_regressions', 'v_soc_coverage', 'audit_events'] LOOP
    EXECUTE format('REVOKE ALL ON soulbah.%I FROM PUBLIC', t);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON soulbah.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.security_findings_pattern_stats(), soulbah.incidents_log_status() FROM %I', r);
    END IF;
  END LOOP;
END $$;
