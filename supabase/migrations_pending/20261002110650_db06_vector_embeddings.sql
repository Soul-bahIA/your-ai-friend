-- =============================================================================
-- DB LOT 6 (vecteurs) — colonnes et index vectoriels : les chunks et les mémoires portent leur modèle d'embedding
-- et sa dimension ; un index HNSW partiel PAR MODÈLE ; table des réindexations (§37-39).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110650_db06_vector_embeddings.down.sql (les vecteurs des mémoires sont perdus ; ceux des chunks restent)
-- soulbah:transaction=single
-- Dépend de : db05 (memory_items), db06 (embedding_models). pgvector : présent sur Supabase (0.8.0, schéma public) ;
-- absent du PostgreSQL local — le banc simule `vector` par real[] et saute les index HNSW (comme la CI).
-- =============================================================================

-- 1. knowledge_chunks (V2) : le modèle devient une référence, la dimension est portée par la ligne.
SELECT soulbah.assert_table_shape('soulbah.knowledge_chunks', '{"embedding": "vector", "embedding_model": "text", "document_id": "uuid"}');
ALTER TABLE soulbah.knowledge_chunks
  ADD COLUMN IF NOT EXISTS embedding_model_id uuid REFERENCES soulbah.embedding_models(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS embedding_dims     integer;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'knowledge_chunks_dims_range') THEN
    ALTER TABLE soulbah.knowledge_chunks ADD CONSTRAINT knowledge_chunks_dims_range CHECK (embedding_dims IS NULL OR embedding_dims BETWEEN 1 AND 16000);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_model_id ON soulbah.knowledge_chunks (embedding_model_id);
UPDATE soulbah.knowledge_chunks c
   SET embedding_model_id = m.id, embedding_dims = coalesce(c.embedding_dims, m.dimensions)
  FROM soulbah.embedding_models m
 WHERE c.embedding_model = m.name AND c.embedding_model_id IS NULL;
COMMENT ON COLUMN soulbah.knowledge_chunks.embedding_model_id IS 'Modèle qui a produit le vecteur ; jamais deux modèles dans un même index.';

-- 2. memory_items : vecteur optionnel, même règle.
ALTER TABLE soulbah.memory_items
  ADD COLUMN IF NOT EXISTS embedding          vector,
  ADD COLUMN IF NOT EXISTS embedding_model_id uuid REFERENCES soulbah.embedding_models(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS embedding_dims     integer;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'memory_items_embedding_requires_model') THEN
    ALTER TABLE soulbah.memory_items ADD CONSTRAINT memory_items_embedding_requires_model
      CHECK (embedding IS NULL OR (embedding_model_id IS NOT NULL AND embedding_dims IS NOT NULL));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'memory_items_dims_range') THEN
    ALTER TABLE soulbah.memory_items ADD CONSTRAINT memory_items_dims_range CHECK (embedding_dims IS NULL OR embedding_dims BETWEEN 1 AND 16000);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_memory_items_embedding_model ON soulbah.memory_items (embedding_model_id);

-- 3. Index HNSW partiels par modèle (une dimension fixée par le cast). Sautés sans pgvector.
CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_hnsw_nomic768 ON soulbah.knowledge_chunks USING hnsw ((embedding::vector(768)) vector_cosine_ops) WHERE embedding_model = 'nomic-embed-text-v1.5-q8_0';
CREATE INDEX IF NOT EXISTS idx_memory_items_hnsw_te3s ON soulbah.memory_items USING hnsw ((embedding::vector(1536)) vector_cosine_ops) WHERE embedding_dims = 1536;
CREATE INDEX IF NOT EXISTS idx_memory_items_hnsw_nomic768 ON soulbah.memory_items USING hnsw ((embedding::vector(768)) vector_cosine_ops) WHERE embedding_dims = 768;

-- 4. Réindexation contrôlée (§39) : ancien index → réindexation en arrière-plan → validation → bascule → nettoyage.
CREATE TABLE IF NOT EXISTS soulbah.knowledge_embedding_jobs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_id      uuid NOT NULL REFERENCES soulbah.embedding_models(id) ON DELETE CASCADE,
  target        text NOT NULL CONSTRAINT knowledge_embedding_jobs_target_check CHECK (target IN ('knowledge_chunks', 'memory_items')),
  status        text NOT NULL DEFAULT 'planned' CONSTRAINT knowledge_embedding_jobs_status_check
                CHECK (status IN ('planned', 'running', 'validating', 'switched', 'cleaned', 'failed', 'cancelled')),
  total_rows    integer NOT NULL DEFAULT 0 CONSTRAINT knowledge_embedding_jobs_total_positive CHECK (total_rows >= 0),
  done_rows     integer NOT NULL DEFAULT 0 CONSTRAINT knowledge_embedding_jobs_done_positive CHECK (done_rows >= 0),
  failed_rows   integer NOT NULL DEFAULT 0 CONSTRAINT knowledge_embedding_jobs_failed_positive CHECK (failed_rows >= 0),
  validation    jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT knowledge_embedding_jobs_validation_object CHECK (soulbah.is_json_object(validation)),
  error         text,
  started_at    timestamptz,
  finished_at   timestamptz,
  created_by    text NOT NULL DEFAULT current_user,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT knowledge_embedding_jobs_progress CHECK (done_rows + failed_rows <= total_rows OR total_rows = 0)
);
COMMENT ON TABLE soulbah.knowledge_embedding_jobs IS 'Réindexation vers un nouveau modèle d''embeddings, par lots avec reprise : jamais de bascule avant validation (Recall mesuré).';
ALTER TABLE soulbah.knowledge_embedding_jobs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_knowledge_embedding_jobs_model ON soulbah.knowledge_embedding_jobs (model_id, status);
DROP TRIGGER IF EXISTS knowledge_embedding_jobs_set_updated_at ON soulbah.knowledge_embedding_jobs;
CREATE TRIGGER knowledge_embedding_jobs_set_updated_at BEFORE UPDATE ON soulbah.knowledge_embedding_jobs FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON soulbah.knowledge_embedding_jobs FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.knowledge_embedding_jobs FROM %I', r);
    END IF;
  END LOOP;
END $$;
