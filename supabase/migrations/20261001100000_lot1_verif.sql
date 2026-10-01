-- =============================================================================
-- LOT 1 — Suite de la vérification adverse (après 20261001090000_lot1_fixes.sql)
-- Migration ADDITIVE et IDEMPOTENTE (même style que hardening / lot1_fixes) :
-- IF [NOT] EXISTS, DROP POLICY IF EXISTS puis CREATE, CREATE OR REPLACE. Aucune donnée
-- supprimée ni modifiée (seuls une valeur par défaut, des policies, un droit EXECUTE,
-- un index et une fonction de trigger changent).
--
--  1. Trigger updated_at d'agent_tasks : le détachement d'une clé agent (FK
--     ON DELETE SET NULL de target_agent_key_id / claimed_by_key_id) ne prolonge plus
--     le bail d'une tâche in_progress.
--  2. agent_memory (S11, contrat §9) : défaut de status 'proposed' ; côté client
--     lecture + suppression seulement (plus d'INSERT/UPDATE direct par PostgREST).
--  3. agent_memory (T11) : index trigramme (pg_trgm, GIN) pour `goal ILIKE ANY(…)`.
--  4. Vague G2/G3 (audit §12, contrat §11) : l'UI n'écrit plus qu'au travers de l'API
--     → knowledge_base en lecture seule pour le client, plus de DELETE client sur
--     agent_tasks.
--  5. agent_keys : plus de DELETE client (la révocation passe par
--     DELETE /api/agent-keys/:id, qui annule d'abord les tâches du PC révoqué).
--  6. Vague G4 (S19) : has_role(uuid, app_role) n'est plus exécutable par authenticated
--     (toutes les policies utilisent is_admin()).
--
-- Prérequis côté application (vérifié par grep dans frontend/ et backend/console/ au
-- LOT 1) : aucune écriture directe dans knowledge_base, agent_tasks, agent_keys ou
-- agent_memory, et aucun appel RPC à has_role. Un ancien front encore déployé qui
-- écrirait directement ces tables échouerait (INSERT refusé, UPDATE/DELETE sans effet) :
-- redéployer le front du même commit (docs/SUPABASE_REPRISE.md §5).
--
-- Règles « Jamais » (audit §12) respectées : le CHECK de statut d'agent_tasks n'est pas
-- touché, aucune FK sur agent_events.task_id, rien n'est renommé ni supprimé.
-- =============================================================================


-- 1) Trigger updated_at d'agent_tasks : détachement de clé ----------------------------
-- Révoquer une clé (DELETE FROM agent_keys) déclenche l'action référentielle
-- ON DELETE SET NULL, c'est-à-dire un UPDATE d'agent_tasks qui ne change que
-- target_agent_key_id / claimed_by_key_id. Le trigger y voyait un « vrai » changement
-- et rafraîchissait updated_at : une tâche in_progress orpheline gagnait un bail complet.
-- Règles (dans l'ordre) :
--   - une colonne autre que control / updated_at / clés change      → updated_at = now()
--   - une clé est ÉCRITE (nouvelle valeur non NULL : claim)          → updated_at = now()
--   - une clé passe seulement à NULL (détachement, SET NULL)        → updated_at conservé
--   - seul control change                                           → updated_at conservé
--   - rien ne change (heartbeat « touch »)                          → updated_at = now()
-- Le second trigger (update_agent_tasks_updated_at_control, UPDATE OF control) est
-- inchangé : il ne s'applique que si control figure dans la liste SET.
CREATE OR REPLACE FUNCTION public.agent_tasks_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  key_cols CONSTANT text[] := ARRAY['target_agent_key_id', 'claimed_by_key_id'];
BEGIN
  IF (to_jsonb(NEW) - 'control' - 'updated_at' - key_cols) IS DISTINCT FROM
     (to_jsonb(OLD) - 'control' - 'updated_at' - key_cols) THEN
    NEW.updated_at := now();
  ELSIF (NEW.target_agent_key_id IS DISTINCT FROM OLD.target_agent_key_id
         AND NEW.target_agent_key_id IS NOT NULL)
     OR (NEW.claimed_by_key_id IS DISTINCT FROM OLD.claimed_by_key_id
         AND NEW.claimed_by_key_id IS NOT NULL) THEN
    NEW.updated_at := now();
  ELSIF NEW.target_agent_key_id IS DISTINCT FROM OLD.target_agent_key_id
     OR NEW.claimed_by_key_id IS DISTINCT FROM OLD.claimed_by_key_id THEN
    NEW.updated_at := OLD.updated_at;
  ELSIF NEW.control IS DISTINCT FROM OLD.control THEN
    NEW.updated_at := OLD.updated_at;
  ELSE
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$$;
-- Le trigger update_agent_tasks_updated_at (lot1_fixes §2) appelle déjà cette fonction.


-- 2) agent_memory : statut par défaut et policies (S11) ------------------------------
-- Défaut 'validated' hérité de 20260706120000 : toute insertion qui omet status (accès
-- direct, futur écrivain) contournait le contrat §9 (« validated » seulement par une
-- action explicite de l'utilisateur). Les lignes existantes ne sont pas modifiées.
ALTER TABLE public.agent_memory ALTER COLUMN status SET DEFAULT 'proposed';

-- Les écritures passent par node-api (writeMemory, POST/PATCH /api/agent-memory, qui
-- pose metadata.validated_by). Côté client : lecture et suppression de ses entrées.
-- Le rejeu de 20260704000000 ne recrée pas la policy FOR ALL (garde « aucune policy »).
DROP POLICY IF EXISTS "Users manage own agent memory" ON public.agent_memory;
DROP POLICY IF EXISTS "Users view own agent memory"   ON public.agent_memory;
DROP POLICY IF EXISTS "Users delete own agent memory" ON public.agent_memory;
CREATE POLICY "Users view own agent memory" ON public.agent_memory
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users delete own agent memory" ON public.agent_memory
  FOR DELETE TO authenticated USING (auth.uid() = user_id);


-- 3) agent_memory : index trigramme sur goal (T11) -----------------------------------
-- getMemoryContext (node-api) filtre par `goal ILIKE ANY('{%mot%,…}')` : sans index
-- trigramme, c'est un parcours de toutes les mémoires de l'utilisateur. pg_trgm est
-- disponible sur Supabase (extension « trusted ») ; installée dans le schéma
-- `extensions` quand il existe (convention Supabase), sinon dans le schéma par défaut.
-- La classe d'opérateurs est recherchée là où l'extension se trouve réellement (une
-- installation antérieure dans public reste valable).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
    IF to_regnamespace('extensions') IS NOT NULL THEN
      CREATE EXTENSION pg_trgm WITH SCHEMA extensions;
    ELSE
      CREATE EXTENSION pg_trgm;
    END IF;
  END IF;
END $$;

DO $$
DECLARE
  opclass text;
BEGIN
  IF to_regclass('public.idx_agent_memory_goal_gin_trgm') IS NULL THEN
    SELECT format('%I.%I', n.nspname, c.opcname) INTO opclass
      FROM pg_opclass c
      JOIN pg_namespace n ON n.oid = c.opcnamespace
      JOIN pg_am a        ON a.oid = c.opcmethod
     WHERE c.opcname = 'gin_trgm_ops' AND a.amname = 'gin'
     LIMIT 1;
    IF opclass IS NULL THEN
      RAISE EXCEPTION 'pg_trgm installée mais classe d''opérateurs gin_trgm_ops introuvable';
    END IF;
    EXECUTE format(
      'CREATE INDEX idx_agent_memory_goal_gin_trgm ON public.agent_memory USING gin (goal %s)',
      opclass);
  END IF;
END $$;


-- 4) Vague G2 / G3 : écritures client retirées (contrat §11, S9, C27) ----------------
-- knowledge_base : l'UI écrit via /api/knowledge (hash, version, embedding calculés par
-- le serveur) ; une écriture directe contournait les trois. La lecture reste ouverte.
DROP POLICY IF EXISTS "Users can create knowledge"     ON public.knowledge_base;
DROP POLICY IF EXISTS "Users can update own knowledge" ON public.knowledge_base;
DROP POLICY IF EXISTS "Users can delete own knowledge" ON public.knowledge_base;

