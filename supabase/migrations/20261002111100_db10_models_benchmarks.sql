-- =============================================================================
-- DB LOT 10 — Modèles, benchmarks, jeux de données, entraînement (Intelligence Lab).
-- Registre des modèles (métadonnées : le fichier reste dans %LOCALAPPDATA%\Soulbah\models), versions, matériel,
-- statut de sécurité, capacités mesurées, règles et historique de routage, compétitions champion/challenger,
-- candidats (téléchargement toujours approuvé par un humain), mode ombre, benchmarks versionnés et gelés, tâches
-- de référence, jeux de données, configurations et exécutions d'entraînement (toujours approuvées).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002111100_db10_models_benchmarks.down.sql (les mesures seraient perdues : réexportables depuis le registre local)
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03, db06 (embedding_models), db09 (tool_benchmarks).
-- =============================================================================

-- 1. Modèles --------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.models (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL UNIQUE CONSTRAINT models_name_format CHECK (name ~ '^[a-z0-9][a-z0-9._-]{0,119}$'),
  display_name  text NOT NULL CONSTRAINT models_display_length CHECK (length(display_name) BETWEEN 1 AND 200),
  family        text NOT NULL CONSTRAINT models_family_length CHECK (length(family) BETWEEN 1 AND 100),
  kind          text NOT NULL CONSTRAINT models_kind_check CHECK (kind IN ('llm', 'embedding', 'reranker', 'vision', 'audio', 'classifier', 'other')),
  provider      text NOT NULL CONSTRAINT models_provider_check CHECK (provider IN ('local', 'cloud')),
  vendor        text CONSTRAINT models_vendor_length CHECK (vendor IS NULL OR length(vendor) <= 100),
  license       text CONSTRAINT models_license_length CHECK (license IS NULL OR length(license) <= 100),
  license_url   text CONSTRAINT models_license_url_length CHECK (license_url IS NULL OR length(license_url) <= 500),
  status        text NOT NULL DEFAULT 'candidate' CONSTRAINT models_status_check CHECK (status IN ('candidate', 'active', 'deprecated', 'retired', 'quarantined')),
  description   text NOT NULL DEFAULT '' CONSTRAINT models_description_length CHECK (length(description) <= 2000),
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT models_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.models IS 'Registre des modèles (métadonnées) : famille, genre, fournisseur local/cloud, licence, statut. Les fichiers restent dans le registre local.';
ALTER TABLE soulbah.models ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.models', '{"name": "text", "kind": "text", "provider": "text", "status": "text"}');
DROP TRIGGER IF EXISTS models_set_updated_at ON soulbah.models;
CREATE TRIGGER models_set_updated_at BEFORE UPDATE ON soulbah.models FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.model_versions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_id           uuid NOT NULL REFERENCES soulbah.models(id) ON DELETE CASCADE,
  version            text NOT NULL CONSTRAINT model_versions_version_length CHECK (length(version) BETWEEN 1 AND 100),
  registry_key       text UNIQUE CONSTRAINT model_versions_registry_key_length CHECK (registry_key IS NULL OR length(registry_key) <= 200),
  file_name          text CONSTRAINT model_versions_file_name_length CHECK (file_name IS NULL OR length(file_name) <= 300),
  sha256             text CONSTRAINT model_versions_sha256_format CHECK (sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes         bigint CONSTRAINT model_versions_size_positive CHECK (size_bytes IS NULL OR size_bytes >= 0),
  quantization       text CONSTRAINT model_versions_quant_length CHECK (quantization IS NULL OR length(quantization) <= 40),
  context_length     integer CONSTRAINT model_versions_context_positive CHECK (context_length IS NULL OR context_length > 0),
  parameters_b       numeric(8, 3) CONSTRAINT model_versions_params_positive CHECK (parameters_b IS NULL OR parameters_b > 0),
  runtime            text CONSTRAINT model_versions_runtime_length CHECK (runtime IS NULL OR length(runtime) <= 60),
  source_kind        text CONSTRAINT model_versions_source_kind_check CHECK (source_kind IS NULL OR source_kind IN ('huggingface', 'vendor_api', 'training', 'import', 'other')),
  source_ref         text CONSTRAINT model_versions_source_ref_length CHECK (source_ref IS NULL OR length(source_ref) <= 500),
  source_revision    text CONSTRAINT model_versions_source_rev_length CHECK (source_revision IS NULL OR length(source_revision) <= 120),
  status             text NOT NULL DEFAULT 'candidate' CONSTRAINT model_versions_status_check CHECK (status IN ('candidate', 'validated', 'active', 'shadow', 'retired')),
  installed          boolean NOT NULL DEFAULT false,
  installed_at       timestamptz,
  metadata           jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT model_versions_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_versions_unique UNIQUE (model_id, version)
);
COMMENT ON TABLE soulbah.model_versions IS 'Versions concrètes (fichier, empreinte, quantification, contexte, source épinglée) ; active seulement après statut de sécurité approuvé (trigger).';
ALTER TABLE soulbah.model_versions ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.model_versions', '{"model_id": "uuid", "sha256": "text", "status": "text", "installed": "boolean"}');
CREATE INDEX IF NOT EXISTS idx_model_versions_status ON soulbah.model_versions (model_id, status);
DROP TRIGGER IF EXISTS model_versions_set_updated_at ON soulbah.model_versions;
CREATE TRIGGER model_versions_set_updated_at BEFORE UPDATE ON soulbah.model_versions FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.model_hardware_requirements (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id           uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE CASCADE,
  profile              text NOT NULL DEFAULT 'cpu' CONSTRAINT model_hardware_profile_check CHECK (profile IN ('cpu', 'gpu', 'hybrid')),
  min_ram_mb           integer CONSTRAINT model_hardware_ram_positive CHECK (min_ram_mb IS NULL OR min_ram_mb >= 0),
  min_vram_mb          integer CONSTRAINT model_hardware_vram_positive CHECK (min_vram_mb IS NULL OR min_vram_mb >= 0),
  cpu_threads          integer CONSTRAINT model_hardware_threads_positive CHECK (cpu_threads IS NULL OR cpu_threads > 0),
  disk_mb              integer CONSTRAINT model_hardware_disk_positive CHECK (disk_mb IS NULL OR disk_mb >= 0),
  measured             boolean NOT NULL DEFAULT false,
  measured_tokens_per_s real CONSTRAINT model_hardware_tps_positive CHECK (measured_tokens_per_s IS NULL OR measured_tokens_per_s >= 0),
  measured_on          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT model_hardware_measured_on_object CHECK (soulbah.is_json_object(measured_on)),
  notes                text NOT NULL DEFAULT '' CONSTRAINT model_hardware_notes_length CHECK (length(notes) <= 2000),
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_hardware_requirements_unique UNIQUE (version_id, profile)
);
COMMENT ON TABLE soulbah.model_hardware_requirements IS 'Besoins matériels par version et profil (déclarés ou mesurés : RAM, VRAM, threads, débit) — pour choisir ce qui tourne sur la machine réelle.';
ALTER TABLE soulbah.model_hardware_requirements ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.model_security_status (
  version_id         uuid PRIMARY KEY REFERENCES soulbah.model_versions(id) ON DELETE CASCADE,
  status             text NOT NULL DEFAULT 'unknown' CONSTRAINT model_security_status_check CHECK (status IN ('unknown', 'checked', 'approved', 'rejected', 'quarantined')),
  checksum_verified  boolean,
  source_verified    boolean,
  license_ok         boolean,
  findings           jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT model_security_findings_array CHECK (soulbah.is_json_array(findings)),
  checked_by         text,
  checked_at         timestamptz,
  approved_by        text,
  approved_at        timestamptz,
  notes              text NOT NULL DEFAULT '' CONSTRAINT model_security_notes_length CHECK (length(notes) <= 4000),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_security_approved_by_human CHECK (status <> 'approved' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL AND checksum_verified IS TRUE AND license_ok IS TRUE))
);
COMMENT ON TABLE soulbah.model_security_status IS 'Statut de sécurité d''une version : empreinte, source et licence vérifiées, constats ; approved exige un approbateur humain, l''empreinte et la licence vérifiées.';
ALTER TABLE soulbah.model_security_status ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS model_security_status_set_updated_at ON soulbah.model_security_status;
CREATE TRIGGER model_security_status_set_updated_at BEFORE UPDATE ON soulbah.model_security_status FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- Une version ne devient active (ou ombre) qu'avec un statut de sécurité approuvé et une empreinte connue.
CREATE OR REPLACE FUNCTION soulbah.model_versions_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.status IN ('active', 'shadow') AND (TG_OP = 'INSERT' OR OLD.status NOT IN ('active', 'shadow')) THEN
    IF NEW.sha256 IS NULL AND NEW.source_kind <> 'vendor_api' THEN
      RAISE EXCEPTION 'soulbah.model_versions : activation refusée — empreinte SHA-256 absente' USING ERRCODE = 'check_violation';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM soulbah.model_security_status s WHERE s.version_id = NEW.id AND s.status = 'approved') THEN
      RAISE EXCEPTION 'soulbah.model_versions : activation refusée — statut de sécurité non approuvé' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS model_versions_guard ON soulbah.model_versions;
