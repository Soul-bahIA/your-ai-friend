-- =============================================================================
-- Assertions de schéma après application des migrations (job CI `db`, PG jetable).
-- Exécuté par scripts/ci/apply_migrations.sh --checks, en SUPERUTILISATEUR, sur une
-- base créée avec scripts/ci/auth_stub.sql. Tout est fait dans UNE transaction
-- annulée à la fin (ROLLBACK) : la base n'est pas modifiée.
-- Chaque échec lève une exception → psql (ON_ERROR_STOP) sort en erreur.
-- =============================================================================
\set ON_ERROR_STOP 1
BEGIN;

-- --- Règles « Jamais » de l'audit (§12) ---------------------------------------------
DO $$
BEGIN
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conname = 'agent_tasks_status_check'
         AND conrelid = 'public.agent_tasks'::regclass)
     IS DISTINCT FROM
     'CHECK ((status = ANY (ARRAY[''pending''::text, ''in_progress''::text, ''completed''::text, ''failed''::text, ''cancelled''::text])))'
  THEN
    RAISE EXCEPTION 'Jamais : le CHECK de statut d''agent_tasks a changé';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_constraint c
               JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
              WHERE c.conrelid = 'public.agent_events'::regclass
                AND c.contype = 'f' AND a.attname = 'task_id') THEN
    RAISE EXCEPTION 'Jamais : FK sur agent_events.task_id';
  END IF;

  IF to_regclass('public.modules_status') IS NULL THEN
    RAISE EXCEPTION 'Jamais : modules_status a été supprimée';
  END IF;
  IF coalesce(obj_description('public.modules_status'::regclass, 'pg_class'), '') NOT LIKE 'DÉPRÉCIÉ%' THEN
    RAISE EXCEPTION 'T48 : modules_status n''est pas marquée DÉPRÉCIÉ';
  END IF;
END $$;

-- --- Index (T46) et pgvector (uniquement si l'extension est réellement présente) ----
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                  WHERE schemaname = 'public' AND indexname = 'idx_agent_tasks_poll'
                    AND indexdef LIKE '%(user_id, priority, created_at) WHERE (status = ''pending''::text)') THEN
    RAISE EXCEPTION 'T46 : index partiel de poll absent ou différent';
  END IF;
  IF to_regclass('public.idx_agent_tasks_target_key') IS NULL
     OR to_regclass('public.idx_agent_tasks_claimed_key') IS NULL THEN
    RAISE EXCEPTION 'Index des FK target/claimed absents';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
    IF format_type((SELECT atttypid FROM pg_attribute
                     WHERE attrelid = 'public.knowledge_base'::regclass AND attname = 'embedding'),
                   (SELECT atttypmod FROM pg_attribute
                     WHERE attrelid = 'public.knowledge_base'::regclass AND attname = 'embedding'))
       <> 'vector(1536)' THEN
      RAISE EXCEPTION 'pgvector : knowledge_base.embedding n''est pas vector(1536)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_indexes
                    WHERE indexname = 'idx_knowledge_base_embedding' AND indexdef LIKE '%USING hnsw%') THEN
      RAISE EXCEPTION 'pgvector : index HNSW absent';
    END IF;
    RAISE NOTICE 'pgvector présent : colonne et index HNSW vérifiés';
  ELSE
    RAISE NOTICE 'pgvector absent (stub) : vérifications vectorielles sautées';
  END IF;
END $$;

-- --- Jeu de données ------------------------------------------------------------------
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-4000-8000-0000000000a1', 'u1@test.invalid'),
  ('00000000-0000-4000-8000-0000000000a2', 'u2@test.invalid');
INSERT INTO public.agent_keys (id, user_id, key_hash, label) VALUES
  ('00000000-0000-4000-8000-0000000000b1', '00000000-0000-4000-8000-0000000000a1', 'hash-k1', 'pc1'),
  ('00000000-0000-4000-8000-0000000000b2', '00000000-0000-4000-8000-0000000000a1', 'hash-k2', 'pc2'),
  ('00000000-0000-4000-8000-0000000000b3', '00000000-0000-4000-8000-0000000000a2', 'hash-k3', 'pc-u2');
INSERT INTO public.agent_tasks (id, user_id, task_type, target_agent_key_id, claimed_by_key_id) VALUES
  ('00000000-0000-4000-8000-0000000000c1', '00000000-0000-4000-8000-0000000000a1', 'goal',
   '00000000-0000-4000-8000-0000000000b1', '00000000-0000-4000-8000-0000000000b1');
INSERT INTO public.chat_conversations (id, user_id) VALUES
  ('00000000-0000-4000-8000-0000000000d1', '00000000-0000-4000-8000-0000000000a1'),
  ('00000000-0000-4000-8000-0000000000d2', '00000000-0000-4000-8000-0000000000a2');
INSERT INTO public.knowledge_base (id, user_id, title, content) VALUES
  ('00000000-0000-4000-8000-0000000000e1', '00000000-0000-4000-8000-0000000000a1', 't1', 'c1'),
  ('00000000-0000-4000-8000-0000000000e2', '00000000-0000-4000-8000-0000000000a2', 't2', 'c2');
