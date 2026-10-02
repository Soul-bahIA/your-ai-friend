-- =============================================================================
-- DB LOT 7 — Project Brain : documents, composants logiques, relations typées entre nœuds, instantanés,
-- couverture mesurée, zones inconnues, décisions d'architecture, mémoire git.
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110800_db07_project_brain.down.sql
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03. Les symboles de code sont au DB LOT 8 (code_symbols) : les relations du
-- Project Brain les référencent par (kind, id).
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.project_brain_documents (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id           uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  kind                 text NOT NULL CONSTRAINT project_brain_documents_kind_check
                       CHECK (kind IN ('architecture', 'module', 'decision', 'runbook', 'api', 'database', 'ui', 'flow', 'dependency', 'note', 'summary')),
  title                text NOT NULL CONSTRAINT project_brain_documents_title_length CHECK (length(title) BETWEEN 1 AND 300),
  path                 text CONSTRAINT project_brain_documents_path_length CHECK (path IS NULL OR length(path) <= 1000),
  content              text NOT NULL DEFAULT '' CONSTRAINT project_brain_documents_content_length CHECK (length(content) <= 60000),
  content_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  content_hash         text CONSTRAINT project_brain_documents_hash_format CHECK (content_hash IS NULL OR content_hash ~ '^[0-9a-f]{64}$'),
  source               text NOT NULL DEFAULT 'generated' CONSTRAINT project_brain_documents_source_check CHECK (source IN ('generated', 'imported', 'human')),
  generated_by         uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  confidence           real NOT NULL DEFAULT 0.5 CONSTRAINT project_brain_documents_confidence_range CHECK (confidence >= 0 AND confidence <= 1),
  status               text NOT NULL DEFAULT 'ACTIVE' CONSTRAINT project_brain_documents_status_check CHECK (status IN ('ACTIVE', 'STALE', 'SUPERSEDED', 'INVALID', 'ARCHIVED')),
  version              integer NOT NULL DEFAULT 1 CONSTRAINT project_brain_documents_version_positive CHECK (version >= 1),
  last_verified_at     timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_brain_documents_content_or_artifact CHECK (length(content) > 0 OR content_artifact_id IS NOT NULL)
);
COMMENT ON TABLE soulbah.project_brain_documents IS 'Connaissance technique structurée d''un projet (architecture, modules, décisions, API, base, UI, parcours) ; générée, importée ou humaine ; versionnée et datée.';
ALTER TABLE soulbah.project_brain_documents ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.project_brain_documents', '{"project_id": "uuid", "kind": "text", "status": "text", "version": "integer"}');
CREATE INDEX IF NOT EXISTS idx_project_brain_documents_project ON soulbah.project_brain_documents (project_id, kind, status);
CREATE UNIQUE INDEX IF NOT EXISTS idx_project_brain_documents_path ON soulbah.project_brain_documents (project_id, path) WHERE path IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_project_brain_documents_artifact ON soulbah.project_brain_documents (content_artifact_id);
CREATE INDEX IF NOT EXISTS idx_project_brain_documents_generated_by ON soulbah.project_brain_documents (generated_by);
DROP TRIGGER IF EXISTS project_brain_documents_set_updated_at ON soulbah.project_brain_documents;
CREATE TRIGGER project_brain_documents_set_updated_at BEFORE UPDATE ON soulbah.project_brain_documents FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.project_brain_components (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id    uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  component_id  uuid REFERENCES soulbah.project_components(id) ON DELETE SET NULL,
  key           text NOT NULL CONSTRAINT project_brain_components_key_format CHECK (key ~ '^[a-z0-9][a-z0-9_.-]{0,119}$'),
  name          text NOT NULL CONSTRAINT project_brain_components_name_length CHECK (length(name) BETWEEN 1 AND 200),
  kind          text NOT NULL CONSTRAINT project_brain_components_kind_check CHECK (kind IN ('domain', 'module', 'service', 'package', 'layer', 'external', 'other')),
  path          text CONSTRAINT project_brain_components_path_length CHECK (path IS NULL OR length(path) <= 1000),
  description   text NOT NULL DEFAULT '' CONSTRAINT project_brain_components_description_length CHECK (length(description) <= 4000),
  confidence    real NOT NULL DEFAULT 0.5 CONSTRAINT project_brain_components_confidence_range CHECK (confidence >= 0 AND confidence <= 1),
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_brain_components_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_brain_components_unique UNIQUE (project_id, key)
);
COMMENT ON TABLE soulbah.project_brain_components IS 'Composants logiques compris par Soulbah (domaines, modules, services) — la carte réelle des modules, vérifiée dans le code (§10-11).';
ALTER TABLE soulbah.project_brain_components ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_brain_components_component ON soulbah.project_brain_components (component_id);
DROP TRIGGER IF EXISTS project_brain_components_set_updated_at ON soulbah.project_brain_components;
CREATE TRIGGER project_brain_components_set_updated_at BEFORE UPDATE ON soulbah.project_brain_components FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.project_brain_relationships (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id  uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  from_kind   text NOT NULL CONSTRAINT project_brain_relationships_from_kind_check
              CHECK (from_kind IN ('document', 'component', 'file', 'symbol', 'table', 'endpoint', 'route', 'ui_component', 'flow', 'dependency', 'db_function')),
  from_id     uuid NOT NULL,
  to_kind     text NOT NULL CONSTRAINT project_brain_relationships_to_kind_check
              CHECK (to_kind IN ('document', 'component', 'file', 'symbol', 'table', 'endpoint', 'route', 'ui_component', 'flow', 'dependency', 'db_function')),
  to_id       uuid NOT NULL,
  kind        text NOT NULL CONSTRAINT project_brain_relationships_kind_check
              CHECK (kind IN ('uses', 'calls', 'imports', 'reads', 'writes', 'triggers', 'renders', 'navigates_to', 'depends_on', 'implements', 'documents', 'part_of', 'exposes', 'consumes')),
  weight      real NOT NULL DEFAULT 1 CONSTRAINT project_brain_relationships_weight_range CHECK (weight >= 0),
  evidence    jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_brain_relationships_evidence_object CHECK (soulbah.is_json_object(evidence)),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_brain_relationships_not_self CHECK (from_kind <> to_kind OR from_id <> to_id),
  CONSTRAINT project_brain_relationships_unique UNIQUE (from_kind, from_id, to_kind, to_id, kind)
);
COMMENT ON TABLE soulbah.project_brain_relationships IS 'Graphe de connaissance du projet : OrderService → calls → PaymentService → writes → transactions… (§5) ; base de l''analyse d''impact (§6).';
ALTER TABLE soulbah.project_brain_relationships ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_brain_relationships_to ON soulbah.project_brain_relationships (to_kind, to_id, kind);
CREATE INDEX IF NOT EXISTS idx_project_brain_relationships_project ON soulbah.project_brain_relationships (project_id);

