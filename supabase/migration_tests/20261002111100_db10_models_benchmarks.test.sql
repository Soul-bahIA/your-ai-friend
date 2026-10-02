-- Test de 20261002111100_db10_models_benchmarks.sql
DO $$
DECLARE
  qwen uuid; nomic uuid; bv uuid; run uuid; rule uuid; comp uuid; ds uuid; dv uuid; cfg uuid; tr uuid; cand uuid;
  r text;
BEGIN
  PERFORM soulbah.assert_table_shape('soulbah.model_versions', '{"sha256": "text", "registry_key": "text", "status": "text"}');
  PERFORM soulbah.assert_table_shape('soulbah.embedding_models', '{"model_id": "uuid"}');
  PERFORM soulbah.assert_table_shape('soulbah.tool_benchmarks', '{"benchmark_run_id": "uuid"}');
  -- Semences : deux modèles du registre local, empreintes réelles, aucun actif sans approbation humaine
  SELECT id INTO qwen FROM soulbah.model_versions WHERE registry_key = 'qwen2.5-1.5b-instruct-q4_k_m';
  SELECT id INTO nomic FROM soulbah.model_versions WHERE registry_key = 'nomic-embed-text-v1.5-q8_0';
  IF qwen IS NULL OR nomic IS NULL THEN RAISE EXCEPTION 'versions semées manquantes'; END IF;
  IF (SELECT sha256 FROM soulbah.model_versions WHERE id = qwen) <> '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e' THEN RAISE EXCEPTION 'empreinte qwen'; END IF;
  IF EXISTS (SELECT 1 FROM soulbah.model_versions WHERE status IN ('active', 'shadow')) THEN RAISE EXCEPTION 'une version semée est active'; END IF;
  IF (SELECT model_id FROM soulbah.embedding_models WHERE name = 'nomic-embed-text-v1.5-q8_0') IS NULL THEN RAISE EXCEPTION 'embedding_models.model_id non relié'; END IF;
  -- Benchmark de fumée : version gelée, 5 tâches, exécution 4/5 adossée à des résultats par tâche
  SELECT v.id INTO bv FROM soulbah.benchmark_versions v JOIN soulbah.benchmarks b ON b.id = v.benchmark_id WHERE b.name = 'local_smoke' AND v.version = 1;
  IF (SELECT count(*) FROM soulbah.benchmark_tasks WHERE benchmark_version_id = bv) <> 5 THEN RAISE EXCEPTION 'tâches du benchmark de fumée'; END IF;
  SELECT id INTO run FROM soulbah.benchmark_runs WHERE external_ref = 'registry:qwen2.5-1.5b-instruct-q4_k_m:2026-10-02T09:48:35Z';
  IF (SELECT count(*) FILTER (WHERE passed) FROM soulbah.benchmark_results WHERE run_id = run) <> 4 THEN RAISE EXCEPTION 'résultats 4/5 attendus'; END IF;
  IF (SELECT score FROM soulbah.model_benchmarks WHERE run_id = run) <> 4 THEN RAISE EXCEPTION 'score agrégé'; END IF;
  BEGIN
    INSERT INTO soulbah.benchmark_tasks (benchmark_version_id, key) VALUES (bv, 'extra');
    RAISE EXCEPTION 'tâche ajoutée à une version gelée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO soulbah.benchmark_runs (benchmark_version_id, subject_kind, model_version_id, status, score, score_max, finished_at) VALUES (bv, 'model', qwen, 'completed', 6, 5, now());
    RAISE EXCEPTION 'score supérieur au maximum accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO soulbah.benchmark_runs (benchmark_version_id, subject_kind, model_version_id, status) VALUES (bv, 'model', qwen, 'completed');
    RAISE EXCEPTION 'exécution « completed » sans score acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO soulbah.model_capabilities (version_id, capability, level, measured) VALUES (nomic, 'rerank', 'weak', true);
    RAISE EXCEPTION 'capacité « mesurée » sans exécution acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Activation : refusée tant que la sécurité n''est pas approuvée par un humain
  BEGIN
    UPDATE soulbah.model_versions SET status = 'active' WHERE id = qwen;
    RAISE EXCEPTION 'version activée sans approbation de sécurité';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE soulbah.model_security_status SET status = 'approved' WHERE version_id = qwen;
    RAISE EXCEPTION 'statut approuvé sans approbateur';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE soulbah.model_security_status SET status = 'approved', approved_by = 'user:pdg', approved_at = now() WHERE version_id = nomic;
    RAISE EXCEPTION 'statut approuvé sans empreinte vérifiée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.model_security_status SET status = 'approved', approved_by = 'user:pdg', approved_at = now() WHERE version_id = qwen;
  UPDATE soulbah.model_versions SET status = 'active' WHERE id = qwen;
  -- Routage : cible active obligatoire ; historique en ajout seul
  BEGIN
    INSERT INTO soulbah.model_routing_rules (name, task_kind, network_mode, model_version_id) VALUES ('embed-offline', 'embed', 'OFFLINE', nomic);
    RAISE EXCEPTION 'règle vers une version non active acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.model_routing_rules (name, task_kind, network_mode, model_version_id) VALUES ('chat-offline', 'chat', 'OFFLINE', qwen) RETURNING id INTO rule;
  INSERT INTO soulbah.model_routing_history (rule_id, chosen_version_id, task_kind, network_mode, latency_ms, outcome) VALUES (rule, qwen, 'chat', 'OFFLINE', 1200, 'ok');
  BEGIN
    UPDATE soulbah.model_routing_history SET outcome = 'error' WHERE rule_id = rule;
    RAISE EXCEPTION 'historique de routage modifié';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    DELETE FROM soulbah.model_routing_rules WHERE id = rule;
    RAISE EXCEPTION 'règle avec historique supprimée';
  EXCEPTION WHEN foreign_key_violation OR restrict_violation THEN NULL;
  END;
  -- Candidats : téléchargement sans approbation humaine refusé
  INSERT INTO soulbah.model_candidates (name, source, source_ref, rationale) VALUES ('qwen2.5-3b-instruct-q4_k_m', 'download', 'Qwen/Qwen2.5-3B-Instruct-GGUF', 'meilleur raisonnement attendu') RETURNING id INTO cand;
  BEGIN
    UPDATE soulbah.model_candidates SET status = 'downloading' WHERE id = cand;
    RAISE EXCEPTION 'téléchargement sans approbation accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.model_candidates SET status = 'download_approved', download_approved_by = 'user:pdg', download_approved_at = now() WHERE id = cand;
  UPDATE soulbah.model_candidates SET status = 'downloading' WHERE id = cand;
  -- Compétition : champion ≠ challenger ; vainqueur parmi les deux ; clôture signée
  BEGIN
    INSERT INTO soulbah.model_competitions (name, champion_version_id, challenger_version_id, benchmark_version_id) VALUES ('self', qwen, qwen, bv);
    RAISE EXCEPTION 'compétition contre soi-même acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.model_competitions (name, champion_version_id, challenger_version_id, benchmark_version_id) VALUES ('chat-2026-10', qwen, nomic, bv) RETURNING id INTO comp;
  INSERT INTO soulbah.model_comparison_results (competition_id, metric, champion_value, challenger_value) VALUES (comp, 'score', 4, 2);
  IF (SELECT better FROM soulbah.model_comparison_results WHERE competition_id = comp) <> 'champion' THEN RAISE EXCEPTION 'meilleur calculé'; END IF;
  INSERT INTO soulbah.model_comparison_results (competition_id, metric, champion_value, challenger_value, higher_is_better) VALUES (comp, 'latency_ms', 1200, 800, false);
  IF (SELECT better FROM soulbah.model_comparison_results WHERE competition_id = comp AND metric = 'latency_ms') <> 'challenger' THEN RAISE EXCEPTION 'meilleur calculé (latence)'; END IF;
  BEGIN
    UPDATE soulbah.model_competitions SET status = 'completed', winner_version_id = qwen WHERE id = comp;
    RAISE EXCEPTION 'compétition close sans signataire';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.model_competitions SET status = 'completed', winner_version_id = qwen, decided_by = 'user:pdg', decided_at = now() WHERE id = comp;
  -- Mode ombre : versions distinctes
  BEGIN
    INSERT INTO soulbah.shadow_runs (shadow_version_id, primary_version_id) VALUES (qwen, qwen);
    RAISE EXCEPTION 'ombre identique au principal acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.shadow_runs (shadow_version_id, primary_version_id, task_kind, status) VALUES (nomic, qwen, 'chat', 'completed');
  -- Jeux de données : jamais « secret » ; entraînement seulement sur configuration approuvée et jeu gelé
  BEGIN
    INSERT INTO soulbah.datasets (name, purpose, sensitivity) VALUES ('secrets', 'training', 'secret');
    RAISE EXCEPTION 'jeu de données secret accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.datasets (name, purpose, domain) VALUES ('golden-regression', 'regression', 'mixed') RETURNING id INTO ds;
  INSERT INTO soulbah.dataset_versions (dataset_id, version, item_count) VALUES (ds, 1, 1) RETURNING id INTO dv;
  INSERT INTO soulbah.dataset_items (version_id, key, input, expected) VALUES (dv, 'g1', '{"q": "x"}', '{"a": "y"}');
  INSERT INTO soulbah.training_configs (name, base_model_version_id, dataset_version_id, method) VALUES ('lora-test', qwen, dv, 'lora') RETURNING id INTO cfg;
  BEGIN
    INSERT INTO soulbah.training_runs (config_id) VALUES (cfg);
    RAISE EXCEPTION 'entraînement sans configuration approuvée accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.training_configs SET approved_by = 'user:pdg', approved_at = now() WHERE id = cfg;
  INSERT INTO soulbah.training_runs (config_id) VALUES (cfg) RETURNING id INTO tr;
  BEGIN
    UPDATE soulbah.training_runs SET status = 'running', started_at = now() WHERE id = tr;
    RAISE EXCEPTION 'entraînement lancé sur un jeu non gelé';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.dataset_versions SET frozen = true, frozen_at = now() WHERE id = dv;
  UPDATE soulbah.training_runs SET status = 'running', started_at = now() WHERE id = tr;
  INSERT INTO soulbah.training_results (run_id, metric, step, value) VALUES (tr, 'loss', 1, 2.31);
  FOR r IN SELECT unnest(ARRAY['models', 'model_versions', 'model_hardware_requirements', 'model_security_status', 'benchmarks', 'benchmark_versions',
                                'golden_tasks', 'golden_task_expected_results', 'benchmark_tasks', 'datasets', 'dataset_versions', 'dataset_sources',
                                'dataset_items', 'dataset_quality_checks', 'benchmark_runs', 'benchmark_results', 'model_benchmarks', 'model_capabilities',
                                'model_routing_rules', 'model_routing_history', 'model_candidates', 'model_competitions', 'model_comparison_results',
                                'shadow_runs', 'shadow_comparisons', 'training_configs', 'training_runs', 'training_results', 'training_artifacts']) LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('soulbah.' || r)::regclass) THEN RAISE EXCEPTION 'RLS absente sur %', r; END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit soulbah.%', r;
    END IF;
  END LOOP;
END $$;
