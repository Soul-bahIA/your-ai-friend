-- Recherche sémantique (RAG) de la base de connaissances via pgvector.
-- Embeddings OpenAI text-embedding-3-small (1536 dimensions). La recherche par
-- distance cosinus (<=>) complète la recherche plein-texte : elle retrouve les
-- connaissances par le SENS, pas seulement par les mots-clés.
CREATE EXTENSION IF NOT EXISTS vector;

ALTER TABLE public.knowledge_base ADD COLUMN IF NOT EXISTS embedding vector(1536);

-- Index HNSW pour la similarité cosinus (rapide sur de gros volumes).
CREATE INDEX IF NOT EXISTS idx_knowledge_base_embedding
  ON public.knowledge_base USING hnsw (embedding vector_cosine_ops);
