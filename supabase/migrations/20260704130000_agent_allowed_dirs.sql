-- Dossiers autorisés (whitelist) de chaque agent local, annoncés par l'agent
-- au démarrage (POST /api/agent-tasks/announce). Le planificateur les injecte
-- dans le contexte de plan_goal pour ne générer que des chemins valides.

ALTER TABLE public.agent_keys
  ADD COLUMN IF NOT EXISTS allowed_dirs JSONB NOT NULL DEFAULT '[]'::jsonb;
