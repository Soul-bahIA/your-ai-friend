-- Retour arrière de 20261002111500_db14_observability.sql
DROP TABLE IF EXISTS soulbah.notifications;
DROP FUNCTION IF EXISTS soulbah.purge_resource_metrics(interval);
DROP TABLE IF EXISTS soulbah.resource_metrics;
DROP FUNCTION IF EXISTS soulbah.retention_guard();
DROP TABLE IF EXISTS soulbah.health_events;
DROP FUNCTION IF EXISTS soulbah.health_events_apply();
DROP TABLE IF EXISTS soulbah.health_checks;
