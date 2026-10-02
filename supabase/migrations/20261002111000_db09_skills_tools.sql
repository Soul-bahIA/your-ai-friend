-- =============================================================================
-- DB LOT 9 — Skills Factory (REUSE + EXTEND soulbah.skills ; versions, étapes, prérequis, outils, tests, métriques,
-- candidats) et Tool Registry (outils, versions, permissions, santé, benchmarks ; constructeur d'outils : candidats,
-- builds, tests, revues de sécurité).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002111000_db09_skills_tools.down.sql (les colonnes ajoutées à soulbah.skills sont retirées)
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03, db04. Le registre des outils est synchronisé par node-api depuis
-- shared/tools/catalog.json (source unique) : aucune semence SQL.
-- =============================================================================

-- 1. Skills ---------------------------------------------------------------------------------------------
SELECT soulbah.assert_table_shape('soulbah.skills', '{"name": "text", "version": "text", "status": "text", "procedure": "jsonb", "source": "text"}');
ALTER TABLE soulbah.skills
  ADD COLUMN IF NOT EXISTS current_version_id uuid,
  ADD COLUMN IF NOT EXISTS category           text,
  ADD COLUMN IF NOT EXISTS description        text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS project_id         uuid REFERENCES soulbah.projects(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS risk_level         text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'skills_risk_level_check') THEN
    ALTER TABLE soulbah.skills ADD CONSTRAINT skills_risk_level_check CHECK (risk_level IS NULL OR soulbah.is_severity(risk_level));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'skills_description_length') THEN
    ALTER TABLE soulbah.skills ADD CONSTRAINT skills_description_length CHECK (length(description) <= 4000);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_skills_project ON soulbah.skills (project_id);
CREATE INDEX IF NOT EXISTS idx_skills_created_by ON soulbah.skills (created_by);

