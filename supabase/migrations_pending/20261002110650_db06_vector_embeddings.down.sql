-- Retour arrière de 20261002110650_db06_vector_embeddings.sql — les vecteurs des mémoires sont perdus.
DROP TABLE IF EXISTS soulbah.knowledge_embedding_jobs;
DROP INDEX IF EXISTS soulbah.idx_memory_items_hnsw_nomic768;
DROP INDEX IF EXISTS soulbah.idx_memory_items_hnsw_te3s;
DROP INDEX IF EXISTS soulbah.idx_knowledge_chunks_hnsw_nomic768;
ALTER TABLE soulbah.memory_items DROP CONSTRAINT IF EXISTS memory_items_embedding_requires_model;
ALTER TABLE soulbah.memory_items DROP CONSTRAINT IF EXISTS memory_items_dims_range;
ALTER TABLE soulbah.memory_items DROP COLUMN IF EXISTS embedding_dims, DROP COLUMN IF EXISTS embedding_model_id, DROP COLUMN IF EXISTS embedding;
ALTER TABLE soulbah.knowledge_chunks DROP CONSTRAINT IF EXISTS knowledge_chunks_dims_range;
ALTER TABLE soulbah.knowledge_chunks DROP COLUMN IF EXISTS embedding_dims, DROP COLUMN IF EXISTS embedding_model_id;
