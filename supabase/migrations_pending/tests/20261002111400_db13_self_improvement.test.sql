-- Test de 20261002111400_db13_self_improvement.sql
DO $$
DECLARE
  c uuid; e uuid; ap bigint; dep uuid; v1 uuid; v2 uuid; run uuid;
  r text;
BEGIN
  PERFORM soulbah.assert_table_shape('soulbah.improvement_deployments', '{"approval_id": "bigint", "from_version_id": "uuid", "to_version_id": "uuid"}');
  INSERT INTO soulbah.system_versions (component, version, status) VALUES ('planner.prompt', '1', 'active') RETURNING id INTO v1;
  INSERT INTO soulbah.system_versions (component, version, status) VALUES ('planner.prompt', '2', 'candidate') RETURNING id INTO v2;
  INSERT INTO soulbah.improvement_candidates (key, kind, title, source, target_component, risk) VALUES ('planner.prompt.compact-v2', 'prompt', 'Prompt compact v2', 'failure_analysis', 'planner.prompt', 'LOW') RETURNING id INTO c;
  -- Expériences : jamais en production ; mesures adossées à une exécution de benchmark
  BEGIN
    INSERT INTO soulbah.improvement_experiments (candidate_id, name, method, environment_name) VALUES (c, 'prod', 'canary', 'PRODUCTION');
    RAISE EXCEPTION 'expérience en production acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.improvement_experiments (candidate_id, name, method, environment_name, baseline_version_id) VALUES (c, 'bench-1', 'benchmark', 'LOCAL', v1) RETURNING id INTO e;
  SELECT id INTO run FROM soulbah.benchmark_runs WHERE external_ref = 'registry:qwen2.5-1.5b-instruct-q4_k_m:2026-10-02T09:48:35Z';
  INSERT INTO soulbah.improvement_benchmarks (experiment_id, benchmark_run_id, role, score, score_max) VALUES (e, run, 'baseline', 4, 5);
  BEGIN
    INSERT INTO soulbah.improvement_benchmarks (experiment_id, benchmark_run_id, role, score, score_max) VALUES (e, gen_random_uuid(), 'candidate', 5, 5);
    RAISE EXCEPTION 'mesure sans exécution acceptée';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  -- Approbations : un agent ne peut pas approuver ; ajout seul
  BEGIN
    INSERT INTO soulbah.improvement_approvals (candidate_id, experiment_id, decision, decider_kind, decided_by) VALUES (c, e, 'approved', 'agent', 'agent:planner');
    RAISE EXCEPTION 'approbation par un agent acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.improvement_approvals (candidate_id, experiment_id, decision, decider_kind, decided_by) VALUES (c, e, 'deferred', 'agent', 'agent:planner');
  INSERT INTO soulbah.improvement_approvals (candidate_id, experiment_id, decision, decider_kind, decided_by, rationale) VALUES (c, e, 'approved', 'human', 'user:pdg', 'gain mesuré') RETURNING id INTO ap;
  BEGIN
    DELETE FROM soulbah.improvement_approvals WHERE id = ap;
    RAISE EXCEPTION 'approbation supprimée';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Déploiement : candidat non approuvé → refus ; auto-amélioration OFF (défaut) → refus ; PROPOSE_ONLY + LOCAL → accepté
  INSERT INTO soulbah.improvement_deployments (candidate_id, approval_id, environment_name, component, from_version_id, to_version_id) VALUES (c, ap, 'LOCAL', 'planner.prompt', v1, v2) RETURNING id INTO dep;
  BEGIN
    UPDATE soulbah.improvement_deployments SET status = 'deployed', deployed_by = 'user:pdg', deployed_at = now() WHERE id = dep;
    RAISE EXCEPTION 'déploiement d''un candidat non approuvé accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.improvement_candidates SET status = 'approved', decided_by = 'user:pdg', decided_at = now() WHERE id = c;
  BEGIN
    UPDATE soulbah.improvement_deployments SET status = 'deployed', deployed_by = 'user:pdg', deployed_at = now() WHERE id = dep;
    RAISE EXCEPTION 'déploiement avec auto-amélioration OFF accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  PERFORM set_config('soulbah.change_reason', 'test db13', true);
  UPDATE soulbah.system_state SET self_improvement = 'PROPOSE_ONLY' WHERE id = 1;
  UPDATE soulbah.improvement_deployments SET status = 'deployed', deployed_by = 'user:pdg', deployed_at = now() WHERE id = dep;
  -- Production : refusée tant que production_changes = OFF
  BEGIN
    INSERT INTO soulbah.improvement_deployments (candidate_id, approval_id, environment_name, component, from_version_id, to_version_id, status, deployed_by, deployed_at)
    VALUES (c, ap, 'PRODUCTION', 'planner.prompt', v1, v2, 'deployed', 'user:pdg', now());
    RAISE EXCEPTION 'déploiement en production avec production_changes OFF accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Révocation : plus aucun déploiement possible sur cette approbation
  INSERT INTO soulbah.improvement_approvals (candidate_id, decision, decider_kind, decided_by, rationale) VALUES (c, 'revoked', 'human', 'user:pdg', 'régression constatée');
  BEGIN
    INSERT INTO soulbah.improvement_deployments (candidate_id, approval_id, environment_name, component, to_version_id) VALUES (c, ap, 'LOCAL', 'planner.prompt', v2);
    RAISE EXCEPTION 'déploiement sur approbation révoquée accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE soulbah.improvement_deployments SET status = 'rolled_back' WHERE id = dep;
    RAISE EXCEPTION 'retour arrière sans motif accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  FOR r IN SELECT unnest(ARRAY['improvement_candidates', 'improvement_experiments', 'improvement_benchmarks', 'improvement_approvals', 'improvement_deployments']) LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('soulbah.' || r)::regclass) THEN RAISE EXCEPTION 'RLS absente sur %', r; END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit soulbah.%', r;
    END IF;
  END LOOP;
END $$;
