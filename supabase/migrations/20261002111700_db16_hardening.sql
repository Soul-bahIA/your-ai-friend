-- =============================================================================
-- DB LOT 16 — Hardening.
--  1. Schéma soulbah : EXECUTE retiré à PUBLIC, anon et authenticated sur toutes les fonctions présentes (PostgreSQL
--     l'accorde à PUBLIC par défaut à la création) ; node-api (propriétaire postgres ou rôle soulbah_api) garde ses
--     droits. Les fonctions futures relèvent de la convention « REVOKE … FROM PUBLIC » de chaque migration.
--  2. Schéma public : anon et authenticated perdent TRUNCATE, TRIGGER, REFERENCES, MAINTAIN (jamais exercés par
--     PostgREST, hors RLS) sur les tables présentes et futures du rôle courant.
--  3. Rôle soulbah_api (s'il existe) : droits sur les objets des lots et par défaut sur les objets futurs de soulbah.
--  4. Vérification finale (lève une exception, donc annule tout) : RLS sur chaque table de soulbah ; aucun droit
--     anon/authenticated/PUBLIC sur ses tables, vues, séquences et fonctions ; chaque journal « ajout seul » protégé par
--     trigger ; un commentaire sur chaque table et vue ; chaque clé étrangère de soulbah indexée ; règles « jamais ».
-- soulbah:rollback=PARTIAL
-- soulbah:recovery=20261002111700_db16_hardening.down.sql (rend les droits retirés, retire les privilèges par défaut ajoutés ; les vérifications n'ont rien créé)
-- soulbah:transaction=single
-- Dépend de : tous les lots précédents. Non fait (hors périmètre, à évaluer sur Supabase) : déplacer pgvector hors de
-- public ; retirer EXECUTE par défaut de anon/authenticated sur les fonctions futures de public (SEC-07/SEC-10).
-- =============================================================================

-- 0. Documentation des tables et vues V2 qui n'avaient pas de commentaire (rôle en une phrase) ------------------------
COMMENT ON TABLE soulbah.actions IS 'V2 — actions exécutées par les agents : outil du catalogue, paramètres (secrets masqués), niveau de sécurité, états planned → verified, preuves typées ; une action simulée n''est jamais « vérifiée ».';
COMMENT ON TABLE soulbah.agents IS 'V2 — instances d''agents d''une session (rôle et version, statut, runtime porteur), étendues par le DB LOT 3 (définition, version, issue, fin).';
COMMENT ON TABLE soulbah.artifacts IS 'V2 — artefacts produits (fichier, capture, vidéo, journal, rapport, diff) : empreinte, taille, emplacement de stockage, classe de rétention — jamais le contenu.';
COMMENT ON TABLE soulbah.audit_chain_head IS 'V2 — tête de la chaîne de hachage du journal d''audit (dernier numéro, dernier hachage) ; ligne unique mise à jour par trigger.';
COMMENT ON TABLE soulbah.audit_logs IS 'V2 — journal d''audit chaîné par hachage (ajout seul) : acteur, action, entité, données masquées ; la vue audit_events (DB LOT 11) le lit de façon typée.';
COMMENT ON TABLE soulbah.checkpoints IS 'V2 — points de reprise d''une tentative de tâche (curseur d''étape, variables), étendus par le DB LOT 12 (libellé, genre, artefact d''état, reprise possible).';
COMMENT ON TABLE soulbah.evaluations IS 'V2 — évaluation d''une tentative de tâche (critères, résultats, verdict, confiance, preuves, suite donnée) ; une seule par tentative.';
COMMENT ON TABLE soulbah.knowledge_chunks IS 'V2 — fragments indexés des documents de connaissance : texte, recherche plein texte, vecteur sans dimension fixe et modèle d''embedding (étendu par le DB LOT 6).';
COMMENT ON TABLE soulbah.messages IS 'V2 — messages entre agents et vers l''utilisateur dans une session (question, blocage, preuve, résultat, demande de revue), accusés de réception.';
COMMENT ON TABLE soulbah.permissions IS 'V2 — permissions de session (L1/L2) et demandes d''approbation par action (L2/L3) liées au contenu présenté ; jeton d''approbation stocké haché.';
COMMENT ON TABLE soulbah.recordings IS 'V2 — enregistrements d''écran d''une tâche (chemin, durée, images par seconde, sonde) liés à un artefact.';
COMMENT ON TABLE soulbah.resource_leases IS 'V2 — baux exclusifs ou partagés sur une ressource (ex. entrées du bureau d''un PC) : exclusivité garantie par index unique partiel.';
COMMENT ON TABLE soulbah.runtimes IS 'V2 — processus superviseurs des PC (clé agent, hôte, version, capacité en emplacements), vus par le plan de contrôle.';
COMMENT ON TABLE soulbah.sessions IS 'V2 — missions (sessions multi-agents) : objectif, statut, plan versionné, budget, simulation ; étendues par le DB LOT 12 (projet, environnement, autonomie, résultat).';
COMMENT ON TABLE soulbah.skills IS 'V2 — compétences : outils du catalogue et procédures apprises, versionnées (UNIQUE nom + version) ; étendues par le DB LOT 9 (versions, étapes, tests, candidats).';
COMMENT ON TABLE soulbah.task_dependencies IS 'V2 — dépendances entre tâches (arêtes du DAG, dures ou souples) avec trigger anti-cycle.';
COMMENT ON TABLE soulbah.tasks IS 'V2 — tâches d''une mission : nœud du plan, rôle, statut, bail, tentatives, spécification, critères d''acceptation, résultat ; étendues par les DB LOT 3 et 12.';
COMMENT ON TABLE soulbah.tool_calls IS 'V2 — métrage de chaque appel d''outil (code de sortie) ou de modèle (jetons, coût, fournisseur) par tâche et par utilisateur.';
COMMENT ON TABLE soulbah.user_settings IS 'V2 — réglages par utilisateur (parallélisme maximal, préférences de la page Paramètres).';
COMMENT ON VIEW soulbah.knowledge_documents IS 'V2 — vue sur public.knowledge_base : source, statut d''ingestion et statut documentaire des documents de connaissance.';
COMMENT ON VIEW soulbah.memories IS 'V2 — vue sur public.agent_memory : mémoire V1 (leçons, préférences) lue par le plan de contrôle ; les éléments validés sont copiés dans memory_items (DB LOT 5).';

-- 1. Fonctions du schéma soulbah ---------------------------------------------------------------------------------
DO $$
DECLARE r text;
BEGIN
  -- Fonctions présentes. Pas de ALTER DEFAULT PRIVILEGES par schéma : une entrée par schéma s'ajoute au défaut global
  -- (qui donne EXECUTE à PUBLIC) et ne peut rien lui retirer. Règle : chaque migration retire PUBLIC de ses
  -- fonctions (docs/db/DB_MIGRATION_CONVENTIONS.md) ; la vérification ci-dessous attrape tout oubli.
  REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA soulbah FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA soulbah FROM %I', r);
      EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA soulbah FROM %I', r);
      EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA soulbah FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- 2. Schéma public : droits que PostgREST n'exerce jamais et que la RLS ne couvre pas ------------------------------------
DO $$
DECLARE r text; privs text;
BEGIN
  privs := 'TRUNCATE, TRIGGER, REFERENCES' || CASE WHEN current_setting('server_version_num')::int >= 170000 THEN ', MAINTAIN' ELSE '' END;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE %s ON ALL TABLES IN SCHEMA public FROM %I', privs, r);
      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE %s ON TABLES FROM %I', privs, r);
    END IF;
  END LOOP;
END $$;

-- 3. Rôle de moindre privilège soulbah_api (node-api) ---------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'soulbah_api') THEN
    GRANT USAGE ON SCHEMA soulbah TO soulbah_api;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA soulbah TO soulbah_api;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA soulbah TO soulbah_api;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA soulbah TO soulbah_api;
    REVOKE UPDATE, DELETE, TRUNCATE ON soulbah.audit_logs FROM soulbah_api;
    ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO soulbah_api;
    ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah GRANT USAGE, SELECT ON SEQUENCES TO soulbah_api;
    ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah GRANT EXECUTE ON FUNCTIONS TO soulbah_api;
    RAISE NOTICE 'Hardening : droits de soulbah_api accordés sur le schéma soulbah (objets présents et futurs)';
  ELSE
    RAISE NOTICE 'Hardening : rôle soulbah_api absent — node-api se connecte en postgres (SEC-06) ; créer le rôle puis rejouer scripts/sql/soulbah_api_grants.sql';
  END IF;
END $$;

-- 4. Vérifications : chaque manquement lève une exception et annule la migration -------------------------------------
DO $$
DECLARE
  bad text; n integer;
BEGIN
  -- RLS sur toute table du schéma soulbah
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'soulbah' AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : RLS absente sur soulbah.%', bad; END IF;

  -- Aucun droit de anon, authenticated ni PUBLIC sur les tables et vues de soulbah
  SELECT string_agg(DISTINCT g.table_name || ':' || g.grantee, ', ') INTO bad
    FROM information_schema.role_table_grants g
   WHERE g.table_schema = 'soulbah' AND g.grantee IN ('anon', 'authenticated', 'PUBLIC');
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : droits anon/authenticated/PUBLIC sur soulbah : %', bad; END IF;

  -- Séquences et fonctions de soulbah : rien pour anon ni authenticated (ni via PUBLIC)
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
      FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname = 'soulbah' AND c.relkind = 'S'
       AND (has_sequence_privilege('anon', c.oid, 'USAGE, SELECT, UPDATE') OR has_sequence_privilege('authenticated', c.oid, 'USAGE, SELECT, UPDATE'));
    IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : séquences de soulbah accessibles à anon/authenticated : %', bad; END IF;
    SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO bad
      FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'soulbah' AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));
    IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : fonctions de soulbah exécutables par anon/authenticated : %', bad; END IF;
  END IF;

  -- Journaux déclarés « ajout seul » (commentaire) : trigger d'ajout seul ou de rétention présent
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'soulbah' AND c.relkind = 'r'
     AND COALESCE(obj_description(c.oid, 'pg_class'), '') ILIKE '%ajout seul%'
     AND NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                      WHERE t.tgrelid = c.oid AND NOT t.tgisinternal
                        AND p.proname IN ('append_only', 'retention_guard', 'policy_versions_freeze', 'guardrails_track', 'audit_logs_immutable', 'schema_migration_runs_append_only'));
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : journaux sans trigger d''ajout seul : %', bad; END IF;

  -- Commentaire sur chaque table et vue de soulbah
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'soulbah' AND c.relkind IN ('r', 'v', 'p') AND obj_description(c.oid, 'pg_class') IS NULL;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : tables ou vues sans commentaire : %', bad; END IF;

  -- Clés étrangères de soulbah : chaque colonne référençante est en tête d'un index
  SELECT string_agg(c.conrelid::regclass::text || '(' || a.attname || ')', ', ' ORDER BY c.conrelid::regclass::text) INTO bad
    FROM pg_constraint c
    JOIN pg_namespace ns ON ns.oid = c.connamespace
    JOIN LATERAL unnest(c.conkey) WITH ORDINALITY k(attnum, ord) ON k.ord = 1
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
   WHERE c.contype = 'f' AND ns.nspname = 'soulbah'
     AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.conrelid AND i.indkey[0] = k.attnum);
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : clés étrangères sans index : %', bad; END IF;

  -- Plus aucun droit TRUNCATE/TRIGGER/REFERENCES/MAINTAIN de anon/authenticated sur public
  SELECT string_agg(DISTINCT g.table_name || ':' || g.grantee || ':' || g.privilege_type, ', ') INTO bad
    FROM information_schema.role_table_grants g
   WHERE g.table_schema = 'public' AND g.grantee IN ('anon', 'authenticated') AND g.privilege_type IN ('TRUNCATE', 'TRIGGER', 'REFERENCES', 'MAINTAIN');
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : droits restants sur public : %', bad; END IF;

  -- Les règles « jamais » de l'audit tiennent toujours (§12 docs/SUPABASE_REPRISE.md)
  IF to_regclass('public.agent_tasks') IS NOT NULL AND (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'agent_tasks_status_check' AND conrelid = 'public.agent_tasks'::regclass)
     IS DISTINCT FROM 'CHECK ((status = ANY (ARRAY[''pending''::text, ''in_progress''::text, ''completed''::text, ''failed''::text, ''cancelled''::text])))' THEN
    RAISE EXCEPTION 'Jamais : le CHECK de statut de public.agent_tasks a changé';
  END IF;
  IF to_regclass('public.agent_events') IS NOT NULL AND EXISTS (
       SELECT 1 FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
        WHERE c.conrelid = 'public.agent_events'::regclass AND c.contype = 'f' AND a.attname = 'task_id') THEN
    RAISE EXCEPTION 'Jamais : FK sur public.agent_events.task_id';
  END IF;
  IF to_regclass('public.modules_status') IS NULL THEN RAISE EXCEPTION 'Jamais : public.modules_status a été supprimée'; END IF;

  SELECT count(*) INTO n FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace WHERE ns.nspname = 'soulbah' AND c.relkind = 'r';
  RAISE NOTICE 'Hardening : % tables du schéma soulbah vérifiées (RLS, droits, journaux, commentaires, index de clés étrangères)', n;
END $$;

-- 5. Trace : version de schéma dans system_versions (idempotente) ---------------------------------------------------
INSERT INTO soulbah.system_versions (component, version, status, reason, activated_by, activated_at, config)
VALUES ('database.schema', '2026-10-02.lots-01-16', 'active', 'DB LOT 16 : architecture cible appliquée et vérifiée', current_user, now(),
        jsonb_build_object('lots', 16, 'hardening', true))
ON CONFLICT (component, version) DO NOTHING;
