-- Test de 20261002110200_db02_projects.sql
DO $$
DECLARE
  p uuid;
  r text;
BEGIN
  PERFORM soulbah.assert_table_shape('soulbah.projects', '{"slug": "text", "authorized": "boolean"}');
  PERFORM soulbah.assert_table_shape('soulbah.project_dependencies', '{"vulnerabilities": "jsonb", "vulnerability_status": "text"}');
  IF (SELECT count(*) FROM soulbah.projects WHERE slug IN ('soulbah', '224solutions', '224connect')) <> 3 THEN
    RAISE EXCEPTION '3 projets semés attendus';
  END IF;
  SELECT id INTO p FROM soulbah.projects WHERE slug = '224connect';
  -- Environnement inconnu refusé (FK vers environments)
  BEGIN
    INSERT INTO soulbah.project_environments (project_id, environment_name) VALUES (p, 'PROD');
    RAISE EXCEPTION 'environnement inconnu accepté';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  INSERT INTO soulbah.project_environments (project_id, environment_name) VALUES (p, 'PRODUCTION');
  BEGIN
    INSERT INTO soulbah.project_environments (project_id, environment_name) VALUES (p, 'PRODUCTION');
    RAISE EXCEPTION 'doublon projet × environnement accepté';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  -- Dépôt : motifs d''exclusion par défaut (secrets jamais indexés)
  INSERT INTO soulbah.project_repositories (project_id, name, location) VALUES (p, 'monorepo', 'C:\Users\SOUL-BAH\Desktop\224');
  IF NOT (SELECT excluded_patterns @> '[".env*"]'::jsonb FROM soulbah.project_repositories WHERE project_id = p) THEN
    RAISE EXCEPTION 'motif .env* absent des exclusions par défaut';
  END IF;
  -- Dépendances : unicité avec component_id NULL (NULLS NOT DISTINCT), statut borné
  INSERT INTO soulbah.project_dependencies (project_id, ecosystem, name, version) VALUES (p, 'npm', 'fastify', '5.0.0');
  BEGIN
    INSERT INTO soulbah.project_dependencies (project_id, ecosystem, name, version) VALUES (p, 'npm', 'fastify', '5.0.0');
    RAISE EXCEPTION 'dépendance en double acceptée';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    UPDATE soulbah.project_dependencies SET vulnerability_status = 'critical' WHERE project_id = p;
    RAISE EXCEPTION 'statut de vulnérabilité hors liste accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Suppression d''un projet : cascade sur ses tables filles (projet de test seulement)
  INSERT INTO soulbah.projects (slug, name) VALUES ('test-cascade', 'Test');
  INSERT INTO soulbah.project_components (project_id, key, name, kind) SELECT id, 'api', 'API', 'api' FROM soulbah.projects WHERE slug = 'test-cascade';
  DELETE FROM soulbah.projects WHERE slug = 'test-cascade';
  IF EXISTS (SELECT 1 FROM soulbah.project_components c JOIN soulbah.projects pr ON pr.id = c.project_id WHERE pr.slug = 'test-cascade') THEN
    RAISE EXCEPTION 'cascade non appliquée';
  END IF;
  FOR r IN SELECT unnest(ARRAY['projects', 'project_repositories', 'project_environments', 'project_components', 'project_dependencies', 'project_versions']) LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('soulbah.' || r)::regclass) THEN RAISE EXCEPTION 'RLS absente sur %', r; END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit soulbah.%', r;
    END IF;
  END LOOP;
END $$;
