-- Retour arrière de 20261002110500_db05_memory.sql — public.agent_memory (V1) n'est pas touchée.
ALTER TABLE soulbah.agent_failures DROP COLUMN IF EXISTS lesson_memory_id;
DROP TABLE IF EXISTS soulbah.memory_contradictions;
DROP TABLE IF EXISTS soulbah.memory_relationships;
DROP TABLE IF EXISTS soulbah.memory_items;
DROP FUNCTION IF EXISTS soulbah.memory_contradictions_apply();
DROP FUNCTION IF EXISTS soulbah.memory_relationships_apply();
DROP FUNCTION IF EXISTS soulbah.memory_items_revalidate();
