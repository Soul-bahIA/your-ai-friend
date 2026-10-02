-- =============================================================================
-- Rôle de moindre privilège soulbah_api (S4, T54) : les droits de
-- scripts/sql/soulbah_api_grants.sql suffisent aux requêtes RÉELLES de node-api.
-- Exécuté par scripts/ci/apply_migrations.sh --checks, en SUPERUTILISATEUR, après les
-- migrations. La ligne marqueur (commentaire SOULBAH_API_GRANTS seul sur sa ligne, plus
-- bas) est remplacée par le contenu du fichier de droits. Tout est annulé à la fin (ROLLBACK) : rôle compris.
-- Chaque échec lève une exception → psql (ON_ERROR_STOP) sort en erreur.
-- =============================================================================
\set ON_ERROR_STOP 1
BEGIN;

-- Rôle de test : mêmes attributs que SUPABASE_REPRISE §10, sans mot de passe ni LOGIN.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'soulbah_api') THEN
    CREATE ROLE soulbah_api NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
      NOINHERIT BYPASSRLS;
  END IF;
  -- Hors superutilisateur (Supabase : postgres a CREATEROLE sans SET automatique, PG16+), SET ROLE exige
  -- l'appartenance avec l'option SET ; sans effet en CI (superutilisateur). Annulé avec la transaction.
  IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
    EXECUTE format('GRANT soulbah_api TO %I WITH SET TRUE, INHERIT FALSE', current_user);
  END IF;
END $$;

-- @@SOULBAH_API_GRANTS@@

-- --- Jeu de données (superutilisateur) ----------------------------------------------
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-4000-8000-00000000a0a1', 'api@test.invalid');
INSERT INTO public.agent_tasks (id, user_id, task_type, status) VALUES
  ('00000000-0000-4000-8000-00000000a0c1', '00000000-0000-4000-8000-00000000a0a1', 'goal', 'completed'),
  ('00000000-0000-4000-8000-00000000a0c2', '00000000-0000-4000-8000-00000000a0a1', 'goal', 'in_progress');
INSERT INTO public.agent_events (task_id, user_id, type, message, data) VALUES
  ('00000000-0000-4000-8000-00000000a0c1', '00000000-0000-4000-8000-00000000a0a1', 'screenshot', 'capture',
   '{"image_b64": "iVBORw0KGgo="}'::jsonb);

SET LOCAL ROLE soulbah_api;

DO $$
DECLARE
  n   int;
  uid uuid := '00000000-0000-4000-8000-00000000a0a1';
