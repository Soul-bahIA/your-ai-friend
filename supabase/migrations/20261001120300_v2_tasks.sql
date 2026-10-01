-- =============================================================================
-- V2 — 4/12 : tâches (10 états, baux, idempotence, critères) — audit §9.4, §9.8, §12.
-- Idempotente, additive. public.agent_tasks garde ses 5 statuts (CHECK intact) : seule la
-- colonne nullable v2_task_id est ajoutée (correspondance avec la tâche V2).
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.tasks (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id           uuid NOT NULL REFERENCES soulbah.sessions(id) ON DELETE CASCADE,
  user_id              uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  parent_task_id       uuid REFERENCES soulbah.tasks(id) ON DELETE SET NULL,
  -- Identifiant stable dans le plan (nœud du DAG), ex. « observe_1 ».
  node_key             text CONSTRAINT tasks_node_key_format CHECK (node_key IS NULL OR node_key ~ '^[a-z][a-z0-9_.-]{0,63}$'),
  title                text NOT NULL CONSTRAINT tasks_title_length CHECK (length(title) BETWEEN 1 AND 500),
  role                 text NOT NULL CONSTRAINT tasks_role_format CHECK (role ~ '^[a-z][a-z0-9_]{0,63}$'),
  status               text NOT NULL DEFAULT 'PENDING'
                       CONSTRAINT tasks_status_check CHECK (status IN
                         ('PENDING', 'READY', 'RUNNING', 'WAITING', 'BLOCKED', 'VALIDATING',
                          'RETRYING', 'COMPLETED', 'FAILED', 'CANCELLED')),
  -- Bail (§9.4) : attempt +1 à chaque READY → RUNNING ; lease_owner = runtime:slot.
  attempt              integer NOT NULL DEFAULT 0 CONSTRAINT tasks_attempt_positive CHECK (attempt >= 0),
  retry_count          integer NOT NULL DEFAULT 0 CONSTRAINT tasks_retry_positive CHECK (retry_count >= 0),
  max_retries          integer NOT NULL DEFAULT 2 CONSTRAINT tasks_max_retries_range CHECK (max_retries BETWEEN 0 AND 10),
  lease_owner          text,
  lease_expires_at     timestamptz,
  -- Clé d'idempotence fournie par le planificateur (unique par session).
  idempotency_key      text,
  security_level       text NOT NULL DEFAULT 'L1'
                       CONSTRAINT tasks_level_check CHECK (soulbah.is_security_level(security_level)),
  -- Ressources exclusives/partagées déclarées (§9.7) : [{"key":"desktop.input:<runtime>","mode":"exclusive"}].
  resources            jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT tasks_resources_array CHECK (soulbah.is_json_array(resources)),
  -- Spécification exécutable (étapes du catalogue d'outils, instructions du rôle…).
  spec                 jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT tasks_spec_object CHECK (soulbah.is_json_object(spec)),
  -- DSL de critères d'acceptation (§9.8) : [{"type":"file_exists","path":…,"required":true}].
  acceptance_criteria  jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT tasks_criteria_array CHECK (soulbah.is_json_array(acceptance_criteria)),
  result               jsonb,
  error                text,
  simulated            boolean NOT NULL DEFAULT false,
  blocked_reason       text,
  waiting_reason       text,
  priority             integer NOT NULL DEFAULT 5 CONSTRAINT tasks_priority_range CHECK (priority BETWEEN 1 AND 10),
  plan_version         integer NOT NULL DEFAULT 0 CONSTRAINT tasks_plan_version_positive CHECK (plan_version >= 0),
  -- RETRYING → READY quand next_attempt_at est atteint (backoff 30 s, 2 min, 8 min).
  next_attempt_at      timestamptz,
  -- BLOCKED → FAILED à l'échéance d'escalade (24 h par défaut).
  escalate_at          timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  started_at           timestamptz,
  finished_at          timestamptz,
  -- Une tâche simulée ne peut pas être COMPLETED (§9.4 « un run simulated ne passe jamais »).
  CONSTRAINT tasks_simulated_never_completed CHECK (NOT (simulated AND status = 'COMPLETED'))
);
ALTER TABLE soulbah.tasks ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.tasks;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.tasks
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE UNIQUE INDEX IF NOT EXISTS uq_tasks_idempotency ON soulbah.tasks (session_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_tasks_node_key ON soulbah.tasks (session_id, plan_version, node_key)
  WHERE node_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_session_status ON soulbah.tasks (session_id, status);
CREATE INDEX IF NOT EXISTS idx_tasks_user_status ON soulbah.tasks (user_id, status, created_at DESC);
-- File du scheduler (READY, par priorité puis ancienneté) et backoff des RETRYING.
CREATE INDEX IF NOT EXISTS idx_tasks_ready ON soulbah.tasks (priority, created_at) WHERE status = 'READY';
CREATE INDEX IF NOT EXISTS idx_tasks_retrying ON soulbah.tasks (next_attempt_at) WHERE status = 'RETRYING';
-- Reaper : baux expirés des tâches actives (§9.4 : passage direct en RETRYING).
CREATE INDEX IF NOT EXISTS idx_tasks_lease ON soulbah.tasks (lease_expires_at)
  WHERE status IN ('RUNNING', 'WAITING', 'VALIDATING');
CREATE INDEX IF NOT EXISTS idx_tasks_parent ON soulbah.tasks (parent_task_id) WHERE parent_task_id IS NOT NULL;

-- Machine à états (§9.4) : toute transition absente du tableau est refusée en base
-- (défense en profondeur ; node-api applique la même table). CANCELLED est atteignable
-- depuis tout état non terminal ; FAILED → READY = relance manuelle auditée.
CREATE OR REPLACE FUNCTION soulbah.tasks_check_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;
  IF NEW.status = 'CANCELLED' AND OLD.status NOT IN ('COMPLETED', 'FAILED', 'CANCELLED') THEN
    RETURN NEW;
  END IF;
  IF (OLD.status, NEW.status) IN (
       ('PENDING', 'READY'), ('PENDING', 'BLOCKED'),
       ('READY', 'RUNNING'),
       ('RUNNING', 'WAITING'), ('RUNNING', 'BLOCKED'), ('RUNNING', 'VALIDATING'),
       ('RUNNING', 'RETRYING'), ('RUNNING', 'FAILED'),
       ('WAITING', 'RUNNING'), ('WAITING', 'BLOCKED'), ('WAITING', 'RETRYING'), ('WAITING', 'FAILED'),
       ('BLOCKED', 'READY'), ('BLOCKED', 'PENDING'), ('BLOCKED', 'FAILED'),
       ('VALIDATING', 'COMPLETED'), ('VALIDATING', 'RETRYING'), ('VALIDATING', 'FAILED'),
       ('RETRYING', 'READY'),
       ('FAILED', 'READY')) THEN
    IF OLD.status = 'READY' AND NEW.status = 'RUNNING' AND NEW.attempt <> OLD.attempt + 1 THEN
      RAISE EXCEPTION 'soulbah.tasks % : READY → RUNNING exige attempt = % (reçu %)', OLD.id, OLD.attempt + 1, NEW.attempt
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'soulbah.tasks % : transition % → % interdite (audit §9.4)', OLD.id, OLD.status, NEW.status
    USING ERRCODE = 'check_violation';
END $$;
DROP TRIGGER IF EXISTS check_transition ON soulbah.tasks;
CREATE TRIGGER check_transition BEFORE UPDATE OF status ON soulbah.tasks
  FOR EACH ROW EXECUTE FUNCTION soulbah.tasks_check_transition();

-- agents.current_task_id (3/12 ne pouvait pas encore référencer tasks).
ALTER TABLE soulbah.agents ADD COLUMN IF NOT EXISTS current_task_id uuid;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agents_current_task_fk') THEN
    ALTER TABLE soulbah.agents ADD CONSTRAINT agents_current_task_fk
      FOREIGN KEY (current_task_id) REFERENCES soulbah.tasks(id) ON DELETE SET NULL;
  END IF;
END $$;

-- Pont V1 : la tâche agent_tasks créée pour exécuter une tâche V2 (legacy_adapter, LOT 8).
ALTER TABLE public.agent_tasks ADD COLUMN IF NOT EXISTS v2_task_id uuid;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_tasks_v2_task_fk') THEN
    ALTER TABLE public.agent_tasks ADD CONSTRAINT agent_tasks_v2_task_fk
      FOREIGN KEY (v2_task_id) REFERENCES soulbah.tasks(id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_agent_tasks_v2_task ON public.agent_tasks (v2_task_id) WHERE v2_task_id IS NOT NULL;
