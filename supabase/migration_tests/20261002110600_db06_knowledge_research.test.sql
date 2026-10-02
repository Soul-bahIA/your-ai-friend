-- Test de 20261002110600_db06_knowledge_research.sql
DO $$
DECLARE
  s uuid; rs uuid; f uuid; m uuid;
  r text;
BEGIN
  PERFORM soulbah.assert_table_shape('soulbah.embedding_models', '{"name": "text", "dimensions": "integer", "is_default": "boolean"}');
  PERFORM soulbah.assert_table_shape('soulbah.research_findings', '{"statement": "text", "confidence": "real", "freshness_policy": "text"}');
  IF (SELECT count(*) FROM soulbah.embedding_models WHERE name IN ('text-embedding-3-small', 'nomic-embed-text-v1.5-q8_0')) <> 2 THEN
    RAISE EXCEPTION 'modèles d''embeddings semés manquants';
  END IF;
  IF (SELECT dimensions FROM soulbah.embedding_models WHERE name = 'nomic-embed-text-v1.5-q8_0') <> 768 THEN RAISE EXCEPTION 'dimension nomic'; END IF;
  -- Un seul modèle par défaut
  UPDATE soulbah.embedding_models SET is_default = true WHERE name = 'text-embedding-3-small';
  BEGIN
    UPDATE soulbah.embedding_models SET is_default = true WHERE name = 'nomic-embed-text-v1.5-q8_0';
    RAISE EXCEPTION 'deux modèles par défaut acceptés';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  -- Source référencée par une provenance : non supprimable (RESTRICT)
  INSERT INTO soulbah.knowledge_sources (kind, uri, title, authority, verified, retrieved_at)
  VALUES ('web', 'https://exemple.test/doc', 'Doc', 'official_documentation', true, now()) RETURNING id INTO s;
  INSERT INTO soulbah.memory_items (type, title, content, source) VALUES ('SEMANTIC', 'Fait', 'x', 'test') RETURNING id INTO m;
  INSERT INTO soulbah.knowledge_provenance (source_id, target_kind, target_id, role, excerpt) VALUES (s, 'memory_item', m, 'origin', 'extrait');
  BEGIN
    DELETE FROM soulbah.knowledge_sources WHERE id = s;
    RAISE EXCEPTION 'source référencée supprimée';
  EXCEPTION WHEN foreign_key_violation OR restrict_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO soulbah.knowledge_sources (kind, uri, title) VALUES ('web', 'https://exemple.test/doc', 'Doublon');
    RAISE EXCEPTION 'source en double acceptée';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  -- Recherche : session, requête, source, finding, candidat ; contraintes du pipeline
  INSERT INTO soulbah.research_sessions (question, topic, mode) VALUES ('Comment configurer X ?', 'config', 'offline') RETURNING id INTO rs;
  INSERT INTO soulbah.research_queries (research_session_id, query, engine, cache_hit) VALUES (rs, 'configurer X', 'knowledge_base', true);
  INSERT INTO soulbah.research_sources (research_session_id, source_id, url, title, verified, excerpt) VALUES (rs, s, 'https://exemple.test/doc', 'Doc', true, 'extrait brut conservé');
  INSERT INTO soulbah.research_findings (research_session_id, statement, confidence, supporting_source_ids) VALUES (rs, 'X se configure par Y', 0.8, jsonb_build_array(s)) RETURNING id INTO f;
  BEGIN
    INSERT INTO soulbah.research_knowledge_candidates (finding_id, target_kind, status) VALUES (f, 'memory_item', 'stored');
    RAISE EXCEPTION 'candidat « stored » sans cible accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.research_knowledge_candidates (finding_id, target_kind, status, target_id, decided_by, decided_at) VALUES (f, 'memory_item', 'stored', m, 'user:pdg', now());
  BEGIN
    INSERT INTO soulbah.research_sessions (question, mode) VALUES ('q', 'cloud_only');
    RAISE EXCEPTION 'mode de recherche inconnu accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Validations en ajout seul
  INSERT INTO soulbah.knowledge_validations (target_kind, target_id, validator_type, validator_id, verdict) VALUES ('memory_item', m, 'human', 'user:pdg', 'valid');
  BEGIN
    UPDATE soulbah.knowledge_validations SET verdict = 'invalid';
    RAISE EXCEPTION 'validation modifiée';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Relation vers soi-même refusée
  BEGIN
    INSERT INTO soulbah.knowledge_relationships (from_kind, from_id, to_kind, to_id, kind) VALUES ('memory_item', m, 'memory_item', m, 'related_to');
    RAISE EXCEPTION 'relation vers soi-même acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- La suppression de la session de recherche emporte requêtes, sources et findings (jamais les knowledge_sources)
  DELETE FROM soulbah.research_sessions WHERE id = rs;
  IF EXISTS (SELECT 1 FROM soulbah.research_findings WHERE id = f) THEN RAISE EXCEPTION 'cascade recherche'; END IF;
  IF NOT EXISTS (SELECT 1 FROM soulbah.knowledge_sources WHERE id = s) THEN RAISE EXCEPTION 'knowledge_source supprimée avec la recherche'; END IF;
  FOR r IN SELECT unnest(ARRAY['embedding_models', 'knowledge_sources', 'knowledge_provenance', 'knowledge_relationships', 'knowledge_validations',
                                'research_sessions', 'research_queries', 'research_sources', 'research_findings', 'research_knowledge_candidates']) LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('soulbah.' || r)::regclass) THEN RAISE EXCEPTION 'RLS absente sur %', r; END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit soulbah.%', r;
    END IF;
  END LOOP;
END $$;
