-- Clés d'accès de l'agent local (worker qui contrôle le poste).
-- On ne stocke QUE le hash SHA-256 de la clé ; la clé en clair n'est affichée
-- qu'une seule fois à sa création. Le backend valide en hashant la clé reçue
-- (en-tête x-agent-key) et retrouve le user_id via le hash — le user_id n'est
-- plus transmis en clair par l'agent.

CREATE TABLE IF NOT EXISTS public.agent_keys (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  key_hash     TEXT NOT NULL UNIQUE,
  label        TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_used_at TIMESTAMPTZ
);

ALTER TABLE public.agent_keys ENABLE ROW LEVEL SECURITY;

-- L'utilisateur gère uniquement ses propres clés (via l'app, JWT).
-- Le backend, lui, lit par hash avec la clé de service (hors RLS) pour la validation.
--
-- [LOT 1 / T47] Garde de rejeu ajoutée a posteriori. Cette migration est peut-être déjà
-- appliquée sur Supabase : `supabase db push` ne la rejouera pas (historique par
-- version), et sur une base neuve le résultat est IDENTIQUE à l'original (la table
-- vient d'être créée, elle n'a aucune policy → la policy est créée). Seul un rejeu
-- (CI : migrations ×2, restauration partielle) devient sûr.
-- Garde volontairement « aucune policy sur la table » plutôt que DROP + CREATE :
-- 20261001090000_lot1_fixes.sql remplace cette policy FOR ALL par SELECT + DELETE, puis
-- 20261001100000_lot1_verif.sql par SELECT seul ; un rejeu de ce fichier ne doit pas
-- rouvrir d'écriture au client.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname = 'public' AND tablename = 'agent_keys') THEN
    CREATE POLICY "Users manage own agent keys" ON public.agent_keys
      FOR ALL TO authenticated
      USING (auth.uid() = user_id)
      WITH CHECK (auth.uid() = user_id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_agent_keys_hash ON public.agent_keys (key_hash);
CREATE INDEX IF NOT EXISTS idx_agent_keys_user ON public.agent_keys (user_id);
