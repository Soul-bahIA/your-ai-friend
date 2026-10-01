-- =============================================================================
-- Droits du rôle de moindre privilège `soulbah_api` (node-api) — S4, T54.
-- Source UNIQUE de ces droits : docs/SUPABASE_REPRISE.md §10 renvoie ici.
--
-- Prérequis : le rôle existe (CREATE ROLE soulbah_api …, voir SUPABASE_REPRISE §10).
-- À exécuter en `postgres` (éditeur SQL de Supabase : copier-coller ce fichier).
-- Idempotent : un GRANT déjà accordé est sans effet.
--
-- Inventaire relevé dans backend/node-api/src (requêtes SQL) et vérifié :
--   * statiquement par scripts/ci/check_api_grants.py (chaque table × opération du code
--     doit figurer ici : INSERT … ON CONFLICT DO UPDATE exige UPDATE, RETURNING / WHERE
--     exigent SELECT) ;
--   * sur une vraie base par scripts/ci/api_role_checks.sql (job CI `db`).
-- Toute nouvelle requête de node-api sur une table ou une opération absente d'ici
-- fait échouer la CI : ajouter le GRANT ici (et nulle part ailleurs).
-- =============================================================================

GRANT USAGE ON SCHEMA public TO soulbah_api;
-- Opérateurs pgvector (<=>) quand l'extension est dans `extensions` (convention Supabase).
DO $$
BEGIN
  IF to_regnamespace('extensions') IS NOT NULL THEN
    GRANT USAGE ON SCHEMA extensions TO soulbah_api;
  END IF;
END $$;

-- File et télémétrie de l'agent
-- agent_tasks  DELETE : DELETE /api/agent-tasks/:id (tâches terminales uniquement).
-- agent_events UPDATE : maintenance horaire (retrait de data.image_b64) ; DELETE : purge.
GRANT SELECT, INSERT, UPDATE, DELETE ON public.agent_tasks        TO soulbah_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.agent_events       TO soulbah_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.agent_keys         TO soulbah_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.agent_memory       TO soulbah_api;

-- Génération
GRANT SELECT, INSERT, UPDATE         ON public.formations         TO soulbah_api;
GRANT SELECT, INSERT, UPDATE         ON public.applications       TO soulbah_api;
GRANT SELECT, INSERT, UPDATE         ON public.analysis_requests  TO soulbah_api;

-- Base de connaissances
-- knowledge_domains UPDATE : INSERT … ON CONFLICT (slug) DO UPDATE (création de domaine).
GRANT SELECT, INSERT, UPDATE, DELETE ON public.knowledge_base     TO soulbah_api;
GRANT SELECT, INSERT                 ON public.knowledge_versions TO soulbah_api;
GRANT SELECT, INSERT, UPDATE         ON public.knowledge_domains  TO soulbah_api;

-- Base dynamique (/api/database)
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_schemas       TO soulbah_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_table_data    TO soulbah_api;
GRANT SELECT, INSERT                 ON public.user_migrations    TO soulbah_api;

-- Journal d'activité
GRANT INSERT                         ON public.system_logs        TO soulbah_api;

-- Schéma V2 `soulbah` (LOT 4) : node-api est le SEUL écrivain (tables, vues, séquences
-- d'identité, fonctions). Le journal d'audit reste en ajout seul : UPDATE/DELETE/TRUNCATE
-- retirés (les triggers les refusent de toute façon).
GRANT USAGE ON SCHEMA soulbah TO soulbah_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA soulbah TO soulbah_api;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA soulbah TO soulbah_api;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA soulbah TO soulbah_api;
REVOKE UPDATE, DELETE, TRUNCATE ON soulbah.audit_logs FROM soulbah_api;
-- Tête de chaîne : mise à jour par le trigger AFTER INSERT (droits du rôle appelant).

-- Admin applicatif (routes/knowledge.ts) : has_role n'est accordé ni à PUBLIC ni à
-- anon (LOT 1) ni à authenticated (vague G4). is_admin() n'est pas accordé : il lit
-- auth.uid() (JWT), que node-api ne pose pas.
GRANT EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) TO soulbah_api;
