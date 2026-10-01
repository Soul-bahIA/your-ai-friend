-- =============================================================================
-- Durcissement du schéma (sécurité, intégrité, performances).
-- Migration IDEMPOTENTE : peut être rejouée sans erreur (IF [NOT] EXISTS, blocs DO).
--
--  1. agent_tasks : plus de création/modification directe via PostgREST (RLS) —
--     les tâches passent exclusivement par l'API Node (connexion privilégiée).
--  2. CHECK sur agent_tasks.status / agent_tasks.control.
--  3. Clés étrangères user_id → auth.users(id) ON DELETE CASCADE.
--     Ajoutées NOT VALID (ne bloquent pas sur d'éventuelles lignes orphelines
--     existantes), puis validation tentée : un échec est seulement signalé (NOTICE).
--  4. Index manquants (user_id, schema_id, file d'attente de l'agent…).
--  5. Nettoyage d'index (nom trompeur, doublon de contrainte UNIQUE).
--  6. Table analysis_requests (route backend /api/analyze), avec RLS propriétaire.
--  7. Trigger updated_at d'agent_tasks : un changement de `control` seul (pause/stop)
--     ne compte plus comme un « signe de vie » de l'agent.
--  8. profiles : lecture limitée à son propre profil.
-- =============================================================================


-- 1) agent_tasks : RLS ------------------------------------------------------------
-- L'app web lit (SELECT/Realtime) et supprime ses tâches ; elle ne les crée ni ne
-- les modifie directement (création : POST /api/agent-tasks, contrôle :
-- POST /api/agent-tasks/:id/control). Laisser INSERT/UPDATE ouverts permettait
-- d'injecter un payload arbitraire exécuté par l'agent local en contournant l'API.
DROP POLICY IF EXISTS "Users can create tasks" ON public.agent_tasks;
DROP POLICY IF EXISTS "Users can update own tasks" ON public.agent_tasks;


-- 2) CHECK constraints -----------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'agent_tasks_status_check'
                   AND conrelid = 'public.agent_tasks'::regclass) THEN
    ALTER TABLE public.agent_tasks
      ADD CONSTRAINT agent_tasks_status_check
      CHECK (status IN ('pending', 'in_progress', 'completed', 'failed', 'cancelled')) NOT VALID;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'agent_tasks_control_check'
                   AND conrelid = 'public.agent_tasks'::regclass) THEN
    ALTER TABLE public.agent_tasks
      ADD CONSTRAINT agent_tasks_control_check
      CHECK (control IN ('none', 'pause', 'stop')) NOT VALID;
  END IF;
END $$;

DO $$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY ARRAY['agent_tasks_status_check', 'agent_tasks_control_check'] LOOP
    BEGIN
      EXECUTE format('ALTER TABLE public.agent_tasks VALIDATE CONSTRAINT %I', c);
    EXCEPTION WHEN check_violation THEN
      RAISE NOTICE 'Contrainte % non validée : des lignes existantes la violent', c;
    END;
  END LOOP;
END $$;


-- 3) Clés étrangères ---------------------------------------------------------------
DO $$
DECLARE
  t       text;
  attnum  smallint;
  cname   text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'agent_tasks', 'chat_conversations', 'chat_messages', 'knowledge_base',
    'user_schemas', 'user_table_data', 'user_migrations', 'knowledge_versions',
    'agent_events'
  ] LOOP
    IF to_regclass('public.' || t) IS NULL THEN
      CONTINUE;
    END IF;

    SELECT a.attnum INTO attnum
      FROM pg_attribute a
     WHERE a.attrelid = ('public.' || t)::regclass
       AND a.attname = 'user_id' AND NOT a.attisdropped;
    IF attnum IS NULL THEN
      CONTINUE;
    END IF;

    -- Déjà une FK sur user_id vers auth.users ?
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE contype = 'f'
                  AND conrelid = ('public.' || t)::regclass
                  AND confrelid = 'auth.users'::regclass
                  AND conkey = ARRAY[attnum]) THEN
      CONTINUE;
    END IF;

    cname := t || '_user_id_fkey';
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = cname AND conrelid = ('public.' || t)::regclass) THEN
      CONTINUE;
    END IF;

    EXECUTE format(
      'ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (user_id) '
      'REFERENCES auth.users(id) ON DELETE CASCADE NOT VALID', t, cname);

    BEGIN
      EXECUTE format('ALTER TABLE public.%I VALIDATE CONSTRAINT %I', t, cname);
    EXCEPTION WHEN foreign_key_violation THEN
      RAISE NOTICE 'FK % non validée : lignes orphelines dans public.%', cname, t;
    END;
  END LOOP;

  -- Pas de FK agent_events.task_id → agent_tasks(id) : la progression des
  -- formations écrit aussi des évènements avec task_id = id de la formation.
  -- Les évènements orphelins sont purgés par la maintenance du backend Node.
END $$;


