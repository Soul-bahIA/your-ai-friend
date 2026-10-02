-- Test de 20261002110900_db08_code_db_api_ui_intelligence.sql
DO $$
DECLARE
  p uuid; repo uuid; repo2 uuid; f1 uuid; f2 uuid; f3 uuid; s1 uuid; s2 uuid; s3 uuid; src uuid; sch uuid; t1 uuid; t2 uuid;
  svc uuid; ep uuid; surf uuid; route uuid; comp uuid; act uuid; flow1 uuid; flow2 uuid;
  r text;
BEGIN
  PERFORM soulbah.assert_table_shape('soulbah.code_symbols', '{"qualified_name": "text", "line_start": "integer", "exported": "boolean"}');
  PERFORM soulbah.assert_table_shape('soulbah.db_sources', '{"connection_ref": "text", "read_only": "boolean", "authorized": "boolean"}');
  PERFORM soulbah.assert_table_shape('soulbah.project_environments', '{"db_source_id": "uuid"}');
  SELECT id INTO p FROM soulbah.projects WHERE slug = '224connect';
  INSERT INTO soulbah.project_repositories (project_id, name, location) VALUES (p, 'repo-test', 'C:\tmp\r') RETURNING id INTO repo;
  -- Code : fichiers, symboles, dépendances, références
  INSERT INTO soulbah.code_files (project_id, repository_id, path, language, content_hash) VALUES (p, repo, 'backend1/src/modules/channels/routes.ts', 'typescript', repeat('a', 64)) RETURNING id INTO f1;
  INSERT INTO soulbah.code_files (project_id, repository_id, path, language) VALUES (p, repo, 'backend1/src/modules/channels/service.ts', 'typescript') RETURNING id INTO f2;
  BEGIN
    INSERT INTO soulbah.code_files (project_id, repository_id, path) VALUES (p, repo, 'backend1/src/modules/channels/routes.ts');
    RAISE EXCEPTION 'fichier en double accepté';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  INSERT INTO soulbah.code_symbols (project_id, file_id, kind, name, qualified_name, line_start, line_end, exported) VALUES (p, f1, 'route_handler', 'listChannels', 'channels.routes.listChannels', 10, 40, true) RETURNING id INTO s1;
  INSERT INTO soulbah.code_symbols (project_id, file_id, kind, name, qualified_name, line_start, exported) VALUES (p, f2, 'function', 'findChannels', 'channels.service.findChannels', 5, true) RETURNING id INTO s2;
  BEGIN
    INSERT INTO soulbah.code_symbols (project_id, file_id, kind, name, qualified_name, line_start, line_end) VALUES (p, f1, 'function', 'x', 'x', 50, 40);
    RAISE EXCEPTION 'ligne de fin avant la ligne de début acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.code_dependencies (project_id, from_file_id, to_file_id, kind) VALUES (p, f1, f2, 'import');
  INSERT INTO soulbah.code_dependencies (project_id, from_file_id, to_module, kind) VALUES (p, f1, 'fastify', 'import');
  BEGIN
    INSERT INTO soulbah.code_dependencies (project_id, from_file_id, kind) VALUES (p, f1, 'import');
    RAISE EXCEPTION 'dépendance sans cible acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.code_references (project_id, from_symbol_id, to_symbol_id, kind, line) VALUES (p, s1, s2, 'call', 22);
  INSERT INTO soulbah.code_change_events (project_id, repository_id, file_id, path, kind) VALUES (p, repo, f1, 'backend1/src/modules/channels/routes.ts', 'modified');
  BEGIN
    DELETE FROM soulbah.code_change_events WHERE file_id = f1;
    RAISE EXCEPTION 'événement de changement supprimé';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  INSERT INTO soulbah.code_index_state (repository_id, status, files_total, files_indexed) VALUES (repo, 'idle', 2, 2);
  -- Base : jamais d''identifiants dans connection_ref ; FK depuis project_environments
  BEGIN
    INSERT INTO soulbah.db_sources (project_id, name, kind, environment_name, connection_ref) VALUES (p, 'base1', 'supabase', 'PRODUCTION', 'postgresql://u:p@h/db');
    RAISE EXCEPTION 'URL avec identifiants acceptée dans connection_ref';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.db_sources (project_id, name, kind, environment_name, connection_ref) VALUES (p, 'base1-coeur', 'supabase', 'PRODUCTION', 'vault:224connect/base1/readonly') RETURNING id INTO src;
  IF (SELECT read_only AND NOT authorized FROM soulbah.db_sources WHERE id = src) IS NOT TRUE THEN RAISE EXCEPTION 'défauts de db_sources : lecture seule et non autorisée'; END IF;
  INSERT INTO soulbah.project_environments (project_id, environment_name, db_source_id) VALUES (p, 'PRODUCTION', src) ON CONFLICT (project_id, environment_name) DO UPDATE SET db_source_id = EXCLUDED.db_source_id;
  INSERT INTO soulbah.db_schemas (source_id, name, managed_by) VALUES (src, 'public', 'app') RETURNING id INTO sch;
  INSERT INTO soulbah.db_tables (schema_id, name, rls_enabled, sensitivity) VALUES (sch, 'channels', true, 'internal') RETURNING id INTO t1;
  INSERT INTO soulbah.db_tables (schema_id, name, rls_enabled, sensitivity) VALUES (sch, 'profiles', true, 'confidential') RETURNING id INTO t2;
  INSERT INTO soulbah.db_columns (table_id, name, position, data_type, is_pk) VALUES (t1, 'id', 1, 'uuid', true);
  INSERT INTO soulbah.db_relations (source_id, from_table_id, to_table_id, name, columns, ref_columns) VALUES (src, t1, t2, 'channels_owner_fkey', '["owner_id"]', '["id"]');
  INSERT INTO soulbah.db_policies (table_id, name, command, roles, using_expr, risk) VALUES (t1, 'Users read channels', 'SELECT', '["authenticated"]', 'true', 'review');
  INSERT INTO soulbah.db_table_usages (table_id, symbol_id, kind, evidence) VALUES (t1, s2, 'read', 'SELECT ... FROM channels');
  BEGIN
    INSERT INTO soulbah.db_table_usages (table_id, kind) VALUES (t1, 'read');
    RAISE EXCEPTION 'usage sans fichier ni symbole accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- API : service, endpoint (méthode bornée), dépendance vers une table, consommateur, règle de sécurité
  INSERT INTO soulbah.api_services (project_id, name, kind, base_path) VALUES (p, 'api-node', 'rest', '/v1') RETURNING id INTO svc;
  INSERT INTO soulbah.api_endpoints (service_id, method, path, handler_symbol_id, auth_required) VALUES (svc, 'GET', '/channels', s1, true) RETURNING id INTO ep;
  BEGIN
    INSERT INTO soulbah.api_endpoints (service_id, method, path) VALUES (svc, 'FETCH', '/x');
    RAISE EXCEPTION 'méthode HTTP inconnue acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.api_dependencies (endpoint_id, depends_on_kind, depends_on_id, usage) VALUES (ep, 'table', t1, 'reads');
  INSERT INTO soulbah.api_security_rules (endpoint_id, rule, expected, observed, status) VALUES (ep, 'auth_required', '{"required": true}', '{"required": true}', 'satisfied');
  BEGIN
    INSERT INTO soulbah.api_security_rules (rule, status) VALUES ('cors', 'unknown');
    RAISE EXCEPTION 'règle sans portée acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- UI : surface, route, composant, action, lien vers l''API
  INSERT INTO soulbah.ui_surfaces (project_id, name, kind) VALUES (p, 'web', 'web') RETURNING id INTO surf;
  INSERT INTO soulbah.ui_routes (surface_id, path, name, auth_required) VALUES (surf, '/channels', 'Canaux', true) RETURNING id INTO route;
  INSERT INTO soulbah.ui_components (surface_id, name, kind, file_id) VALUES (surf, 'ChannelsPage', 'page', NULL) RETURNING id INTO comp;
  INSERT INTO soulbah.ui_actions (component_id, name, kind, label) VALUES (comp, 'refresh', 'button', 'Rafraîchir') RETURNING id INTO act;
  INSERT INTO soulbah.ui_api_links (endpoint_id, action_id, evidence) VALUES (ep, act, 'fetch(/v1/channels)');
  INSERT INTO soulbah.api_consumers (endpoint_id, consumer_kind, consumer_id) VALUES (ep, 'ui_component', comp);
  BEGIN
    INSERT INTO soulbah.ui_api_links (endpoint_id) VALUES (ep);
    RAISE EXCEPTION 'lien UI → API sans source accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Parcours : étapes ordonnées, dépendances sans boucle sur soi
  INSERT INTO soulbah.user_flows (project_id, key, name, actor) VALUES (p, 'join-channel', 'Rejoindre un canal', 'utilisateur') RETURNING id INTO flow1;
  INSERT INTO soulbah.user_flows (project_id, key, name) VALUES (p, 'login', 'Connexion') RETURNING id INTO flow2;
  INSERT INTO soulbah.user_flow_steps (flow_id, position, name, route_id, endpoint_id, table_id) VALUES (flow1, 1, 'Ouvrir la liste', route, ep, t1);
  BEGIN
    INSERT INTO soulbah.user_flow_steps (flow_id, position, name) VALUES (flow1, 1, 'Doublon');
    RAISE EXCEPTION 'position d''étape en double acceptée';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  INSERT INTO soulbah.user_flow_dependencies (flow_id, depends_on_flow_id, kind) VALUES (flow1, flow2, 'requires');
  BEGIN
    INSERT INTO soulbah.user_flow_dependencies (flow_id, depends_on_flow_id) VALUES (flow1, flow1);
    RAISE EXCEPTION 'dépendance d''un parcours vers lui-même acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Journal en ajout seul : un dépôt qui a des événements ne se supprime pas (RESTRICT, pas de cascade silencieuse)
  BEGIN
    DELETE FROM soulbah.project_repositories WHERE id = repo;
    RAISE EXCEPTION 'dépôt avec journal supprimé';
  EXCEPTION WHEN foreign_key_violation OR restrict_violation THEN NULL;
  END;
  -- Cascade : la suppression d''un dépôt sans journal emporte fichiers, symboles, références, état d''index
  INSERT INTO soulbah.project_repositories (project_id, name, location) VALUES (p, 'repo-test-2', 'C:\tmp\r2') RETURNING id INTO repo2;
  INSERT INTO soulbah.code_files (project_id, repository_id, path, language) VALUES (p, repo2, 'src/a.ts', 'typescript') RETURNING id INTO f3;
  INSERT INTO soulbah.code_symbols (project_id, file_id, kind, name, qualified_name, line_start) VALUES (p, f3, 'function', 'a', 'a', 1) RETURNING id INTO s3;
  INSERT INTO soulbah.code_references (project_id, from_symbol_id, to_symbol_id, kind) VALUES (p, s3, s2, 'call');
  INSERT INTO soulbah.code_index_state (repository_id, status) VALUES (repo2, 'idle');
  UPDATE soulbah.api_endpoints SET handler_symbol_id = s3 WHERE id = ep;
  DELETE FROM soulbah.project_repositories WHERE id = repo2;
  IF EXISTS (SELECT 1 FROM soulbah.code_files WHERE id = f3) OR EXISTS (SELECT 1 FROM soulbah.code_symbols WHERE id = s3)
     OR EXISTS (SELECT 1 FROM soulbah.code_references WHERE from_symbol_id = s3) OR EXISTS (SELECT 1 FROM soulbah.code_index_state WHERE repository_id = repo2) THEN
    RAISE EXCEPTION 'cascade dépôt → fichiers → symboles → références';
  END IF;
  IF (SELECT handler_symbol_id FROM soulbah.api_endpoints WHERE id = ep) IS NOT NULL THEN RAISE EXCEPTION 'handler non détaché'; END IF;
  FOR r IN SELECT unnest(ARRAY['code_files', 'code_symbols', 'code_dependencies', 'code_references', 'code_change_events', 'code_index_state',
                                'db_sources', 'db_snapshots', 'db_schemas', 'db_tables', 'db_columns', 'db_relations', 'db_indexes', 'db_policies',
                                'db_functions', 'db_triggers', 'db_table_usages', 'api_services', 'api_endpoints', 'api_dependencies', 'api_consumers',
                                'api_security_rules', 'ui_surfaces', 'ui_routes', 'ui_components', 'ui_actions', 'ui_api_links',
                                'user_flows', 'user_flow_steps', 'user_flow_dependencies']) LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('soulbah.' || r)::regclass) THEN RAISE EXCEPTION 'RLS absente sur %', r; END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit soulbah.%', r;
    END IF;
  END LOOP;
END $$;
