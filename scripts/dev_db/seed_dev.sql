-- =============================================================================
-- Jeu de données de DÉVELOPPEMENT pour la base locale jetable (scripts/dev_db/dev_db.sh seed).
-- Idempotent. Variables psql : user_id, email, key_hash, key_label, workspace.
-- À NE JAMAIS exécuter sur un vrai projet Supabase : auth.users y est géré par GoTrue.
-- =============================================================================
\set ON_ERROR_STOP 1
BEGIN;

-- Utilisateur de dev (AUTH_MODE=dev-local côté node-api). Le trigger handle_new_user crée
-- son profil et son rôle « user » au premier insert.
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES (:'user_id'::uuid, :'email', jsonb_build_object('display_name', 'Développeur local'))
ON CONFLICT (id) DO NOTHING;

-- Clé agent du PC de dev : seul le hash SHA-256 est stocké (la clé en clair est écrite dans
-- .dev_db/dev.env, SOULBAH_AGENT_KEY). allowed_dirs = dossier autorisé déclaré pour ce PC.
INSERT INTO public.agent_keys (user_id, key_hash, label, allowed_dirs)
VALUES (:'user_id'::uuid, :'key_hash', :'key_label', jsonb_build_array(:'workspace'::text))
ON CONFLICT (key_hash) DO UPDATE
  SET label = EXCLUDED.label, allowed_dirs = EXCLUDED.allowed_dirs;

COMMIT;

SELECT (SELECT count(*) FROM auth.users WHERE id = :'user_id'::uuid)          AS dev_users,
       (SELECT count(*) FROM public.profiles WHERE user_id = :'user_id'::uuid) AS profiles,
       (SELECT count(*) FROM public.agent_keys WHERE user_id = :'user_id'::uuid) AS agent_keys;
