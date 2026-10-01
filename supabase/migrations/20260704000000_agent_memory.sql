-- Mémoire d'exécution de l'agent : erreurs rencontrées, solutions validées,
-- bonnes pratiques issues de l'auto-amélioration. Réinjectée dans la planification
-- (moteur de raisonnement) pour éviter de répéter les mêmes échecs.

CREATE TABLE IF NOT EXISTS public.agent_memory (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  type         TEXT NOT NULL CHECK (type IN ('error', 'solution', 'practice')),
  goal         TEXT NOT NULL,
  content      TEXT NOT NULL,
  metadata     JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.agent_memory ENABLE ROW LEVEL SECURITY;

-- Gérée par le backend (connexion directe) ; policy pour un accès direct éventuel.
--
-- [LOT 1 / T47] Gardes de rejeu ajoutées a posteriori, sans changer le schéma obtenu
-- sur une base neuve (table sans policy → policy créée ; index absent → créé).
-- Déjà appliquée → `supabase db push` ne rejoue pas ce fichier ; rejeu (CI ×2) → no-op.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname = 'public' AND tablename = 'agent_memory') THEN
    CREATE POLICY "Users manage own agent memory" ON public.agent_memory
      FOR ALL TO authenticated
      USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_agent_memory_user ON public.agent_memory (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_memory_type ON public.agent_memory (user_id, type);
-- 20261001000000_hardening.sql renomme cet index en idx_agent_memory_user_goal : ne pas
-- le recréer sous l'ancien nom lors d'un rejeu (sinon le RENAME de hardening échoue).
DO $$
BEGIN
  IF to_regclass('public.idx_agent_memory_user_goal') IS NULL THEN
    CREATE INDEX IF NOT EXISTS idx_agent_memory_goal_trgm ON public.agent_memory (user_id, goal);
  END IF;
END $$;