CREATE TRIGGER model_versions_guard BEFORE INSERT OR UPDATE ON soulbah.model_versions FOR EACH ROW EXECUTE FUNCTION soulbah.model_versions_guard();

-- 2. Benchmarks et tâches de référence -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.benchmarks (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                text NOT NULL UNIQUE CONSTRAINT benchmarks_name_format CHECK (name ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  domain              text NOT NULL CONSTRAINT benchmarks_domain_check CHECK (domain IN (
                        'reasoning', 'planning', 'code', 'code_review', 'sql', 'security', 'documentation', 'french', 'tools', 'memory', 'ui', 'embedding', 'mixed')),
  description         text NOT NULL DEFAULT '' CONSTRAINT benchmarks_description_length CHECK (length(description) <= 2000),
  current_version_id  uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.benchmarks IS 'Suites d''évaluation internes, par domaine ; chaque version est gelée pour que deux exécutions soient comparables.';
ALTER TABLE soulbah.benchmarks ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS benchmarks_set_updated_at ON soulbah.benchmarks;
CREATE TRIGGER benchmarks_set_updated_at BEFORE UPDATE ON soulbah.benchmarks FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.benchmark_versions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  benchmark_id  uuid NOT NULL REFERENCES soulbah.benchmarks(id) ON DELETE CASCADE,
  version       integer NOT NULL CONSTRAINT benchmark_versions_version_positive CHECK (version >= 1),
  spec          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT benchmark_versions_spec_object CHECK (soulbah.is_json_object(spec)),
  frozen        boolean NOT NULL DEFAULT false,
  checksum      text CONSTRAINT benchmark_versions_checksum_format CHECK (checksum IS NULL OR checksum ~ '^[0-9a-f]{64}$'),
  created_at    timestamptz NOT NULL DEFAULT now(),
  frozen_at     timestamptz,
  CONSTRAINT benchmark_versions_unique UNIQUE (benchmark_id, version),
  CONSTRAINT benchmark_versions_frozen_dated CHECK (NOT frozen OR frozen_at IS NOT NULL)
);
COMMENT ON TABLE soulbah.benchmark_versions IS 'Versions d''un benchmark ; une version gelée ne change plus (ses tâches non plus).';
ALTER TABLE soulbah.benchmark_versions ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'benchmarks_current_version_fkey') THEN
    ALTER TABLE soulbah.benchmarks ADD CONSTRAINT benchmarks_current_version_fkey
      FOREIGN KEY (current_version_id) REFERENCES soulbah.benchmark_versions(id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_benchmarks_current_version ON soulbah.benchmarks (current_version_id);

CREATE TABLE IF NOT EXISTS soulbah.golden_tasks (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key          text NOT NULL UNIQUE CONSTRAINT golden_tasks_key_format CHECK (key ~ '^[a-z][a-z0-9_.-]{0,119}$'),
  domain       text NOT NULL CONSTRAINT golden_tasks_domain_length CHECK (length(domain) BETWEEN 1 AND 60),
  project_id   uuid REFERENCES soulbah.projects(id) ON DELETE SET NULL,
  description  text NOT NULL CONSTRAINT golden_tasks_description_length CHECK (length(description) BETWEEN 1 AND 4000),
  input        jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT golden_tasks_input_object CHECK (soulbah.is_json_object(input)),
  difficulty   text NOT NULL DEFAULT 'medium' CONSTRAINT golden_tasks_difficulty_check CHECK (difficulty IN ('easy', 'medium', 'hard')),
  status       text NOT NULL DEFAULT 'draft' CONSTRAINT golden_tasks_status_check CHECK (status IN ('draft', 'active', 'retired')),
  created_by   text NOT NULL DEFAULT current_user,
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.golden_tasks IS 'Tâches de référence (réelles, issues des projets ou des incidents) servant d''étalon aux benchmarks et aux régressions.';
ALTER TABLE soulbah.golden_tasks ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_golden_tasks_project ON soulbah.golden_tasks (project_id);

CREATE TABLE IF NOT EXISTS soulbah.golden_task_expected_results (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  golden_task_id  uuid NOT NULL REFERENCES soulbah.golden_tasks(id) ON DELETE CASCADE,
  version         integer NOT NULL DEFAULT 1 CONSTRAINT golden_expected_version_positive CHECK (version >= 1),
  expected        jsonb NOT NULL CONSTRAINT golden_expected_object CHECK (soulbah.is_json_object(expected)),
  scoring         text NOT NULL DEFAULT 'exact' CONSTRAINT golden_expected_scoring_check CHECK (scoring IN ('exact', 'contains', 'json_schema', 'test_suite', 'rubric', 'human')),
  validated_by    text,
  validated_at    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT golden_task_expected_results_unique UNIQUE (golden_task_id, version)
);
COMMENT ON TABLE soulbah.golden_task_expected_results IS 'Résultat attendu versionné d''une tâche de référence et méthode de notation.';
ALTER TABLE soulbah.golden_task_expected_results ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.benchmark_tasks (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  benchmark_version_id  uuid NOT NULL REFERENCES soulbah.benchmark_versions(id) ON DELETE CASCADE,
  key                   text NOT NULL CONSTRAINT benchmark_tasks_key_format CHECK (key ~ '^[a-z][a-z0-9_.-]{0,119}$'),
  golden_task_id        uuid REFERENCES soulbah.golden_tasks(id) ON DELETE SET NULL,
  input                 jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT benchmark_tasks_input_object CHECK (soulbah.is_json_object(input)),
  expected              jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT benchmark_tasks_expected_object CHECK (soulbah.is_json_object(expected)),
  scoring               text NOT NULL DEFAULT 'exact' CONSTRAINT benchmark_tasks_scoring_check CHECK (scoring IN ('exact', 'contains', 'json_schema', 'test_suite', 'rubric', 'human')),
  weight                numeric(6, 3) NOT NULL DEFAULT 1 CONSTRAINT benchmark_tasks_weight_positive CHECK (weight > 0),
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT benchmark_tasks_unique UNIQUE (benchmark_version_id, key)
);
COMMENT ON TABLE soulbah.benchmark_tasks IS 'Tâches d''une version de benchmark (entrée, attendu, notation, poids).';
ALTER TABLE soulbah.benchmark_tasks ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_benchmark_tasks_golden ON soulbah.benchmark_tasks (golden_task_id);

-- Les tâches d'une version gelée ne changent plus.
CREATE OR REPLACE FUNCTION soulbah.benchmark_tasks_freeze()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
DECLARE v uuid;
BEGIN
  v := COALESCE(NEW.benchmark_version_id, OLD.benchmark_version_id);
  IF EXISTS (SELECT 1 FROM soulbah.benchmark_versions b WHERE b.id = v AND b.frozen) THEN
    RAISE EXCEPTION 'soulbah.benchmark_tasks : version de benchmark gelée — % refusé', TG_OP USING ERRCODE = 'check_violation';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
DROP TRIGGER IF EXISTS benchmark_tasks_freeze ON soulbah.benchmark_tasks;
CREATE TRIGGER benchmark_tasks_freeze BEFORE INSERT OR UPDATE OR DELETE ON soulbah.benchmark_tasks FOR EACH ROW EXECUTE FUNCTION soulbah.benchmark_tasks_freeze();

-- 3. Jeux de données ---------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.datasets (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                text NOT NULL UNIQUE CONSTRAINT datasets_name_format CHECK (name ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  purpose             text NOT NULL CONSTRAINT datasets_purpose_check CHECK (purpose IN ('evaluation', 'regression', 'training', 'fine_tuning', 'distillation')),
  domain              text NOT NULL DEFAULT 'mixed' CONSTRAINT datasets_domain_length CHECK (length(domain) BETWEEN 1 AND 60),
  -- Jamais de données secrètes dans un jeu de données (§65) ; les données confidentielles exigent une source consentie.
  sensitivity         text NOT NULL DEFAULT 'internal' CONSTRAINT datasets_sensitivity_check CHECK (sensitivity IN ('public', 'internal', 'confidential')),
  license             text CONSTRAINT datasets_license_length CHECK (license IS NULL OR length(license) <= 100),
  description         text NOT NULL DEFAULT '' CONSTRAINT datasets_description_length CHECK (length(description) <= 2000),
  current_version_id  uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.datasets IS 'Jeux de données (évaluation, régression, entraînement) : usage, domaine, sensibilité — jamais de secrets.';
ALTER TABLE soulbah.datasets ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS datasets_set_updated_at ON soulbah.datasets;
CREATE TRIGGER datasets_set_updated_at BEFORE UPDATE ON soulbah.datasets FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.dataset_versions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dataset_id   uuid NOT NULL REFERENCES soulbah.datasets(id) ON DELETE CASCADE,
  version      integer NOT NULL CONSTRAINT dataset_versions_version_positive CHECK (version >= 1),
  item_count   integer NOT NULL DEFAULT 0 CONSTRAINT dataset_versions_count_positive CHECK (item_count >= 0),
  checksum     text CONSTRAINT dataset_versions_checksum_format CHECK (checksum IS NULL OR checksum ~ '^[0-9a-f]{64}$'),
  artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  frozen       boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now(),
  frozen_at    timestamptz,
  CONSTRAINT dataset_versions_unique UNIQUE (dataset_id, version),
  CONSTRAINT dataset_versions_frozen_dated CHECK (NOT frozen OR frozen_at IS NOT NULL)
);
COMMENT ON TABLE soulbah.dataset_versions IS 'Versions d''un jeu de données (empreinte, artefact exporté, gel).';
ALTER TABLE soulbah.dataset_versions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_dataset_versions_artifact ON soulbah.dataset_versions (artifact_id);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'datasets_current_version_fkey') THEN
    ALTER TABLE soulbah.datasets ADD CONSTRAINT datasets_current_version_fkey
      FOREIGN KEY (current_version_id) REFERENCES soulbah.dataset_versions(id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_datasets_current_version ON soulbah.datasets (current_version_id);

CREATE TABLE IF NOT EXISTS soulbah.dataset_sources (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dataset_id  uuid NOT NULL REFERENCES soulbah.datasets(id) ON DELETE CASCADE,
  kind        text NOT NULL CONSTRAINT dataset_sources_kind_check CHECK (kind IN ('project_history', 'golden_tasks', 'incidents', 'research', 'synthetic', 'human', 'public_dataset')),
  ref         text NOT NULL CONSTRAINT dataset_sources_ref_length CHECK (length(ref) BETWEEN 1 AND 500),
  license     text CONSTRAINT dataset_sources_license_length CHECK (license IS NULL OR length(license) <= 100),
  consent_ok  boolean NOT NULL DEFAULT false,
  notes       text NOT NULL DEFAULT '' CONSTRAINT dataset_sources_notes_length CHECK (length(notes) <= 2000),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dataset_sources_unique UNIQUE (dataset_id, kind, ref)
);
COMMENT ON TABLE soulbah.dataset_sources IS 'Provenance des données (historique projet, tâches de référence, incidents, recherche, synthèse, humain, jeu public) et consentement.';
ALTER TABLE soulbah.dataset_sources ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.dataset_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id    uuid NOT NULL REFERENCES soulbah.dataset_versions(id) ON DELETE CASCADE,
  key           text NOT NULL CONSTRAINT dataset_items_key_length CHECK (length(key) BETWEEN 1 AND 200),
  source_id     uuid REFERENCES soulbah.dataset_sources(id) ON DELETE SET NULL,
  input         jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT dataset_items_input_object CHECK (soulbah.is_json_object(input)),
  expected      jsonb CONSTRAINT dataset_items_expected_object CHECK (expected IS NULL OR soulbah.is_json_object(expected)),
  quality_flag  text NOT NULL DEFAULT 'ok' CONSTRAINT dataset_items_quality_check CHECK (quality_flag IN ('ok', 'suspect', 'rejected')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dataset_items_unique UNIQUE (version_id, key)
);
COMMENT ON TABLE soulbah.dataset_items IS 'Éléments d''une version de jeu de données (entrée, attendu, source, qualité).';
ALTER TABLE soulbah.dataset_items ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_dataset_items_source ON soulbah.dataset_items (source_id);

CREATE TABLE IF NOT EXISTS soulbah.dataset_quality_checks (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id  uuid NOT NULL REFERENCES soulbah.dataset_versions(id) ON DELETE CASCADE,
  check_name  text NOT NULL CONSTRAINT dataset_quality_check_name_format CHECK (check_name ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  status      text NOT NULL CONSTRAINT dataset_quality_status_check CHECK (status IN ('passed', 'warning', 'failed')),
  detail      jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT dataset_quality_detail_object CHECK (soulbah.is_json_object(detail)),
  checked_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dataset_quality_checks_unique UNIQUE (version_id, check_name, checked_at)
);
COMMENT ON TABLE soulbah.dataset_quality_checks IS 'Contrôles de qualité d''une version (doublons, secrets, PII, déséquilibre, taille).';
ALTER TABLE soulbah.dataset_quality_checks ENABLE ROW LEVEL SECURITY;

-- 4. Exécutions et résultats ------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.benchmark_runs (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  benchmark_version_id  uuid NOT NULL REFERENCES soulbah.benchmark_versions(id) ON DELETE RESTRICT,
  subject_kind          text NOT NULL DEFAULT 'model' CONSTRAINT benchmark_runs_subject_kind_check CHECK (subject_kind IN ('model', 'agent', 'tool', 'skill', 'system')),
  model_version_id      uuid REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  subject_ref           text CONSTRAINT benchmark_runs_subject_ref_length CHECK (subject_ref IS NULL OR length(subject_ref) <= 300),
  external_ref          text UNIQUE CONSTRAINT benchmark_runs_external_ref_length CHECK (external_ref IS NULL OR length(external_ref) <= 300),
  status                text NOT NULL DEFAULT 'pending' CONSTRAINT benchmark_runs_status_check CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled')),
  environment           jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT benchmark_runs_environment_object CHECK (soulbah.is_json_object(environment)),
  hardware              jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT benchmark_runs_hardware_object CHECK (soulbah.is_json_object(hardware)),
  seed                  integer,
  score                 numeric(10, 4) CONSTRAINT benchmark_runs_score_positive CHECK (score IS NULL OR score >= 0),
  score_max             numeric(10, 4) CONSTRAINT benchmark_runs_score_max_positive CHECK (score_max IS NULL OR score_max > 0),
  triggered_by          text NOT NULL DEFAULT current_user,
  notes                 text NOT NULL DEFAULT '' CONSTRAINT benchmark_runs_notes_length CHECK (length(notes) <= 4000),
  started_at            timestamptz,
  finished_at           timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT benchmark_runs_subject CHECK ((subject_kind = 'model' AND model_version_id IS NOT NULL) OR (subject_kind <> 'model' AND subject_ref IS NOT NULL)),
  CONSTRAINT benchmark_runs_score_bounded CHECK (score IS NULL OR score_max IS NULL OR score <= score_max),
  CONSTRAINT benchmark_runs_completed_scored CHECK (status <> 'completed' OR (score IS NOT NULL AND score_max IS NOT NULL AND finished_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.benchmark_runs IS 'Exécution d''une version de benchmark sur un sujet (version de modèle, agent, outil, compétence, système) : environnement, matériel, score sur score_max — jamais de score sans exécution.';
ALTER TABLE soulbah.benchmark_runs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_benchmark_runs_version ON soulbah.benchmark_runs (benchmark_version_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_benchmark_runs_model ON soulbah.benchmark_runs (model_version_id);

CREATE TABLE IF NOT EXISTS soulbah.benchmark_results (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id              uuid NOT NULL REFERENCES soulbah.benchmark_runs(id) ON DELETE CASCADE,
  task_id             uuid NOT NULL REFERENCES soulbah.benchmark_tasks(id) ON DELETE RESTRICT,
  passed              boolean,
  score               numeric(10, 4) CONSTRAINT benchmark_results_score_positive CHECK (score IS NULL OR score >= 0),
  score_max           numeric(10, 4) CONSTRAINT benchmark_results_score_max_positive CHECK (score_max IS NULL OR score_max > 0),
  latency_ms          integer CONSTRAINT benchmark_results_latency_positive CHECK (latency_ms IS NULL OR latency_ms >= 0),
  tokens_in           integer CONSTRAINT benchmark_results_tokens_in_positive CHECK (tokens_in IS NULL OR tokens_in >= 0),
  tokens_out          integer CONSTRAINT benchmark_results_tokens_out_positive CHECK (tokens_out IS NULL OR tokens_out >= 0),
  output_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  output_excerpt      text CONSTRAINT benchmark_results_excerpt_length CHECK (output_excerpt IS NULL OR length(output_excerpt) <= 4000),
  error               text,
  detail              jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT benchmark_results_detail_object CHECK (soulbah.is_json_object(detail)),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT benchmark_results_unique UNIQUE (run_id, task_id),
  CONSTRAINT benchmark_results_score_bounded CHECK (score IS NULL OR score_max IS NULL OR score <= score_max)
);
COMMENT ON TABLE soulbah.benchmark_results IS 'Résultat par tâche d''une exécution (réussite, score, latence, jetons, sortie en artefact ou extrait).';
ALTER TABLE soulbah.benchmark_results ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_benchmark_results_task ON soulbah.benchmark_results (task_id);
CREATE INDEX IF NOT EXISTS idx_benchmark_results_artifact ON soulbah.benchmark_results (output_artifact_id);

CREATE TABLE IF NOT EXISTS soulbah.model_benchmarks (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_version_id      uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE CASCADE,
  benchmark_version_id  uuid NOT NULL REFERENCES soulbah.benchmark_versions(id) ON DELETE RESTRICT,
  run_id                uuid NOT NULL REFERENCES soulbah.benchmark_runs(id) ON DELETE CASCADE,
  score                 numeric(10, 4) NOT NULL CONSTRAINT model_benchmarks_score_positive CHECK (score >= 0),
  score_max             numeric(10, 4) NOT NULL CONSTRAINT model_benchmarks_score_max_positive CHECK (score_max > 0),
  passed_count          integer CONSTRAINT model_benchmarks_passed_positive CHECK (passed_count IS NULL OR passed_count >= 0),
  task_count            integer CONSTRAINT model_benchmarks_tasks_positive CHECK (task_count IS NULL OR task_count >= 0),
  measured_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_benchmarks_unique UNIQUE (run_id),
  CONSTRAINT model_benchmarks_score_bounded CHECK (score <= score_max),
  CONSTRAINT model_benchmarks_counts CHECK (passed_count IS NULL OR task_count IS NULL OR passed_count <= task_count)
);
COMMENT ON TABLE soulbah.model_benchmarks IS 'Scores agrégés d''une version de modèle par version de benchmark, toujours adossés à une exécution (run_id).';
ALTER TABLE soulbah.model_benchmarks ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_model_benchmarks_model ON soulbah.model_benchmarks (model_version_id, benchmark_version_id, measured_at DESC);
CREATE INDEX IF NOT EXISTS idx_model_benchmarks_benchmark ON soulbah.model_benchmarks (benchmark_version_id);

CREATE TABLE IF NOT EXISTS soulbah.model_capabilities (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id       uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE CASCADE,
  capability       text NOT NULL CONSTRAINT model_capabilities_format CHECK (capability ~ '^[a-z][a-z0-9_.]{0,59}$'),
  level            text NOT NULL DEFAULT 'unknown' CONSTRAINT model_capabilities_level_check CHECK (level IN ('unknown', 'none', 'weak', 'usable', 'strong')),
  measured         boolean NOT NULL DEFAULT false,
  evidence_run_id  uuid REFERENCES soulbah.benchmark_runs(id) ON DELETE SET NULL,
  notes            text NOT NULL DEFAULT '' CONSTRAINT model_capabilities_notes_length CHECK (length(notes) <= 2000),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_capabilities_unique UNIQUE (version_id, capability),
  CONSTRAINT model_capabilities_measured_evidence CHECK (NOT measured OR evidence_run_id IS NOT NULL)
);
COMMENT ON TABLE soulbah.model_capabilities IS 'Capacités d''une version (json_schema, planning, french, code_review, embedding…) : déclarées ou mesurées — mesuré exige une exécution de benchmark.';
ALTER TABLE soulbah.model_capabilities ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_model_capabilities_run ON soulbah.model_capabilities (evidence_run_id);
DROP TRIGGER IF EXISTS model_capabilities_set_updated_at ON soulbah.model_capabilities;
CREATE TRIGGER model_capabilities_set_updated_at BEFORE UPDATE ON soulbah.model_capabilities FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- 5. Routage ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.model_routing_rules (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                 text NOT NULL UNIQUE CONSTRAINT model_routing_rules_name_format CHECK (name ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  priority             integer NOT NULL DEFAULT 100 CONSTRAINT model_routing_rules_priority_range CHECK (priority BETWEEN 0 AND 10000),
  task_kind            text NOT NULL DEFAULT 'any' CONSTRAINT model_routing_rules_task_kind_check CHECK (task_kind IN ('any', 'chat', 'plan', 'code', 'review', 'summarize', 'classify', 'embed', 'rerank', 'extract')),
  network_mode         text NOT NULL DEFAULT 'ANY' CONSTRAINT model_routing_rules_mode_check CHECK (network_mode IN ('ANY', 'OFFLINE', 'LOCAL_INTERNET', 'HYBRID')),
  model_version_id     uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  fallback_version_id  uuid REFERENCES soulbah.model_versions(id) ON DELETE SET NULL,
  conditions           jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT model_routing_rules_conditions_object CHECK (soulbah.is_json_object(conditions)),
  enabled              boolean NOT NULL DEFAULT true,
  created_by           text NOT NULL DEFAULT current_user,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_routing_rules_fallback_differs CHECK (fallback_version_id IS NULL OR fallback_version_id <> model_version_id)
);
COMMENT ON TABLE soulbah.model_routing_rules IS 'Règles de routage (genre de tâche, mode réseau, conditions) vers une version active, avec repli ; se désactivent, ne se suppriment pas si un historique existe.';
ALTER TABLE soulbah.model_routing_rules ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_model_routing_rules_target ON soulbah.model_routing_rules (model_version_id);
CREATE INDEX IF NOT EXISTS idx_model_routing_rules_fallback ON soulbah.model_routing_rules (fallback_version_id);
CREATE INDEX IF NOT EXISTS idx_model_routing_rules_lookup ON soulbah.model_routing_rules (task_kind, network_mode, priority) WHERE enabled;
DROP TRIGGER IF EXISTS model_routing_rules_set_updated_at ON soulbah.model_routing_rules;
CREATE TRIGGER model_routing_rules_set_updated_at BEFORE UPDATE ON soulbah.model_routing_rules FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE OR REPLACE FUNCTION soulbah.model_routing_rules_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.enabled AND NOT EXISTS (SELECT 1 FROM soulbah.model_versions v WHERE v.id = NEW.model_version_id AND v.status = 'active') THEN
    RAISE EXCEPTION 'soulbah.model_routing_rules : la cible doit être une version de modèle active' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS model_routing_rules_guard ON soulbah.model_routing_rules;
CREATE TRIGGER model_routing_rules_guard BEFORE INSERT OR UPDATE ON soulbah.model_routing_rules FOR EACH ROW EXECUTE FUNCTION soulbah.model_routing_rules_guard();

CREATE TABLE IF NOT EXISTS soulbah.model_routing_history (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rule_id              uuid REFERENCES soulbah.model_routing_rules(id) ON DELETE RESTRICT,
  chosen_version_id    uuid REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  session_id           uuid,
  task_id              uuid,
  task_kind            text NOT NULL CONSTRAINT model_routing_history_task_kind_length CHECK (length(task_kind) BETWEEN 1 AND 40),
  network_mode         text NOT NULL CONSTRAINT model_routing_history_mode_length CHECK (length(network_mode) BETWEEN 1 AND 40),
  fallback_used        boolean NOT NULL DEFAULT false,
  reason               text NOT NULL DEFAULT '' CONSTRAINT model_routing_history_reason_length CHECK (length(reason) <= 1000),
  latency_ms           integer CONSTRAINT model_routing_history_latency_positive CHECK (latency_ms IS NULL OR latency_ms >= 0),
  tokens_in            integer CONSTRAINT model_routing_history_tokens_in_positive CHECK (tokens_in IS NULL OR tokens_in >= 0),
  tokens_out           integer CONSTRAINT model_routing_history_tokens_out_positive CHECK (tokens_out IS NULL OR tokens_out >= 0),
  outcome              text NOT NULL DEFAULT 'unknown' CONSTRAINT model_routing_history_outcome_check CHECK (outcome IN ('unknown', 'ok', 'error', 'timeout', 'refused', 'busy')),
  decided_at           timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.model_routing_history IS 'Journal (ajout seul) de chaque décision de routage : règle, version choisie, repli, latence, jetons, issue — base des mesures réelles.';
ALTER TABLE soulbah.model_routing_history ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_model_routing_history_version ON soulbah.model_routing_history (chosen_version_id, id);
CREATE INDEX IF NOT EXISTS idx_model_routing_history_rule ON soulbah.model_routing_history (rule_id);
CREATE INDEX IF NOT EXISTS idx_model_routing_history_task ON soulbah.model_routing_history (task_id);
DROP TRIGGER IF EXISTS model_routing_history_append_only ON soulbah.model_routing_history;
CREATE TRIGGER model_routing_history_append_only BEFORE UPDATE OR DELETE ON soulbah.model_routing_history FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS model_routing_history_no_truncate ON soulbah.model_routing_history;
CREATE TRIGGER model_routing_history_no_truncate BEFORE TRUNCATE ON soulbah.model_routing_history FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

-- 6. Candidats, compétitions, mode ombre -----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.model_candidates (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_id              uuid REFERENCES soulbah.models(id) ON DELETE SET NULL,
  version_id            uuid REFERENCES soulbah.model_versions(id) ON DELETE SET NULL,
  name                  text NOT NULL CONSTRAINT model_candidates_name_length CHECK (length(name) BETWEEN 1 AND 200),
  source                text NOT NULL CONSTRAINT model_candidates_source_check CHECK (source IN ('download', 'training', 'import', 'vendor_api')),
  source_ref            text CONSTRAINT model_candidates_source_ref_length CHECK (source_ref IS NULL OR length(source_ref) <= 500),
  size_bytes            bigint CONSTRAINT model_candidates_size_positive CHECK (size_bytes IS NULL OR size_bytes >= 0),
  rationale             text NOT NULL DEFAULT '' CONSTRAINT model_candidates_rationale_length CHECK (length(rationale) <= 4000),
  proposed_by           text NOT NULL DEFAULT current_user,
  status                text NOT NULL DEFAULT 'proposed' CONSTRAINT model_candidates_status_check CHECK (status IN (
                          'proposed', 'download_approved', 'downloading', 'installed', 'benchmarking', 'security_review', 'approved', 'rejected', 'promoted')),
  download_approved_by  text,
  download_approved_at  timestamptz,
  decided_by            text,
  decided_at            timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  -- Aucun téléchargement sans approbation humaine explicite (règle de la mission).
  CONSTRAINT model_candidates_download_approved CHECK (source <> 'download' OR status IN ('proposed', 'rejected') OR (download_approved_by IS NOT NULL AND download_approved_at IS NOT NULL)),
  CONSTRAINT model_candidates_decided CHECK (status NOT IN ('approved', 'rejected', 'promoted') OR (decided_by IS NOT NULL AND decided_at IS NOT NULL)),
  CONSTRAINT model_candidates_promoted CHECK (status <> 'promoted' OR version_id IS NOT NULL)
);
COMMENT ON TABLE soulbah.model_candidates IS 'Modèles candidats : un téléchargement exige une approbation humaine explicite ; promotion seulement après benchmarks et revue de sécurité.';
ALTER TABLE soulbah.model_candidates ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_model_candidates_status ON soulbah.model_candidates (status);
CREATE INDEX IF NOT EXISTS idx_model_candidates_model ON soulbah.model_candidates (model_id);
CREATE INDEX IF NOT EXISTS idx_model_candidates_version ON soulbah.model_candidates (version_id);
DROP TRIGGER IF EXISTS model_candidates_set_updated_at ON soulbah.model_candidates;
CREATE TRIGGER model_candidates_set_updated_at BEFORE UPDATE ON soulbah.model_candidates FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.model_competitions (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                   text NOT NULL UNIQUE CONSTRAINT model_competitions_name_format CHECK (name ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  task_kind              text NOT NULL DEFAULT 'any' CONSTRAINT model_competitions_task_kind_length CHECK (length(task_kind) BETWEEN 1 AND 40),
  champion_version_id    uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  challenger_version_id  uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  benchmark_version_id   uuid NOT NULL REFERENCES soulbah.benchmark_versions(id) ON DELETE RESTRICT,
  status                 text NOT NULL DEFAULT 'planned' CONSTRAINT model_competitions_status_check CHECK (status IN ('planned', 'running', 'completed', 'cancelled')),
  winner_version_id      uuid REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  decision               text NOT NULL DEFAULT '' CONSTRAINT model_competitions_decision_length CHECK (length(decision) <= 4000),
  decided_by             text,
  decided_at             timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_competitions_distinct CHECK (champion_version_id <> challenger_version_id),
  CONSTRAINT model_competitions_winner_valid CHECK (winner_version_id IS NULL OR winner_version_id IN (champion_version_id, challenger_version_id)),
  CONSTRAINT model_competitions_completed CHECK (status <> 'completed' OR (winner_version_id IS NOT NULL AND decided_by IS NOT NULL AND decided_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.model_competitions IS 'Champion contre challenger sur une version de benchmark gelée ; le vainqueur est l''un des deux et la décision est signée.';
ALTER TABLE soulbah.model_competitions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_model_competitions_champion ON soulbah.model_competitions (champion_version_id);
CREATE INDEX IF NOT EXISTS idx_model_competitions_challenger ON soulbah.model_competitions (challenger_version_id);
CREATE INDEX IF NOT EXISTS idx_model_competitions_benchmark ON soulbah.model_competitions (benchmark_version_id);
CREATE INDEX IF NOT EXISTS idx_model_competitions_winner ON soulbah.model_competitions (winner_version_id);

CREATE TABLE IF NOT EXISTS soulbah.model_comparison_results (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  competition_id    uuid NOT NULL REFERENCES soulbah.model_competitions(id) ON DELETE CASCADE,
  metric            text NOT NULL CONSTRAINT model_comparison_metric_format CHECK (metric ~ '^[a-z][a-z0-9_.]{0,99}$'),
  champion_run_id   uuid REFERENCES soulbah.benchmark_runs(id) ON DELETE SET NULL,
  challenger_run_id uuid REFERENCES soulbah.benchmark_runs(id) ON DELETE SET NULL,
  champion_value    numeric(18, 6) NOT NULL,
  challenger_value  numeric(18, 6) NOT NULL,
  higher_is_better  boolean NOT NULL DEFAULT true,
  better            text GENERATED ALWAYS AS (
                      CASE WHEN champion_value = challenger_value THEN 'tie'
                           WHEN (challenger_value > champion_value) = higher_is_better THEN 'challenger' ELSE 'champion' END) STORED,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_comparison_results_unique UNIQUE (competition_id, metric)
);
COMMENT ON TABLE soulbah.model_comparison_results IS 'Comparaison métrique par métrique d''une compétition, adossée aux exécutions ; le meilleur est calculé, pas saisi.';
ALTER TABLE soulbah.model_comparison_results ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_model_comparison_champion_run ON soulbah.model_comparison_results (champion_run_id);
CREATE INDEX IF NOT EXISTS idx_model_comparison_challenger_run ON soulbah.model_comparison_results (challenger_run_id);

CREATE TABLE IF NOT EXISTS soulbah.shadow_runs (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shadow_version_id           uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  primary_version_id          uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  session_id                  uuid,
  task_id                     uuid,
  task_kind                   text NOT NULL DEFAULT 'any' CONSTRAINT shadow_runs_task_kind_length CHECK (length(task_kind) BETWEEN 1 AND 40),
  input_hash                  text CONSTRAINT shadow_runs_input_hash_format CHECK (input_hash IS NULL OR input_hash ~ '^[0-9a-f]{64}$'),
  primary_output_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  shadow_output_artifact_id   uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  primary_latency_ms          integer CONSTRAINT shadow_runs_primary_latency_positive CHECK (primary_latency_ms IS NULL OR primary_latency_ms >= 0),
  shadow_latency_ms           integer CONSTRAINT shadow_runs_shadow_latency_positive CHECK (shadow_latency_ms IS NULL OR shadow_latency_ms >= 0),
  status                      text NOT NULL DEFAULT 'pending' CONSTRAINT shadow_runs_status_check CHECK (status IN ('pending', 'completed', 'failed', 'skipped')),
  created_at                  timestamptz NOT NULL DEFAULT now(),
  finished_at                 timestamptz,
  CONSTRAINT shadow_runs_distinct CHECK (shadow_version_id <> primary_version_id)
);
COMMENT ON TABLE soulbah.shadow_runs IS 'Mode ombre : le challenger reçoit la même entrée que le modèle principal ; sa sortie est enregistrée et comparée, jamais utilisée par la mission.';
ALTER TABLE soulbah.shadow_runs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_shadow_runs_shadow ON soulbah.shadow_runs (shadow_version_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_shadow_runs_primary ON soulbah.shadow_runs (primary_version_id);
CREATE INDEX IF NOT EXISTS idx_shadow_runs_task ON soulbah.shadow_runs (task_id);
CREATE INDEX IF NOT EXISTS idx_shadow_runs_primary_artifact ON soulbah.shadow_runs (primary_output_artifact_id);
CREATE INDEX IF NOT EXISTS idx_shadow_runs_shadow_artifact ON soulbah.shadow_runs (shadow_output_artifact_id);

CREATE TABLE IF NOT EXISTS soulbah.shadow_comparisons (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shadow_run_id  uuid NOT NULL REFERENCES soulbah.shadow_runs(id) ON DELETE CASCADE,
  comparator     text NOT NULL CONSTRAINT shadow_comparisons_comparator_check CHECK (comparator IN ('rules', 'llm', 'human')),
  verdict        text NOT NULL CONSTRAINT shadow_comparisons_verdict_check CHECK (verdict IN ('shadow_better', 'primary_better', 'equivalent', 'undetermined')),
  score          numeric(6, 3) CONSTRAINT shadow_comparisons_score_range CHECK (score IS NULL OR (score >= -1 AND score <= 1)),
  notes          text NOT NULL DEFAULT '' CONSTRAINT shadow_comparisons_notes_length CHECK (length(notes) <= 4000),
  created_by     text NOT NULL DEFAULT current_user,
  created_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.shadow_comparisons IS 'Verdict d''une comparaison ombre/principal (règles, LLM ou humain).';
ALTER TABLE soulbah.shadow_comparisons ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_shadow_comparisons_run ON soulbah.shadow_comparisons (shadow_run_id);

-- 7. Entraînement (toujours approuvé par un humain avant de tourner) ------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.training_configs (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                     text NOT NULL UNIQUE CONSTRAINT training_configs_name_format CHECK (name ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  base_model_version_id    uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  dataset_version_id       uuid NOT NULL REFERENCES soulbah.dataset_versions(id) ON DELETE RESTRICT,
  method                   text NOT NULL CONSTRAINT training_configs_method_check CHECK (method IN ('lora', 'qlora', 'full', 'distillation', 'prompt_tuning', 'embedding_finetune')),
  hyperparameters          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT training_configs_hparams_object CHECK (soulbah.is_json_object(hyperparameters)),
  hardware                 jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT training_configs_hardware_object CHECK (soulbah.is_json_object(hardware)),
  estimated_duration_min   integer CONSTRAINT training_configs_duration_positive CHECK (estimated_duration_min IS NULL OR estimated_duration_min >= 0),
  rationale                text NOT NULL DEFAULT '' CONSTRAINT training_configs_rationale_length CHECK (length(rationale) <= 4000),
  approved_by              text,
  approved_at              timestamptz,
  created_by               text NOT NULL DEFAULT current_user,
  created_at               timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.training_configs IS 'Configurations d''entraînement (modèle de base, jeu de données gelé, méthode, hyperparamètres, matériel) ; une exécution exige une configuration approuvée.';
ALTER TABLE soulbah.training_configs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_training_configs_base ON soulbah.training_configs (base_model_version_id);
CREATE INDEX IF NOT EXISTS idx_training_configs_dataset ON soulbah.training_configs (dataset_version_id);

CREATE TABLE IF NOT EXISTS soulbah.training_runs (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  config_id         uuid NOT NULL REFERENCES soulbah.training_configs(id) ON DELETE RESTRICT,
  status            text NOT NULL DEFAULT 'planned' CONSTRAINT training_runs_status_check CHECK (status IN ('planned', 'running', 'completed', 'failed', 'cancelled')),
  resource_usage    jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT training_runs_usage_object CHECK (soulbah.is_json_object(resource_usage)),
  logs_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  error             text,
  started_by        text NOT NULL DEFAULT current_user,
  started_at        timestamptz,
  finished_at       timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.training_runs IS 'Exécutions d''entraînement (ressources consommées, journal en artefact) — jamais sans configuration approuvée (trigger).';
ALTER TABLE soulbah.training_runs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_training_runs_config ON soulbah.training_runs (config_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_training_runs_logs ON soulbah.training_runs (logs_artifact_id);

CREATE OR REPLACE FUNCTION soulbah.training_runs_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM soulbah.training_configs c WHERE c.id = NEW.config_id AND c.approved_by IS NOT NULL AND c.approved_at IS NOT NULL) THEN
    RAISE EXCEPTION 'soulbah.training_runs : configuration d''entraînement non approuvée' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.status IN ('running', 'completed') AND NOT EXISTS (
       SELECT 1 FROM soulbah.training_configs c JOIN soulbah.dataset_versions d ON d.id = c.dataset_version_id WHERE c.id = NEW.config_id AND d.frozen) THEN
    RAISE EXCEPTION 'soulbah.training_runs : le jeu de données doit être gelé avant l''entraînement' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS training_runs_guard ON soulbah.training_runs;
CREATE TRIGGER training_runs_guard BEFORE INSERT OR UPDATE ON soulbah.training_runs FOR EACH ROW EXECUTE FUNCTION soulbah.training_runs_guard();

CREATE TABLE IF NOT EXISTS soulbah.training_results (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id      uuid NOT NULL REFERENCES soulbah.training_runs(id) ON DELETE CASCADE,
  metric      text NOT NULL CONSTRAINT training_results_metric_format CHECK (metric ~ '^[a-z][a-z0-9_.]{0,99}$'),
  step        integer CONSTRAINT training_results_step_positive CHECK (step IS NULL OR step >= 0),
  value       numeric(18, 6) NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.training_results IS 'Métriques d''une exécution d''entraînement (perte, exactitude…) par étape.';
ALTER TABLE soulbah.training_results ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_training_results_run ON soulbah.training_results (run_id, metric, step);

CREATE TABLE IF NOT EXISTS soulbah.training_artifacts (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id            uuid NOT NULL REFERENCES soulbah.training_runs(id) ON DELETE CASCADE,
  kind              text NOT NULL CONSTRAINT training_artifacts_kind_check CHECK (kind IN ('adapter', 'checkpoint', 'merged_model', 'report', 'eval')),
  artifact_id       uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  sha256            text CONSTRAINT training_artifacts_sha256_format CHECK (sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes        bigint CONSTRAINT training_artifacts_size_positive CHECK (size_bytes IS NULL OR size_bytes >= 0),
  model_version_id  uuid REFERENCES soulbah.model_versions(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.training_artifacts IS 'Produits d''un entraînement (adaptateur, point de contrôle, modèle fusionné, rapport) ; model_version_id une fois enregistré comme version candidate.';
ALTER TABLE soulbah.training_artifacts ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_training_artifacts_run ON soulbah.training_artifacts (run_id);
CREATE INDEX IF NOT EXISTS idx_training_artifacts_artifact ON soulbah.training_artifacts (artifact_id);
CREATE INDEX IF NOT EXISTS idx_training_artifacts_version ON soulbah.training_artifacts (model_version_id);

-- 8. Liens avec les lots précédents --------------------------------------------------------------------------------
ALTER TABLE soulbah.embedding_models ADD COLUMN IF NOT EXISTS model_id uuid REFERENCES soulbah.models(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_embedding_models_model ON soulbah.embedding_models (model_id);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tool_benchmarks_run_fkey') THEN
    ALTER TABLE soulbah.tool_benchmarks ADD CONSTRAINT tool_benchmarks_run_fkey
      FOREIGN KEY (benchmark_run_id) REFERENCES soulbah.benchmark_runs(id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_tool_benchmarks_run ON soulbah.tool_benchmarks (benchmark_run_id);

-- 9. Semences : les deux modèles installés localement, tels que décrits par le registre local le 2026-10-02
-- (%LOCALAPPDATA%\Soulbah\models\registry.json) ; empreintes et sources épinglées réelles ; aucun n'est « actif »
-- ici car le statut de sécurité n'a pas été approuvé par un humain (checked, pas approved).
INSERT INTO soulbah.models (name, display_name, family, kind, provider, vendor, license, license_url, status, description, metadata) VALUES
  ('qwen2.5-1.5b-instruct', 'Qwen2.5 1.5B Instruct', 'qwen2.5', 'llm', 'local', 'Alibaba Qwen', 'apache-2.0',
   'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF', 'candidate',
   'Modèle de conversation et de planification compacte servi par llama.cpp sur CPU (1 slot, contexte 8192).',
   '{"roles": ["chat", "planning", "reasoning", "fast"], "registry": "local"}'),
  ('nomic-embed-text-v1.5', 'nomic-embed-text v1.5', 'nomic-embed', 'embedding', 'local', 'Nomic AI', 'apache-2.0',
   'https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF', 'candidate',
   'Modèle d''embeddings local (768 dimensions) installé, pas encore branché sur la base de connaissances.',
   '{"roles": ["embedding"], "registry": "local"}')
ON CONFLICT (name) DO NOTHING;

INSERT INTO soulbah.model_versions (model_id, version, registry_key, file_name, sha256, size_bytes, quantization, context_length, parameters_b, runtime,
                                    source_kind, source_ref, source_revision, status, installed, installed_at, metadata)
SELECT m.id, v.version, v.registry_key, v.file_name, v.sha256, v.size_bytes, v.quantization, v.context_length, v.parameters_b, 'llama.cpp',
       'huggingface', v.source_ref, v.source_revision, 'candidate', true, v.installed_at, v.metadata
FROM (VALUES
  ('qwen2.5-1.5b-instruct', '2.5-q4_k_m', 'qwen2.5-1.5b-instruct-q4_k_m', 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
   '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e', 1117320736::bigint, 'Q4_K_M', 32768, 1.5::numeric,
   'Qwen/Qwen2.5-1.5B-Instruct-GGUF', '91cad51170dc346986eccefdc2dd33a9da36ead9', '2026-10-01T20:31:36+00:00'::timestamptz,
   '{"json_schema": true, "vision": false, "license_accepted_at": "2026-10-01T20:31:36+00:00", "registry_status": "verified"}'::jsonb),
  ('nomic-embed-text-v1.5', '1.5-q8_0', 'nomic-embed-text-v1.5-q8_0', 'nomic-embed-text-v1.5.Q8_0.gguf',
   '3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7', 146146432::bigint, 'Q8_0', 8192, NULL::numeric,
   'nomic-ai/nomic-embed-text-v1.5-GGUF', '0188c9bf409793f810680a5a431e7b899c46104c', '2026-10-01T20:32:27+00:00'::timestamptz,
   '{"embedding_dim": 768, "license_accepted_at": "2026-10-01T20:32:27+00:00", "registry_status": "installed"}'::jsonb)
) AS v(model_name, version, registry_key, file_name, sha256, size_bytes, quantization, context_length, parameters_b, source_ref, source_revision, installed_at, metadata)
JOIN soulbah.models m ON m.name = v.model_name
ON CONFLICT (model_id, version) DO NOTHING;

INSERT INTO soulbah.model_hardware_requirements (version_id, profile, min_ram_mb, min_vram_mb, measured, notes)
SELECT v.id, 'cpu', h.ram_mb, 0, false, 'Estimation du registre local (ram_estimate_gb) ; débit mesuré 2 à 11,5 jetons/s sur le CPU de la machine de développement.'
FROM (VALUES ('qwen2.5-1.5b-instruct-q4_k_m', 1628), ('nomic-embed-text-v1.5-q8_0', 707)) AS h(registry_key, ram_mb)
JOIN soulbah.model_versions v ON v.registry_key = h.registry_key
ON CONFLICT (version_id, profile) DO NOTHING;

INSERT INTO soulbah.model_security_status (version_id, status, checksum_verified, source_verified, license_ok, checked_by, checked_at, notes)
SELECT v.id, 'checked', s.checksum_verified, true, true, 'system:model_registry', s.checked_at, s.notes
FROM (VALUES
  ('qwen2.5-1.5b-instruct-q4_k_m', true, '2026-10-01T20:31:36+00:00'::timestamptz, 'Empreinte SHA-256 vérifiée au téléchargement (registre : verified) ; source Hugging Face épinglée par révision ; licence Apache-2.0 acceptée. Approbation humaine en attente.'),
  ('nomic-embed-text-v1.5-q8_0', NULL::boolean, '2026-10-01T20:32:27+00:00'::timestamptz, 'Installé (registre : installed) ; vérification de l''empreinte non attestée par le registre ; source épinglée par révision ; licence Apache-2.0 acceptée. Approbation humaine en attente.')
) AS s(registry_key, checksum_verified, checked_at, notes)
JOIN soulbah.model_versions v ON v.registry_key = s.registry_key
ON CONFLICT (version_id) DO NOTHING;

UPDATE soulbah.embedding_models e SET model_id = m.id
FROM soulbah.models m WHERE m.name = 'nomic-embed-text-v1.5' AND e.name = 'nomic-embed-text-v1.5-q8_0' AND e.model_id IS NULL;

-- Benchmark de fumée local (5 tâches) et sa seule exécution connue (registre, 2026-10-02T09:48:35Z, qwen2.5 sur CPU).
INSERT INTO soulbah.benchmarks (name, domain, description) VALUES
  ('local_smoke', 'mixed', 'Fumée locale du lanceur : plan JSON, raisonnement, revue de code, question sur document, résumé en français — mesure de débit incluse.')
ON CONFLICT (name) DO NOTHING;
INSERT INTO soulbah.benchmark_versions (benchmark_id, version, spec, frozen, frozen_at)
SELECT b.id, 1, '{"source": "agent/local_models benchmark (registre local)", "tasks": 5, "scoring": "exact|contains"}', true, '2026-10-02T09:48:35+00:00'
FROM soulbah.benchmarks b WHERE b.name = 'local_smoke'
ON CONFLICT (benchmark_id, version) DO NOTHING;
UPDATE soulbah.benchmarks b SET current_version_id = v.id
FROM soulbah.benchmark_versions v WHERE v.benchmark_id = b.id AND v.version = 1 AND b.name = 'local_smoke' AND b.current_version_id IS NULL;
-- La version est gelée : les tâches sont insérées sous déverrouillage explicite du gel, dans cette seule migration.
DO $$
DECLARE bv uuid;
BEGIN
  SELECT v.id INTO bv FROM soulbah.benchmark_versions v JOIN soulbah.benchmarks b ON b.id = v.benchmark_id WHERE b.name = 'local_smoke' AND v.version = 1;
  IF (SELECT count(*) FROM soulbah.benchmark_tasks WHERE benchmark_version_id = bv) = 0 THEN
    ALTER TABLE soulbah.benchmark_tasks DISABLE TRIGGER benchmark_tasks_freeze;
    INSERT INTO soulbah.benchmark_tasks (benchmark_version_id, key, scoring, expected) VALUES
      (bv, 'plan_json', 'json_schema', '{"schema": "steps[] with tool/path/content"}'),
      (bv, 'reasoning', 'exact', '{"answer": "arithmetic result"}'),
      (bv, 'code_review', 'exact', '{"answer": "line number of the bug"}'),
      (bv, 'doc_qa', 'contains', '{"answer": "7 ans"}'),
      (bv, 'french_summary', 'rubric', '{"language": "fr", "max_sentences": 2}');
    ALTER TABLE soulbah.benchmark_tasks ENABLE TRIGGER benchmark_tasks_freeze;
  END IF;
END $$;
INSERT INTO soulbah.benchmark_runs (benchmark_version_id, subject_kind, model_version_id, external_ref, status, environment, hardware, score, score_max, triggered_by, started_at, finished_at, notes)
SELECT bv.id, 'model', mv.id, 'registry:qwen2.5-1.5b-instruct-q4_k_m:2026-10-02T09:48:35Z', 'completed',
       '{"base_url": "http://127.0.0.1:8091/v1", "runtime": "llama.cpp b11325", "slots": 1, "ctx": 8192}', '{"device": "cpu"}',
       4, 5, 'system:model_registry', '2026-10-02T09:48:35+00:00', '2026-10-02T09:48:35+00:00',
       'Résultats copiés du registre local (bloc benchmark) ; tâche reasoning échouée (réponse 47).'
FROM soulbah.benchmark_versions bv JOIN soulbah.benchmarks b ON b.id = bv.benchmark_id AND b.name = 'local_smoke' AND bv.version = 1
JOIN soulbah.model_versions mv ON mv.registry_key = 'qwen2.5-1.5b-instruct-q4_k_m'
ON CONFLICT (external_ref) DO NOTHING;
INSERT INTO soulbah.benchmark_results (run_id, task_id, passed, score, score_max, latency_ms, tokens_out, detail)
SELECT r.id, t.id, d.passed, CASE WHEN d.passed THEN 1 ELSE 0 END, 1, d.latency_ms, d.tokens_out, jsonb_build_object('tokens_per_s', d.tps)
FROM (VALUES ('plan_json', true, 15020, 46, 4.0), ('reasoning', false, 1060, 3, 5.5), ('code_review', true, 1170, 2, 7.1),
             ('doc_qa', true, 4750, 15, 3.9), ('french_summary', true, 5410, 38, 7.2)) AS d(key, passed, latency_ms, tokens_out, tps)
JOIN soulbah.benchmark_runs r ON r.external_ref = 'registry:qwen2.5-1.5b-instruct-q4_k_m:2026-10-02T09:48:35Z'
JOIN soulbah.benchmark_tasks t ON t.benchmark_version_id = r.benchmark_version_id AND t.key = d.key
ON CONFLICT (run_id, task_id) DO NOTHING;
INSERT INTO soulbah.model_benchmarks (model_version_id, benchmark_version_id, run_id, score, score_max, passed_count, task_count, measured_at)
SELECT r.model_version_id, r.benchmark_version_id, r.id, 4, 5, 4, 5, r.finished_at
FROM soulbah.benchmark_runs r WHERE r.external_ref = 'registry:qwen2.5-1.5b-instruct-q4_k_m:2026-10-02T09:48:35Z'
ON CONFLICT (run_id) DO NOTHING;
INSERT INTO soulbah.model_capabilities (version_id, capability, level, measured, evidence_run_id, notes)
SELECT mv.id, c.capability, c.level, c.measured, CASE WHEN c.measured THEN r.id END, c.notes
FROM soulbah.model_versions mv
JOIN soulbah.benchmark_runs r ON r.external_ref = 'registry:qwen2.5-1.5b-instruct-q4_k_m:2026-10-02T09:48:35Z'
CROSS JOIN (VALUES
  ('json_schema', 'usable', true, 'plan_json réussi ; planification DAG multi-agents non fiable (0/4, V3 LOT 4)'),
  ('reasoning', 'weak', true, 'tâche reasoning échouée'),
  ('code_review', 'usable', true, 'code_review réussi sur un cas trivial'),
  ('french', 'usable', true, 'doc_qa et french_summary réussis'),
  ('vision', 'none', false, 'déclaré par le registre')) AS c(capability, level, measured, notes)
WHERE mv.registry_key = 'qwen2.5-1.5b-instruct-q4_k_m'
ON CONFLICT (version_id, capability) DO NOTHING;
INSERT INTO soulbah.model_capabilities (version_id, capability, level, measured, notes)
SELECT mv.id, 'embedding', 'unknown', false, '768 dimensions déclarées ; pas encore branché ni mesuré'
FROM soulbah.model_versions mv WHERE mv.registry_key = 'nomic-embed-text-v1.5-q8_0'
ON CONFLICT (version_id, capability) DO NOTHING;

-- 10. Droits ------------------------------------------------------------------------------------------------------
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['models', 'model_versions', 'model_hardware_requirements', 'model_security_status', 'benchmarks', 'benchmark_versions',
                           'golden_tasks', 'golden_task_expected_results', 'benchmark_tasks', 'datasets', 'dataset_versions', 'dataset_sources',
                           'dataset_items', 'dataset_quality_checks', 'benchmark_runs', 'benchmark_results', 'model_benchmarks', 'model_capabilities',
                           'model_routing_rules', 'model_routing_history', 'model_candidates', 'model_competitions', 'model_comparison_results',
                           'shadow_runs', 'shadow_comparisons', 'training_configs', 'training_runs', 'training_results', 'training_artifacts'] LOOP
    EXECUTE format('REVOKE ALL ON soulbah.%I FROM PUBLIC', t);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON soulbah.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.model_versions_guard(), soulbah.benchmark_tasks_freeze(), soulbah.model_routing_rules_guard(), soulbah.training_runs_guard() FROM %I', r);
    END IF;
  END LOOP;
END $$;