CREATE TABLE IF NOT EXISTS soulbah.project_brain_snapshots (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id     uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  repository_id  uuid REFERENCES soulbah.project_repositories(id) ON DELETE SET NULL,
  app_commit     text,
  schema_hash    text CONSTRAINT project_brain_snapshots_hash_format CHECK (schema_hash IS NULL OR schema_hash ~ '^[0-9a-f]{64}$'),
  index_state    jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_brain_snapshots_index_object CHECK (soulbah.is_json_object(index_state)),
  coverage       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_brain_snapshots_coverage_object CHECK (soulbah.is_json_object(coverage)),
  stats          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_brain_snapshots_stats_object CHECK (soulbah.is_json_object(stats)),
  taken_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.project_brain_snapshots IS 'Instantanés du Project Brain (commit, empreinte, état de l''index, couverture, statistiques) pour comparer avant / après.';
ALTER TABLE soulbah.project_brain_snapshots ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_brain_snapshots_project ON soulbah.project_brain_snapshots (project_id, taken_at);
CREATE INDEX IF NOT EXISTS idx_project_brain_snapshots_repository ON soulbah.project_brain_snapshots (repository_id);

-- Couverture MESURÉE (§43 : jamais 100 % inventé) et zones inconnues (§44-45).
CREATE TABLE IF NOT EXISTS soulbah.project_brain_coverage (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id   uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  area         text NOT NULL CONSTRAINT project_brain_coverage_area_check CHECK (area IN ('code', 'database', 'api', 'ui', 'documentation', 'tests', 'flows', 'dependencies')),
  numerator    integer NOT NULL CONSTRAINT project_brain_coverage_numerator_positive CHECK (numerator >= 0),
  denominator  integer NOT NULL CONSTRAINT project_brain_coverage_denominator_positive CHECK (denominator >= 0),
  ratio        real GENERATED ALWAYS AS (CASE WHEN denominator = 0 THEN 0 ELSE least(1.0, numerator::real / denominator) END) STORED,
  method       text NOT NULL CONSTRAINT project_brain_coverage_method_length CHECK (length(method) BETWEEN 1 AND 500),
  snapshot_id  uuid REFERENCES soulbah.project_brain_snapshots(id) ON DELETE SET NULL,
  measured_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_brain_coverage_bounds CHECK (numerator <= denominator)
);
COMMENT ON TABLE soulbah.project_brain_coverage IS 'Couverture par domaine : numérateur / dénominateur mesurés et méthode (ex. fichiers indexés / fichiers du dépôt hors exclusions). Le ratio est calculé, jamais saisi.';
ALTER TABLE soulbah.project_brain_coverage ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_brain_coverage_project ON soulbah.project_brain_coverage (project_id, area, measured_at DESC);
CREATE INDEX IF NOT EXISTS idx_project_brain_coverage_snapshot ON soulbah.project_brain_coverage (snapshot_id);

CREATE TABLE IF NOT EXISTS soulbah.knowledge_gaps (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id   uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  kind         text NOT NULL CONSTRAINT knowledge_gaps_kind_check CHECK (kind IN (
                 'unindexed_file', 'table_without_relation', 'endpoint_without_consumer', 'module_without_tests',
                 'undocumented_code', 'unknown_module', 'stale_document', 'unresolved_dependency', 'other')),
  target_kind  text CONSTRAINT knowledge_gaps_target_kind_check CHECK (target_kind IS NULL OR target_kind IN ('file', 'symbol', 'table', 'endpoint', 'route', 'component', 'document', 'dependency')),
  target_id    uuid,
  target_ref   text CONSTRAINT knowledge_gaps_target_ref_length CHECK (target_ref IS NULL OR length(target_ref) <= 1000),
  severity     text NOT NULL DEFAULT 'LOW' CONSTRAINT knowledge_gaps_severity_check CHECK (soulbah.is_severity(severity)),
  status       text NOT NULL DEFAULT 'open' CONSTRAINT knowledge_gaps_status_check CHECK (status IN ('open', 'exploring', 'resolved', 'dismissed')),
  notes        text NOT NULL DEFAULT '' CONSTRAINT knowledge_gaps_notes_length CHECK (length(notes) <= 4000),
  detected_at  timestamptz NOT NULL DEFAULT now(),
  resolved_at  timestamptz,
  CONSTRAINT knowledge_gaps_target CHECK (target_id IS NOT NULL OR target_ref IS NOT NULL),
  CONSTRAINT knowledge_gaps_resolved_at CHECK (status NOT IN ('resolved', 'dismissed') OR resolved_at IS NOT NULL)
);
COMMENT ON TABLE soulbah.knowledge_gaps IS 'Zones mal comprises détectées par le KnowledgeGapDetector (§45) ; « je ne connais pas encore suffisamment ce module » — ouvrable en exploration (§46).';
ALTER TABLE soulbah.knowledge_gaps ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_knowledge_gaps_project_status ON soulbah.knowledge_gaps (project_id, status, severity);

-- Décisions d'architecture (§17) et mémoire git (§16).
CREATE TABLE IF NOT EXISTS soulbah.project_decisions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id     uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  title          text NOT NULL CONSTRAINT project_decisions_title_length CHECK (length(title) BETWEEN 1 AND 300),
  context        text NOT NULL DEFAULT '' CONSTRAINT project_decisions_context_length CHECK (length(context) <= 20000),
  decision       text NOT NULL CONSTRAINT project_decisions_decision_length CHECK (length(decision) BETWEEN 1 AND 20000),
  consequences   text NOT NULL DEFAULT '' CONSTRAINT project_decisions_consequences_length CHECK (length(consequences) <= 20000),
  status         text NOT NULL DEFAULT 'accepted' CONSTRAINT project_decisions_status_check CHECK (status IN ('proposed', 'accepted', 'superseded', 'deprecated')),
  supersedes_id  uuid REFERENCES soulbah.project_decisions(id) ON DELETE SET NULL,
  source         text NOT NULL DEFAULT 'human' CONSTRAINT project_decisions_source_check CHECK (source IN ('human', 'agent', 'imported')),
  decided_by     text NOT NULL DEFAULT current_user,
  decided_at     timestamptz NOT NULL DEFAULT now(),
  evidence       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_decisions_evidence_object CHECK (soulbah.is_json_object(evidence)),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_decisions_not_self CHECK (supersedes_id IS NULL OR supersedes_id <> id)
);
COMMENT ON TABLE soulbah.project_decisions IS 'ArchitectureDecisionMemory : pourquoi Redis, pourquoi telle table, pourquoi telle règle de sécurité — avec contexte, décision, conséquences et remplacements.';
ALTER TABLE soulbah.project_decisions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_decisions_project ON soulbah.project_decisions (project_id, status);
CREATE INDEX IF NOT EXISTS idx_project_decisions_supersedes ON soulbah.project_decisions (supersedes_id);

