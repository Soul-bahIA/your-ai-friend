-- =============================================================================
-- LOT 1 — Corrections de schéma issues de l'audit LOT 0 (docs/SOULBAH_V2_LOT0_AUDIT.md)
-- Migration ADDITIVE et IDEMPOTENTE (style de 20261001000000_hardening.sql) :
-- IF [NOT] EXISTS, DROP POLICY IF EXISTS puis CREATE, contraintes NOT VALID puis
-- VALIDATE dans un bloc d'exception. Aucune donnée supprimée ni modifiée.
--
--  1. agent_tasks : ciblage d'un PC (contrat LOT 1 §7, T16) — colonnes nullables
--     target_agent_key_id / claimed_by_key_id → agent_keys(id) ON DELETE SET NULL,
--     index partiel de poll (T46) et index des deux FK.
--  2. Trigger updated_at d'agent_tasks (T45) : poser `control` (même valeur ou non)
--     ne prolonge plus le bail ; le heartbeat (UPDATE … SET updated_at = now()) oui.
--  3. has_role (S19) : plus exécutable par anon ; nouvelle fonction is_admin().
--  4. Policies (S20) : agent_keys en lecture + suppression seulement côté client ;
--     les INSERT vérifient la propriété de la ligne parente (chat_messages,
--     knowledge_versions, user_table_data, user_migrations).
--  5. modules_status marquée DÉPRÉCIÉE (T48) — jamais supprimée.
--  6. agent_memory : CHECK sur status et level (S11).
--
-- Règles « Jamais » de l'audit (§12) respectées : le CHECK de statut d'agent_tasks
-- n'est pas touché, aucune FK sur agent_events.task_id, rien n'est renommé ni supprimé.
-- =============================================================================


-- 1) agent_tasks : ciblage d'un PC + index de poll -------------------------------
-- target_agent_key_id : PC (clé agent) visé par la tâche ; NULL = n'importe lequel des
--                       agents de l'utilisateur.
-- claimed_by_key_id   : clé agent qui a réclamé la tâche (écrit par le claim).
-- Révoquer/supprimer une clé ne supprime pas l'historique : la référence passe à NULL.
ALTER TABLE public.agent_tasks
  ADD COLUMN IF NOT EXISTS target_agent_key_id uuid,
  ADD COLUMN IF NOT EXISTS claimed_by_key_id   uuid;

COMMENT ON COLUMN public.agent_tasks.target_agent_key_id IS
  'Clé agent (PC) ciblée ; NULL = tout agent de l''utilisateur. Le poll ne renvoie que target IS NULL OR = clé appelante.';
COMMENT ON COLUMN public.agent_tasks.claimed_by_key_id IS
  'Clé agent ayant réclamé la tâche (écrit par le claim). NULL si jamais réclamée ou clé supprimée.';

DO $$
DECLARE
  col   text;
  cname text;
BEGIN
  FOREACH col IN ARRAY ARRAY['target_agent_key_id', 'claimed_by_key_id'] LOOP
    cname := 'agent_tasks_' || col || '_fkey';
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = cname
                      AND conrelid = 'public.agent_tasks'::regclass) THEN
      EXECUTE format(
        'ALTER TABLE public.agent_tasks ADD CONSTRAINT %I FOREIGN KEY (%I) '
        'REFERENCES public.agent_keys(id) ON DELETE SET NULL NOT VALID', cname, col);
    END IF;

    BEGIN
      EXECUTE format('ALTER TABLE public.agent_tasks VALIDATE CONSTRAINT %I', cname);
    EXCEPTION WHEN foreign_key_violation THEN
      RAISE NOTICE 'FK % non validée : public.agent_tasks.% référence des clés inexistantes', cname, col;
    END;
  END LOOP;
END $$;

-- Poll de l'agent (T46) : WHERE user_id = $1 AND status = 'pending'
--                         ORDER BY priority, created_at LIMIT 5
CREATE INDEX IF NOT EXISTS idx_agent_tasks_poll
  ON public.agent_tasks (user_id, priority, created_at)
  WHERE status = 'pending';
-- FK : filtre du poll par clé + ON DELETE SET NULL sans parcours complet de la table.
CREATE INDEX IF NOT EXISTS idx_agent_tasks_target_key
  ON public.agent_tasks (target_agent_key_id)
  WHERE target_agent_key_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_agent_tasks_claimed_key
  ON public.agent_tasks (claimed_by_key_id)
  WHERE claimed_by_key_id IS NOT NULL;


