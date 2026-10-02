-- Retour arrière de 20261002111300_db12_missions_checkpoints.sql — sessions, tasks et checkpoints retrouvent leurs colonnes V2.
DROP VIEW IF EXISTS soulbah.computer_actions;
DROP TABLE IF EXISTS soulbah.computer_observations;
DROP TABLE IF EXISTS soulbah.computer_permissions;
DROP TABLE IF EXISTS soulbah.computer_sessions;
DROP TABLE IF EXISTS soulbah.context_metrics;
DROP TABLE IF EXISTS soulbah.context_items;
DROP TABLE IF EXISTS soulbah.context_sources;
DROP TABLE IF EXISTS soulbah.context_builds;
DROP TABLE IF EXISTS soulbah.session_checkpoints;
DROP INDEX IF EXISTS soulbah.idx_checkpoints_state_artifact;
ALTER TABLE soulbah.checkpoints DROP CONSTRAINT IF EXISTS checkpoints_kind_check;
ALTER TABLE soulbah.checkpoints DROP CONSTRAINT IF EXISTS checkpoints_label_length;
ALTER TABLE soulbah.checkpoints DROP COLUMN IF EXISTS created_by, DROP COLUMN IF EXISTS resumable, DROP COLUMN IF EXISTS state_artifact_id,
  DROP COLUMN IF EXISTS kind, DROP COLUMN IF EXISTS label;
DROP INDEX IF EXISTS soulbah.idx_tasks_project;
ALTER TABLE soulbah.tasks DROP COLUMN IF EXISTS project_id;
DROP TRIGGER IF EXISTS sessions_default_result ON soulbah.sessions;
DROP FUNCTION IF EXISTS soulbah.sessions_default_result();
DROP INDEX IF EXISTS soulbah.idx_sessions_project;
DROP INDEX IF EXISTS soulbah.idx_sessions_environment;
DROP INDEX IF EXISTS soulbah.idx_sessions_parent;
ALTER TABLE soulbah.sessions DROP CONSTRAINT IF EXISTS sessions_autonomy_level_check;
ALTER TABLE soulbah.sessions DROP CONSTRAINT IF EXISTS sessions_mission_kind_check;
ALTER TABLE soulbah.sessions DROP CONSTRAINT IF EXISTS sessions_result_check;
ALTER TABLE soulbah.sessions DROP CONSTRAINT IF EXISTS sessions_result_summary_length;
ALTER TABLE soulbah.sessions DROP CONSTRAINT IF EXISTS sessions_not_own_parent;
ALTER TABLE soulbah.sessions DROP CONSTRAINT IF EXISTS sessions_completed_has_result;
ALTER TABLE soulbah.sessions DROP CONSTRAINT IF EXISTS sessions_simulated_never_success;
ALTER TABLE soulbah.sessions DROP COLUMN IF EXISTS result_summary, DROP COLUMN IF EXISTS result, DROP COLUMN IF EXISTS parent_session_id,
  DROP COLUMN IF EXISTS mission_kind, DROP COLUMN IF EXISTS autonomy_level, DROP COLUMN IF EXISTS environment_name, DROP COLUMN IF EXISTS project_id;
