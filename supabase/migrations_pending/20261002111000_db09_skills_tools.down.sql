-- Retour arrière de 20261002111000_db09_skills_tools.sql — soulbah.skills retrouve ses colonnes V2.
DROP TABLE IF EXISTS soulbah.tool_security_reviews;
DROP TABLE IF EXISTS soulbah.tool_tests;
DROP TABLE IF EXISTS soulbah.tool_builds;
DROP TABLE IF EXISTS soulbah.tool_candidates;
DROP TABLE IF EXISTS soulbah.tool_benchmarks;
DROP TABLE IF EXISTS soulbah.tool_health;
DROP TABLE IF EXISTS soulbah.tool_permissions;
DROP TABLE IF EXISTS soulbah.tool_versions;
DROP TABLE IF EXISTS soulbah.tools;
DROP TABLE IF EXISTS soulbah.skill_candidates;
DROP TABLE IF EXISTS soulbah.skill_metrics;
DROP TABLE IF EXISTS soulbah.skill_tests;
DROP TABLE IF EXISTS soulbah.skill_tools;
DROP TABLE IF EXISTS soulbah.skill_requirements;
DROP TABLE IF EXISTS soulbah.skill_steps;
ALTER TABLE soulbah.skills DROP CONSTRAINT IF EXISTS skills_current_version_fkey;
DROP TABLE IF EXISTS soulbah.skill_versions;
ALTER TABLE soulbah.skills DROP CONSTRAINT IF EXISTS skills_risk_level_check;
ALTER TABLE soulbah.skills DROP CONSTRAINT IF EXISTS skills_description_length;
DROP INDEX IF EXISTS soulbah.idx_skills_project;
DROP INDEX IF EXISTS soulbah.idx_skills_created_by;
DROP INDEX IF EXISTS soulbah.idx_skills_current_version;
ALTER TABLE soulbah.skills DROP COLUMN IF EXISTS risk_level, DROP COLUMN IF EXISTS project_id, DROP COLUMN IF EXISTS description,
  DROP COLUMN IF EXISTS category, DROP COLUMN IF EXISTS current_version_id;
DROP FUNCTION IF EXISTS soulbah.skill_versions_guard();
DROP FUNCTION IF EXISTS soulbah.tool_candidates_guard();