-- 2) Trigger updated_at d'agent_tasks (T45) -----------------------------------------
-- updated_at sert de bail / signe de vie (remise en file des tâches in_progress muettes).
-- Avant : POST /api/agent-tasks/:id/control exécute
--   UPDATE agent_tasks SET control = $1, updated_at = now() …
-- et, quand la valeur de control ne change pas, la ligne est identique à part
-- updated_at : le trigger y voyait un heartbeat et prolongeait le bail.
-- Le heartbeat (UPDATE agent_tasks SET updated_at = now() …) et un envoi répété de
-- control produisent la même ligne : seule la LISTE SET les distingue. D'où deux triggers :
--
--   a) update_agent_tasks_updated_at (toute UPDATE) — inchangé sur le fond :
--        - une colonne autre que control/updated_at change  → updated_at = now()
--        - seul control change                               → updated_at conservé
--        - rien ne change (heartbeat « touch »)              → updated_at = now()
--   b) update_agent_tasks_updated_at_control (UPDATE OF control : `control` figure
--      dans la liste SET, que sa valeur change ou non) :
--        - aucune colonne autre que control/updated_at ne change → updated_at conservé
--
-- (b) DOIT s'exécuter APRÈS (a) : PostgreSQL déclenche les triggers BEFORE d'un même
-- évènement par ordre alphabétique de nom ('…_updated_at' < '…_updated_at_control').
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

CREATE OR REPLACE FUNCTION public.agent_tasks_keep_updated_at_on_control()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF (to_jsonb(NEW) - 'control' - 'updated_at') IS NOT DISTINCT FROM
     (to_jsonb(OLD) - 'control' - 'updated_at') THEN
    NEW.updated_at := OLD.updated_at;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS update_agent_tasks_updated_at ON public.agent_tasks;
CREATE TRIGGER update_agent_tasks_updated_at
  BEFORE UPDATE ON public.agent_tasks
  FOR EACH ROW EXECUTE FUNCTION public.agent_tasks_set_updated_at();

DROP TRIGGER IF EXISTS update_agent_tasks_updated_at_control ON public.agent_tasks;
CREATE TRIGGER update_agent_tasks_updated_at_control
  BEFORE UPDATE OF control ON public.agent_tasks
  FOR EACH ROW EXECUTE FUNCTION public.agent_tasks_keep_updated_at_on_control();


-- 3) has_role / is_admin (S19) ------------------------------------------------------
-- has_role(_user_id, _role) répond pour n'importe quel utilisateur, y compris pour
-- anon. Une fonction reçoit EXECUTE pour PUBLIC à sa création : révoquer seulement
-- « FROM anon » laisserait anon passer par PUBLIC. On révoque donc PUBLIC + anon et on
-- ré-accorde explicitement authenticated (policy « Admins can manage roles », encore
-- utilisée) et service_role. Le propriétaire (postgres, utilisé par node-api :
-- routes/knowledge.ts) garde son droit. NE PAS révoquer authenticated ici (vague G4).
REVOKE EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) FROM anon;
GRANT  EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) TO authenticated, service_role;

-- is_admin() : sans argument, ne répond que pour l'appelant (auth.uid()).
-- search_path vide : tous les objets sont qualifiés (pas de détournement par search_path).
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.user_roles
     WHERE user_id = auth.uid()
       AND role = 'admin'::public.app_role
  )
$$;

COMMENT ON FUNCTION public.is_admin() IS
  'Vrai si l''utilisateur courant (auth.uid()) a le rôle admin. Remplace has_role(auth.uid(), ''admin'') dans les policies.';

REVOKE EXECUTE ON FUNCTION public.is_admin() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.is_admin() FROM anon;
GRANT  EXECUTE ON FUNCTION public.is_admin() TO authenticated, service_role;

-- Même sémantique qu'avant (FOR ALL, USING = has_role(auth.uid(), 'admin')), mais via
-- is_admin() : la future révocation de has_role pour authenticated (G4) ne la cassera pas.
DROP POLICY IF EXISTS "Admins can manage roles" ON public.user_roles;
CREATE POLICY "Admins can manage roles" ON public.user_roles
  FOR ALL TO authenticated USING (public.is_admin());


