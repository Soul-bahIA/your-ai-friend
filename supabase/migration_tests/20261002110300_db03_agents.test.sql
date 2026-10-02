-- Test de 20261002110300_db03_agents.sql
DO $$
DECLARE
  d_coder uuid;
  d_qa uuid;
  q uuid;
  r text;
BEGIN
  PERFORM soulbah.assert_table_shape('soulbah.agent_definitions', '{"name": "text", "executor": "text", "current_version_id": "uuid", "immutable": "boolean"}');
  PERFORM soulbah.assert_table_shape('soulbah.agents', '{"definition_id": "uuid", "version_id": "uuid", "outcome": "text"}');
  PERFORM soulbah.assert_table_shape('soulbah.tasks', '{"agent_definition_id": "uuid"}');
  -- Semence : 7 agents, chacun avec une version active et un état
  IF (SELECT count(*) FROM soulbah.agent_definitions) < 7 THEN RAISE EXCEPTION '7 définitions attendues'; END IF;
  IF EXISTS (SELECT 1 FROM soulbah.agent_definitions WHERE current_version_id IS NULL) THEN RAISE EXCEPTION 'définition sans version courante'; END IF;
  IF (SELECT count(*) FROM soulbah.agent_status) < 7 THEN RAISE EXCEPTION 'état manquant'; END IF;
  IF (SELECT v.tools @> '["git_merge"]'::jsonb FROM soulbah.agent_definition_versions v JOIN soulbah.agent_definitions d ON d.id = v.definition_id
      WHERE d.name = 'coder' AND v.version = '1.1.0') IS NOT TRUE THEN RAISE EXCEPTION 'outils du coder incorrects'; END IF;
  SELECT id INTO d_coder FROM soulbah.agent_definitions WHERE name = 'coder';
  SELECT id INTO d_qa FROM soulbah.agent_definitions WHERE name = 'qa_reviewer';
  -- Permissions par environnement : DEV ≠ PRODUCTION, doublon refusé
  INSERT INTO soulbah.agent_permissions (definition_id, permission, environment_name, decision) VALUES (d_coder, 'git.write', 'DEV', 'allow');
  INSERT INTO soulbah.agent_permissions (definition_id, permission, environment_name, decision) VALUES (d_coder, 'git.write', 'PRODUCTION', 'deny');
  BEGIN
    INSERT INTO soulbah.agent_permissions (definition_id, permission, environment_name, decision) VALUES (d_coder, 'git.write', 'DEV', 'deny');
    RAISE EXCEPTION 'doublon de permission accepté';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO soulbah.agent_permissions (definition_id, permission, environment_name, decision) VALUES (d_coder, 'git write', 'DEV', 'allow');
    RAISE EXCEPTION 'permission mal formée acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Affectation avec niveau d''autonomie borné
  INSERT INTO soulbah.agent_assignments (definition_id, project_id, environment_name, autonomy_level)
  SELECT d_coder, id, 'DEV', 'LAB' FROM soulbah.projects WHERE slug = '224connect';
  BEGIN
    INSERT INTO soulbah.agent_assignments (definition_id, project_id, environment_name, autonomy_level)
    SELECT d_coder, id, 'PRODUCTION', 'FULL' FROM soulbah.projects WHERE slug = '224connect';
    RAISE EXCEPTION 'niveau d''autonomie inconnu accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Relecture croisée : jamais soi-même
  BEGIN
    INSERT INTO soulbah.agent_peer_reviews (task_id, attempt, reviewer_definition_id, author_definition_id, lens, verdict)
    VALUES (gen_random_uuid(), 1, d_coder, d_coder, 'quality', 'approved');
    RAISE EXCEPTION 'auto-relecture acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
    WHEN foreign_key_violation THEN RAISE EXCEPTION 'la contrainte « pas soi-même » doit être vérifiée avant la FK';
  END;
  -- Watchdog : ajout seul
  INSERT INTO soulbah.agent_watchdog_events (definition_id, kind, severity, action_taken) VALUES (d_coder, 'loop', 'HIGH', 'quarantined');
  BEGIN
    DELETE FROM soulbah.agent_watchdog_events WHERE definition_id = d_coder;
    RAISE EXCEPTION 'suppression d''un événement watchdog acceptée';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Quarantaine : l''agent passe en quarantaine ; la levée le laisse suspendu (réactivation explicite)
  INSERT INTO soulbah.agent_quarantines (definition_id, reason) VALUES (d_coder, 'boucle détectée (test)') RETURNING id INTO q;
  IF (SELECT status FROM soulbah.agent_definitions WHERE id = d_coder) <> 'quarantined' THEN RAISE EXCEPTION 'définition non mise en quarantaine'; END IF;
  IF (SELECT status FROM soulbah.agent_status WHERE definition_id = d_coder) <> 'quarantined' THEN RAISE EXCEPTION 'état non mis en quarantaine'; END IF;
  BEGIN
    UPDATE soulbah.agent_quarantines SET status = 'lifted' WHERE id = q;
    RAISE EXCEPTION 'levée sans auteur ni date acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.agent_quarantines SET status = 'lifted', lifted_by = 'user:pdg', lifted_at = now(), lifted_reason = 'analysé' WHERE id = q;
  IF (SELECT status FROM soulbah.agent_definitions WHERE id = d_coder) <> 'suspended' THEN RAISE EXCEPTION 'après levée : suspendu attendu'; END IF;
  -- Définition immuable protégée par le Trusted Core (rendre immuable est déjà un acte réservé)
  BEGIN
    UPDATE soulbah.agent_definitions SET immutable = true WHERE id = d_qa;
    RAISE EXCEPTION 'agent rendu immuable sans Trusted Core';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('soulbah.trusted_core', 'unlocked', true);
  UPDATE soulbah.agent_definitions SET immutable = true WHERE id = d_qa;
  PERFORM set_config('soulbah.trusted_core', '', true);
  BEGIN
    UPDATE soulbah.agent_definitions SET max_security_level = 'L3' WHERE id = d_qa;
    RAISE EXCEPTION 'agent immuable modifié sans Trusted Core';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Métriques : période cohérente
  BEGIN
    INSERT INTO soulbah.agent_metrics (definition_id, period_start, period_end) VALUES (d_coder, now(), now() - interval '1 hour');
    RAISE EXCEPTION 'période incohérente acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  FOR r IN SELECT unnest(ARRAY['agent_definitions', 'agent_definition_versions', 'agent_capabilities', 'agent_permissions', 'agent_assignments',
                                'agent_status', 'agent_metrics', 'agent_failures', 'agent_watchdog_events', 'agent_peer_reviews', 'agent_quarantines']) LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('soulbah.' || r)::regclass) THEN RAISE EXCEPTION 'RLS absente sur %', r; END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit soulbah.%', r;
    END IF;
  END LOOP;
END $$;