CREATE TABLE IF NOT EXISTS soulbah.skill_versions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  skill_id      uuid NOT NULL REFERENCES soulbah.skills(id) ON DELETE CASCADE,
  version       text NOT NULL CONSTRAINT skill_versions_semver CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  procedure     jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skill_versions_procedure_array CHECK (soulbah.is_json_array(procedure)),
  input_schema  jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT skill_versions_schema_object CHECK (soulbah.is_json_object(input_schema)),
  permissions   jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skill_versions_permissions_array CHECK (soulbah.is_json_array(permissions)),
  status        text NOT NULL DEFAULT 'candidate' CONSTRAINT skill_versions_status_check CHECK (status IN ('candidate', 'testing', 'validated', 'active', 'retired')),
  changelog     text NOT NULL DEFAULT '' CONSTRAINT skill_versions_changelog_length CHECK (length(changelog) <= 4000),
  created_by    text NOT NULL DEFAULT current_user,
  created_at    timestamptz NOT NULL DEFAULT now(),
  validated_by  text,
  validated_at  timestamptz,
  CONSTRAINT skill_versions_unique UNIQUE (skill_id, version),
  CONSTRAINT skill_versions_validated_author CHECK (status NOT IN ('validated', 'active') OR validated_by IS NOT NULL)
);
COMMENT ON TABLE soulbah.skill_versions IS 'Versions d''une compétence : procédure, schéma d''entrée, permissions ; active seulement après validation (§41, §68-69).';
ALTER TABLE soulbah.skill_versions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_skill_versions_status ON soulbah.skill_versions (skill_id, status);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'skills_current_version_fkey') THEN
    ALTER TABLE soulbah.skills ADD CONSTRAINT skills_current_version_fkey
      FOREIGN KEY (current_version_id) REFERENCES soulbah.skill_versions(id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_skills_current_version ON soulbah.skills (current_version_id);

CREATE TABLE IF NOT EXISTS soulbah.skill_steps (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id         uuid NOT NULL REFERENCES soulbah.skill_versions(id) ON DELETE CASCADE,
  position           integer NOT NULL CONSTRAINT skill_steps_position_positive CHECK (position >= 1),
  tool_name          text NOT NULL CONSTRAINT skill_steps_tool_format CHECK (tool_name ~ '^[a-z][a-z0-9_]{0,63}$'),
  params             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT skill_steps_params_object CHECK (soulbah.is_json_object(params)),
  condition          text CONSTRAINT skill_steps_condition_length CHECK (condition IS NULL OR length(condition) <= 1000),
  expected_evidence  jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skill_steps_evidence_array CHECK (soulbah.is_json_array(expected_evidence)),
  on_failure         text NOT NULL DEFAULT 'abort' CONSTRAINT skill_steps_on_failure_check CHECK (on_failure IN ('abort', 'retry', 'skip', 'escalate')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_steps_unique UNIQUE (version_id, position)
);
COMMENT ON TABLE soulbah.skill_steps IS 'Étapes ordonnées d''une version de compétence : outil, paramètres, condition, preuve attendue, conduite en cas d''échec.';
ALTER TABLE soulbah.skill_steps ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.skill_requirements (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id  uuid NOT NULL REFERENCES soulbah.skill_versions(id) ON DELETE CASCADE,
  kind        text NOT NULL CONSTRAINT skill_requirements_kind_check CHECK (kind IN ('tool', 'permission', 'capability', 'model', 'environment', 'project', 'os', 'network')),
  value       text NOT NULL CONSTRAINT skill_requirements_value_length CHECK (length(value) BETWEEN 1 AND 300),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_requirements_unique UNIQUE (version_id, kind, value)
);
COMMENT ON TABLE soulbah.skill_requirements IS 'Conditions d''emploi d''une compétence (outil, permission, capacité, modèle, environnement, projet, OS, réseau).';
ALTER TABLE soulbah.skill_requirements ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.skill_tools (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id  uuid NOT NULL REFERENCES soulbah.skill_versions(id) ON DELETE CASCADE,
  tool_name   text NOT NULL CONSTRAINT skill_tools_tool_format CHECK (tool_name ~ '^[a-z][a-z0-9_]{0,63}$'),
  required    boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_tools_unique UNIQUE (version_id, tool_name)
);
COMMENT ON TABLE soulbah.skill_tools IS 'Outils employés par une version de compétence.';
ALTER TABLE soulbah.skill_tools ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_skill_tools_tool ON soulbah.skill_tools (tool_name);

CREATE TABLE IF NOT EXISTS soulbah.skill_tests (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id    uuid NOT NULL REFERENCES soulbah.skill_versions(id) ON DELETE CASCADE,
  name          text NOT NULL CONSTRAINT skill_tests_name_length CHECK (length(name) BETWEEN 1 AND 200),
  kind          text NOT NULL DEFAULT 'integration' CONSTRAINT skill_tests_kind_check CHECK (kind IN ('unit', 'integration', 'golden', 'security', 'regression')),
  spec          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT skill_tests_spec_object CHECK (soulbah.is_json_object(spec)),
  last_result   text NOT NULL DEFAULT 'unknown' CONSTRAINT skill_tests_result_check CHECK (last_result IN ('unknown', 'passed', 'failed')),
  last_run_at   timestamptz,
  evidence_ids  jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skill_tests_evidence_array CHECK (soulbah.is_json_array(evidence_ids)),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_tests_unique UNIQUE (version_id, name)
);
COMMENT ON TABLE soulbah.skill_tests IS 'Tests d''une compétence et dernier résultat avec preuves.';
ALTER TABLE soulbah.skill_tests ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.skill_metrics (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  skill_id             uuid NOT NULL REFERENCES soulbah.skills(id) ON DELETE CASCADE,
  period_start         timestamptz NOT NULL,
  period_end           timestamptz NOT NULL,
  runs                 integer NOT NULL DEFAULT 0,
  successes            integer NOT NULL DEFAULT 0,
  failures             integer NOT NULL DEFAULT 0,
  avg_duration_ms      integer,
  human_interventions  integer NOT NULL DEFAULT 0,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_metrics_period CHECK (period_end > period_start),
  CONSTRAINT skill_metrics_unique UNIQUE (skill_id, period_start, period_end)
);
COMMENT ON TABLE soulbah.skill_metrics IS 'Mesures d''usage et de réussite d''une compétence par période.';
ALTER TABLE soulbah.skill_metrics ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.skill_candidates (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                 text NOT NULL CONSTRAINT skill_candidates_name_format CHECK (name ~ '^[a-z][a-z0-9_]{0,99}$'),
  source               text NOT NULL CONSTRAINT skill_candidates_source_check CHECK (source IN ('agent_learning', 'failure_analysis', 'human', 'research', 'imported')),
  proposed_by          uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  project_id           uuid REFERENCES soulbah.projects(id) ON DELETE SET NULL,
  procedure            jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skill_candidates_procedure_array CHECK (soulbah.is_json_array(procedure)),
  evidence             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT skill_candidates_evidence_object CHECK (soulbah.is_json_object(evidence)),
  tests_required       jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skill_candidates_tests_array CHECK (soulbah.is_json_array(tests_required)),
  status               text NOT NULL DEFAULT 'proposed' CONSTRAINT skill_candidates_status_check CHECK (status IN ('proposed', 'testing', 'validated', 'promoted', 'rejected')),
  promoted_skill_id    uuid REFERENCES soulbah.skills(id) ON DELETE SET NULL,
  promoted_version_id  uuid REFERENCES soulbah.skill_versions(id) ON DELETE SET NULL,
  decided_by           text,
  decided_at           timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_candidates_promoted CHECK (status <> 'promoted' OR (promoted_skill_id IS NOT NULL AND promoted_version_id IS NOT NULL)),
  CONSTRAINT skill_candidates_decided CHECK (status IN ('proposed', 'testing') OR (decided_by IS NOT NULL AND decided_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.skill_candidates IS 'Procédures candidates : jamais directement dans les compétences validées — candidate → tests → validation → promotion (§41, §69).';
ALTER TABLE soulbah.skill_candidates ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_skill_candidates_status ON soulbah.skill_candidates (status);
CREATE INDEX IF NOT EXISTS idx_skill_candidates_proposed_by ON soulbah.skill_candidates (proposed_by);
CREATE INDEX IF NOT EXISTS idx_skill_candidates_project ON soulbah.skill_candidates (project_id);
CREATE INDEX IF NOT EXISTS idx_skill_candidates_promoted_skill ON soulbah.skill_candidates (promoted_skill_id);
CREATE INDEX IF NOT EXISTS idx_skill_candidates_promoted_version ON soulbah.skill_candidates (promoted_version_id);

-- 2. Tool Registry ------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.tools (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text NOT NULL UNIQUE CONSTRAINT tools_name_format CHECK (name ~ '^[a-z][a-z0-9_]{0,63}$'),
  category         text NOT NULL CONSTRAINT tools_category_format CHECK (category ~ '^[a-z_]{1,40}$'),
  security_level   text NOT NULL CONSTRAINT tools_level_check CHECK (soulbah.is_security_level(security_level)),
  permission       text REFERENCES soulbah.permission_definitions(name) ON DELETE SET NULL,
  description      text NOT NULL DEFAULT '' CONSTRAINT tools_description_length CHECK (length(description) <= 2000),
  current_version  text,
  status           text NOT NULL DEFAULT 'active' CONSTRAINT tools_status_check CHECK (status IN ('active', 'deprecated', 'disabled', 'quarantined')),
  offline_ok       boolean NOT NULL DEFAULT true,
  source           text NOT NULL DEFAULT 'catalog' CONSTRAINT tools_source_check CHECK (source IN ('catalog', 'built')),
  manifest         jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT tools_manifest_object CHECK (soulbah.is_json_object(manifest)),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.tools IS 'Registre des outils : synchronisé depuis shared/tools/catalog.json (source unique) ; permission nommée, niveau, statut (quarantaine possible).';
ALTER TABLE soulbah.tools ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.tools', '{"name": "text", "security_level": "text", "status": "text", "manifest": "jsonb"}');
CREATE INDEX IF NOT EXISTS idx_tools_permission ON soulbah.tools (permission);
DROP TRIGGER IF EXISTS tools_set_updated_at ON soulbah.tools;
CREATE TRIGGER tools_set_updated_at BEFORE UPDATE ON soulbah.tools FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.tool_versions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tool_id     uuid NOT NULL REFERENCES soulbah.tools(id) ON DELETE CASCADE,
  version     text NOT NULL CONSTRAINT tool_versions_version_length CHECK (length(version) BETWEEN 1 AND 50),
  manifest    jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT tool_versions_manifest_object CHECK (soulbah.is_json_object(manifest)),
  checksum    text CONSTRAINT tool_versions_checksum_format CHECK (checksum IS NULL OR checksum ~ '^[0-9a-f]{64}$'),
  status      text NOT NULL DEFAULT 'active' CONSTRAINT tool_versions_status_check CHECK (status IN ('draft', 'active', 'retired')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tool_versions_unique UNIQUE (tool_id, version)
);
COMMENT ON TABLE soulbah.tool_versions IS 'Versions d''un outil (manifeste, empreinte).';
ALTER TABLE soulbah.tool_versions ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.tool_permissions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tool_id           uuid NOT NULL REFERENCES soulbah.tools(id) ON DELETE CASCADE,
  permission        text NOT NULL REFERENCES soulbah.permission_definitions(name) ON DELETE CASCADE,
  environment_name  text REFERENCES soulbah.environments(name),
  decision          text NOT NULL CONSTRAINT tool_permissions_decision_check CHECK (decision IN ('allow', 'deny', 'approval')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tool_permissions_unique UNIQUE NULLS NOT DISTINCT (tool_id, permission, environment_name)
);
COMMENT ON TABLE soulbah.tool_permissions IS 'Permissions exigées ou refusées par outil et environnement (passerelle d''outils, §39).';
ALTER TABLE soulbah.tool_permissions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_tool_permissions_permission ON soulbah.tool_permissions (permission);
CREATE INDEX IF NOT EXISTS idx_tool_permissions_env ON soulbah.tool_permissions (environment_name);

CREATE TABLE IF NOT EXISTS soulbah.tool_health (
  tool_id            uuid PRIMARY KEY REFERENCES soulbah.tools(id) ON DELETE CASCADE,
  status             text NOT NULL DEFAULT 'unknown' CONSTRAINT tool_health_status_check CHECK (status IN ('healthy', 'degraded', 'failing', 'unknown')),
  last_success_at    timestamptz,
  last_failure_at    timestamptz,
  failure_count_24h  integer NOT NULL DEFAULT 0 CONSTRAINT tool_health_failures_positive CHECK (failure_count_24h >= 0),
  avg_latency_ms     integer,
  detail             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT tool_health_detail_object CHECK (soulbah.is_json_object(detail)),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.tool_health IS 'Santé courante de chaque outil (succès, échecs récents, latence).';
ALTER TABLE soulbah.tool_health ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS tool_health_set_updated_at ON soulbah.tool_health;
CREATE TRIGGER tool_health_set_updated_at BEFORE UPDATE ON soulbah.tool_health FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.tool_benchmarks (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tool_id           uuid NOT NULL REFERENCES soulbah.tools(id) ON DELETE CASCADE,
  benchmark_run_id  uuid,
  metric            text NOT NULL CONSTRAINT tool_benchmarks_metric_format CHECK (metric ~ '^[a-z][a-z0-9_.]{0,99}$'),
  value             numeric(18, 6) NOT NULL,
  unit              text NOT NULL DEFAULT '' CONSTRAINT tool_benchmarks_unit_length CHECK (length(unit) <= 40),
  measured_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.tool_benchmarks IS 'Mesures d''un outil (latence, fiabilité, coût) ; benchmark_run_id renvoie aux exécutions du DB LOT 10.';
ALTER TABLE soulbah.tool_benchmarks ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_tool_benchmarks_tool ON soulbah.tool_benchmarks (tool_id, metric, measured_at DESC);

-- 3. Constructeur d'outils (§43 mission Control Center) ------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.tool_candidates (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name              text NOT NULL CONSTRAINT tool_candidates_name_format CHECK (name ~ '^[a-z][a-z0-9_]{0,63}$'),
  purpose           text NOT NULL CONSTRAINT tool_candidates_purpose_length CHECK (length(purpose) BETWEEN 1 AND 4000),
  proposed_by       uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  spec              jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT tool_candidates_spec_object CHECK (soulbah.is_json_object(spec)),
  status            text NOT NULL DEFAULT 'proposed' CONSTRAINT tool_candidates_status_check
                    CHECK (status IN ('proposed', 'building', 'testing', 'security_review', 'approved', 'rejected', 'promoted')),
  promoted_tool_id  uuid REFERENCES soulbah.tools(id) ON DELETE SET NULL,
  decided_by        text,
  decided_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tool_candidates_promoted CHECK (status <> 'promoted' OR promoted_tool_id IS NOT NULL),
  CONSTRAINT tool_candidates_decided CHECK (status NOT IN ('approved', 'rejected', 'promoted') OR (decided_by IS NOT NULL AND decided_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.tool_candidates IS 'Outils proposés par les agents ou le PDG : construction, tests, revue de sécurité, décision humaine avant promotion.';
ALTER TABLE soulbah.tool_candidates ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_tool_candidates_status ON soulbah.tool_candidates (status);
CREATE INDEX IF NOT EXISTS idx_tool_candidates_proposed_by ON soulbah.tool_candidates (proposed_by);
CREATE INDEX IF NOT EXISTS idx_tool_candidates_promoted ON soulbah.tool_candidates (promoted_tool_id);

CREATE TABLE IF NOT EXISTS soulbah.tool_builds (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id           uuid NOT NULL REFERENCES soulbah.tool_candidates(id) ON DELETE CASCADE,
  version                text NOT NULL CONSTRAINT tool_builds_version_length CHECK (length(version) BETWEEN 1 AND 50),
  artifact_id            uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  build_log_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  status                 text NOT NULL DEFAULT 'pending' CONSTRAINT tool_builds_status_check CHECK (status IN ('pending', 'running', 'succeeded', 'failed')),
  error                  text,
  started_at             timestamptz,
  finished_at            timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tool_builds_unique UNIQUE (candidate_id, version)
);
COMMENT ON TABLE soulbah.tool_builds IS 'Constructions d''un outil candidat (artefact produit, journal), en sandbox.';
ALTER TABLE soulbah.tool_builds ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_tool_builds_artifact ON soulbah.tool_builds (artifact_id);
CREATE INDEX IF NOT EXISTS idx_tool_builds_log ON soulbah.tool_builds (build_log_artifact_id);

CREATE TABLE IF NOT EXISTS soulbah.tool_tests (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  build_id      uuid NOT NULL REFERENCES soulbah.tool_builds(id) ON DELETE CASCADE,
  name          text NOT NULL CONSTRAINT tool_tests_name_length CHECK (length(name) BETWEEN 1 AND 200),
  kind          text NOT NULL DEFAULT 'sandbox' CONSTRAINT tool_tests_kind_check CHECK (kind IN ('unit', 'integration', 'security', 'sandbox')),
  status        text NOT NULL DEFAULT 'pending' CONSTRAINT tool_tests_status_check CHECK (status IN ('pending', 'passed', 'failed')),
  evidence_ids  jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT tool_tests_evidence_array CHECK (soulbah.is_json_array(evidence_ids)),
  created_at    timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz,
  CONSTRAINT tool_tests_unique UNIQUE (build_id, name)
);
COMMENT ON TABLE soulbah.tool_tests IS 'Tests d''une construction d''outil, avec preuves.';
ALTER TABLE soulbah.tool_tests ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.tool_security_reviews (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  build_id       uuid NOT NULL REFERENCES soulbah.tool_builds(id) ON DELETE RESTRICT,
  reviewer_type  text NOT NULL CONSTRAINT tool_security_reviews_reviewer_type_check CHECK (reviewer_type IN ('agent', 'human')),
  reviewer_id    text NOT NULL CONSTRAINT tool_security_reviews_reviewer_id_length CHECK (length(reviewer_id) BETWEEN 1 AND 200),
  verdict        text NOT NULL CONSTRAINT tool_security_reviews_verdict_check CHECK (verdict IN ('approved', 'rejected', 'changes_requested')),
  findings       jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT tool_security_reviews_findings_array CHECK (soulbah.is_json_array(findings)),
  created_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.tool_security_reviews IS 'Revues de sécurité d''une construction d''outil (ajout seul) ; une revue humaine est exigée avant promotion.';
ALTER TABLE soulbah.tool_security_reviews ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_tool_security_reviews_build ON soulbah.tool_security_reviews (build_id);
DROP TRIGGER IF EXISTS tool_security_reviews_append_only ON soulbah.tool_security_reviews;
CREATE TRIGGER tool_security_reviews_append_only BEFORE UPDATE OR DELETE ON soulbah.tool_security_reviews FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS tool_security_reviews_no_truncate ON soulbah.tool_security_reviews;
CREATE TRIGGER tool_security_reviews_no_truncate BEFORE TRUNCATE ON soulbah.tool_security_reviews FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

-- Promotion d'un candidat : exige un build réussi, ses tests passés et une revue de sécurité humaine approuvée.
CREATE OR REPLACE FUNCTION soulbah.tool_candidates_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.status = 'promoted' AND (TG_OP = 'INSERT' OR OLD.status <> 'promoted') THEN
    IF NOT EXISTS (
      SELECT 1 FROM soulbah.tool_builds b
       WHERE b.candidate_id = NEW.id AND b.status = 'succeeded'
         AND EXISTS (SELECT 1 FROM soulbah.tool_tests t WHERE t.build_id = b.id)
         AND NOT EXISTS (SELECT 1 FROM soulbah.tool_tests t WHERE t.build_id = b.id AND t.status <> 'passed')
         AND EXISTS (SELECT 1 FROM soulbah.tool_security_reviews r WHERE r.build_id = b.id AND r.reviewer_type = 'human' AND r.verdict = 'approved')) THEN
      RAISE EXCEPTION 'soulbah.tool_candidates : promotion refusée — il faut un build réussi, tous ses tests passés et une revue de sécurité humaine approuvée'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS tool_candidates_guard ON soulbah.tool_candidates;
CREATE TRIGGER tool_candidates_guard BEFORE INSERT OR UPDATE ON soulbah.tool_candidates FOR EACH ROW EXECUTE FUNCTION soulbah.tool_candidates_guard();

-- Même règle pour les compétences : une version ne devient active qu'avec au moins un test passé.
CREATE OR REPLACE FUNCTION soulbah.skill_versions_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.status = 'active' AND (TG_OP = 'INSERT' OR OLD.status <> 'active') THEN
    IF NOT EXISTS (SELECT 1 FROM soulbah.skill_tests t WHERE t.version_id = NEW.id AND t.last_result = 'passed')
       OR EXISTS (SELECT 1 FROM soulbah.skill_tests t WHERE t.version_id = NEW.id AND t.last_result = 'failed') THEN
      RAISE EXCEPTION 'soulbah.skill_versions : activation refusée — au moins un test passé et aucun test en échec'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS skill_versions_guard ON soulbah.skill_versions;
CREATE TRIGGER skill_versions_guard BEFORE INSERT OR UPDATE ON soulbah.skill_versions FOR EACH ROW EXECUTE FUNCTION soulbah.skill_versions_guard();

DO $$
DECLARE r text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['skill_versions', 'skill_steps', 'skill_requirements', 'skill_tools', 'skill_tests', 'skill_metrics', 'skill_candidates',
                           'tools', 'tool_versions', 'tool_permissions', 'tool_health', 'tool_benchmarks', 'tool_candidates', 'tool_builds',
                           'tool_tests', 'tool_security_reviews'] LOOP
    EXECUTE format('REVOKE ALL ON soulbah.%I FROM PUBLIC', t);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON soulbah.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.tool_candidates_guard(), soulbah.skill_versions_guard() FROM %I', r);
    END IF;
  END LOOP;
END $$;
