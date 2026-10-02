-- Test de 20261002110800_db07_project_brain.sql
DO $$
DECLARE
  p uuid; repo uuid; d1 uuid; d2 uuid; c uuid;
  r text;
BEGIN
  PERFORM soulbah.assert_table_shape('soulbah.project_brain_coverage', '{"numerator": "integer", "denominator": "integer", "ratio": "real"}');
  PERFORM soulbah.assert_table_shape('soulbah.knowledge_gaps', '{"kind": "text", "severity": "text", "status": "text"}');
  SELECT id INTO p FROM soulbah.projects WHERE slug = '224connect';
  INSERT INTO soulbah.project_repositories (project_id, name, location) VALUES (p, 'test-repo', 'C:\tmp\repo') RETURNING id INTO repo;
  -- Couverture : ratio calculé, jamais > 1, numérateur ≤ dénominateur
  INSERT INTO soulbah.project_brain_coverage (project_id, area, numerator, denominator, method) VALUES (p, 'code', 320, 650, 'fichiers indexés / fichiers hors exclusions');
  IF abs((SELECT ratio FROM soulbah.project_brain_coverage WHERE project_id = p AND area = 'code') - 0.4923) > 0.001 THEN RAISE EXCEPTION 'ratio de couverture'; END IF;
  BEGIN
    INSERT INTO soulbah.project_brain_coverage (project_id, area, numerator, denominator, method) VALUES (p, 'api', 10, 5, 'x');
    RAISE EXCEPTION 'couverture > 100 %% acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.project_brain_coverage (project_id, area, numerator, denominator, method) VALUES (p, 'ui', 0, 0, 'rien de mesuré');
  IF (SELECT ratio FROM soulbah.project_brain_coverage WHERE project_id = p AND area = 'ui') <> 0 THEN RAISE EXCEPTION 'ratio sans dénominateur'; END IF;
  -- Documents : contenu ou artefact ; chemin unique par projet
  BEGIN
    INSERT INTO soulbah.project_brain_documents (project_id, kind, title) VALUES (p, 'module', 'Vide');
    RAISE EXCEPTION 'document sans contenu accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.project_brain_documents (project_id, kind, title, path, content) VALUES (p, 'module', 'Canaux', 'brain/channels.md', '# Canaux') RETURNING id INTO d1;
  BEGIN
    INSERT INTO soulbah.project_brain_documents (project_id, kind, title, path, content) VALUES (p, 'module', 'Canaux bis', 'brain/channels.md', 'x');
    RAISE EXCEPTION 'chemin de document en double accepté';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  INSERT INTO soulbah.project_brain_documents (project_id, kind, title, content) VALUES (p, 'flow', 'Live', 'créer un live') RETURNING id INTO d2;
  INSERT INTO soulbah.project_brain_components (project_id, key, name, kind) VALUES (p, 'channels', 'Canaux', 'module') RETURNING id INTO c;
  -- Relations : typées, uniques, jamais vers soi-même
  INSERT INTO soulbah.project_brain_relationships (project_id, from_kind, from_id, to_kind, to_id, kind) VALUES (p, 'document', d1, 'component', c, 'documents');
  INSERT INTO soulbah.project_brain_relationships (project_id, from_kind, from_id, to_kind, to_id, kind) VALUES (p, 'flow', d2, 'component', c, 'uses');
  BEGIN
    INSERT INTO soulbah.project_brain_relationships (project_id, from_kind, from_id, to_kind, to_id, kind) VALUES (p, 'document', d1, 'component', c, 'documents');
    RAISE EXCEPTION 'relation en double acceptée';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO soulbah.project_brain_relationships (project_id, from_kind, from_id, to_kind, to_id, kind) VALUES (p, 'component', c, 'component', c, 'uses');
    RAISE EXCEPTION 'relation vers soi-même acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Zones inconnues : cible obligatoire, résolution datée
  BEGIN
    INSERT INTO soulbah.knowledge_gaps (project_id, kind) VALUES (p, 'unknown_module');
    RAISE EXCEPTION 'zone inconnue sans cible acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.knowledge_gaps (project_id, kind, target_ref, severity) VALUES (p, 'module_without_tests', 'backend2/src/intelligence/feed', 'MEDIUM');
  BEGIN
    UPDATE soulbah.knowledge_gaps SET status = 'resolved' WHERE project_id = p;
    RAISE EXCEPTION 'résolution sans date acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Commits : empreinte valide, unicité, ajout seul
  INSERT INTO soulbah.project_commits (project_id, repository_id, sha, message, files) VALUES (p, repo, 'abc1234', 'fix', '["a.ts"]');
  BEGIN
    INSERT INTO soulbah.project_commits (project_id, repository_id, sha, message) VALUES (p, repo, 'abc1234', 'doublon');
    RAISE EXCEPTION 'commit en double accepté';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    DELETE FROM soulbah.project_commits WHERE sha = 'abc1234';
    RAISE EXCEPTION 'commit supprimé';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Décision : remplacement
  INSERT INTO soulbah.project_decisions (project_id, title, decision) VALUES (p, 'Redis pour le cache', 'Utiliser Redis');
  FOR r IN SELECT unnest(ARRAY['project_brain_documents', 'project_brain_components', 'project_brain_relationships', 'project_brain_snapshots',
                                'project_brain_coverage', 'knowledge_gaps', 'project_decisions', 'project_commits']) LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('soulbah.' || r)::regclass) THEN RAISE EXCEPTION 'RLS absente sur %', r; END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit soulbah.%', r;
    END IF;
  END LOOP;
END $$;
