-- Test de 20261002111300_db12_missions_checkpoints.sql
DO $$
DECLARE
  u uuid := '00000000-0000-4000-8000-00000000d012'; p uuid; s uuid; s2 uuid; t uuid; cb uuid; cs uuid; csess uuid; a uuid; d_qa uuid;
  r text;
BEGIN
  PERFORM soulbah.assert_table_shape('soulbah.sessions', '{"project_id": "uuid", "autonomy_level": "text", "mission_kind": "text", "result": "text"}');
  PERFORM soulbah.assert_table_shape('soulbah.checkpoints', '{"label": "text", "kind": "text", "state_artifact_id": "uuid", "resumable": "boolean"}');
  PERFORM soulbah.assert_table_shape('soulbah.tasks', '{"project_id": "uuid"}');
  INSERT INTO auth.users (id, email) VALUES (u, 'db12@test.invalid') ON CONFLICT (id) DO NOTHING;
  SELECT id INTO p FROM soulbah.projects WHERE slug = 'soulbah';
  -- Mission : niveau d'autonomie borné ; une mission simulée n'est jamais un succès ; résultat déduit du statut
  BEGIN
    INSERT INTO soulbah.sessions (user_id, goal, autonomy_level) VALUES (u, 'x', 'GOD_MODE');
    RAISE EXCEPTION 'niveau d''autonomie inconnu accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.sessions (user_id, goal, project_id, environment_name, autonomy_level, mission_kind) VALUES (u, 'Indexer le projet', p, 'LOCAL', 'ASSIST', 'order') RETURNING id INTO s;
  BEGIN
    INSERT INTO soulbah.sessions (user_id, goal, simulated, status, result) VALUES (u, 'sim', true, 'COMPLETED', 'success');
    RAISE EXCEPTION 'mission simulée réussie acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.sessions (user_id, goal, simulated, status) VALUES (u, 'sim', true, 'COMPLETED') RETURNING id INTO s2;
  IF (SELECT result FROM soulbah.sessions WHERE id = s2) <> 'partial' THEN RAISE EXCEPTION 'résultat déduit (simulée)'; END IF;
  UPDATE soulbah.sessions SET status = 'FAILED' WHERE id = s2;
  IF (SELECT result FROM soulbah.sessions WHERE id = s2) <> 'partial' THEN RAISE EXCEPTION 'le résultat posé ne doit pas être écrasé'; END IF;
  BEGIN
    UPDATE soulbah.sessions SET parent_session_id = s WHERE id = s;
    RAISE EXCEPTION 'mission parente d''elle-même acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.sessions SET parent_session_id = s WHERE id = s2;
  INSERT INTO soulbah.tasks (session_id, user_id, title, role, project_id) VALUES (s, u, 'Lister les fichiers', 'coder', p) RETURNING id INTO t;
  -- Checkpoints : genre borné ; checkpoint de mission unique par séquence
  INSERT INTO soulbah.checkpoints (task_id, attempt, seq, step_cursor, label, kind) VALUES (t, 0, 0, 2, 'après lecture', 'before_risky_action');
  BEGIN
    INSERT INTO soulbah.checkpoints (task_id, attempt, seq, kind) VALUES (t, 0, 1, 'weird');
    RAISE EXCEPTION 'genre de checkpoint inconnu accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.session_checkpoints (session_id, seq, label, state, plan_version) VALUES (s, 1, 'tâche 1 faite', '{"done": ["t1"]}', 1);
  BEGIN
    INSERT INTO soulbah.session_checkpoints (session_id, seq, label) VALUES (s, 1, 'doublon');
    RAISE EXCEPTION 'séquence de checkpoint en double acceptée';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  -- Contexte : portée obligatoire ; sources avec cible ; métriques bornées
  BEGIN
    INSERT INTO soulbah.context_builds (purpose) VALUES ('sans portée');
    RAISE EXCEPTION 'construction de contexte sans mission ni tâche acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  SELECT id INTO d_qa FROM soulbah.agent_definitions WHERE name = 'qa_reviewer';
  INSERT INTO soulbah.context_builds (session_id, task_id, agent_definition_id, purpose, token_budget, tokens_used, status) VALUES (s, t, d_qa, 'exécuter la tâche', 6000, 5800, 'truncated') RETURNING id INTO cb;
  INSERT INTO soulbah.context_sources (build_id, kind, source_ref, score, tokens, included, reason) VALUES (cb, 'code_file', 'src/a.ts', 0.8, 900, true, 'fichier ciblé') RETURNING id INTO cs;
  BEGIN
    INSERT INTO soulbah.context_sources (build_id, kind, score) VALUES (cb, 'memory_item', 0.5);
    RAISE EXCEPTION 'source sans cible acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.context_items (build_id, position, role, tokens, content_hash, source_id) VALUES (cb, 0, 'system', 300, repeat('b', 64), NULL);
  INSERT INTO soulbah.context_items (build_id, position, role, tokens, source_id) VALUES (cb, 1, 'user', 900, cs);
  BEGIN
    INSERT INTO soulbah.context_metrics (build_id, candidates, included) VALUES (cb, 3, 5);
    RAISE EXCEPTION 'plus de retenus que de candidats accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.context_metrics (build_id, candidates, included, duplicates_removed, secrets_redacted, truncation_ratio) VALUES (cb, 12, 2, 1, 1, 0.03);
  -- Contrôle de l''ordinateur : permissions sensibles humaines ; observations sensibles éphémères ; vue des actions
  INSERT INTO soulbah.computer_sessions (session_id, task_id, kind, started_by) VALUES (s, t, 'desktop', 'agent:runtime') RETURNING id INTO csess;
  BEGIN
    INSERT INTO soulbah.computer_permissions (computer_session_id, scope, decision, granted_by, granted_at) VALUES (csess, 'payments', 'allow', 'agent:planner', now());
    RAISE EXCEPTION 'paiement autorisé par un agent';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.computer_permissions (computer_session_id, scope, decision, granted_by, granted_at) VALUES (csess, 'screen_read', 'allow', 'agent:runtime', now());
  INSERT INTO soulbah.computer_permissions (computer_session_id, scope, decision, granted_by, granted_at) VALUES (csess, 'payments', 'allow', 'user:pdg', now());
  BEGIN
    INSERT INTO soulbah.computer_observations (computer_session_id, kind, sensitivity, retention_class) VALUES (csess, 'screenshot', 'credentials', 'session');
    RAISE EXCEPTION 'observation sensible conservée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.computer_observations (computer_session_id, kind, sensitivity, retention_class, redacted) VALUES (csess, 'screenshot', 'credentials', 'ephemeral', true);
  INSERT INTO soulbah.tools (name, category, security_level) VALUES ('click', 'mouse', 'L2'), ('read_file', 'filesystem', 'L1') ON CONFLICT (name) DO NOTHING;
  INSERT INTO soulbah.actions (task_id, user_id, attempt, step_index, tool, status) VALUES (t, u, 0, 0, 'click', 'executed') RETURNING id INTO a;
  INSERT INTO soulbah.actions (task_id, user_id, attempt, step_index, tool, status) VALUES (t, u, 0, 1, 'read_file', 'executed');
  IF (SELECT count(*) FROM soulbah.computer_actions WHERE task_id = t) <> 1 THEN RAISE EXCEPTION 'vue computer_actions'; END IF;
  INSERT INTO soulbah.computer_observations (computer_session_id, action_id, kind, sensitivity) VALUES (csess, a, 'ui_snapshot', 'internal');
  BEGIN
    UPDATE soulbah.computer_sessions SET status = 'ended' WHERE id = csess;
    RAISE EXCEPTION 'session close sans date';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.computer_sessions SET status = 'ended', ended_at = now() WHERE id = csess;
  FOR r IN SELECT unnest(ARRAY['session_checkpoints', 'context_builds', 'context_sources', 'context_items', 'context_metrics', 'computer_sessions',
                                'computer_permissions', 'computer_observations']) LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('soulbah.' || r)::regclass) THEN RAISE EXCEPTION 'RLS absente sur %', r; END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit soulbah.%', r;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.computer_actions', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated lit la vue computer_actions';
  END IF;
END $$;
