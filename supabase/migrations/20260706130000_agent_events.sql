-- Poste de pilotage temps réel : évènements émis par l'agent pendant l'exécution
-- (timeline live + captures d'écran live) et contrôle de l'exécution (pause/stop).

-- Flux d'évènements de l'agent (chaque étape, capture, erreur, correction…).
CREATE TABLE IF NOT EXISTS public.agent_events (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id    UUID NOT NULL,
  user_id    UUID NOT NULL,
  type       TEXT NOT NULL,   -- task_started|step_started|step_done|step_failed|screenshot|task_completed|task_failed|info
  message    TEXT,
  data       JSONB NOT NULL DEFAULT '{}'::jsonb,  -- ex. {index, step_type, image_b64, duration_s}
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.agent_events ENABLE ROW LEVEL SECURITY;

-- [LOT 1 / T47] Garde de rejeu ajoutée a posteriori, sans changer le schéma obtenu :
-- sur une base neuve la table n'a aucune policy → création identique à l'original ;
-- déjà appliquée → `supabase db push` ne rejoue pas ce fichier ; rejeu (CI ×2) → no-op.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname = 'public' AND tablename = 'agent_events') THEN
    CREATE POLICY "Users view own agent events" ON public.agent_events
      FOR SELECT TO authenticated USING (auth.uid() = user_id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_agent_events_task ON public.agent_events (task_id, created_at);
CREATE INDEX IF NOT EXISTS idx_agent_events_user ON public.agent_events (user_id, created_at DESC);

-- Contrôle de l'exécution posé par l'utilisateur, lu par l'agent entre les étapes.
ALTER TABLE public.agent_tasks ADD COLUMN IF NOT EXISTS control TEXT NOT NULL DEFAULT 'none';  -- none|pause|stop

-- Diffusion temps réel (Supabase Realtime) des évènements vers l'UI.
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.agent_events;
EXCEPTION
  WHEN duplicate_object THEN NULL;  -- déjà dans la publication
  WHEN undefined_object THEN NULL;  -- publication absente (env non-Supabase)
END $$;
