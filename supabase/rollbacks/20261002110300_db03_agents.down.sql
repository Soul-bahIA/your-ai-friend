-- Retour arrière de 20261002110300_db03_agents.sql — retirer d'abord les lots suivants.
-- Les colonnes ajoutées à soulbah.agents et soulbah.tasks sont supprimées (leurs valeurs sont perdues).
DROP TABLE IF EXISTS soulbah.agent_quarantines;
DROP TABLE IF EXISTS soulbah.agent_peer_reviews;
DROP TABLE IF EXISTS soulbah.agent_watchdog_events;
DROP TABLE IF EXISTS soulbah.agent_failures;
ALTER TABLE soulbah.tasks DROP COLUMN IF EXISTS agent_definition_id;
ALTER TABLE soulbah.agents DROP COLUMN IF EXISTS finished_at, DROP COLUMN IF EXISTS outcome,
  DROP COLUMN IF EXISTS version_id, DROP COLUMN IF EXISTS definition_id;
DROP TABLE IF EXISTS soulbah.agent_metrics;
DROP TABLE IF EXISTS soulbah.agent_status;
DROP TABLE IF EXISTS soulbah.agent_assignments;
DROP TABLE IF EXISTS soulbah.agent_permissions;
DROP TABLE IF EXISTS soulbah.agent_capabilities;
ALTER TABLE soulbah.agent_definitions DROP CONSTRAINT IF EXISTS agent_definitions_current_version_fkey;
DROP TABLE IF EXISTS soulbah.agent_definition_versions;
DROP TABLE IF EXISTS soulbah.agent_definitions;
DROP FUNCTION IF EXISTS soulbah.agent_quarantine_apply();
