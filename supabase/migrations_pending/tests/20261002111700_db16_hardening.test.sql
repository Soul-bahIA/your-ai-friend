-- Test de 20261002111700_db16_hardening.sql
DO $$
DECLARE
  bad text; n integer;
BEGIN
  -- Les invariants vérifiés par la migration tiennent encore après son application
  SELECT string_agg(c.relname, ', ') INTO bad FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'soulbah' AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'RLS absente : %', bad; END IF;
  SELECT string_agg(DISTINCT g.table_name || ':' || g.grantee, ', ') INTO bad FROM information_schema.role_table_grants g
   WHERE g.table_schema = 'soulbah' AND g.grantee IN ('anon', 'authenticated', 'PUBLIC');
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'droits indus sur soulbah : %', bad; END IF;
  SELECT string_agg(DISTINCT g.table_name || ':' || g.grantee || ':' || g.privilege_type, ', ') INTO bad FROM information_schema.role_table_grants g
   WHERE g.table_schema = 'public' AND g.grantee IN ('anon', 'authenticated') AND g.privilege_type IN ('TRUNCATE', 'TRIGGER', 'REFERENCES', 'MAINTAIN');
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'droits restants sur public : %', bad; END IF;
  -- Fonctions de soulbah : PUBLIC n'a plus EXECUTE ; le propriétaire (node-api en postgres) l'a toujours
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    SELECT string_agg(p.proname, ', ') INTO bad FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'soulbah' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF bad IS NOT NULL THEN RAISE EXCEPTION 'anon exécute encore : %', bad; END IF;
  END IF;
  IF NOT has_function_privilege(current_user, 'soulbah.is_json_object(jsonb)', 'EXECUTE') THEN RAISE EXCEPTION 'le rôle courant a perdu EXECUTE'; END IF;
  -- Les contraintes CHECK qui appellent ces fonctions fonctionnent toujours pour le rôle courant
  INSERT INTO soulbah.feature_flags (key, enabled, description) VALUES ('db16.selftest', false, 'test') ON CONFLICT (key) DO NOTHING;
  -- anon et authenticated gardent SELECT/INSERT/UPDATE/DELETE sur public (RLS les encadre) : rien de cassé pour l'application
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND to_regclass('public.profiles') IS NOT NULL
     AND NOT has_table_privilege('authenticated', 'public.profiles', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated a perdu SELECT sur public.profiles';
  END IF;
  -- Privilèges par défaut du rôle courant sur public : plus de TRUNCATE pour anon/authenticated
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    SELECT count(*) INTO n FROM pg_default_acl d JOIN pg_namespace ns ON ns.oid = d.defaclnamespace
     WHERE ns.nspname = 'public' AND d.defaclobjtype = 'r' AND d.defaclrole = (SELECT oid FROM pg_roles WHERE rolname = current_user)
       AND (aclcontains(d.defaclacl, makeaclitem((SELECT oid FROM pg_roles WHERE rolname = 'anon'), d.defaclrole, 'TRUNCATE', false))
            OR aclcontains(d.defaclacl, makeaclitem((SELECT oid FROM pg_roles WHERE rolname = 'authenticated'), d.defaclrole, 'TRUNCATE', false)));
    IF n > 0 THEN RAISE EXCEPTION 'privilèges par défaut : TRUNCATE encore accordé à anon/authenticated sur public'; END IF;
  END IF;
  -- Clés étrangères indexées
  SELECT string_agg(c.conrelid::regclass::text || '(' || a.attname || ')', ', ') INTO bad
    FROM pg_constraint c JOIN pg_namespace ns ON ns.oid = c.connamespace
    JOIN LATERAL unnest(c.conkey) WITH ORDINALITY k(attnum, ord) ON k.ord = 1
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
   WHERE c.contype = 'f' AND ns.nspname = 'soulbah' AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.conrelid AND i.indkey[0] = k.attnum);
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'FK sans index : %', bad; END IF;
  -- Trace de version
  IF NOT EXISTS (SELECT 1 FROM soulbah.system_versions WHERE component = 'database.schema' AND version = '2026-10-02.lots-01-16' AND status = 'active') THEN
    RAISE EXCEPTION 'version database.schema absente';
  END IF;
  -- Rôle API : si présent, il lit et écrit les tables des lots et exécute les fonctions
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'soulbah_api') THEN
    IF NOT has_table_privilege('soulbah_api', 'soulbah.memory_items', 'INSERT') THEN RAISE EXCEPTION 'soulbah_api sans INSERT sur memory_items'; END IF;
    IF has_table_privilege('soulbah_api', 'soulbah.audit_logs', 'DELETE') THEN RAISE EXCEPTION 'soulbah_api peut supprimer dans audit_logs'; END IF;
    IF NOT has_function_privilege('soulbah_api', 'soulbah.is_json_object(jsonb)', 'EXECUTE') THEN RAISE EXCEPTION 'soulbah_api sans EXECUTE'; END IF;
  END IF;
END $$;