INSERT INTO public.user_schemas (id, user_id, table_name) VALUES
  ('00000000-0000-4000-8000-0000000000f1', '00000000-0000-4000-8000-0000000000a1', 'mine'),
  ('00000000-0000-4000-8000-0000000000f2', '00000000-0000-4000-8000-0000000000a2', 'theirs');

-- --- FK agent_tasks → agent_keys ON DELETE SET NULL (contrat §7) --------------------
DELETE FROM public.agent_keys WHERE id = '00000000-0000-4000-8000-0000000000b1';
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.agent_tasks
              WHERE id = '00000000-0000-4000-8000-0000000000c1'
                AND (target_agent_key_id IS NOT NULL OR claimed_by_key_id IS NOT NULL)) THEN
    RAISE EXCEPTION 'FK : la suppression de la clé n''a pas mis target/claimed à NULL';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.agent_tasks WHERE id = '00000000-0000-4000-8000-0000000000c1') THEN
    RAISE EXCEPTION 'FK : la suppression de la clé a supprimé la tâche';
  END IF;
  BEGIN
    INSERT INTO public.agent_tasks (user_id, task_type, target_agent_key_id)
    VALUES ('00000000-0000-4000-8000-0000000000a1', 'goal', gen_random_uuid());
    RAISE EXCEPTION 'FK : target_agent_key_id accepte une clé inexistante';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
END $$;

