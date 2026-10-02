-- Test de 20261002110650_db06_vector_embeddings.sql (pgvector simulé en local : la colonne vaut real[]).
DO $$
DECLARE
  m uuid; mi uuid; j uuid;
  has_vector boolean := EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector');
BEGIN
  PERFORM soulbah.assert_table_shape('soulbah.knowledge_chunks', '{"embedding_model_id": "uuid", "embedding_dims": "integer"}');
  PERFORM soulbah.assert_table_shape('soulbah.memory_items', '{"embedding_model_id": "uuid", "embedding_dims": "integer"}');
  SELECT id INTO m FROM soulbah.embedding_models WHERE name = 'nomic-embed-text-v1.5-q8_0';
  INSERT INTO soulbah.memory_items (type, title, content, source) VALUES ('SEMANTIC', 'v', 'x', 'test') RETURNING id INTO mi;
  -- Un vecteur sans modèle ni dimension est refusé
  BEGIN
    IF has_vector THEN
      EXECUTE 'UPDATE soulbah.memory_items SET embedding = ''[0.1,0.2,0.3]''::vector WHERE id = $1' USING mi;
    ELSE
      UPDATE soulbah.memory_items SET embedding = ARRAY[0.1, 0.2, 0.3]::real[] WHERE id = mi;
    END IF;
    RAISE EXCEPTION 'vecteur sans modèle accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  IF has_vector THEN
    EXECUTE 'UPDATE soulbah.memory_items SET embedding = ''[0.1,0.2,0.3]''::vector, embedding_model_id = $1, embedding_dims = 3 WHERE id = $2' USING m, mi;
  ELSE
    UPDATE soulbah.memory_items SET embedding = ARRAY[0.1, 0.2, 0.3]::real[], embedding_model_id = m, embedding_dims = 3 WHERE id = mi;
  END IF;
  -- Index HNSW : présents seulement avec pgvector (sautés en local, attendus sur Supabase)
  IF has_vector AND to_regclass('soulbah.idx_memory_items_hnsw_nomic768') IS NULL THEN
    RAISE EXCEPTION 'index HNSW attendu avec pgvector';
  END IF;
  -- Réindexation : progression cohérente, statut borné
  INSERT INTO soulbah.knowledge_embedding_jobs (model_id, target, total_rows) VALUES (m, 'memory_items', 10) RETURNING id INTO j;
  BEGIN
    UPDATE soulbah.knowledge_embedding_jobs SET done_rows = 11 WHERE id = j;
    RAISE EXCEPTION 'progression incohérente acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE soulbah.knowledge_embedding_jobs SET status = 'done' WHERE id = j;
    RAISE EXCEPTION 'statut inconnu accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.knowledge_embedding_jobs SET status = 'running', done_rows = 4, started_at = now() WHERE id = j;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'soulbah.knowledge_embedding_jobs'::regclass) THEN RAISE EXCEPTION 'RLS absente'; END IF;
END $$;
