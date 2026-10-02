-- Test de 20261002110100_db01_core.sql (transaction annulée par le banc d'essai).
DO $$
DECLARE
  r text;
  v integer;
BEGIN
  -- Forme des tables
  PERFORM soulbah.assert_table_shape('soulbah.environments', '{"name": "text", "rank": "smallint"}');
  PERFORM soulbah.assert_table_shape('soulbah.system_state', '{"emergency_stop": "boolean", "migrations": "text"}');
  PERFORM soulbah.assert_table_shape('soulbah.system_versions', '{"component": "text", "rollback_info": "jsonb"}');
  PERFORM soulbah.assert_table_shape('soulbah.feature_flags', '{"key": "text", "enabled": "boolean", "version": "integer"}');
  -- assert_table_shape refuse une colonne absente et un type différent
  BEGIN
    PERFORM soulbah.assert_table_shape('soulbah.environments', '{"colonne_inexistante": "text"}');
    RAISE EXCEPTION 'assert_table_shape : colonne absente non détectée';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%incompatible%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM soulbah.assert_table_shape('soulbah.environments', '{"rank": "text"}');
    RAISE EXCEPTION 'assert_table_shape : type différent non détecté';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%incompatible%' THEN RAISE; END IF;
  END;

  -- Semences
  IF (SELECT count(*) FROM soulbah.environments) <> 5 THEN RAISE EXCEPTION '5 environnements attendus'; END IF;
  IF NOT (SELECT is_production FROM soulbah.environments WHERE name = 'PRODUCTION') THEN RAISE EXCEPTION 'PRODUCTION doit être marqué production'; END IF;
  IF NOT soulbah.is_environment('STAGING') OR soulbah.is_environment('PROD') THEN RAISE EXCEPTION 'is_environment'; END IF;
  IF NOT soulbah.is_autonomy_level('PRODUCTION_GUARDED') OR soulbah.is_autonomy_level('AUTO') THEN RAISE EXCEPTION 'is_autonomy_level'; END IF;
  IF (SELECT count(*) FROM soulbah.system_state) <> 1 THEN RAISE EXCEPTION 'system_state : une ligne attendue'; END IF;
  IF (SELECT internet_allowed OR external_ai_allowed OR emergency_stop OR safe_mode FROM soulbah.system_state WHERE id = 1) THEN
    RAISE EXCEPTION 'system_state : valeurs par défaut prudentes attendues';
  END IF;
  IF NOT soulbah.writes_allowed() THEN RAISE EXCEPTION 'writes_allowed doit être vrai par défaut'; END IF;

  -- STOP SOULBAH : historisé, writes_allowed passe à faux, la ligne unique ne se supprime pas
  PERFORM set_config('soulbah.change_reason', 'test : arrêt d''urgence', true);
  UPDATE soulbah.system_state SET emergency_stop = true WHERE id = 1;
  IF soulbah.writes_allowed() THEN RAISE EXCEPTION 'writes_allowed doit être faux sous STOP'; END IF;
  SELECT version INTO v FROM soulbah.system_state WHERE id = 1;
  IF v <> 2 THEN RAISE EXCEPTION 'version de system_state attendue 2, obtenue %', v; END IF;
  IF (SELECT count(*) FROM soulbah.system_state_history WHERE reason LIKE 'test :%') <> 1 THEN RAISE EXCEPTION 'historique de system_state absent'; END IF;
  IF (SELECT emergency_stop_at FROM soulbah.system_state) IS NULL THEN RAISE EXCEPTION 'emergency_stop_at non posé'; END IF;
  BEGIN
    DELETE FROM soulbah.system_state WHERE id = 1;
    RAISE EXCEPTION 'suppression de system_state acceptée';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO soulbah.system_state (id) VALUES (2);
    RAISE EXCEPTION 'deuxième ligne de system_state acceptée';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE soulbah.system_state SET production_changes = 'FULL_AUTO' WHERE id = 1;
    RAISE EXCEPTION 'valeur hors liste acceptée pour production_changes';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- Réglage immuable : refusé sans Trusted Core, accepté avec, historisé
  INSERT INTO soulbah.system_settings (key, value, critical, immutable) VALUES ('test.immutable', '"a"', true, true);
  BEGIN
    UPDATE soulbah.system_settings SET value = '"b"' WHERE key = 'test.immutable';
    RAISE EXCEPTION 'réglage immuable modifié sans Trusted Core';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('soulbah.trusted_core', 'unlocked', true);
  PERFORM set_config('soulbah.actor', 'user:pdg', true);
  UPDATE soulbah.system_settings SET value = '"b"' WHERE key = 'test.immutable';
  PERFORM set_config('soulbah.trusted_core', '', true);
  SELECT version INTO v FROM soulbah.system_settings WHERE key = 'test.immutable';
  IF v <> 2 THEN RAISE EXCEPTION 'version du réglage attendue 2'; END IF;
  IF (SELECT changed_by FROM soulbah.system_settings_history WHERE key = 'test.immutable' AND version = 2) <> 'user:pdg' THEN
    RAISE EXCEPTION 'auteur du changement non tracé';
  END IF;
  IF (SELECT count(*) FROM soulbah.system_settings_history WHERE key = 'test.immutable') <> 2 THEN
    RAISE EXCEPTION 'historique du réglage : 2 lignes attendues (création, modification)';
  END IF;
  -- Historique en ajout seul
  BEGIN
    DELETE FROM soulbah.system_settings_history WHERE key = 'test.immutable';
    RAISE EXCEPTION 'suppression de l''historique acceptée';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE soulbah.system_state_history SET reason = 'x';
    RAISE EXCEPTION 'modification de system_state_history acceptée';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- Feature flag historisé
  INSERT INTO soulbah.feature_flags (key, enabled) VALUES ('test.flag', false);
  UPDATE soulbah.feature_flags SET enabled = true WHERE key = 'test.flag';
  IF (SELECT version FROM soulbah.feature_flags WHERE key = 'test.flag') <> 2 THEN RAISE EXCEPTION 'version du flag'; END IF;
  IF (SELECT count(*) FROM soulbah.feature_flags_history WHERE key = 'test.flag') <> 2 THEN RAISE EXCEPTION 'historique du flag'; END IF;

  -- Versions : unicité composant + version
  INSERT INTO soulbah.system_versions (component, version) VALUES ('test.component', '1.0.0');
  BEGIN
    INSERT INTO soulbah.system_versions (component, version) VALUES ('test.component', '1.0.0');
    RAISE EXCEPTION 'doublon de version accepté';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  -- RLS et droits
  FOR r IN SELECT unnest(ARRAY['environments', 'system_settings', 'system_settings_history', 'system_state',
                                'system_state_history', 'system_versions', 'system_health', 'feature_flags',
                                'feature_flags_history']) LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('soulbah.' || r)::regclass) THEN
      RAISE EXCEPTION 'RLS non activée sur soulbah.%', r;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') AND has_table_privilege('anon', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'anon lit soulbah.%', r;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') AND has_table_privilege('authenticated', 'soulbah.' || r, 'SELECT') THEN
      RAISE EXCEPTION 'authenticated lit soulbah.%', r;
    END IF;
  END LOOP;
END $$;
