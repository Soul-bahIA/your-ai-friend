-- Retour arrière de 20261002100000_db00_migration_history.sql — PERD l'historique des migrations.
-- À n'utiliser que pour abandonner entièrement le dispositif ; exporter d'abord :
--   COPY soulbah.schema_migrations TO STDOUT ; COPY soulbah.schema_migration_runs TO STDOUT ;
-- Le schéma soulbah lui-même n'est pas supprimé (il porte aussi les tables V2).
DROP TABLE IF EXISTS soulbah.schema_migration_runs;
DROP TABLE IF EXISTS soulbah.schema_migrations;
DROP FUNCTION IF EXISTS soulbah.schema_migration_runs_append_only();
