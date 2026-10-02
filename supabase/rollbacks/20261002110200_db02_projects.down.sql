-- Retour arrière de 20261002110200_db02_projects.sql — retirer d'abord les lots suivants (clés étrangères vers projects).
DROP TABLE IF EXISTS soulbah.project_versions;
DROP TABLE IF EXISTS soulbah.project_dependencies;
DROP TABLE IF EXISTS soulbah.project_components;
DROP TABLE IF EXISTS soulbah.project_environments;
DROP TABLE IF EXISTS soulbah.project_repositories;
DROP TABLE IF EXISTS soulbah.projects;
