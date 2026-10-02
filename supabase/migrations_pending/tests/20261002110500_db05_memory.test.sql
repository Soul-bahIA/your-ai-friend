-- Test de 20261002110500_db05_memory.sql
DO $$
DECLARE
  a uuid; b uuid; c uuid;
  p uuid;
  r text;
  n_v1 integer;
BEGIN
  PERFORM soulbah.assert_table_shape('soulbah.memory_items', '{"type": "text", "reliable": "boolean", "version": "integer", "status": "text", "freshness_policy": "text"}');
  PERFORM soulbah.assert_table_shape('soulbah.agent_failures', '{"lesson_memory_id": "uuid"}');
  -- Leçons V1 validées copiées une seule fois (source v1:agent_memory)
  SELECT count(*) INTO n_v1 FROM public.agent_memory WHERE status = 'validated' AND coalesce(is_simulation, false) = false;
  IF (SELECT count(*) FROM soulbah.memory_items WHERE source = 'v1:agent_memory') <> n_v1 THEN RAISE EXCEPTION 'copie des leçons V1 incomplète'; END IF;
  IF EXISTS (SELECT 1 FROM soulbah.memory_items WHERE source = 'v1:agent_memory' AND NOT reliable) THEN RAISE EXCEPTION 'leçon V1 copiée non fiable'; END IF;
  SELECT id INTO p FROM soulbah.projects WHERE slug = '224connect';
  -- Candidat non fiable ; validation sans auteur refusée ; validation correcte → fiable
  INSERT INTO soulbah.memory_items (type, project_id, title, content, source) VALUES ('SOLUTION', p, 'Correctif A', 'Utiliser X', 'test') RETURNING id INTO a;
  IF (SELECT reliable FROM soulbah.memory_items WHERE id = a) THEN RAISE EXCEPTION 'candidat marqué fiable'; END IF;
  BEGIN
    UPDATE soulbah.memory_items SET validation_status = 'validated' WHERE id = a;
    RAISE EXCEPTION 'validation sans auteur acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.memory_items SET validation_status = 'validated', validated_by = 'user:pdg' WHERE id = a;
  IF NOT (SELECT reliable FROM soulbah.memory_items WHERE id = a) THEN RAISE EXCEPTION 'mémoire validée non fiable'; END IF;
  IF (SELECT validated_at FROM soulbah.memory_items WHERE id = a) IS NULL THEN RAISE EXCEPTION 'validated_at non posé'; END IF;
  -- Modification du contenu : version +1 et retour en candidate
  UPDATE soulbah.memory_items SET content = 'Utiliser X puis Y' WHERE id = a;
  IF (SELECT version FROM soulbah.memory_items WHERE id = a) <> 2 OR (SELECT validation_status FROM soulbah.memory_items WHERE id = a) <> 'candidate' THEN
    RAISE EXCEPTION 'contenu modifié : version 2 et candidate attendus';
  END IF;
  -- Remplacement : l''ancienne passe SUPERSEDED, la nouvelle pointe supersedes_id
  INSERT INTO soulbah.memory_items (type, project_id, title, content, source) VALUES ('SOLUTION', p, 'Correctif B', 'Utiliser Z', 'test') RETURNING id INTO b;
  INSERT INTO soulbah.memory_relationships (from_id, to_id, kind) VALUES (b, a, 'supersedes');
  IF (SELECT status FROM soulbah.memory_items WHERE id = a) <> 'SUPERSEDED' THEN RAISE EXCEPTION 'ancienne mémoire non remplacée'; END IF;
  IF (SELECT supersedes_id FROM soulbah.memory_items WHERE id = b) <> a THEN RAISE EXCEPTION 'supersedes_id non posé'; END IF;
  -- Contradiction : ouverte par la relation, résolue → perdante INVALID ; résolution sans auteur refusée
  INSERT INTO soulbah.memory_items (type, project_id, title, content, source) VALUES ('SEMANTIC', p, 'Fait C', 'Redis sert au cache', 'test') RETURNING id INTO c;
  INSERT INTO soulbah.memory_relationships (from_id, to_id, kind) VALUES (c, b, 'contradicts');
  IF (SELECT count(*) FROM soulbah.memory_contradictions WHERE memory_a = least(b, c) AND memory_b = greatest(b, c) AND status = 'open') <> 1 THEN
    RAISE EXCEPTION 'contradiction non ouverte';
  END IF;
  BEGIN
    UPDATE soulbah.memory_contradictions SET status = 'resolved_a' WHERE memory_a = least(b, c);
    RAISE EXCEPTION 'résolution sans auteur acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.memory_contradictions SET status = 'resolved_a', resolved_by = 'user:pdg', resolved_at = now(), resolution = 'preuve' WHERE memory_a = least(b, c);
  IF (SELECT status FROM soulbah.memory_items WHERE id = greatest(b, c)) <> 'INVALID' THEN RAISE EXCEPTION 'mémoire perdante non invalidée'; END IF;
  -- Relation vers soi-même refusée ; type inconnu refusé
  BEGIN
    INSERT INTO soulbah.memory_relationships (from_id, to_id, kind) VALUES (a, a, 'related_to');
    RAISE EXCEPTION 'relation vers soi-même acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO soulbah.memory_items (type, title, content, source) VALUES ('DREAM', 'x', 'y', 'test');
    RAISE EXCEPTION 'type de mémoire inconnu accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  FOR r IN SELECT unnest(ARRAY['memory_items', 'memory_relationships', 'memory_contradictions']) LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('soulbah.' || r)::regclass) THEN RAISE EXCEPTION 'RLS absente sur %', r; END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit soulbah.%', r;
    END IF;
  END LOOP;
END $$;