CREATE TABLE IF NOT EXISTS soulbah.project_commits (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Journal en ajout seul : un projet ou un dépôt qui a des commits enregistrés ne se supprime pas (RESTRICT) ;
  -- il se désactive (authorized = false). session_id sans FK : les sessions V2 sont purgées, le journal survit.
  project_id     uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE RESTRICT,
  repository_id  uuid NOT NULL REFERENCES soulbah.project_repositories(id) ON DELETE RESTRICT,
  sha            text NOT NULL CONSTRAINT project_commits_sha_format CHECK (sha ~ '^[0-9a-f]{7,64}$'),
  author         text NOT NULL DEFAULT '' CONSTRAINT project_commits_author_length CHECK (length(author) <= 200),
  committed_at   timestamptz,
  message        text NOT NULL DEFAULT '' CONSTRAINT project_commits_message_length CHECK (length(message) <= 4000),
  files          jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT project_commits_files_array CHECK (soulbah.is_json_array(files)),
  reason         text CONSTRAINT project_commits_reason_length CHECK (reason IS NULL OR length(reason) <= 4000),
  tests_passed   boolean,
  incident_id    uuid,
  session_id     uuid,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_commits_unique UNIQUE (repository_id, sha)
);
COMMENT ON TABLE soulbah.project_commits IS 'Mémoire git : commits pertinents (fichiers, auteur, raison, tests, incident lié, mission) — « pourquoi ce code existe » ; ajout seul.';
ALTER TABLE soulbah.project_commits ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_commits_project ON soulbah.project_commits (project_id, committed_at DESC);
CREATE INDEX IF NOT EXISTS idx_project_commits_session ON soulbah.project_commits (session_id);
CREATE INDEX IF NOT EXISTS idx_project_commits_incident ON soulbah.project_commits (incident_id) WHERE incident_id IS NOT NULL;
DROP TRIGGER IF EXISTS project_commits_append_only ON soulbah.project_commits;
CREATE TRIGGER project_commits_append_only BEFORE DELETE ON soulbah.project_commits FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS project_commits_no_truncate ON soulbah.project_commits;
CREATE TRIGGER project_commits_no_truncate BEFORE TRUNCATE ON soulbah.project_commits FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON soulbah.project_brain_documents, soulbah.project_brain_components, soulbah.project_brain_relationships,
    soulbah.project_brain_snapshots, soulbah.project_brain_coverage, soulbah.knowledge_gaps, soulbah.project_decisions,
    soulbah.project_commits FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.project_brain_documents, soulbah.project_brain_components, soulbah.project_brain_relationships, '
                     'soulbah.project_brain_snapshots, soulbah.project_brain_coverage, soulbah.knowledge_gaps, soulbah.project_decisions, '
                     'soulbah.project_commits FROM %I', r);
    END IF;
  END LOOP;
END $$;
