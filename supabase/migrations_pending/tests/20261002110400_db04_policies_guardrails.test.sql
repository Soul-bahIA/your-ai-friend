-- Test de 20261002110400_db04_policies_guardrails.sql
DO $$
DECLARE
  g uuid;
  pv uuid;
  d_coder uuid;
  r text;
BEGIN
  PERFORM soulbah.assert_table_shape('soulbah.guardrails', '{"key": "text", "level": "text", "critical": "boolean", "immutable": "boolean"}');
  PERFORM soulbah.assert_table_shape('soulbah.policy_decisions', '{"decision": "text", "request": "jsonb"}');
  -- Semences
  IF (SELECT count(*) FROM soulbah.permission_definitions) < 30 THEN RAISE EXCEPTION 'permissions semées manquantes'; END IF;
  IF (SELECT count(*) FROM soulbah.roles WHERE name IN ('pdg', 'super_admin', 'admin', 'user')) <> 4 THEN RAISE EXCEPTION '4 rôles attendus'; END IF;
  IF (SELECT count(*) FROM soulbah.guardrails) <> 12 THEN RAISE EXCEPTION '12 garde-fous attendus'; END IF;
  IF (SELECT count(*) FROM soulbah.guardrail_versions) < 12 THEN RAISE EXCEPTION 'version initiale des garde-fous non historisée'; END IF;
  IF (SELECT current_version_id FROM soulbah.policies WHERE key = 'baseline.safe') IS NULL THEN RAISE EXCEPTION 'politique de base sans version courante'; END IF;
  IF (SELECT count(*) FROM soulbah.policy_rules pr JOIN soulbah.policy_versions v ON v.id = pr.version_id JOIN soulbah.policies p ON p.id = v.policy_id WHERE p.key = 'baseline.safe') < 30 THEN
    RAISE EXCEPTION 'règles de la politique de base manquantes';
  END IF;
  IF EXISTS (SELECT 1 FROM soulbah.policy_rules pr JOIN soulbah.policy_versions v ON v.id = pr.version_id JOIN soulbah.policies p ON p.id = v.policy_id
             WHERE p.key = 'baseline.safe' AND pr.permission IN ('production.deploy', 'network.external_ai', 'policies.manage') AND pr.effect = 'allow') THEN
    RAISE EXCEPTION 'la politique de base autorise une action critique';
  END IF;
  -- admin n''a pas les permissions critiques ; pdg les a toutes
  IF EXISTS (SELECT 1 FROM soulbah.role_permissions rp JOIN soulbah.roles r2 ON r2.id = rp.role_id JOIN soulbah.permission_definitions p ON p.name = rp.permission WHERE r2.name = 'admin' AND p.critical) THEN
    RAISE EXCEPTION 'admin a une permission critique';
  END IF;
  IF (SELECT count(*) FROM soulbah.role_permissions rp JOIN soulbah.roles r2 ON r2.id = rp.role_id WHERE r2.name = 'pdg') <> (SELECT count(*) FROM soulbah.permission_definitions) THEN
    RAISE EXCEPTION 'pdg n''a pas toutes les permissions';
  END IF;
  -- Garde-fou immuable : refusé sans Trusted Core
  SELECT id INTO g FROM soulbah.guardrails WHERE key = 'production.changes';
  BEGIN
    UPDATE soulbah.guardrails SET value = '{"mode": "LIMITED_AUTO"}' WHERE id = g;
    RAISE EXCEPTION 'garde-fou immuable modifié sans Trusted Core';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Garde-fou critique : justification obligatoire même sous Trusted Core ; puis historisé
  PERFORM set_config('soulbah.trusted_core', 'unlocked', true);
  BEGIN
    UPDATE soulbah.guardrails SET value = '{"mode": "APPROVAL_REQUIRED"}' WHERE id = g;
    RAISE EXCEPTION 'garde-fou critique modifié sans justification';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  PERFORM set_config('soulbah.change_reason', 'test : passage en approbation requise', true);
  PERFORM set_config('soulbah.actor', 'user:pdg', true);
  UPDATE soulbah.guardrails SET value = '{"mode": "APPROVAL_REQUIRED"}' WHERE id = g;
  PERFORM set_config('soulbah.trusted_core', '', true);
  IF (SELECT version FROM soulbah.guardrails WHERE id = g) <> 2 THEN RAISE EXCEPTION 'version du garde-fou attendue 2'; END IF;
  IF NOT EXISTS (SELECT 1 FROM soulbah.guardrail_versions WHERE guardrail_id = g AND version = 2 AND changed_by = 'user:pdg'
                 AND justification LIKE 'test :%' AND old_value->>'mode' = 'OFF' AND new_value->>'mode' = 'APPROVAL_REQUIRED') THEN
    RAISE EXCEPTION 'historique du garde-fou incomplet (ancien, nouveau, auteur, justification)';
  END IF;
  BEGIN
    DELETE FROM soulbah.guardrail_versions WHERE guardrail_id = g;
    RAISE EXCEPTION 'suppression de l''historique des garde-fous acceptée';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Garde-fou non critique : modifiable sans justification, historisé
  UPDATE soulbah.guardrails SET level = 'STANDARD' WHERE key = 'git.push';
  IF (SELECT count(*) FROM soulbah.guardrail_versions gv JOIN soulbah.guardrails gg ON gg.id = gv.guardrail_id WHERE gg.key = 'git.push') <> 2 THEN
    RAISE EXCEPTION 'historique du garde-fou git.push';
  END IF;
  -- Version de politique figée ; décisions en ajout seul
  SELECT v.id INTO pv FROM soulbah.policy_versions v JOIN soulbah.policies p ON p.id = v.policy_id WHERE p.key = 'baseline.safe' AND v.version = 1;
  BEGIN
    UPDATE soulbah.policy_versions SET rules = '[{"x": 1}]' WHERE id = pv;
    RAISE EXCEPTION 'règles d''une version publiée modifiées';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  INSERT INTO soulbah.policy_decisions (principal_type, principal_id, permission, environment_name, decision, policy_version_id, reason)
  VALUES ('agent', 'coder', 'production.deploy', 'PRODUCTION', 'deny', pv, 'politique de base');
  BEGIN
    UPDATE soulbah.policy_decisions SET decision = 'allow';
    RAISE EXCEPTION 'décision modifiée';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Niveaux d''autonomie : PRODUCTION n''admet pas SAFE_AUTO ; changement historisé
  SELECT id INTO d_coder FROM soulbah.agent_definitions WHERE name = 'coder';
  BEGIN
    INSERT INTO soulbah.autonomy_rules (definition_id, environment_name, level) VALUES (d_coder, 'PRODUCTION', 'SAFE_AUTO');
    RAISE EXCEPTION 'SAFE_AUTO accepté en PRODUCTION';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.autonomy_rules (definition_id, environment_name, level) VALUES (d_coder, 'DEV', 'LAB');
  UPDATE soulbah.autonomy_rules SET level = 'SAFE_AUTO' WHERE definition_id = d_coder AND environment_name = 'DEV';
  IF (SELECT count(*) FROM soulbah.autonomy_rules_history h JOIN soulbah.autonomy_rules a ON a.id = h.rule_id WHERE a.definition_id = d_coder) <> 2 THEN
    RAISE EXCEPTION 'historique d''autonomie attendu : 2 lignes';
  END IF;
  -- Rôle immuable protégé
  BEGIN
    DELETE FROM soulbah.roles WHERE name = 'pdg';
    RAISE EXCEPTION 'rôle pdg supprimé';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  FOR r IN SELECT unnest(ARRAY['permissions', 'roles', 'role_permissions', 'principal_roles', 'resource_policies', 'policies', 'policy_versions', 'policy_rules',
                                'policy_bindings', 'policy_decisions', 'autonomy_rules', 'autonomy_rules_history', 'guardrails', 'guardrail_versions',
                                'guardrail_assignments', 'guardrail_events']) LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('soulbah.' || r)::regclass) THEN RAISE EXCEPTION 'RLS absente sur %', r; END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit soulbah.%', r;
    END IF;
  END LOOP;
END $$;
