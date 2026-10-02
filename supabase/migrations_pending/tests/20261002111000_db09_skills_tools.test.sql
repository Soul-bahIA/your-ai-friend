-- Test de 20261002111000_db09_skills_tools.sql
DO $$
DECLARE
  sk uuid; sv uuid; tool uuid; cand uuid; b uuid;
  r text;
BEGIN
  PERFORM soulbah.assert_table_shape('soulbah.skills', '{"current_version_id": "uuid", "category": "text", "project_id": "uuid", "risk_level": "text"}');
  PERFORM soulbah.assert_table_shape('soulbah.tools', '{"name": "text", "permission": "text", "status": "text"}');
  -- Compétence : version candidate → active seulement avec un test passé
  INSERT INTO soulbah.skills (name, version, source, status, security_level, schema, procedure) VALUES ('repair_rls_issue', '1.0.0', 'learned', 'proposed', 'L2', '{}', '{}') RETURNING id INTO sk;
  INSERT INTO soulbah.skill_versions (skill_id, version, status) VALUES (sk, '1.0.0', 'candidate') RETURNING id INTO sv;
  INSERT INTO soulbah.skill_steps (version_id, position, tool_name, params) VALUES (sv, 1, 'read_file', '{"path": "x"}');
  INSERT INTO soulbah.skill_requirements (version_id, kind, value) VALUES (sv, 'permission', 'database.read');
  BEGIN
    UPDATE soulbah.skill_versions SET status = 'active', validated_by = 'user:pdg' WHERE id = sv;
    RAISE EXCEPTION 'version activée sans test passé';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.skill_tests (version_id, name, kind, last_result, last_run_at) VALUES (sv, 'golden-1', 'golden', 'passed', now());
  BEGIN
    UPDATE soulbah.skill_versions SET status = 'active' WHERE id = sv;
    RAISE EXCEPTION 'version activée sans auteur de validation';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.skill_versions SET status = 'active', validated_by = 'user:pdg', validated_at = now() WHERE id = sv;
  UPDATE soulbah.skills SET current_version_id = sv WHERE id = sk;
  INSERT INTO soulbah.skill_tests (version_id, name, kind, last_result) VALUES (sv, 'sec-1', 'security', 'failed');
  BEGIN
    UPDATE soulbah.skill_versions SET status = 'candidate' WHERE id = sv;
    UPDATE soulbah.skill_versions SET status = 'active' WHERE id = sv;
    RAISE EXCEPTION 'version activée avec un test en échec';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Candidat de compétence : promotion exige les identifiants promus, décision tracée
  BEGIN
    INSERT INTO soulbah.skill_candidates (name, source, status) VALUES ('fix_x', 'agent_learning', 'promoted');
    RAISE EXCEPTION 'candidat promu sans compétence cible';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.skill_candidates (name, source, status, promoted_skill_id, promoted_version_id, decided_by, decided_at)
  VALUES ('fix_x', 'agent_learning', 'promoted', sk, sv, 'user:pdg', now());
  -- Outils : permission FK vers le catalogue des permissions ; statut borné
  INSERT INTO soulbah.tools (name, category, security_level, permission) VALUES ('write_file', 'filesystem', 'L1', 'filesystem.write') RETURNING id INTO tool;
  BEGIN
    INSERT INTO soulbah.tools (name, category, security_level, permission) VALUES ('odd_tool', 'x', 'L1', 'nope.nope');
    RAISE EXCEPTION 'permission inconnue acceptée';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  INSERT INTO soulbah.tool_permissions (tool_id, permission, environment_name, decision) VALUES (tool, 'filesystem.write', 'PRODUCTION', 'deny');
  INSERT INTO soulbah.tool_health (tool_id, status) VALUES (tool, 'healthy');
  INSERT INTO soulbah.tool_benchmarks (tool_id, metric, value, unit) VALUES (tool, 'latency_p95', 120, 'ms');
  -- Constructeur : promotion refusée sans build réussi + tests + revue humaine
  INSERT INTO soulbah.tool_candidates (name, purpose) VALUES ('csv_probe', 'Lire un CSV') RETURNING id INTO cand;
  BEGIN
    UPDATE soulbah.tool_candidates SET status = 'promoted', promoted_tool_id = tool, decided_by = 'user:pdg', decided_at = now() WHERE id = cand;
    RAISE EXCEPTION 'outil promu sans build';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.tool_builds (candidate_id, version, status) VALUES (cand, '0.1.0', 'succeeded') RETURNING id INTO b;
  INSERT INTO soulbah.tool_tests (build_id, name, kind, status) VALUES (b, 'sandbox-1', 'sandbox', 'passed');
  INSERT INTO soulbah.tool_security_reviews (build_id, reviewer_type, reviewer_id, verdict) VALUES (b, 'agent', 'security_reviewer', 'approved');
  BEGIN
    UPDATE soulbah.tool_candidates SET status = 'promoted', promoted_tool_id = tool, decided_by = 'user:pdg', decided_at = now() WHERE id = cand;
    RAISE EXCEPTION 'outil promu sans revue humaine';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.tool_security_reviews (build_id, reviewer_type, reviewer_id, verdict) VALUES (b, 'human', 'user:pdg', 'approved');
  UPDATE soulbah.tool_candidates SET status = 'promoted', promoted_tool_id = tool, decided_by = 'user:pdg', decided_at = now() WHERE id = cand;
  BEGIN
    DELETE FROM soulbah.tool_security_reviews WHERE build_id = b;
    RAISE EXCEPTION 'revue de sécurité supprimée';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  FOR r IN SELECT unnest(ARRAY['skill_versions', 'skill_steps', 'skill_requirements', 'skill_tools', 'skill_tests', 'skill_metrics', 'skill_candidates',
                                'tools', 'tool_versions', 'tool_permissions', 'tool_health', 'tool_benchmarks', 'tool_candidates', 'tool_builds',
                                'tool_tests', 'tool_security_reviews']) LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('soulbah.' || r)::regclass) THEN RAISE EXCEPTION 'RLS absente sur %', r; END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit soulbah.%', r;
    END IF;
  END LOOP;
END $$;