-- 4) Index manquants --------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_formations_user          ON public.formations (user_id);
CREATE INDEX IF NOT EXISTS idx_applications_user        ON public.applications (user_id);
CREATE INDEX IF NOT EXISTS idx_chat_conversations_user  ON public.chat_conversations (user_id);
CREATE INDEX IF NOT EXISTS idx_knowledge_base_user      ON public.knowledge_base (user_id);
CREATE INDEX IF NOT EXISTS idx_system_logs_user_created ON public.system_logs (user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_user_table_data_schema   ON public.user_table_data (schema_id);
CREATE INDEX IF NOT EXISTS idx_user_migrations_schema   ON public.user_migrations (schema_id);
-- File de l'agent (poll / requeue des tâches périmées) : remplace (user_id, status).
CREATE INDEX IF NOT EXISTS idx_agent_tasks_user_status_updated
  ON public.agent_tasks (user_id, status, updated_at);
DROP INDEX IF EXISTS public.idx_agent_tasks_user_status;
-- agent_events(task_id, created_at) : déjà couvert par idx_agent_events_task.
CREATE INDEX IF NOT EXISTS idx_agent_events_task ON public.agent_events (task_id, created_at);


-- 5) Nettoyage d'index ------------------------------------------------------------
-- idx_agent_memory_goal_trgm est un simple B-tree (user_id, goal), pas un index trigramme.
ALTER INDEX IF EXISTS public.idx_agent_memory_goal_trgm RENAME TO idx_agent_memory_user_goal;

-- idx_agent_keys_hash double l'index créé par la contrainte UNIQUE (key_hash).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
     WHERE c.conrelid = 'public.agent_keys'::regclass
       AND c.contype = 'u'
       AND array_length(c.conkey, 1) = 1
       AND a.attname = 'key_hash'
  ) THEN
    DROP INDEX IF EXISTS public.idx_agent_keys_hash;
  END IF;
END $$;


-- 6) analysis_requests (backend POST /api/analyze) ---------------------------------
CREATE TABLE IF NOT EXISTS public.analysis_requests (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  input_text  TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'pending',   -- pending | processing | done | error
  result      JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Si la table existait déjà (schéma backend/postgres/init.sql), on ajoute user_id.
ALTER TABLE public.analysis_requests
  ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'analysis_requests_status_check'
                   AND conrelid = 'public.analysis_requests'::regclass) THEN
    ALTER TABLE public.analysis_requests
      ADD CONSTRAINT analysis_requests_status_check
      CHECK (status IN ('pending', 'processing', 'done', 'error')) NOT VALID;
  END IF;
  BEGIN
    ALTER TABLE public.analysis_requests VALIDATE CONSTRAINT analysis_requests_status_check;
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'Contrainte analysis_requests_status_check non validée';
  END;
END $$;

CREATE INDEX IF NOT EXISTS idx_analysis_requests_user       ON public.analysis_requests (user_id);
CREATE INDEX IF NOT EXISTS idx_analysis_requests_status     ON public.analysis_requests (status);
CREATE INDEX IF NOT EXISTS idx_analysis_requests_created_at ON public.analysis_requests (created_at DESC);

ALTER TABLE public.analysis_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users view own analysis requests"   ON public.analysis_requests;
DROP POLICY IF EXISTS "Users create own analysis requests" ON public.analysis_requests;
DROP POLICY IF EXISTS "Users update own analysis requests" ON public.analysis_requests;
DROP POLICY IF EXISTS "Users delete own analysis requests" ON public.analysis_requests;

CREATE POLICY "Users view own analysis requests" ON public.analysis_requests
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users create own analysis requests" ON public.analysis_requests
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users update own analysis requests" ON public.analysis_requests
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users delete own analysis requests" ON public.analysis_requests
  FOR DELETE TO authenticated USING (auth.uid() = user_id);


-- 7) Trigger updated_at d'agent_tasks ---------------------------------------------
-- updated_at sert de heartbeat (requeue des tâches in_progress périmées). Un ordre
-- pause/stop posé par l'utilisateur ne doit pas faire croire que l'agent est vivant :
--   - une autre colonne que control/updated_at change  → updated_at = now()
--   - seul control change (même si updated_at est fixé)  → updated_at conservé
--   - rien d'autre ne change (heartbeat « touch »)       → updated_at = now()
CREATE OR REPLACE FUNCTION public.agent_tasks_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF (to_jsonb(NEW) - 'control' - 'updated_at') IS DISTINCT FROM
     (to_jsonb(OLD) - 'control' - 'updated_at') THEN
    NEW.updated_at := now();
  ELSIF NEW.control IS DISTINCT FROM OLD.control THEN
    NEW.updated_at := OLD.updated_at;
  ELSE
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS update_agent_tasks_updated_at ON public.agent_tasks;
CREATE TRIGGER update_agent_tasks_updated_at
  BEFORE UPDATE ON public.agent_tasks
  FOR EACH ROW EXECUTE FUNCTION public.agent_tasks_set_updated_at();


-- 8) profiles : lecture de son propre profil uniquement ----------------------------
-- Le frontend ne lit que le profil de l'utilisateur connecté (src/pages/Settings.tsx).
DROP POLICY IF EXISTS "Users can view all profiles" ON public.profiles;
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
CREATE POLICY "Users can view own profile" ON public.profiles
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