BEGIN
  -- DELETE /api/agent-tasks/:id (routes/agentTasks.ts) : tâches terminales uniquement.
  DELETE FROM agent_tasks
   WHERE id = '00000000-0000-4000-8000-00000000a0c1' AND user_id = uid
     AND status IN ('completed', 'failed', 'cancelled');
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'soulbah_api : DELETE d''une tâche terminale = % ligne(s)', n; END IF;

  -- Maintenance horaire (services/maintenance.ts) : retrait des captures des événements.
  UPDATE agent_events SET data = (data - 'image_b64') || '{"has_image": true}'::jsonb
   WHERE data ? 'image_b64';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'soulbah_api : UPDATE agent_events = % ligne(s)', n; END IF;
  DELETE FROM agent_events WHERE created_at < now() - interval '3 days';

  -- Création de domaine (services/knowledge/supabaseStore.ts) : ON CONFLICT DO UPDATE.
  INSERT INTO knowledge_domains (slug, label, is_system) VALUES ('ci-domaine', 'CI', false)
    ON CONFLICT (slug) DO UPDATE SET label = EXCLUDED.label;
  INSERT INTO knowledge_domains (slug, label, is_system) VALUES ('ci-domaine', 'CI bis', false)
    ON CONFLICT (slug) DO UPDATE SET label = EXCLUDED.label;

  -- Heartbeat, claim, reaper (lib/agentTaskSql.ts) : UPDATE d'agent_tasks.
  UPDATE agent_tasks SET updated_at = now()
   WHERE id = '00000000-0000-4000-8000-00000000a0c2' AND user_id = uid;

  -- Mémoire, clés, journal, connaissances, base dynamique, générations.
  INSERT INTO agent_memory (user_id, type, goal, content, status)
  VALUES (uid, 'practice', '(général)', 'c', 'proposed');
  -- PATCH /api/agent-memory/:id (routes/agentMemory.ts) : la validation pose metadata.validated_by
  -- dans la même instruction (exigé par agent_memory_validated_requires_proof, LOT 4).
  UPDATE agent_memory SET status = 'validated',
         metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('validated_by', uid::text, 'validated_at', now())
   WHERE user_id = uid;
  DELETE FROM agent_memory WHERE user_id = uid;
  INSERT INTO agent_keys (user_id, key_hash, label) VALUES (uid, 'ci-hash', 'pc');
  UPDATE agent_keys SET last_used_at = now() WHERE user_id = uid;
  DELETE FROM agent_keys WHERE user_id = uid;
  INSERT INTO system_logs (user_id, module, event, level) VALUES (uid, 'CI', 'test', 'info');
  INSERT INTO knowledge_base (id, user_id, title, content)
  VALUES ('00000000-0000-4000-8000-00000000a0e1', uid, 't', 'c');
  INSERT INTO knowledge_versions (entry_id, user_id, version, snapshot)
  VALUES ('00000000-0000-4000-8000-00000000a0e1', uid, 1, '{}');
  UPDATE knowledge_base SET content = 'c2' WHERE id = '00000000-0000-4000-8000-00000000a0e1';
  DELETE FROM knowledge_base WHERE id = '00000000-0000-4000-8000-00000000a0e1';
  INSERT INTO formations (user_id, title) VALUES (uid, 'f');
  UPDATE formations SET status = 'Erreur' WHERE user_id = uid;
  INSERT INTO applications (user_id, title) VALUES (uid, 'a');
  UPDATE applications SET status = 'Erreur' WHERE user_id = uid;

  -- Admin applicatif (routes/knowledge.ts).
  PERFORM public.has_role(uid, 'admin');

  -- Contrôle de démarrage (server.ts) : colonnes LOT 1 visibles dans information_schema.
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'agent_tasks'
     AND column_name IN ('target_agent_key_id', 'claimed_by_key_id');
  IF n <> 2 THEN RAISE EXCEPTION 'soulbah_api : colonnes LOT 1 d''agent_tasks invisibles (%)', n; END IF;

  -- Ce que le rôle ne doit PAS pouvoir faire (SUPABASE_REPRISE §10).
  BEGIN
    PERFORM 1 FROM public.profiles LIMIT 1;
    RAISE EXCEPTION 'soulbah_api lit profiles';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM public.user_roles LIMIT 1;
    RAISE EXCEPTION 'soulbah_api lit user_roles';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM auth.users LIMIT 1;
    RAISE EXCEPTION 'soulbah_api lit auth.users';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    DELETE FROM public.system_logs;
    RAISE EXCEPTION 'soulbah_api supprime system_logs';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    EXECUTE 'CREATE TABLE public.ci_ddl_interdit (id int)';
    RAISE EXCEPTION 'soulbah_api exécute du DDL';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- V2 (LOT 4) : seul écrivain du schéma soulbah ; audit en ajout seul même pour lui.
  INSERT INTO soulbah.sessions (id, user_id, goal) VALUES ('00000000-0000-4000-8000-00000000a0f1', uid, 'session api');
  INSERT INTO soulbah.tasks (id, session_id, user_id, title, role)
    VALUES ('00000000-0000-4000-8000-00000000a0e1', '00000000-0000-4000-8000-00000000a0f1', uid, 'T', 'coder');
  UPDATE soulbah.tasks SET status = 'READY' WHERE id = '00000000-0000-4000-8000-00000000a0e1';
  INSERT INTO soulbah.audit_logs (user_id, actor, action, entity, entity_id, data)
    VALUES (uid, 'system:scheduler', 'task.transition', 'task', '00000000-0000-4000-8000-00000000a0e1', '{"to":"READY"}');
  IF (SELECT ok FROM soulbah.verify_audit_chain()) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'soulbah_api : chaîne d''audit invalide après insertion';
  END IF;
  BEGIN
    UPDATE soulbah.audit_logs SET data = '{}' WHERE actor = 'system:scheduler';
    RAISE EXCEPTION 'soulbah_api modifie audit_logs';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    DELETE FROM soulbah.audit_logs WHERE actor = 'system:scheduler';
    RAISE EXCEPTION 'soulbah_api supprime audit_logs';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM 1 FROM soulbah.memories LIMIT 1;
  PERFORM 1 FROM soulbah.knowledge_documents LIMIT 1;
END $$;
RESET ROLE;

\echo 'api_role_checks : soulbah_api couvre les requêtes de node-api'
ROLLBACK;
