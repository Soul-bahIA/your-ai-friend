-- Test de 20261002111200_db11_security_immune.sql
DO $$
DECLARE
  p uuid; pat uuid; inc uuid; f uuid; act uuid; fix uuid; d_qa uuid; q uuid;
  r text; n integer;
BEGIN
  PERFORM soulbah.assert_table_shape('soulbah.security_findings', '{"fingerprint": "text", "severity_justification": "text", "confidence": "real"}');
  PERFORM soulbah.assert_table_shape('soulbah.agent_quarantines', '{"incident_id": "uuid"}');
  SELECT id INTO p FROM soulbah.projects WHERE slug = '224connect';
  -- Motif : statistiques tenues par les constats
  INSERT INTO soulbah.security_patterns (key, pattern_kind, category, title, severity, status) VALUES ('rls.policy_true', 'security', 'rls', 'Policy RLS « true »', 'HIGH', 'active') RETURNING id INTO pat;
  -- Constat : sévérité haute sans justification refusée ; empreinte unique ; triage signé
  BEGIN
    INSERT INTO soulbah.security_findings (fingerprint, project_id, pattern_id, kind, severity, title) VALUES (repeat('1', 64), p, pat, 'vulnerability', 'HIGH', 'Policy ouverte');
    RAISE EXCEPTION 'sévérité HIGH sans justification acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.security_findings (fingerprint, project_id, pattern_id, kind, severity, severity_justification, confidence, title, location)
  VALUES (repeat('1', 64), p, pat, 'vulnerability', 'HIGH', 'Lecture de toutes les lignes par tout utilisateur authentifié', 0.9, 'Policy ouverte', '{"table": "public.channels", "policy": "Users read channels"}') RETURNING id INTO f;
  BEGIN
    INSERT INTO soulbah.security_findings (fingerprint, project_id, kind, severity, title) VALUES (repeat('1', 64), p, 'bug', 'LOW', 'Doublon');
    RAISE EXCEPTION 'constat en double accepté';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  IF (SELECT occurrences FROM soulbah.security_patterns WHERE id = pat) <> 1 THEN RAISE EXCEPTION 'occurrences du motif'; END IF;
  IF NOT (SELECT projects_affected ? p::text FROM soulbah.security_patterns WHERE id = pat) THEN RAISE EXCEPTION 'projet touché non noté'; END IF;
  BEGIN
    UPDATE soulbah.security_findings SET status = 'CONFIRMED' WHERE id = f;
    RAISE EXCEPTION 'confirmation sans triage signé acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.security_findings SET status = 'CONFIRMED', triaged_by = 'agent:security_reviewer', triaged_at = now() WHERE id = f;
  BEGIN
    UPDATE soulbah.security_findings SET status = 'VERIFIED' WHERE id = f;
    RAISE EXCEPTION 'vérification non signée acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Incident : événement de détection automatique ; changement de statut journalisé ; clôture signée
  INSERT INTO soulbah.incidents (kind, severity, title, project_id, environment_name) VALUES ('security', 'HIGH', 'Fuite potentielle de données canaux', p, 'PRODUCTION') RETURNING id INTO inc;
  IF (SELECT count(*) FROM soulbah.incident_events WHERE incident_id = inc AND kind = 'detected') <> 1 THEN RAISE EXCEPTION 'événement de détection absent'; END IF;
  IF (SELECT count(*) FROM soulbah.security_incidents WHERE id = inc) <> 1 THEN RAISE EXCEPTION 'vue security_incidents'; END IF;
  UPDATE soulbah.security_findings SET incident_id = inc WHERE id = f;
  PERFORM set_config('soulbah.change_reason', 'policy corrigée en test', true);
  UPDATE soulbah.incidents SET status = 'CONTAINED', contained_at = now() WHERE id = inc;
  IF (SELECT count(*) FROM soulbah.incident_events WHERE incident_id = inc AND kind = 'status_change' AND detail ->> 'to' = 'CONTAINED') <> 1 THEN RAISE EXCEPTION 'changement de statut non journalisé'; END IF;
  BEGIN
    UPDATE soulbah.incidents SET status = 'CLOSED' WHERE id = inc;
    RAISE EXCEPTION 'clôture non signée acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    DELETE FROM soulbah.incident_events WHERE incident_id = inc;
    RAISE EXCEPTION 'chronologie supprimée';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Action : exécution sans approbation refusée
  INSERT INTO soulbah.incident_actions (incident_id, kind, description) VALUES (inc, 'patch', 'Restreindre la policy') RETURNING id INTO act;
  BEGIN
    UPDATE soulbah.incident_actions SET status = 'executed', executed_by = 'agent:fixer', executed_at = now() WHERE id = act;
    RAISE EXCEPTION 'action exécutée sans approbation';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.incident_actions SET status = 'approved', approved_by = 'user:pdg', approved_at = now() WHERE id = act;
  UPDATE soulbah.incident_actions SET status = 'executed', executed_by = 'agent:fixer', executed_at = now() WHERE id = act;
  INSERT INTO soulbah.incident_evidence (incident_id, finding_id, kind, description, sha256) VALUES (inc, f, 'query', 'SELECT sur la policy', repeat('a', 64));
  INSERT INTO soulbah.incident_decisions (incident_id, decision, decider_kind, decided_by, autonomy_level) VALUES (inc, 'Corriger en production après revue', 'human', 'user:pdg', 'PRODUCTION_GUARDED');
  INSERT INTO soulbah.incident_recovery_steps (incident_id, position, description) VALUES (inc, 1, 'Déployer la policy corrigée');
  BEGIN
    UPDATE soulbah.incident_recovery_steps SET status = 'done' WHERE incident_id = inc;
    RAISE EXCEPTION 'étape faite sans signature';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Correctif : en PRODUCTION, appliqué seulement avec approbation
  INSERT INTO soulbah.security_fixes (finding_id, incident_id, environment_name, change_kind, description) VALUES (f, inc, 'PRODUCTION', 'database', 'Policy restreinte au propriétaire') RETURNING id INTO fix;
  BEGIN
    UPDATE soulbah.security_fixes SET status = 'applied', applied_by = 'agent:fixer', applied_at = now() WHERE id = fix;
    RAISE EXCEPTION 'correctif appliqué en production sans approbation';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.security_fixes SET status = 'approved', approved_by = 'user:pdg', approved_at = now() WHERE id = fix;
  UPDATE soulbah.security_fixes SET status = 'applied', applied_by = 'agent:fixer', applied_at = now() WHERE id = fix;
  INSERT INTO soulbah.security_regression_tests (project_id, finding_id, fix_id, name, kind, location, last_result, last_run_at) VALUES (p, f, fix, 'rls-channels-owner-only', 'sql', 'tests/rls/channels.sql', 'failed', now());
  INSERT INTO soulbah.security_detection_rules (key, pattern_id, kind, target, rule, severity) VALUES ('rls.policy_true.detect', pat, 'database', 'pg_policies', '{"using": "true"}', 'HIGH');
  -- Lien avec les commits et les quarantaines
  SELECT id INTO d_qa FROM soulbah.agent_definitions WHERE name = 'qa_reviewer';
  INSERT INTO soulbah.agent_quarantines (definition_id, reason, incident_id) VALUES (d_qa, 'test', inc) RETURNING id INTO q;
  -- Vues SOC
  IF (SELECT count(*) FROM soulbah.v_soc_active_incidents WHERE id = inc) <> 1 THEN RAISE EXCEPTION 'v_soc_active_incidents'; END IF;
  IF (SELECT pending_actions FROM soulbah.v_soc_active_incidents WHERE id = inc) <> 0 THEN RAISE EXCEPTION 'actions en attente'; END IF;
  IF (SELECT count(*) FROM soulbah.v_soc_critical_findings WHERE id = f) <> 1 THEN RAISE EXCEPTION 'v_soc_critical_findings'; END IF;
  IF (SELECT count(*) FROM soulbah.v_soc_quarantined_agents WHERE quarantine_id = q) <> 1 THEN RAISE EXCEPTION 'v_soc_quarantined_agents'; END IF;
  IF (SELECT count(*) FROM soulbah.v_soc_recent_fixes WHERE id = fix) <> 1 THEN RAISE EXCEPTION 'v_soc_recent_fixes'; END IF;
  IF (SELECT count(*) FROM soulbah.v_soc_regressions WHERE name = 'rls-channels-owner-only') <> 1 THEN RAISE EXCEPTION 'v_soc_regressions'; END IF;
  SELECT findings_open INTO n FROM soulbah.v_soc_coverage WHERE project_id = p;
  IF n <> 1 THEN RAISE EXCEPTION 'v_soc_coverage findings_open = %', n; END IF;
  -- audit_events : vue sur audit_logs
  IF to_regclass('soulbah.audit_events') IS NULL THEN RAISE EXCEPTION 'vue audit_events absente'; END IF;
  PERFORM 1 FROM soulbah.audit_events LIMIT 1;
  FOR r IN SELECT unnest(ARRAY['security_patterns', 'incidents', 'security_findings', 'incident_events', 'incident_actions', 'incident_evidence',
                                'incident_decisions', 'incident_recovery_steps', 'security_fixes', 'security_regression_tests', 'security_detection_rules']) LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('soulbah.' || r)::regclass) THEN RAISE EXCEPTION 'RLS absente sur %', r; END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit soulbah.%', r;
    END IF;
  END LOOP;
  FOR r IN SELECT unnest(ARRAY['security_incidents', 'v_soc_active_incidents', 'v_soc_open_findings', 'v_soc_critical_findings', 'v_soc_quarantined_agents',
                                'v_soc_recent_fixes', 'v_soc_regressions', 'v_soc_coverage', 'audit_events']) LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit la vue soulbah.%', r;
    END IF;
  END LOOP;
END $$;
