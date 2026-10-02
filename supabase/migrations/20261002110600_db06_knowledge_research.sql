-- =============================================================================
-- DB LOT 6 — Knowledge et research : modèles d'embeddings, sources et provenance, relations, validations,
-- sessions de recherche (requêtes, sources, findings, candidats de connaissance).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110600_db06_knowledge_research.down.sql (public.knowledge_base, knowledge_versions, soulbah.knowledge_chunks restent intacts)
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03, db05. REUSE : public.knowledge_base, public.knowledge_versions, public.knowledge_domains,
-- soulbah.knowledge_chunks, vue soulbah.knowledge_documents — inchangés ici (colonnes vectorielles : db06_vector).
-- =============================================================================

-- 1. Modèles d'embeddings (§38) : un vecteur porte toujours son modèle et sa dimension --------------------
CREATE TABLE IF NOT EXISTS soulbah.embedding_models (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL UNIQUE CONSTRAINT embedding_models_name_length CHECK (length(name) BETWEEN 1 AND 200),
  provider    text NOT NULL CONSTRAINT embedding_models_provider_check CHECK (provider IN ('local', 'cloud')),
  dimensions  integer NOT NULL CONSTRAINT embedding_models_dimensions_range CHECK (dimensions BETWEEN 1 AND 16000),
  version     text NOT NULL DEFAULT '1' CONSTRAINT embedding_models_version_length CHECK (length(version) BETWEEN 1 AND 50),
  status      text NOT NULL DEFAULT 'candidate' CONSTRAINT embedding_models_status_check CHECK (status IN ('candidate', 'active', 'reindexing', 'retired')),
  is_default  boolean NOT NULL DEFAULT false,
  metadata    jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT embedding_models_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.embedding_models IS 'Modèles d''embeddings connus (nom, fournisseur local/cloud, dimensions, version, statut) ; un seul modèle par défaut.';
ALTER TABLE soulbah.embedding_models ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.embedding_models', '{"name": "text", "dimensions": "integer", "status": "text", "is_default": "boolean"}');
CREATE UNIQUE INDEX IF NOT EXISTS idx_embedding_models_default ON soulbah.embedding_models (is_default) WHERE is_default;
DROP TRIGGER IF EXISTS embedding_models_set_updated_at ON soulbah.embedding_models;
CREATE TRIGGER embedding_models_set_updated_at BEFORE UPDATE ON soulbah.embedding_models FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
INSERT INTO soulbah.embedding_models (name, provider, dimensions, version, status, metadata) VALUES
  ('text-embedding-3-small', 'cloud', 1536, '1', 'active', '{"vendor": "openai", "note": "modèle des embeddings existants (public.knowledge_base.embedding)"}'),
  ('nomic-embed-text-v1.5-q8_0', 'local', 768, '1.5', 'candidate', '{"license": "apache-2.0", "runtime": "llama.cpp", "note": "installé localement le 2026-10-01, pas encore branché"}')
ON CONFLICT (name) DO NOTHING;

-- 2. Sources et provenance (§33, §35) ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.knowledge_sources (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind              text NOT NULL CONSTRAINT knowledge_sources_kind_check
                    CHECK (kind IN ('web', 'document', 'repository', 'database', 'api', 'human', 'model', 'memory', 'test', 'log')),
  uri               text CONSTRAINT knowledge_sources_uri_length CHECK (uri IS NULL OR length(uri) <= 2000),
  title             text NOT NULL DEFAULT '' CONSTRAINT knowledge_sources_title_length CHECK (length(title) <= 500),
  project_id        uuid REFERENCES soulbah.projects(id) ON DELETE SET NULL,
  authority         text NOT NULL DEFAULT 'unknown' CONSTRAINT knowledge_sources_authority_check
                    CHECK (authority IN ('official_documentation', 'source_code', 'standard', 'forum', 'opinion', 'internal', 'unknown')),
  reliability       real NOT NULL DEFAULT 0.5 CONSTRAINT knowledge_sources_reliability_range CHECK (reliability >= 0 AND reliability <= 1),
  verified          boolean NOT NULL DEFAULT false,
  retrieved_at      timestamptz,
  last_verified_at  timestamptz,
  freshness_policy  text NOT NULL DEFAULT 'slow' CONSTRAINT knowledge_sources_freshness_check CHECK (freshness_policy IN ('static', 'slow', 'fast', 'volatile')),
  content_hash      text CONSTRAINT knowledge_sources_hash_format CHECK (content_hash IS NULL OR content_hash ~ '^[0-9a-f]{64}$'),
  metadata          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT knowledge_sources_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.knowledge_sources IS 'Sources de connaissance (page, document, dépôt, base, API, humain, modèle…) avec autorité, fiabilité, dates de récupération et de vérification, politique de fraîcheur.';
ALTER TABLE soulbah.knowledge_sources ENABLE ROW LEVEL SECURITY;
CREATE UNIQUE INDEX IF NOT EXISTS idx_knowledge_sources_kind_uri ON soulbah.knowledge_sources (kind, uri) WHERE uri IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_knowledge_sources_project ON soulbah.knowledge_sources (project_id);

CREATE TABLE IF NOT EXISTS soulbah.knowledge_provenance (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id    uuid NOT NULL REFERENCES soulbah.knowledge_sources(id) ON DELETE RESTRICT,
  target_kind  text NOT NULL CONSTRAINT knowledge_provenance_target_kind_check
               CHECK (target_kind IN ('knowledge_base', 'memory_item', 'research_finding', 'project_brain_document', 'security_pattern')),
  target_id    uuid NOT NULL,
  role         text NOT NULL DEFAULT 'origin' CONSTRAINT knowledge_provenance_role_check CHECK (role IN ('origin', 'supporting', 'contradicting')),
  excerpt      text CONSTRAINT knowledge_provenance_excerpt_length CHECK (excerpt IS NULL OR length(excerpt) <= 4000),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT knowledge_provenance_unique UNIQUE (source_id, target_kind, target_id, role)
);
COMMENT ON TABLE soulbah.knowledge_provenance IS 'Provenance : quelle source fonde quelle connaissance (entrée de la base, mémoire, finding, document du Project Brain). Une source référencée ne se supprime pas (RESTRICT) — « Pourquoi sais-tu cela ? ».';
ALTER TABLE soulbah.knowledge_provenance ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_knowledge_provenance_target ON soulbah.knowledge_provenance (target_kind, target_id);

CREATE TABLE IF NOT EXISTS soulbah.knowledge_relationships (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_kind   text NOT NULL CONSTRAINT knowledge_relationships_from_kind_check CHECK (from_kind IN ('knowledge_base', 'memory_item', 'research_finding', 'project_brain_document')),
  from_id     uuid NOT NULL,
  to_kind     text NOT NULL CONSTRAINT knowledge_relationships_to_kind_check CHECK (to_kind IN ('knowledge_base', 'memory_item', 'research_finding', 'project_brain_document')),
  to_id       uuid NOT NULL,
  kind        text NOT NULL CONSTRAINT knowledge_relationships_kind_check CHECK (kind IN ('related_to', 'supersedes', 'contradicts', 'derived_from', 'part_of', 'duplicates')),
  created_by  text NOT NULL DEFAULT current_user,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT knowledge_relationships_not_self CHECK (from_kind <> to_kind OR from_id <> to_id),
  CONSTRAINT knowledge_relationships_unique UNIQUE (from_kind, from_id, to_kind, to_id, kind)
);
COMMENT ON TABLE soulbah.knowledge_relationships IS 'Relations entre connaissances de toute nature (base, mémoire, finding, document) : related_to, supersedes, contradicts, derived_from, part_of, duplicates (déduplication §65).';
ALTER TABLE soulbah.knowledge_relationships ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_knowledge_relationships_to ON soulbah.knowledge_relationships (to_kind, to_id);

CREATE TABLE IF NOT EXISTS soulbah.knowledge_validations (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  target_kind     text NOT NULL CONSTRAINT knowledge_validations_target_kind_check CHECK (target_kind IN ('knowledge_base', 'memory_item', 'research_finding', 'project_brain_document', 'knowledge_source')),
  target_id       uuid NOT NULL,
  validator_type  text NOT NULL CONSTRAINT knowledge_validations_validator_type_check CHECK (validator_type IN ('human', 'agent', 'test', 'source_check', 'cross_check')),
  validator_id    text NOT NULL CONSTRAINT knowledge_validations_validator_id_length CHECK (length(validator_id) BETWEEN 1 AND 200),
  verdict         text NOT NULL CONSTRAINT knowledge_validations_verdict_check CHECK (verdict IN ('valid', 'invalid', 'stale', 'uncertain')),
  evidence        jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT knowledge_validations_evidence_object CHECK (soulbah.is_json_object(evidence)),
  notes           text CONSTRAINT knowledge_validations_notes_length CHECK (notes IS NULL OR length(notes) <= 4000),
  created_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.knowledge_validations IS 'Validations de connaissances (humain, agent, test, vérification de source), ajout seul : qui a jugé quoi, avec quelle preuve.';
ALTER TABLE soulbah.knowledge_validations ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_knowledge_validations_target ON soulbah.knowledge_validations (target_kind, target_id, id);
DROP TRIGGER IF EXISTS knowledge_validations_append_only ON soulbah.knowledge_validations;
CREATE TRIGGER knowledge_validations_append_only BEFORE UPDATE OR DELETE ON soulbah.knowledge_validations FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS knowledge_validations_no_truncate ON soulbah.knowledge_validations;
CREATE TRIGGER knowledge_validations_no_truncate BEFORE TRUNCATE ON soulbah.knowledge_validations FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

-- 3. Recherche (§29-32, §63-64) -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.research_sessions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id           uuid REFERENCES soulbah.projects(id) ON DELETE SET NULL,
  agent_definition_id  uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  user_id              uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  session_id           uuid REFERENCES soulbah.sessions(id) ON DELETE SET NULL,
  question             text NOT NULL CONSTRAINT research_sessions_question_length CHECK (length(question) BETWEEN 1 AND 2000),
  topic                text NOT NULL DEFAULT '' CONSTRAINT research_sessions_topic_length CHECK (length(topic) <= 200),
  mode                 text NOT NULL CONSTRAINT research_sessions_mode_check CHECK (mode IN ('offline', 'local_internet', 'hybrid')),
  status               text NOT NULL DEFAULT 'running' CONSTRAINT research_sessions_status_check CHECK (status IN ('running', 'completed', 'failed', 'cancelled')),
  cache_level          text CONSTRAINT research_sessions_cache_check CHECK (cache_level IS NULL OR cache_level IN ('session', 'project', 'research_memory', 'knowledge_base', 'local_docs', 'none')),
  summary              text NOT NULL DEFAULT '' CONSTRAINT research_sessions_summary_length CHECK (length(summary) <= 20000),
  reliability          real CONSTRAINT research_sessions_reliability_range CHECK (reliability IS NULL OR (reliability >= 0 AND reliability <= 1)),
  reusable             boolean,
  tags                 jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT research_sessions_tags_array CHECK (soulbah.is_json_array(tags)),
  created_at           timestamptz NOT NULL DEFAULT now(),
  finished_at          timestamptz
);
COMMENT ON TABLE soulbah.research_sessions IS 'Recherches menées par les agents : question, sujet, mode, niveau de cache consulté (§31), résumé, fiabilité, réutilisable (§64).';
ALTER TABLE soulbah.research_sessions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_research_sessions_project ON soulbah.research_sessions (project_id, created_at);
CREATE INDEX IF NOT EXISTS idx_research_sessions_agent ON soulbah.research_sessions (agent_definition_id);
CREATE INDEX IF NOT EXISTS idx_research_sessions_user ON soulbah.research_sessions (user_id);
CREATE INDEX IF NOT EXISTS idx_research_sessions_session ON soulbah.research_sessions (session_id);
CREATE INDEX IF NOT EXISTS idx_research_sessions_tags ON soulbah.research_sessions USING gin (tags jsonb_path_ops);

CREATE TABLE IF NOT EXISTS soulbah.research_queries (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  research_session_id  uuid NOT NULL REFERENCES soulbah.research_sessions(id) ON DELETE CASCADE,
  query                text NOT NULL CONSTRAINT research_queries_query_length CHECK (length(query) BETWEEN 1 AND 1000),
  engine               text NOT NULL CONSTRAINT research_queries_engine_length CHECK (length(engine) BETWEEN 1 AND 50),
  results_count        integer NOT NULL DEFAULT 0 CONSTRAINT research_queries_results_positive CHECK (results_count >= 0),
  cache_hit            boolean NOT NULL DEFAULT false,
  executed_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.research_queries IS 'Requêtes d''une recherche (moteur : tavily, serper, brave, knowledge_base, local_docs, memory…), cache consulté ou non.';
ALTER TABLE soulbah.research_queries ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_research_queries_session ON soulbah.research_queries (research_session_id);

CREATE TABLE IF NOT EXISTS soulbah.research_sources (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  research_session_id  uuid NOT NULL REFERENCES soulbah.research_sessions(id) ON DELETE CASCADE,
  source_id            uuid REFERENCES soulbah.knowledge_sources(id) ON DELETE SET NULL,
  url                  text CONSTRAINT research_sources_url_length CHECK (url IS NULL OR length(url) <= 2000),
  title                text NOT NULL DEFAULT '' CONSTRAINT research_sources_title_length CHECK (length(title) <= 500),
  authority            text NOT NULL DEFAULT 'unknown' CONSTRAINT research_sources_authority_check
                       CHECK (authority IN ('official_documentation', 'source_code', 'standard', 'forum', 'opinion', 'internal', 'unknown')),
  retrieved_at         timestamptz,
  verified             boolean NOT NULL DEFAULT false,
  published_at         timestamptz,
  excerpt              text CONSTRAINT research_sources_excerpt_length CHECK (excerpt IS NULL OR length(excerpt) <= 8000),
  reliability          real CONSTRAINT research_sources_reliability_range CHECK (reliability IS NULL OR (reliability >= 0 AND reliability <= 1)),
  created_at           timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.research_sources IS 'Sources consultées par une recherche, avec date de publication si connue, extrait conservé (jamais supprimé après résumé), vérification réelle.';
ALTER TABLE soulbah.research_sources ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_research_sources_session ON soulbah.research_sources (research_session_id);
CREATE INDEX IF NOT EXISTS idx_research_sources_source ON soulbah.research_sources (source_id);

CREATE TABLE IF NOT EXISTS soulbah.research_findings (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  research_session_id      uuid NOT NULL REFERENCES soulbah.research_sessions(id) ON DELETE CASCADE,
  statement                text NOT NULL CONSTRAINT research_findings_statement_length CHECK (length(statement) BETWEEN 1 AND 4000),
  confidence               real NOT NULL DEFAULT 0.5 CONSTRAINT research_findings_confidence_range CHECK (confidence >= 0 AND confidence <= 1),
  supporting_source_ids    jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT research_findings_supporting_array CHECK (soulbah.is_json_array(supporting_source_ids)),
  contradicting_source_ids jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT research_findings_contradicting_array CHECK (soulbah.is_json_array(contradicting_source_ids)),
  freshness_policy         text NOT NULL DEFAULT 'slow' CONSTRAINT research_findings_freshness_check CHECK (freshness_policy IN ('static', 'slow', 'fast', 'volatile')),
  retrieved_at             timestamptz NOT NULL DEFAULT now(),
  status                   text NOT NULL DEFAULT 'candidate' CONSTRAINT research_findings_status_check CHECK (status IN ('candidate', 'validated', 'rejected', 'stale')),
  created_at               timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.research_findings IS 'Faits établis par une recherche, avec sources pour et contre, confiance (jamais une preuve), fraîcheur, statut.';
ALTER TABLE soulbah.research_findings ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_research_findings_session ON soulbah.research_findings (research_session_id);

CREATE TABLE IF NOT EXISTS soulbah.research_knowledge_candidates (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  finding_id      uuid NOT NULL REFERENCES soulbah.research_findings(id) ON DELETE CASCADE,
  target_kind     text NOT NULL CONSTRAINT research_knowledge_candidates_target_kind_check CHECK (target_kind IN ('knowledge_base', 'memory_item')),
  target_id       uuid,
  status          text NOT NULL DEFAULT 'pending' CONSTRAINT research_knowledge_candidates_status_check CHECK (status IN ('pending', 'deduplicated', 'stored', 'rejected')),
  duplicate_of_kind text CONSTRAINT research_knowledge_candidates_dup_kind_check CHECK (duplicate_of_kind IS NULL OR duplicate_of_kind IN ('knowledge_base', 'memory_item')),
  duplicate_of_id uuid,
  decided_by      text,
  decided_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT research_knowledge_candidates_stored_target CHECK (status <> 'stored' OR target_id IS NOT NULL),
  CONSTRAINT research_knowledge_candidates_dedup_target CHECK (status <> 'deduplicated' OR duplicate_of_id IS NOT NULL)
);
COMMENT ON TABLE soulbah.research_knowledge_candidates IS 'Pipeline §30 : finding → candidat → déduplication → validation → stockage (ou rejet). Jamais de stockage direct.';
ALTER TABLE soulbah.research_knowledge_candidates ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_research_knowledge_candidates_finding ON soulbah.research_knowledge_candidates (finding_id);
CREATE INDEX IF NOT EXISTS idx_research_knowledge_candidates_status ON soulbah.research_knowledge_candidates (status) WHERE status = 'pending';

DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON soulbah.embedding_models, soulbah.knowledge_sources, soulbah.knowledge_provenance, soulbah.knowledge_relationships,
    soulbah.knowledge_validations, soulbah.research_sessions, soulbah.research_queries, soulbah.research_sources,
    soulbah.research_findings, soulbah.research_knowledge_candidates FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.embedding_models, soulbah.knowledge_sources, soulbah.knowledge_provenance, '
                     'soulbah.knowledge_relationships, soulbah.knowledge_validations, soulbah.research_sessions, soulbah.research_queries, '
                     'soulbah.research_sources, soulbah.research_findings, soulbah.research_knowledge_candidates FROM %I', r);
    END IF;
  END LOOP;
END $$;
