-- =============================================================================
-- DB LOT 5 — Memory Core : mémoire unifiée typée (WORKING, EPISODIC, SEMANTIC, PROJECT, RESEARCH, BUG, SOLUTION,
-- SECURITY, SKILL), provenance, confiance, validation, fraîcheur, versions, statuts, relations, contradictions.
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110500_db05_memory.down.sql (les mémoires V1 restent dans public.agent_memory ; les mémoires créées ensuite sont perdues)
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03. public.agent_memory et la vue soulbah.memories (V1/V2) restent inchangées.
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.memory_items (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type                 text NOT NULL CONSTRAINT memory_items_type_check
                       CHECK (type IN ('WORKING', 'EPISODIC', 'SEMANTIC', 'PROJECT', 'RESEARCH', 'BUG', 'SOLUTION', 'SECURITY', 'SKILL')),
  project_id           uuid REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  agent_definition_id  uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  user_id              uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  session_id           uuid REFERENCES soulbah.sessions(id) ON DELETE SET NULL,
  task_id              uuid REFERENCES soulbah.tasks(id) ON DELETE SET NULL,
  title                text NOT NULL CONSTRAINT memory_items_title_length CHECK (length(title) BETWEEN 1 AND 300),
  content              text NOT NULL DEFAULT '' CONSTRAINT memory_items_content_length CHECK (length(content) <= 20000),
  content_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  source               text NOT NULL CONSTRAINT memory_items_source_length CHECK (length(source) BETWEEN 1 AND 200),
  source_ref           text CONSTRAINT memory_items_source_ref_length CHECK (source_ref IS NULL OR length(source_ref) <= 500),
  provenance           jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT memory_items_provenance_object CHECK (soulbah.is_json_object(provenance)),
  confidence           real NOT NULL DEFAULT 0.5 CONSTRAINT memory_items_confidence_range CHECK (confidence >= 0 AND confidence <= 1),
  validation_status    text NOT NULL DEFAULT 'candidate' CONSTRAINT memory_items_validation_check CHECK (validation_status IN ('candidate', 'validated', 'rejected')),
  validated_by         text,
  validated_at         timestamptz,
  freshness_policy     text NOT NULL DEFAULT 'slow' CONSTRAINT memory_items_freshness_check CHECK (freshness_policy IN ('static', 'slow', 'fast', 'volatile')),
  retrieved_at         timestamptz,
  last_verified_at     timestamptz,
  version              integer NOT NULL DEFAULT 1 CONSTRAINT memory_items_version_positive CHECK (version >= 1),
  status               text NOT NULL DEFAULT 'ACTIVE' CONSTRAINT memory_items_status_check CHECK (status IN ('ACTIVE', 'STALE', 'SUPERSEDED', 'INVALID', 'ARCHIVED')),
  supersedes_id        uuid REFERENCES soulbah.memory_items(id) ON DELETE SET NULL,
  tags                 jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT memory_items_tags_array CHECK (soulbah.is_json_array(tags)),
  metadata             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT memory_items_metadata_object CHECK (soulbah.is_json_object(metadata)),
  -- Fiable = validée ET active : seule une mémoire fiable est injectée dans un plan (§69).
  reliable             boolean GENERATED ALWAYS AS (validation_status = 'validated' AND status = 'ACTIVE') STORED,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT memory_items_validated_requires_author CHECK (validation_status <> 'validated' OR validated_by IS NOT NULL),
  CONSTRAINT memory_items_content_or_artifact CHECK (length(content) > 0 OR content_artifact_id IS NOT NULL),
  CONSTRAINT memory_items_not_self_supersede CHECK (supersedes_id IS NULL OR supersedes_id <> id)
);
COMMENT ON TABLE soulbah.memory_items IS 'Mémoire unifiée de Soulbah : type, projet, agent, provenance, confiance, validation humaine ou par preuves, fraîcheur, version, statut. reliable = validée et active.';
ALTER TABLE soulbah.memory_items ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_memory_items_project_type ON soulbah.memory_items (project_id, type, status);
CREATE INDEX IF NOT EXISTS idx_memory_items_reliable ON soulbah.memory_items (type, updated_at) WHERE reliable;
CREATE INDEX IF NOT EXISTS idx_memory_items_agent ON soulbah.memory_items (agent_definition_id);
CREATE INDEX IF NOT EXISTS idx_memory_items_user ON soulbah.memory_items (user_id);
CREATE INDEX IF NOT EXISTS idx_memory_items_session ON soulbah.memory_items (session_id);
CREATE INDEX IF NOT EXISTS idx_memory_items_task ON soulbah.memory_items (task_id);
CREATE INDEX IF NOT EXISTS idx_memory_items_artifact ON soulbah.memory_items (content_artifact_id);
CREATE INDEX IF NOT EXISTS idx_memory_items_supersedes ON soulbah.memory_items (supersedes_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_items_source_ref ON soulbah.memory_items (source, source_ref) WHERE source_ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_memory_items_tags ON soulbah.memory_items USING gin (tags jsonb_path_ops);
DROP TRIGGER IF EXISTS memory_items_set_updated_at ON soulbah.memory_items;
CREATE TRIGGER memory_items_set_updated_at BEFORE UPDATE ON soulbah.memory_items FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- Version : toute modification du contenu d'une mémoire validée incrémente la version et repasse en candidate.
CREATE OR REPLACE FUNCTION soulbah.memory_items_revalidate()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.content IS DISTINCT FROM OLD.content OR NEW.content_artifact_id IS DISTINCT FROM OLD.content_artifact_id THEN
    NEW.version := OLD.version + 1;
    IF OLD.validation_status = 'validated' AND NEW.validation_status = 'validated' AND NEW.validated_at IS NOT DISTINCT FROM OLD.validated_at THEN
      NEW.validation_status := 'candidate';   -- un contenu modifié n'est plus validé tant qu'il n'est pas revalidé
      NEW.validated_by := NULL;
      NEW.validated_at := NULL;
    END IF;
  END IF;
  IF NEW.validation_status = 'validated' AND OLD.validation_status <> 'validated' AND NEW.validated_at IS NULL THEN
    NEW.validated_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS memory_items_revalidate ON soulbah.memory_items;
CREATE TRIGGER memory_items_revalidate BEFORE UPDATE ON soulbah.memory_items FOR EACH ROW EXECUTE FUNCTION soulbah.memory_items_revalidate();

CREATE TABLE IF NOT EXISTS soulbah.memory_relationships (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_id     uuid NOT NULL REFERENCES soulbah.memory_items(id) ON DELETE CASCADE,
  to_id       uuid NOT NULL REFERENCES soulbah.memory_items(id) ON DELETE CASCADE,
  kind        text NOT NULL CONSTRAINT memory_relationships_kind_check CHECK (kind IN ('supports', 'contradicts', 'supersedes', 'derived_from', 'related_to')),
  created_by  text NOT NULL DEFAULT current_user,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT memory_relationships_not_self CHECK (from_id <> to_id),
  CONSTRAINT memory_relationships_unique UNIQUE (from_id, to_id, kind)
);
COMMENT ON TABLE soulbah.memory_relationships IS 'Relations entre mémoires : supports, contradicts, supersedes, derived_from, related_to.';
ALTER TABLE soulbah.memory_relationships ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_memory_relationships_to ON soulbah.memory_relationships (to_id, kind);

-- §60 : « supersedes » marque l'ancienne mémoire SUPERSEDED ; « contradicts » ouvre une contradiction.
CREATE TABLE IF NOT EXISTS soulbah.memory_contradictions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  memory_a     uuid NOT NULL REFERENCES soulbah.memory_items(id) ON DELETE CASCADE,
  memory_b     uuid NOT NULL REFERENCES soulbah.memory_items(id) ON DELETE CASCADE,
  detected_by  text NOT NULL DEFAULT current_user,
  status       text NOT NULL DEFAULT 'open' CONSTRAINT memory_contradictions_status_check CHECK (status IN ('open', 'resolved_a', 'resolved_b', 'both_invalid', 'dismissed')),
  resolution   text,
  resolved_by  text,
  resolved_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT memory_contradictions_not_self CHECK (memory_a <> memory_b),
  CONSTRAINT memory_contradictions_unique UNIQUE (memory_a, memory_b),
  CONSTRAINT memory_contradictions_resolution_complete CHECK (status = 'open' OR (resolved_by IS NOT NULL AND resolved_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.memory_contradictions IS 'Contradictions détectées entre deux mémoires et leur résolution (§33, §60).';
ALTER TABLE soulbah.memory_contradictions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_memory_contradictions_b ON soulbah.memory_contradictions (memory_b);
CREATE INDEX IF NOT EXISTS idx_memory_contradictions_open ON soulbah.memory_contradictions (status) WHERE status = 'open';

CREATE OR REPLACE FUNCTION soulbah.memory_relationships_apply()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.kind = 'supersedes' THEN
    UPDATE soulbah.memory_items SET status = 'SUPERSEDED' WHERE id = NEW.to_id AND status IN ('ACTIVE', 'STALE');
    UPDATE soulbah.memory_items SET supersedes_id = NEW.to_id WHERE id = NEW.from_id AND supersedes_id IS NULL;
  ELSIF NEW.kind = 'contradicts' THEN
    INSERT INTO soulbah.memory_contradictions (memory_a, memory_b, detected_by)
    VALUES (least(NEW.from_id, NEW.to_id), greatest(NEW.from_id, NEW.to_id), NEW.created_by)
    ON CONFLICT (memory_a, memory_b) DO NOTHING;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS memory_relationships_apply ON soulbah.memory_relationships;
CREATE TRIGGER memory_relationships_apply AFTER INSERT ON soulbah.memory_relationships FOR EACH ROW EXECUTE FUNCTION soulbah.memory_relationships_apply();

-- Résolution d'une contradiction : la mémoire perdante est marquée INVALID (jamais les deux valides).
CREATE OR REPLACE FUNCTION soulbah.memory_contradictions_apply()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.status = 'resolved_a' THEN
    UPDATE soulbah.memory_items SET status = 'INVALID' WHERE id = NEW.memory_b AND status <> 'ARCHIVED';
  ELSIF NEW.status = 'resolved_b' THEN
    UPDATE soulbah.memory_items SET status = 'INVALID' WHERE id = NEW.memory_a AND status <> 'ARCHIVED';
  ELSIF NEW.status = 'both_invalid' THEN
    UPDATE soulbah.memory_items SET status = 'INVALID' WHERE id IN (NEW.memory_a, NEW.memory_b) AND status <> 'ARCHIVED';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS memory_contradictions_apply ON soulbah.memory_contradictions;
CREATE TRIGGER memory_contradictions_apply AFTER UPDATE OF status ON soulbah.memory_contradictions FOR EACH ROW EXECUTE FUNCTION soulbah.memory_contradictions_apply();

-- Leçon validée d'un échec d'agent (§35) → mémoire fiable.
ALTER TABLE soulbah.agent_failures ADD COLUMN IF NOT EXISTS lesson_memory_id uuid REFERENCES soulbah.memory_items(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_agent_failures_lesson ON soulbah.agent_failures (lesson_memory_id);

-- Données : les leçons V1 validées (public.agent_memory) deviennent visibles dans la mémoire unifiée, sans copie double.
SELECT soulbah.assert_table_shape('public.agent_memory', '{"goal": "text", "content": "text", "status": "text", "type": "text", "user_id": "uuid"}');
INSERT INTO soulbah.memory_items (type, user_id, title, content, source, source_ref, provenance, confidence, validation_status,
                                  validated_by, validated_at, metadata, created_at)
SELECT CASE m.type WHEN 'error' THEN 'BUG' WHEN 'solution' THEN 'SOLUTION' WHEN 'practice' THEN 'SEMANTIC' WHEN 'optimization' THEN 'SOLUTION' ELSE 'EPISODIC' END,
       m.user_id, left(coalesce(nullif(m.goal, ''), m.type || ' (V1)'), 300), left(m.content, 20000),
       'v1:agent_memory', m.id::text,
       jsonb_build_object('origin', 'public.agent_memory', 'level', m.level, 'type', m.type, 'source_task_id', m.source_task_id),
       coalesce(m.confidence, 0.5), 'validated', coalesce(m.validated_by::text, 'user:' || m.user_id::text),
       coalesce(m.validated_at, m.updated_at, m.created_at), coalesce(m.metadata, '{}'::jsonb), m.created_at
FROM public.agent_memory m
WHERE m.status = 'validated' AND coalesce(m.is_simulation, false) = false
ON CONFLICT (source, source_ref) WHERE source_ref IS NOT NULL DO NOTHING;

DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON soulbah.memory_items, soulbah.memory_relationships, soulbah.memory_contradictions FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.memory_items, soulbah.memory_relationships, soulbah.memory_contradictions FROM %I', r);
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.memory_items_revalidate(), soulbah.memory_relationships_apply(), soulbah.memory_contradictions_apply() FROM %I', r);
    END IF;
  END LOOP;
END $$;