-- --- Trigger updated_at (T45) ------------------------------------------------------
-- Remet updated_at à une date fixe sans déclencher les triggers (superutilisateur).
CREATE FUNCTION pg_temp.reset_updated_at(t uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  UPDATE public.agent_tasks SET updated_at = '2000-01-01 00:00:00+00' WHERE id = t;
  PERFORM set_config('session_replication_role', 'origin', true);
END $$;

DO $$
DECLARE
  t     uuid := '00000000-0000-4000-8000-0000000000c1';
  epoch timestamptz := '2000-01-01 00:00:00+00';
  ts    timestamptz;
BEGIN
  PERFORM pg_temp.reset_updated_at(t);
  -- Requête réelle de POST /api/agent-tasks/:id/control
  UPDATE public.agent_tasks SET control = 'pause', updated_at = now() WHERE id = t;
  SELECT updated_at INTO ts FROM public.agent_tasks WHERE id = t;
  IF ts <> epoch THEN RAISE EXCEPTION 'T45 : changer control a prolongé le bail'; END IF;

  UPDATE public.agent_tasks SET control = 'pause', updated_at = now() WHERE id = t;
  SELECT updated_at INTO ts FROM public.agent_tasks WHERE id = t;
  IF ts <> epoch THEN RAISE EXCEPTION 'T45 : renvoyer la même valeur de control a prolongé le bail'; END IF;

  UPDATE public.agent_tasks SET control = 'pause' WHERE id = t;
  SELECT updated_at INTO ts FROM public.agent_tasks WHERE id = t;
  IF ts <> epoch THEN RAISE EXCEPTION 'T45 : control identique (sans updated_at) a prolongé le bail'; END IF;

  -- Heartbeat (lib/agentTaskSql.ts buildTaskTouch) : doit TOUJOURS rafraîchir.
  UPDATE public.agent_tasks SET updated_at = now() WHERE id = t;
  SELECT updated_at INTO ts FROM public.agent_tasks WHERE id = t;
  IF ts = epoch THEN RAISE EXCEPTION 'Régression : le heartbeat ne rafraîchit plus updated_at'; END IF;

  PERFORM pg_temp.reset_updated_at(t);
  UPDATE public.agent_tasks SET status = 'in_progress', updated_at = now() WHERE id = t;
  SELECT updated_at INTO ts FROM public.agent_tasks WHERE id = t;
  IF ts = epoch THEN RAISE EXCEPTION 'Régression : un changement de statut ne rafraîchit plus updated_at'; END IF;

  PERFORM pg_temp.reset_updated_at(t);
  UPDATE public.agent_tasks SET status = 'cancelled', control = 'stop' WHERE id = t;
  SELECT updated_at INTO ts FROM public.agent_tasks WHERE id = t;
  IF ts = epoch THEN RAISE EXCEPTION 'Régression : statut + control ne rafraîchit plus updated_at'; END IF;

  PERFORM pg_temp.reset_updated_at(t);
  UPDATE public.agent_tasks SET claimed_by_key_id = '00000000-0000-4000-8000-0000000000b2' WHERE id = t;
  SELECT updated_at INTO ts FROM public.agent_tasks WHERE id = t;
  IF ts = epoch THEN RAISE EXCEPTION 'Régression : écrire claimed_by_key_id ne rafraîchit pas updated_at'; END IF;
END $$;

-- --- agent_memory : CHECK status / level ----------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO public.agent_memory (user_id, type, goal, content, status)
    VALUES ('00000000-0000-4000-8000-0000000000a1', 'error', 'g', 'c', 'bogus');
    RAISE EXCEPTION 'agent_memory : status invalide accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.agent_memory (user_id, type, goal, content, level)
    VALUES ('00000000-0000-4000-8000-0000000000a1', 'error', 'g', 'c', 'bogus');
    RAISE EXCEPTION 'agent_memory : level invalide accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO public.agent_memory (user_id, type, goal, content, level, status)
  VALUES ('00000000-0000-4000-8000-0000000000a1', 'practice', '(général)', 'c', 'optimization', 'proposed');
END $$;

-- --- RLS côté client : utilisateur u1 (rôle authenticated) --------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a1"}';

DO $$
DECLARE n int;
BEGIN
  -- agent_keys : lecture de ses clés uniquement (k2 ; k1 supprimée, k3 à u2)
  SELECT count(*) INTO n FROM public.agent_keys;
  IF n <> 1 THEN RAISE EXCEPTION 'S20 : agent_keys visibles = % (attendu 1)', n; END IF;

  BEGIN
    INSERT INTO public.agent_keys (user_id, key_hash) VALUES (auth.uid(), 'hash-client');
    RAISE EXCEPTION 'S20 : le client peut encore créer une clé agent';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  UPDATE public.agent_keys SET label = 'modifié' WHERE user_id = auth.uid();
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 0 THEN RAISE EXCEPTION 'S20 : le client peut encore modifier une clé agent'; END IF;

  -- INSERT inter-locataires refusés
  BEGIN
    INSERT INTO public.chat_messages (conversation_id, user_id, role, content)
    VALUES ('00000000-0000-4000-8000-0000000000d2', auth.uid(), 'user', 'intrus');
    RAISE EXCEPTION 'S20 : message inséré dans la conversation d''un autre utilisateur';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  INSERT INTO public.chat_messages (conversation_id, user_id, role, content)
  VALUES ('00000000-0000-4000-8000-0000000000d1', auth.uid(), 'user', 'ok');

  BEGIN
    INSERT INTO public.knowledge_versions (entry_id, user_id, version, snapshot)
    VALUES ('00000000-0000-4000-8000-0000000000e2', auth.uid(), 1, '{}');
    RAISE EXCEPTION 'S20 : version créée sur l''entrée de connaissance d''un autre utilisateur';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  INSERT INTO public.knowledge_versions (entry_id, user_id, version, snapshot)
  VALUES ('00000000-0000-4000-8000-0000000000e1', auth.uid(), 1, '{}');

  BEGIN
    INSERT INTO public.user_table_data (user_id, schema_id, row_data)
    VALUES (auth.uid(), '00000000-0000-4000-8000-0000000000f2', '{}');
    RAISE EXCEPTION 'S20 : ligne insérée dans le schéma d''un autre utilisateur';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO public.user_migrations (user_id, schema_id, migration_type)
    VALUES (auth.uid(), '00000000-0000-4000-8000-0000000000f2', 'x');
    RAISE EXCEPTION 'S20 : migration insérée sur le schéma d''un autre utilisateur';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  INSERT INTO public.user_table_data (user_id, schema_id, row_data)
  VALUES (auth.uid(), '00000000-0000-4000-8000-0000000000f1', '{}');

  -- has_role reste appelable par authenticated (policy, vague G4 non faite) ; is_admin()
  PERFORM public.has_role(auth.uid(), 'admin');
  IF public.is_admin() THEN RAISE EXCEPTION 'is_admin() vrai pour un non-admin'; END IF;

  -- Révocation : suppression de sa propre clé autorisée
  DELETE FROM public.agent_keys WHERE id = '00000000-0000-4000-8000-0000000000b2';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'S20 : le client ne peut plus supprimer sa clé'; END IF;
END $$;
RESET ROLE;

-- --- anon : plus d'accès à has_role / is_admin (S19) ----------------------------------
SET LOCAL ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM public.has_role('00000000-0000-4000-8000-0000000000a1', 'admin');
    RAISE EXCEPTION 'S19 : anon peut encore appeler has_role';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.is_admin();
    RAISE EXCEPTION 'S19 : anon peut appeler is_admin';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;

-- --- is_admin() vrai pour un admin ; la policy user_roles l'utilise ------------------
INSERT INTO public.user_roles (user_id, role) VALUES ('00000000-0000-4000-8000-0000000000a1', 'admin');
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000000a1"}';
DO $$
DECLARE n int;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'is_admin() faux pour un admin'; END IF;
  -- Admin : voit aussi les rôles des autres (policy « Admins can manage roles »)
  SELECT count(*) INTO n FROM public.user_roles
   WHERE user_id = '00000000-0000-4000-8000-0000000000a2';
  IF n <> 1 THEN RAISE EXCEPTION 'Policy admin user_roles cassée (% ligne(s) vues)', n; END IF;
END $$;
RESET ROLE;

\echo 'schema_checks : toutes les assertions sont passées'
ROLLBACK;
