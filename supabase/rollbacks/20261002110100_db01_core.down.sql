-- Retour arrière de 20261002110100_db01_core.sql — ne s'applique que si aucun lot suivant n'est en place
-- (leurs clés étrangères vers environments bloqueraient). Les historiques sont perdus : les exporter avant.
DROP TABLE IF EXISTS soulbah.feature_flags_history;
DROP TABLE IF EXISTS soulbah.feature_flags;
DROP TABLE IF EXISTS soulbah.system_health;
DROP TABLE IF EXISTS soulbah.system_versions;
DROP TABLE IF EXISTS soulbah.system_state_history;
DROP TABLE IF EXISTS soulbah.system_state;
DROP TABLE IF EXISTS soulbah.system_settings_history;
DROP TABLE IF EXISTS soulbah.system_settings;
DROP TABLE IF EXISTS soulbah.environments;
DROP FUNCTION IF EXISTS soulbah.feature_flags_track();
DROP FUNCTION IF EXISTS soulbah.system_state_track();
DROP FUNCTION IF EXISTS soulbah.system_settings_track();
DROP FUNCTION IF EXISTS soulbah.writes_allowed();
DROP FUNCTION IF EXISTS soulbah.change_actor();
DROP FUNCTION IF EXISTS soulbah.change_reason();
DROP FUNCTION IF EXISTS soulbah.protect_immutable();
DROP FUNCTION IF EXISTS soulbah.trusted_core_unlocked();
DROP FUNCTION IF EXISTS soulbah.is_severity(text);
DROP FUNCTION IF EXISTS soulbah.is_autonomy_level(text);
DROP FUNCTION IF EXISTS soulbah.is_environment(text);
DROP FUNCTION IF EXISTS soulbah.assert_table_shape(regclass, jsonb);
DROP FUNCTION IF EXISTS soulbah.append_only();
