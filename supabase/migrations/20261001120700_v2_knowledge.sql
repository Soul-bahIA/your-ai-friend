-- =============================================================================
-- V2 — 8/12 : connaissances — extension de public.knowledge_base (documents), vue
-- soulbah.knowledge_documents, table soulbah.knowledge_chunks (RAG hybride) — audit §12, T14, T38.
-- Idempotente, additive. La dimension de knowledge_base.embedding (vector(1536)) n'est
-- JAMAIS changée en place (« Jamais », §12) : les chunks portent un `embedding vector`
-- sans dimension fixe et un embedding_model par ligne.
-- =============================================================================

-- knowledge_base = knowledge_documents : source, statut d'ingestion et statut documentaire.
-- doc_status est NULLABLE SANS défaut : les lignes héritées ne sont pas modifiées, la vue
-- dérive leur statut (category = 'recherche' → finding, non validé ; sinon user).
ALTER TABLE public.knowledge_base
  ADD COLUMN IF NOT EXISTS source_uri       text,
  ADD COLUMN IF NOT EXISTS mime             text,
  ADD COLUMN IF NOT EXISTS ingest_status    text,
  ADD COLUMN IF NOT EXISTS embedding_model  text,
  ADD COLUMN IF NOT EXISTS last_written_at  timestamptz,
  ADD COLUMN IF NOT EXISTS doc_status       text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'knowledge_base_doc_status_check'
                   AND conrelid = 'public.knowledge_base'::regclass) THEN
    ALTER TABLE public.knowledge_base ADD CONSTRAINT knowledge_base_doc_status_check
      CHECK (doc_status IS NULL OR doc_status IN ('finding', 'user', 'validated', 'rejected', 'deprecated')) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'knowledge_base_ingest_status_check'
                   AND conrelid = 'public.knowledge_base'::regclass) THEN
    ALTER TABLE public.knowledge_base ADD CONSTRAINT knowledge_base_ingest_status_check
      CHECK (ingest_status IS NULL OR ingest_status IN ('pending', 'chunked', 'embedded', 'failed')) NOT VALID;
  END IF;
END $$;
DO $$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY ARRAY['knowledge_base_doc_status_check', 'knowledge_base_ingest_status_check'] LOOP
    BEGIN
      EXECUTE format('ALTER TABLE public.knowledge_base VALIDATE CONSTRAINT %I', c);
    EXCEPTION WHEN check_violation THEN
      RAISE NOTICE 'Contrainte % non validée : des lignes existantes la violent', c;
    END;
  END LOOP;
END $$;
CREATE INDEX IF NOT EXISTS idx_knowledge_base_doc_status ON public.knowledge_base (user_id, doc_status);

-- Vue : statut effectif des documents. Le RAG « connaissance validée » exclut les findings.
CREATE OR REPLACE VIEW soulbah.knowledge_documents AS
SELECT kb.id,
       kb.user_id,
       kb.title,
       kb.category,
       kb.domain,
       kb.source,
       kb.source_uri,
       kb.mime,
       kb.ingest_status,
       kb.embedding_model,
       kb.content_hash,
       kb.version,
       kb.confidence,
       COALESCE(kb.doc_status, CASE WHEN kb.category = 'recherche' THEN 'finding' ELSE 'user' END) AS doc_status,
       (kb.doc_status IS NULL) AS doc_status_derived,
       kb.last_verified_at,
       kb.last_written_at,
       kb.created_at,
       kb.updated_at
  FROM public.knowledge_base kb;

-- Chunks : unité de récupération (FTS + vecteur, fusion RRF au LOT 13).
CREATE TABLE IF NOT EXISTS soulbah.knowledge_chunks (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id      uuid NOT NULL REFERENCES public.knowledge_base(id) ON DELETE CASCADE,
  user_id          uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  chunk_index      integer NOT NULL CONSTRAINT knowledge_chunks_index_positive CHECK (chunk_index >= 0),
  content          text NOT NULL CONSTRAINT knowledge_chunks_content_length CHECK (length(content) BETWEEN 1 AND 20000),
  token_count      integer CONSTRAINT knowledge_chunks_tokens_positive CHECK (token_count IS NULL OR token_count >= 0),
  -- tsvector généré (FTS) ; configuration « simple » : multilingue, sans racinisation.
  tsv              tsvector GENERATED ALWAYS AS (to_tsvector('simple', content)) STORED,
  -- Vecteur SANS dimension fixe (T38) : le modèle est porté par la ligne.
  embedding        vector,
  embedding_model  text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT knowledge_chunks_unique UNIQUE (document_id, chunk_index),
  CONSTRAINT knowledge_chunks_model_with_embedding CHECK (embedding IS NULL OR embedding_model IS NOT NULL)
);
ALTER TABLE soulbah.knowledge_chunks ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_document ON soulbah.knowledge_chunks (document_id, chunk_index);
CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_user ON soulbah.knowledge_chunks (user_id);
CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_tsv ON soulbah.knowledge_chunks USING gin (tsv);
-- Index HNSW PARTIEL par modèle (une dimension fixée par le cast) — un index par modèle d'embedding.
CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_hnsw_te3s ON soulbah.knowledge_chunks
  USING hnsw ((embedding::vector(1536)) vector_cosine_ops)
  WHERE embedding_model = 'text-embedding-3-small';
