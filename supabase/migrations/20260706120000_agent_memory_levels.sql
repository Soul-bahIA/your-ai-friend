-- Mémoire multi-niveaux + validation.
-- `level` : niveau de mémoire (extensible) — working | project | user | technical |
--            documentary | workflow | error | optimization.
-- `status`: proposed | validated | rejected — une optimisation est PROPOSÉE puis
--            validée avant d'être réinjectée dans la planification (traçable, réversible).
ALTER TABLE public.agent_memory
  ADD COLUMN IF NOT EXISTS level      TEXT NOT NULL DEFAULT 'workflow',
  ADD COLUMN IF NOT EXISTS status     TEXT NOT NULL DEFAULT 'validated',
  ADD COLUMN IF NOT EXISTS project_id UUID,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_agent_memory_level ON public.agent_memory (user_id, level);
CREATE INDEX IF NOT EXISTS idx_agent_memory_status ON public.agent_memory (user_id, status);