-- agent_tasks : suppression via DELETE /api/agent-tasks/:id (tâches terminales
-- seulement ; une tâche en cours s'annule par /cancel). INSERT et UPDATE client sont
-- déjà retirés (20261001000000_hardening.sql §1). Lecture et Realtime inchangés.
DROP POLICY IF EXISTS "Users can delete own tasks" ON public.agent_tasks;


-- 5) agent_keys : révocation par l'API uniquement ------------------------------------
-- DELETE /api/agent-keys/:id annule, dans la même transaction, les tâches ciblant ce PC
-- ou réclamées par lui, puis supprime la clé. Un DELETE direct (PostgREST) sautait
-- cette étape : la FK ON DELETE SET NULL rendait ces tâches non ciblées, réclamables et
-- finalisables par n'importe quel autre PC de l'utilisateur. Le client garde la lecture.
DROP POLICY IF EXISTS "Users delete own agent keys" ON public.agent_keys;


-- 6) Vague G4 : has_role n'est plus exécutable par authenticated (S19) ----------------
-- Il répondait pour n'importe quel utilisateur (« X est-il admin ? »). Plus aucune policy
-- ne l'utilise (« Admins can manage roles » → is_admin(), lot1_fixes §3) et ni le front
-- ni la console ne l'appellent. Le propriétaire (postgres), service_role et soulbah_api
-- (scripts/sql/soulbah_api_grants.sql) gardent leur droit : routes/knowledge.ts.
-- Garde-fou : si une policy créée hors migrations (tableau de bord) l'utilise encore,
-- la révocation la casserait → elle est sautée avec un WARNING (à traiter à la main,
-- docs/SUPABASE_REPRISE.md §7).
DO $$
DECLARE
  users text;
BEGIN
  SELECT string_agg(format('%I.%I « %s »', schemaname, tablename, policyname), ', ')
    INTO users
    FROM pg_policies
   WHERE coalesce(qual, '') ~ '\mhas_role\s*\('
      OR coalesce(with_check, '') ~ '\mhas_role\s*\(';
  IF users IS NULL THEN
    REVOKE EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) FROM authenticated;
  ELSE
    RAISE WARNING 'G4 non appliquée : has_role est encore utilisée par %', users;
  END IF;
END $$;
