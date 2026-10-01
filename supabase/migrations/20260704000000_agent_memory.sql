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
CREATE POLICY "Users manage own agent memory" ON public.agent_memory
  FOR ALL TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_agent_memory_user ON public.agent_memory (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_memory_type ON public.agent_memory (user_id, type);
CREATE INDEX IF NOT EXISTS idx_agent_memory_goal_trgm ON public.agent_memory (user_id, goal);