-- 4) Policies (S20) -----------------------------------------------------------------
-- 4a) agent_keys : les clés sont créées et mises à jour par node-api
--     (POST /api/agent-keys, announce, last_used_at). Le navigateur passe par l'API
--     (frontend/src/pages/Security.tsx) : aucune écriture directe vérifiée par grep.
--     Le client garde la lecture et la suppression (révocation) de ses propres clés.
DROP POLICY IF EXISTS "Users manage own agent keys" ON public.agent_keys;
DROP POLICY IF EXISTS "Users view own agent keys"   ON public.agent_keys;
DROP POLICY IF EXISTS "Users delete own agent keys" ON public.agent_keys;
CREATE POLICY "Users view own agent keys" ON public.agent_keys
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users delete own agent keys" ON public.agent_keys
  FOR DELETE TO authenticated USING (auth.uid() = user_id);

-- 4b) INSERT inter-locataires : user_id = auth.uid() ne suffit pas, la ligne parente
--     (conversation, entrée de connaissance, schéma) doit aussi appartenir à l'appelant.
--     Le nom des policies est conservé.
DROP POLICY IF EXISTS "Users can create messages" ON public.chat_messages;
CREATE POLICY "Users can create messages" ON public.chat_messages
  FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (SELECT 1 FROM public.chat_conversations c
                 WHERE c.id = chat_messages.conversation_id
                   AND c.user_id = auth.uid())
  );

DROP POLICY IF EXISTS "Users create own knowledge versions" ON public.knowledge_versions;
CREATE POLICY "Users create own knowledge versions" ON public.knowledge_versions
  FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (SELECT 1 FROM public.knowledge_base kb
                 WHERE kb.id = knowledge_versions.entry_id
                   AND kb.user_id = auth.uid())
  );

-- Même défaut sur la base dynamique (schema_id d'un autre utilisateur). Aucune écriture
-- directe côté client (tout passe par POST /api/database) : resserrement sans impact.
DROP POLICY IF EXISTS "Users can insert own data" ON public.user_table_data;
CREATE POLICY "Users can insert own data" ON public.user_table_data
  FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (SELECT 1 FROM public.user_schemas s
                 WHERE s.id = user_table_data.schema_id
                   AND s.user_id = auth.uid())
  );

DROP POLICY IF EXISTS "Users can update own data" ON public.user_table_data;
CREATE POLICY "Users can update own data" ON public.user_table_data
  FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (SELECT 1 FROM public.user_schemas s
                 WHERE s.id = user_table_data.schema_id
                   AND s.user_id = auth.uid())
  );

DROP POLICY IF EXISTS "Users can create migrations" ON public.user_migrations;
CREATE POLICY "Users can create migrations" ON public.user_migrations
  FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (SELECT 1 FROM public.user_schemas s
                 WHERE s.id = user_migrations.schema_id
                   AND s.user_id = auth.uid())
  );


-- 5) modules_status : schéma mort (T48) ---------------------------------------------
-- Aucune lecture ni écriture dans frontend/, backend/ ou agent/. Conservée (règle
-- « Jamais » : ne pas supprimer), seulement marquée.
COMMENT ON TABLE public.modules_status IS
  'DÉPRÉCIÉ (LOT 1, T48) : table inutilisée par le code (frontend, node-api, agent). Conservée sans suppression ; ne pas l''utiliser pour de nouveaux développements.';


-- 6) agent_memory : valeurs autorisées (S11) ---------------------------------------
-- status : workflow proposed → validated | rejected (contrat LOT 1 §9).
-- level  : niveaux acceptés par node-api (routes/agentMemory.ts, LEVELS).
-- NOT VALID : n'échoue pas sur d'éventuelles lignes historiques ; validation tentée
-- ensuite, un échec est seulement signalé (NOTICE).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'agent_memory_status_check'
                    AND conrelid = 'public.agent_memory'::regclass) THEN
    ALTER TABLE public.agent_memory
      ADD CONSTRAINT agent_memory_status_check
      CHECK (status IN ('proposed', 'validated', 'rejected')) NOT VALID;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'agent_memory_level_check'
                    AND conrelid = 'public.agent_memory'::regclass) THEN
    ALTER TABLE public.agent_memory
      ADD CONSTRAINT agent_memory_level_check
      CHECK (level IN ('working', 'project', 'user', 'technical',
                       'documentary', 'workflow', 'error', 'optimization')) NOT VALID;
  END IF;
END $$;

DO $$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY ARRAY['agent_memory_status_check', 'agent_memory_level_check'] LOOP
    BEGIN
      EXECUTE format('ALTER TABLE public.agent_memory VALIDATE CONSTRAINT %I', c);
    EXCEPTION WHEN check_violation THEN
      RAISE NOTICE 'Contrainte % non validée : des lignes existantes la violent', c;
    END;
  END LOOP;
END $$;
