-- =============================================================================
-- DB LOT 14 — Observabilité : définitions de contrôles de santé, événements de santé (ajout seul, alimentent
-- system_health), métriques de ressources (ajout seul avec purge contrôlée), notifications au PDG (§51, §88).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002111500_db14_observability.down.sql (les séries de mesures seraient perdues)
-- soulbah:transaction=single
-- Dépend de : db01 (system_health).
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.health_checks (
  key               text PRIMARY KEY CONSTRAINT health_checks_key_format CHECK (key ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  component         text NOT NULL CONSTRAINT health_checks_component_format CHECK (component ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  kind              text NOT NULL CONSTRAINT health_checks_kind_check CHECK (kind IN ('http', 'tcp', 'sql', 'process', 'file', 'queue', 'model', 'custom')),
  target            text NOT NULL DEFAULT '' CONSTRAINT health_checks_target_length CHECK (length(target) <= 500),
  interval_s        integer NOT NULL DEFAULT 60 CONSTRAINT health_checks_interval_range CHECK (interval_s BETWEEN 5 AND 86400),
  timeout_s         integer NOT NULL DEFAULT 10 CONSTRAINT health_checks_timeout_range CHECK (timeout_s BETWEEN 1 AND 600),
  enabled           boolean NOT NULL DEFAULT true,
  severity_on_fail  text NOT NULL DEFAULT 'MEDIUM' CONSTRAINT health_checks_severity_check CHECK (soulbah.is_severity(severity_on_fail)),
  description       text NOT NULL DEFAULT '' CONSTRAINT health_checks_description_length CHECK (length(description) <= 1000),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT health_checks_timeout_lt_interval CHECK (timeout_s < interval_s)
);
COMMENT ON TABLE soulbah.health_checks IS 'Contrôles de santé déclarés (composant, genre, cible, cadence, sévérité en cas d''échec) ; enregistrés par node-api au démarrage.';
ALTER TABLE soulbah.health_checks ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.health_checks', '{"key": "text", "component": "text", "interval_s": "integer", "enabled": "boolean"}');
CREATE INDEX IF NOT EXISTS idx_health_checks_component ON soulbah.health_checks (component);
DROP TRIGGER IF EXISTS health_checks_set_updated_at ON soulbah.health_checks;
CREATE TRIGGER health_checks_set_updated_at BEFORE UPDATE ON soulbah.health_checks FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.health_events (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  check_key        text REFERENCES soulbah.health_checks(key) ON DELETE RESTRICT,
  component        text NOT NULL CONSTRAINT health_events_component_format CHECK (component ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  status           text NOT NULL CONSTRAINT health_events_status_check CHECK (status IN ('healthy', 'degraded', 'down', 'unknown')),
  previous_status  text CONSTRAINT health_events_previous_check CHECK (previous_status IS NULL OR previous_status IN ('healthy', 'degraded', 'down', 'unknown')),
  latency_ms       integer CONSTRAINT health_events_latency_positive CHECK (latency_ms IS NULL OR latency_ms >= 0),
  detail           jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT health_events_detail_object CHECK (soulbah.is_json_object(detail)),
  observed_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.health_events IS 'Résultats des contrôles de santé (ajout seul) ; chaque événement met à jour soulbah.system_health pour son composant.';
ALTER TABLE soulbah.health_events ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_health_events_component ON soulbah.health_events (component, id DESC);
CREATE INDEX IF NOT EXISTS idx_health_events_check ON soulbah.health_events (check_key);
CREATE INDEX IF NOT EXISTS idx_health_events_transitions ON soulbah.health_events (observed_at DESC) WHERE previous_status IS DISTINCT FROM status;
DROP TRIGGER IF EXISTS health_events_append_only ON soulbah.health_events;
CREATE TRIGGER health_events_append_only BEFORE UPDATE OR DELETE ON soulbah.health_events FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS health_events_no_truncate ON soulbah.health_events;
CREATE TRIGGER health_events_no_truncate BEFORE TRUNCATE ON soulbah.health_events FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE OR REPLACE FUNCTION soulbah.health_events_apply()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  INSERT INTO soulbah.system_health (component, status, detail, checked_at)
  VALUES (NEW.component, NEW.status, NEW.detail || jsonb_build_object('check_key', NEW.check_key, 'latency_ms', NEW.latency_ms), NEW.observed_at)
  ON CONFLICT (component) DO UPDATE
    SET status = EXCLUDED.status, detail = EXCLUDED.detail, checked_at = EXCLUDED.checked_at
    WHERE soulbah.system_health.checked_at IS NULL OR soulbah.system_health.checked_at <= EXCLUDED.checked_at;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS health_events_apply ON soulbah.health_events;
CREATE TRIGGER health_events_apply AFTER INSERT ON soulbah.health_events FOR EACH ROW EXECUTE FUNCTION soulbah.health_events_apply();

-- Métriques : ajout seul, mais purge possible par la seule fonction de rétention (jamais de DELETE direct).
CREATE TABLE IF NOT EXISTS soulbah.resource_metrics (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  host         text NOT NULL DEFAULT '' CONSTRAINT resource_metrics_host_length CHECK (length(host) <= 200),
  component    text NOT NULL CONSTRAINT resource_metrics_component_format CHECK (component ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  metric       text NOT NULL CONSTRAINT resource_metrics_metric_format CHECK (metric ~ '^[a-z][a-z0-9_.]{0,99}$'),
  value        numeric(18, 4) NOT NULL,
  unit         text NOT NULL DEFAULT '' CONSTRAINT resource_metrics_unit_length CHECK (length(unit) <= 40),
  labels       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT resource_metrics_labels_object CHECK (soulbah.is_json_object(labels)),
  observed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.resource_metrics IS 'Séries de mesures (CPU, RAM, GPU, VRAM, disque, base, modèles, agents, files) ; ajout seul, purge par soulbah.purge_resource_metrics() uniquement.';
ALTER TABLE soulbah.resource_metrics ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_resource_metrics_lookup ON soulbah.resource_metrics (metric, component, observed_at DESC);
CREATE INDEX IF NOT EXISTS idx_resource_metrics_time ON soulbah.resource_metrics (observed_at);

CREATE OR REPLACE FUNCTION soulbah.retention_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'soulbah.% est en ajout seul (UPDATE refusé)', TG_TABLE_NAME USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF coalesce(current_setting('soulbah.retention_purge', true), '') <> 'on' THEN
    RAISE EXCEPTION 'soulbah.% : suppression réservée à la purge de rétention (% refusé)', TG_TABLE_NAME, TG_OP USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN COALESCE(OLD, NEW);
END $$;
COMMENT ON FUNCTION soulbah.retention_guard() IS 'Trigger : refuse UPDATE ; refuse DELETE/TRUNCATE sauf sous soulbah.retention_purge = on (posé par la fonction de purge).';
DROP TRIGGER IF EXISTS resource_metrics_retention ON soulbah.resource_metrics;
CREATE TRIGGER resource_metrics_retention BEFORE UPDATE OR DELETE ON soulbah.resource_metrics FOR EACH ROW EXECUTE FUNCTION soulbah.retention_guard();
DROP TRIGGER IF EXISTS resource_metrics_no_truncate ON soulbah.resource_metrics;
CREATE TRIGGER resource_metrics_no_truncate BEFORE TRUNCATE ON soulbah.resource_metrics FOR EACH STATEMENT EXECUTE FUNCTION soulbah.retention_guard();

CREATE OR REPLACE FUNCTION soulbah.purge_resource_metrics(p_older_than interval DEFAULT interval '30 days')
RETURNS bigint LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
DECLARE n bigint;
BEGIN
  IF p_older_than < interval '1 day' THEN
    RAISE EXCEPTION 'soulbah.purge_resource_metrics : rétention minimale d''un jour' USING ERRCODE = 'check_violation';
  END IF;
  PERFORM set_config('soulbah.retention_purge', 'on', true);
  DELETE FROM soulbah.resource_metrics WHERE observed_at < now() - p_older_than;
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM set_config('soulbah.retention_purge', '', true);
  RETURN n;
END $$;
COMMENT ON FUNCTION soulbah.purge_resource_metrics(interval) IS 'Purge des mesures plus anciennes que l''intervalle (minimum un jour) ; seul chemin de suppression ; renvoie le nombre de lignes purgées.';

CREATE TABLE IF NOT EXISTS soulbah.notifications (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind          text NOT NULL CONSTRAINT notifications_kind_check CHECK (kind IN ('alert', 'approval_request', 'incident', 'report', 'info', 'watchdog', 'resource')),
  severity      text NOT NULL DEFAULT 'INFO' CONSTRAINT notifications_severity_check CHECK (soulbah.is_severity(severity)),
  title         text NOT NULL CONSTRAINT notifications_title_length CHECK (length(title) BETWEEN 1 AND 300),
  body          text NOT NULL DEFAULT '' CONSTRAINT notifications_body_length CHECK (length(body) <= 8000),
  recipient     text NOT NULL CONSTRAINT notifications_recipient_format CHECK (recipient ~ '^(user:[0-9a-f-]{36}|role:[a-z_]+|all)$'),
  channel       text NOT NULL DEFAULT 'ui' CONSTRAINT notifications_channel_check CHECK (channel IN ('ui', 'email', 'sms', 'push', 'log')),
  status        text NOT NULL DEFAULT 'pending' CONSTRAINT notifications_status_check CHECK (status IN ('pending', 'sent', 'delivered', 'read', 'failed', 'dismissed', 'expired')),
  related_kind  text CONSTRAINT notifications_related_kind_length CHECK (related_kind IS NULL OR length(related_kind) <= 60),
  related_id    uuid,
  dedupe_key    text UNIQUE CONSTRAINT notifications_dedupe_length CHECK (dedupe_key IS NULL OR length(dedupe_key) <= 300),
  action_url    text CONSTRAINT notifications_action_url_length CHECK (action_url IS NULL OR length(action_url) <= 1000),
  created_at    timestamptz NOT NULL DEFAULT now(),
  sent_at       timestamptz,
  read_at       timestamptz,
  expires_at    timestamptz,
  CONSTRAINT notifications_read_dated CHECK (status <> 'read' OR read_at IS NOT NULL),
  CONSTRAINT notifications_sent_dated CHECK (status NOT IN ('sent', 'delivered', 'read') OR sent_at IS NOT NULL)
);
COMMENT ON TABLE soulbah.notifications IS 'Notifications au PDG et aux rôles (alertes, demandes d''approbation, incidents, rapports) : destinataire, canal, dédoublonnage, cycle envoi/lecture.';
ALTER TABLE soulbah.notifications ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_notifications_recipient ON soulbah.notifications (recipient, created_at DESC) WHERE status IN ('pending', 'sent', 'delivered');
CREATE INDEX IF NOT EXISTS idx_notifications_related ON soulbah.notifications (related_kind, related_id);

DO $$
DECLARE r text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['health_checks', 'health_events', 'resource_metrics', 'notifications'] LOOP
    EXECUTE format('REVOKE ALL ON soulbah.%I FROM PUBLIC', t);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON soulbah.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
  REVOKE ALL ON FUNCTION soulbah.purge_resource_metrics(interval) FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.health_events_apply(), soulbah.retention_guard(), soulbah.purge_resource_metrics(interval) FROM %I', r);
    END IF;
  END LOOP;
END $$;
