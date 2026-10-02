-- Test de 20261002111500_db14_observability.sql
DO $$
DECLARE
  n bigint; r text;
BEGIN
  PERFORM soulbah.assert_table_shape('soulbah.health_events', '{"component": "text", "status": "text", "observed_at": "timestamp with time zone"}');
  PERFORM soulbah.assert_table_shape('soulbah.system_health', '{"component": "text", "status": "text", "checked_at": "timestamp with time zone"}');
  -- Contrôles : délai < cadence
  BEGIN
    INSERT INTO soulbah.health_checks (key, component, kind, interval_s, timeout_s) VALUES ('bad', 'db', 'sql', 10, 20);
    RAISE EXCEPTION 'délai supérieur à la cadence accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.health_checks (key, component, kind, target, interval_s, timeout_s) VALUES ('db.ping', 'db', 'sql', 'SELECT 1', 30, 5);
  -- Événements : alimentent system_health ; ajout seul ; un événement plus ancien n''écrase pas un plus récent
  INSERT INTO soulbah.health_events (check_key, component, status, latency_ms, observed_at) VALUES ('db.ping', 'db', 'healthy', 3, now());
  IF (SELECT status FROM soulbah.system_health WHERE component = 'db') <> 'healthy' THEN RAISE EXCEPTION 'system_health non mis à jour'; END IF;
  INSERT INTO soulbah.health_events (check_key, component, status, previous_status, latency_ms, observed_at) VALUES ('db.ping', 'db', 'down', 'healthy', NULL, now() - interval '1 hour');
  IF (SELECT status FROM soulbah.system_health WHERE component = 'db') <> 'healthy' THEN RAISE EXCEPTION 'un événement ancien a écrasé l''état courant'; END IF;
  INSERT INTO soulbah.health_events (check_key, component, status, previous_status, observed_at) VALUES ('db.ping', 'db', 'degraded', 'healthy', now() + interval '1 second');
  IF (SELECT status FROM soulbah.system_health WHERE component = 'db') <> 'degraded' THEN RAISE EXCEPTION 'transition non appliquée'; END IF;
  BEGIN
    DELETE FROM soulbah.health_events WHERE component = 'db';
    RAISE EXCEPTION 'événement de santé supprimé';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    DELETE FROM soulbah.health_checks WHERE key = 'db.ping';
    RAISE EXCEPTION 'contrôle avec historique supprimé';
  EXCEPTION WHEN foreign_key_violation OR restrict_violation THEN NULL;
  END;
  -- Métriques : pas de modification ni de suppression directe ; purge par la fonction, rétention minimale d''un jour
  INSERT INTO soulbah.resource_metrics (host, component, metric, value, unit, observed_at) VALUES ('pc1', 'host', 'ram_used_mb', 9800, 'MB', now() - interval '40 days');
  INSERT INTO soulbah.resource_metrics (host, component, metric, value, unit) VALUES ('pc1', 'host', 'ram_used_mb', 9900, 'MB');
  BEGIN
    UPDATE soulbah.resource_metrics SET value = 0 WHERE component = 'host';
    RAISE EXCEPTION 'métrique modifiée';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    DELETE FROM soulbah.resource_metrics WHERE component = 'host';
    RAISE EXCEPTION 'métrique supprimée directement';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM soulbah.purge_resource_metrics(interval '1 hour');
    RAISE EXCEPTION 'purge sous un jour acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  n := soulbah.purge_resource_metrics(interval '30 days');
  IF n <> 1 THEN RAISE EXCEPTION 'purge : % ligne(s) au lieu de 1', n; END IF;
  IF (SELECT count(*) FROM soulbah.resource_metrics WHERE component = 'host') <> 1 THEN RAISE EXCEPTION 'la mesure récente a été purgée'; END IF;
  IF coalesce(current_setting('soulbah.retention_purge', true), '') = 'on' THEN RAISE EXCEPTION 'drapeau de purge laissé actif'; END IF;
  -- Notifications : destinataire typé ; dédoublonnage ; lecture datée
  BEGIN
    INSERT INTO soulbah.notifications (kind, title, recipient) VALUES ('alert', 'x', 'everyone');
    RAISE EXCEPTION 'destinataire libre accepté';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO soulbah.notifications (kind, severity, title, recipient, dedupe_key) VALUES ('alert', 'HIGH', 'RAM > 90 %%', 'role:pdg', 'resource.ram.high');
  BEGIN
    INSERT INTO soulbah.notifications (kind, severity, title, recipient, dedupe_key) VALUES ('alert', 'HIGH', 'RAM > 90 %% (bis)', 'role:pdg', 'resource.ram.high');
    RAISE EXCEPTION 'notification en double acceptée';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    UPDATE soulbah.notifications SET status = 'read' WHERE dedupe_key = 'resource.ram.high';
    RAISE EXCEPTION 'lecture sans date acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE soulbah.notifications SET status = 'read', sent_at = now(), read_at = now() WHERE dedupe_key = 'resource.ram.high';
  FOR r IN SELECT unnest(ARRAY['health_checks', 'health_events', 'resource_metrics', 'notifications']) LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('soulbah.' || r)::regclass) THEN RAISE EXCEPTION 'RLS absente sur %', r; END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit soulbah.%', r;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') AND has_function_privilege('anon', 'soulbah.purge_resource_metrics(interval)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon peut purger les métriques';
  END IF;
END $$;
