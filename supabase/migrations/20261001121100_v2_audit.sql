-- =============================================================================
-- V2 — 12/12 : journal d'audit en AJOUT SEUL et CHAÎNÉ (prev_hash / row_hash) — audit §9.3, §12.
-- Idempotente, additive.
--
--  * Chaque ligne porte le hash de la précédente (tête de chaîne soulbah.audit_chain_head,
--    verrouillée FOR UPDATE : la chaîne est linéaire même sous concurrence) et son propre
--    hash SHA-256 (fonction native sha256(), aucune extension requise).
--  * UPDATE, DELETE et TRUNCATE sont refusés par trigger ; aucune purge.
--  * soulbah.verify_audit_chain() recalcule toute la chaîne : (ok, checked, broken_at).
--
-- Les autres points prévus par l'audit pour ce dernier fichier étaient déjà livrés au LOT 1 :
-- trigger agent_tasks_set_updated_at insensible à `control` (20261001090000 §2, 20261001100000 §1),
-- is_admin() sans argument et REVOKE has_role FROM anon (20261001090000 §3), policies
-- agent_keys / agent_memory en SELECT (+DELETE) côté client (20261001100000 §2, §5).
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.audit_logs (
  seq          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  user_id      uuid,
  session_id   uuid,
  task_id      uuid,
  -- Qui : user:<uuid>, system:scheduler, runtime:<id>, agent:<role>…
  actor        text NOT NULL CONSTRAINT audit_logs_actor_length CHECK (length(actor) BETWEEN 1 AND 200),
  -- Quoi : task.transition, permission.approved, memory.validated, skill.promoted…
  action       text NOT NULL CONSTRAINT audit_logs_action_format CHECK (action ~ '^[a-z][a-z0-9_.]{0,99}$'),
  entity       text,
  entity_id    uuid,
  data         jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT audit_logs_data_object CHECK (soulbah.is_json_object(data)),
  prev_hash    text NOT NULL CONSTRAINT audit_logs_prev_hash_format CHECK (prev_hash ~ '^[0-9a-f]{64}$'),
  row_hash     text NOT NULL CONSTRAINT audit_logs_row_hash_format CHECK (row_hash ~ '^[0-9a-f]{64}$'),
  created_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE soulbah.audit_logs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_audit_logs_session ON soulbah.audit_logs (session_id, seq) WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_logs_task ON soulbah.audit_logs (task_id, seq) WHERE task_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_logs_user ON soulbah.audit_logs (user_id, seq) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON soulbah.audit_logs (action, seq);

CREATE TABLE IF NOT EXISTS soulbah.audit_chain_head (
  id          smallint PRIMARY KEY CONSTRAINT audit_chain_head_single CHECK (id = 1),
  last_seq    bigint NOT NULL DEFAULT 0,
  last_hash   text NOT NULL DEFAULT repeat('0', 64),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE soulbah.audit_chain_head ENABLE ROW LEVEL SECURITY;
INSERT INTO soulbah.audit_chain_head (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- Hash d'une ligne : prev_hash + champs canoniques (jsonb::text est canonique : clés triées).
CREATE OR REPLACE FUNCTION soulbah.audit_row_hash(
  p_prev text, p_id uuid, p_user uuid, p_session uuid, p_task uuid, p_actor text, p_action text,
  p_entity text, p_entity_id uuid, p_data jsonb, p_created timestamptz)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT encode(sha256(convert_to(
    p_prev || '|' || p_id::text || '|' || coalesce(p_user::text, '') || '|' || coalesce(p_session::text, '')
    || '|' || coalesce(p_task::text, '') || '|' || p_actor || '|' || p_action || '|' || coalesce(p_entity, '')
    || '|' || coalesce(p_entity_id::text, '') || '|' || p_data::text
    || '|' || to_char(p_created AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'UTF8')), 'hex')
$$;

CREATE OR REPLACE FUNCTION soulbah.audit_logs_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
DECLARE
  head soulbah.audit_chain_head%ROWTYPE;
BEGIN
  SELECT * INTO head FROM soulbah.audit_chain_head WHERE id = 1 FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO soulbah.audit_chain_head (id) VALUES (1) RETURNING * INTO head;
  END IF;
  NEW.created_at := coalesce(NEW.created_at, now());
  NEW.prev_hash  := head.last_hash;
  NEW.row_hash   := soulbah.audit_row_hash(NEW.prev_hash, NEW.id, NEW.user_id, NEW.session_id, NEW.task_id,
                                           NEW.actor, NEW.action, NEW.entity, NEW.entity_id, NEW.data, NEW.created_at);
  -- La tête avance ICI (trigger BEFORE, ligne par ligne) : un trigger AFTER ne s'exécute qu'en
  -- fin d'instruction et laisserait toutes les lignes d'un INSERT multi-lignes sur le même prev_hash.
  UPDATE soulbah.audit_chain_head
     SET last_seq = NEW.seq, last_hash = NEW.row_hash, updated_at = now()
   WHERE id = 1;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION soulbah.audit_logs_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'soulbah.audit_logs est en ajout seul : % refusé', TG_OP
    USING ERRCODE = 'insufficient_privilege';
END $$;

DROP TRIGGER IF EXISTS chain_before_insert ON soulbah.audit_logs;
CREATE TRIGGER chain_before_insert BEFORE INSERT ON soulbah.audit_logs
  FOR EACH ROW EXECUTE FUNCTION soulbah.audit_logs_before_insert();
DROP TRIGGER IF EXISTS immutable_rows ON soulbah.audit_logs;
CREATE TRIGGER immutable_rows BEFORE UPDATE OR DELETE ON soulbah.audit_logs
  FOR EACH ROW EXECUTE FUNCTION soulbah.audit_logs_immutable();
DROP TRIGGER IF EXISTS immutable_table ON soulbah.audit_logs;
CREATE TRIGGER immutable_table BEFORE TRUNCATE ON soulbah.audit_logs
  FOR EACH STATEMENT EXECUTE FUNCTION soulbah.audit_logs_immutable();

-- Vérification intégrale : première ligne dont prev_hash ou row_hash ne correspond pas.
CREATE OR REPLACE FUNCTION soulbah.verify_audit_chain(OUT ok boolean, OUT checked bigint, OUT broken_at bigint)
LANGUAGE plpgsql
STABLE
SET search_path = soulbah, pg_temp
AS $$
DECLARE
  r     record;
  prev  text := repeat('0', 64);
  n     bigint := 0;
  head  soulbah.audit_chain_head%ROWTYPE;
BEGIN
  FOR r IN SELECT * FROM soulbah.audit_logs ORDER BY seq LOOP
    IF r.prev_hash <> prev
       OR r.row_hash <> soulbah.audit_row_hash(r.prev_hash, r.id, r.user_id, r.session_id, r.task_id,
                                               r.actor, r.action, r.entity, r.entity_id, r.data, r.created_at) THEN
      ok := false; checked := n; broken_at := r.seq;
      RETURN;
    END IF;
    prev := r.row_hash;
    n := n + 1;
  END LOOP;
  SELECT * INTO head FROM soulbah.audit_chain_head WHERE id = 1;
  IF FOUND AND head.last_hash <> prev THEN
    ok := false; checked := n; broken_at := head.last_seq;
    RETURN;
  END IF;
  ok := true; checked := n; broken_at := NULL;
END $$;
