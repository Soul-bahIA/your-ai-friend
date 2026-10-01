-- =============================================================================
-- Contrôles APRÈS une restauration (ou après `supabase db push`) — S19, S11, G2–G4.
-- LECTURE SEULE : aucune donnée ni aucun droit n'est modifié. Chaque écart lève une
-- exception qui dit quoi corriger.
--
--   psql "$URL" -X -v ON_ERROR_STOP=1 -f scripts/sql/post_restore_checks.sql
--   (ou : coller le fichier dans l'éditeur SQL de Supabase)
--
-- Pourquoi : une restauration faite avec `--no-privileges` (anciennes sauvegardes,
-- avant LOT 1) recrée les fonctions avec les droits par défaut (EXECUTE pour PUBLIC) et
-- annule silencieusement la révocation de has_role / is_admin. Correctif en cas
-- d'échec : rejouer les blocs REVOKE/GRANT de 20261001090000_lot1_fixes.sql §3 et
-- 20261001100000_lot1_verif.sql §6 (migrations idempotentes : les rejouer entières
-- convient aussi), puis relancer ce fichier.
-- Également exécuté en CI après les migrations (scripts/ci/apply_migrations.sh --checks).
-- Aucune méta-commande psql : le fichier se colle tel quel dans l'éditeur SQL de Supabase.
-- =============================================================================

DO $$
DECLARE
  bad text;
BEGIN
  -- 1) Droits EXECUTE des fonctions d'autorisation (S19, vague G4) -------------------
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
              WHERE p.oid = 'public.has_role(uuid, public.app_role)'::regprocedure
                AND a.grantee = 0 AND a.privilege_type = 'EXECUTE') THEN
    RAISE EXCEPTION 'S19 : has_role exécutable par PUBLIC (droits perdus à la restauration ?)';
  END IF;
  IF has_function_privilege('anon', 'public.has_role(uuid, public.app_role)', 'EXECUTE') THEN
    RAISE EXCEPTION 'S19 : has_role exécutable par anon';
  END IF;
  IF has_function_privilege('authenticated', 'public.has_role(uuid, public.app_role)', 'EXECUTE') THEN
    RAISE EXCEPTION 'S19/G4 : has_role exécutable par authenticated (WARNING « G4 non appliquée » lors de la migration ?)';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
              WHERE p.oid = 'public.is_admin()'::regprocedure
                AND a.grantee = 0 AND a.privilege_type = 'EXECUTE')
     OR has_function_privilege('anon', 'public.is_admin()', 'EXECUTE') THEN
    RAISE EXCEPTION 'S19 : is_admin exécutable par PUBLIC ou anon';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.is_admin()', 'EXECUTE') THEN
    RAISE EXCEPTION 'is_admin non exécutable par authenticated : la policy « Admins can manage roles » échouera';
  END IF;

  -- 2) RLS active sur toutes les tables du schéma public ------------------------------
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
    FROM pg_class c
   WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
     AND NOT c.relrowsecurity;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'RLS désactivée sur : %', bad;
  END IF;

  -- 3) Écritures client retirées (S11, S20, G2, G3) : seules ces commandes restent -----
  SELECT string_agg(format('%s « %s » (%s)', tablename, policyname, cmd), ', ') INTO bad
    FROM pg_policies
   WHERE schemaname = 'public'
     AND (   (tablename = 'knowledge_base' AND cmd <> 'SELECT')
          OR (tablename = 'agent_tasks'    AND cmd <> 'SELECT')
          OR (tablename = 'agent_keys'     AND cmd <> 'SELECT')
          OR (tablename = 'agent_memory'   AND cmd NOT IN ('SELECT', 'DELETE')));
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'Policies d''écriture client inattendues : %', bad;
  END IF;

  RAISE NOTICE 'post_restore_checks : droits, RLS et policies conformes';
END $$;
