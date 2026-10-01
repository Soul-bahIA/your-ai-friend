-- =============================================================================
-- V2 — 5/12 : dépendances entre tâches (arêtes du DAG) + trigger anti-cycle — audit §9.4, §12.
-- Idempotente, additive.
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.task_dependencies (
  task_id             uuid NOT NULL REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  depends_on_task_id  uuid NOT NULL REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  -- hard : bloque READY tant que la dépendance n'est pas COMPLETED (FAILED/CANCELLED → BLOCKED) ;
  -- soft : ordre préféré, jamais bloquant.
  kind                text NOT NULL DEFAULT 'hard' CONSTRAINT task_dependencies_kind_check CHECK (kind IN ('hard', 'soft')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (task_id, depends_on_task_id),
  CONSTRAINT task_dependencies_no_self CHECK (task_id <> depends_on_task_id)
);
ALTER TABLE soulbah.task_dependencies ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_task_dependencies_reverse ON soulbah.task_dependencies (depends_on_task_id);

-- Anti-cycle : A → B → A est refusé (critère de sortie LOT 4). Les deux tâches doivent
-- appartenir à la même session ; la session est verrouillée (FOR UPDATE) pour sérialiser
-- les insertions concurrentes d'un même DAG.
CREATE OR REPLACE FUNCTION soulbah.task_dependencies_check_cycle()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
DECLARE
  s_task  uuid;
  s_dep   uuid;
  cyc     boolean;
BEGIN
  SELECT session_id INTO s_task FROM soulbah.tasks WHERE id = NEW.task_id;
  SELECT session_id INTO s_dep  FROM soulbah.tasks WHERE id = NEW.depends_on_task_id;
  IF s_task IS NULL OR s_dep IS NULL OR s_task <> s_dep THEN
    RAISE EXCEPTION 'soulbah.task_dependencies : % et % ne sont pas dans la même session', NEW.task_id, NEW.depends_on_task_id
      USING ERRCODE = 'check_violation';
  END IF;
  PERFORM 1 FROM soulbah.sessions WHERE id = s_task FOR UPDATE;

  -- Cycle si, en remontant les dépendances existantes depuis depends_on_task_id, on
  -- retrouve task_id (profondeur bornée : un DAG légitime fait au plus quelques dizaines de nœuds).
  WITH RECURSIVE up(id, depth) AS (
    SELECT NEW.depends_on_task_id, 1
    UNION ALL
    SELECT d.depends_on_task_id, up.depth + 1
      FROM soulbah.task_dependencies d
      JOIN up ON d.task_id = up.id
     WHERE up.depth < 1000
  )
  SELECT EXISTS (SELECT 1 FROM up WHERE up.id = NEW.task_id) INTO cyc;
  IF cyc THEN
    RAISE EXCEPTION 'soulbah.task_dependencies : cycle de dépendances refusé (% dépendrait de % qui en dépend déjà)',
      NEW.task_id, NEW.depends_on_task_id USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS check_cycle ON soulbah.task_dependencies;
CREATE TRIGGER check_cycle BEFORE INSERT OR UPDATE ON soulbah.task_dependencies
  FOR EACH ROW EXECUTE FUNCTION soulbah.task_dependencies_check_cycle();
