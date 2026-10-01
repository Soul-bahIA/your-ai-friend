-- Reprise des tâches interrompues : un agent tué en pleine exécution laisse
-- sa tâche bloquée en 'in_progress'. On compte les reprises pour plafonner
-- (au-delà de 3, la tâche est marquée 'failed' au lieu de boucler).
ALTER TABLE public.agent_tasks
  ADD COLUMN IF NOT EXISTS requeue_count integer NOT NULL DEFAULT 0;
