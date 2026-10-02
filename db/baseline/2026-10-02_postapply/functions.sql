-- public.agent_tasks_keep_updated_at_on_control()
CREATE OR REPLACE FUNCTION public.agent_tasks_keep_updated_at_on_control()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF (to_jsonb(NEW) - 'control' - 'updated_at') IS NOT DISTINCT FROM
     (to_jsonb(OLD) - 'control' - 'updated_at') THEN
    NEW.updated_at := OLD.updated_at;
  END IF;
  RETURN NEW;
END;
$function$
;

-- public.agent_tasks_set_updated_at()
CREATE OR REPLACE FUNCTION public.agent_tasks_set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  key_cols CONSTANT text[] := ARRAY['target_agent_key_id', 'claimed_by_key_id'];
BEGIN
  IF (to_jsonb(NEW) - 'control' - 'updated_at' - key_cols) IS DISTINCT FROM
     (to_jsonb(OLD) - 'control' - 'updated_at' - key_cols) THEN
    NEW.updated_at := now();
  ELSIF (NEW.target_agent_key_id IS DISTINCT FROM OLD.target_agent_key_id
         AND NEW.target_agent_key_id IS NOT NULL)
     OR (NEW.claimed_by_key_id IS DISTINCT FROM OLD.claimed_by_key_id
         AND NEW.claimed_by_key_id IS NOT NULL) THEN
    NEW.updated_at := now();
  ELSIF NEW.target_agent_key_id IS DISTINCT FROM OLD.target_agent_key_id
     OR NEW.claimed_by_key_id IS DISTINCT FROM OLD.claimed_by_key_id THEN
    NEW.updated_at := OLD.updated_at;
  ELSIF NEW.control IS DISTINCT FROM OLD.control THEN
    NEW.updated_at := OLD.updated_at;
  ELSE
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$function$
;

-- public.handle_new_user()
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

BEGIN

  INSERT INTO public.profiles (user_id, display_name)

  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'display_name', NEW.email));

  INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'user');

  RETURN NEW;

END;

$function$
;

-- public.has_role(_user_id uuid, _role app_role)
CREATE OR REPLACE FUNCTION public.has_role(_user_id uuid, _role app_role)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)

$function$
;

-- public.is_admin()
CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM public.user_roles
     WHERE user_id = auth.uid()
       AND role = 'admin'::public.app_role
  )
$function$
;

-- public.rls_auto_enable()
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$
;

-- public.update_updated_at_column()
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$

BEGIN

  NEW.updated_at = now();

  RETURN NEW;

END;

$function$
;

-- soulbah.agent_quarantine_apply()
CREATE OR REPLACE FUNCTION soulbah.agent_quarantine_apply()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF NEW.status = 'active' THEN
    UPDATE soulbah.agent_definitions SET status = 'quarantined' WHERE id = NEW.definition_id AND status <> 'retired';
    INSERT INTO soulbah.agent_status (definition_id, status, quarantined_at) VALUES (NEW.definition_id, 'quarantined', now())
    ON CONFLICT (definition_id) DO UPDATE SET status = 'quarantined', quarantined_at = now();
  ELSIF TG_OP = 'UPDATE' AND OLD.status = 'active' AND NEW.status = 'lifted'
        AND NOT EXISTS (SELECT 1 FROM soulbah.agent_quarantines q WHERE q.definition_id = NEW.definition_id AND q.status = 'active' AND q.id <> NEW.id) THEN
    UPDATE soulbah.agent_definitions SET status = 'suspended' WHERE id = NEW.definition_id AND status = 'quarantined';
    UPDATE soulbah.agent_status SET status = 'suspended', quarantined_at = NULL WHERE definition_id = NEW.definition_id;
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.append_only()
CREATE OR REPLACE FUNCTION soulbah.append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  RAISE EXCEPTION 'soulbah.% est en ajout seul (% refusé)', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'insufficient_privilege';
END $function$
;

-- soulbah.assert_table_shape(p_table regclass, p_columns jsonb)
CREATE OR REPLACE FUNCTION soulbah.assert_table_shape(p_table regclass, p_columns jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
  k text;
  expected text;
  actual text;
BEGIN
  IF p_columns IS NULL OR jsonb_typeof(p_columns) <> 'object' THEN
    RAISE EXCEPTION 'assert_table_shape(%) : objet JSON attendu', p_table;
  END IF;
  FOR k, expected IN SELECT key, value #>> '{}' FROM jsonb_each(p_columns) LOOP
    SELECT format_type(a.atttypid, a.atttypmod) INTO actual
      FROM pg_attribute a WHERE a.attrelid = p_table AND a.attname = k AND a.attnum > 0 AND NOT a.attisdropped;
    IF actual IS NULL THEN
      RAISE EXCEPTION 'table % : colonne « % » attendue (%), absente — structure incompatible, migration arrêtée',
        p_table, k, expected;
    END IF;
    IF lower(actual) <> lower(expected)
       AND NOT (lower(expected) LIKE 'vector%' AND lower(actual) = 'real[]') THEN
      RAISE EXCEPTION 'table % : colonne « % » de type %, attendu % — structure incompatible, migration arrêtée',
        p_table, k, actual, expected;
    END IF;
  END LOOP;
END $function$
;

-- soulbah.audit_logs_before_insert()
CREATE OR REPLACE FUNCTION soulbah.audit_logs_before_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
DECLARE
  head soulbah.audit_chain_head%ROWTYPE;
BEGIN
  SELECT * INTO head FROM soulbah.audit_chain_head WHERE id = 1 FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO soulbah.audit_chain_head (id) VALUES (1) RETURNING * INTO head;
  END IF;
  NEW.created_at := coalesce(NEW.created_at, now());
  NEW.seq        := head.last_seq + 1;
  NEW.prev_hash  := head.last_hash;
  NEW.row_hash   := soulbah.audit_row_hash(NEW.prev_hash, NEW.id, NEW.user_id, NEW.session_id, NEW.task_id,
                                           NEW.actor, NEW.action, NEW.entity, NEW.entity_id, NEW.data, NEW.created_at);
  -- La tête avance ICI (trigger BEFORE, ligne par ligne) : un trigger AFTER ne s'exécute qu'en
  -- fin d'instruction et laisserait toutes les lignes d'un INSERT multi-lignes sur le même prev_hash.
  UPDATE soulbah.audit_chain_head
     SET last_seq = NEW.seq, last_hash = NEW.row_hash, updated_at = now()
   WHERE id = 1;
  RETURN NEW;
END $function$
;

-- soulbah.audit_logs_immutable()
CREATE OR REPLACE FUNCTION soulbah.audit_logs_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  RAISE EXCEPTION 'soulbah.audit_logs est en ajout seul : % refusé', TG_OP
    USING ERRCODE = 'insufficient_privilege';
END $function$
;

-- soulbah.audit_row_hash(p_prev text, p_id uuid, p_user uuid, p_session uuid, p_task uuid, p_actor text, p_action text, p_entity text, p_entity_id uuid, p_data jsonb, p_created timestamp with time zone)
CREATE OR REPLACE FUNCTION soulbah.audit_row_hash(p_prev text, p_id uuid, p_user uuid, p_session uuid, p_task uuid, p_actor text, p_action text, p_entity text, p_entity_id uuid, p_data jsonb, p_created timestamp with time zone)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT encode(sha256(convert_to(
    p_prev || '|' || p_id::text || '|' || coalesce(p_user::text, '') || '|' || coalesce(p_session::text, '')
    || '|' || coalesce(p_task::text, '') || '|' || p_actor || '|' || p_action || '|' || coalesce(p_entity, '')
    || '|' || coalesce(p_entity_id::text, '') || '|' || p_data::text
    || '|' || to_char(p_created AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'UTF8')), 'hex')
$function$
;

-- soulbah.autonomy_rules_track()
CREATE OR REPLACE FUNCTION soulbah.autonomy_rules_track()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO soulbah.autonomy_rules_history (rule_id, old_level, new_level, version, changed_by, reason)
    VALUES (NEW.id, NULL, NEW.level, NEW.version, soulbah.change_actor(), soulbah.change_reason());
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.level IS DISTINCT FROM OLD.level THEN
      NEW.version := OLD.version + 1;
      NEW.updated_at := now();
      NEW.set_by := soulbah.change_actor();
      INSERT INTO soulbah.autonomy_rules_history (rule_id, old_level, new_level, version, changed_by, reason)
      VALUES (OLD.id, OLD.level, NEW.level, NEW.version, NEW.set_by, soulbah.change_reason());
    END IF;
    RETURN NEW;
  END IF;
  INSERT INTO soulbah.autonomy_rules_history (rule_id, old_level, new_level, version, changed_by, reason)
  VALUES (OLD.id, OLD.level, NULL, OLD.version + 1, soulbah.change_actor(), soulbah.change_reason());
  RETURN OLD;
END $function$
;

-- soulbah.benchmark_tasks_freeze()
CREATE OR REPLACE FUNCTION soulbah.benchmark_tasks_freeze()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
DECLARE v uuid;
BEGIN
  v := COALESCE(NEW.benchmark_version_id, OLD.benchmark_version_id);
  IF EXISTS (SELECT 1 FROM soulbah.benchmark_versions b WHERE b.id = v AND b.frozen) THEN
    RAISE EXCEPTION 'soulbah.benchmark_tasks : version de benchmark gelée — % refusé', TG_OP USING ERRCODE = 'check_violation';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $function$
;

-- soulbah.change_actor()
CREATE OR REPLACE FUNCTION soulbah.change_actor()
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$ SELECT coalesce(nullif(current_setting('soulbah.actor', true), ''), current_user) $function$
;

-- soulbah.change_reason()
CREATE OR REPLACE FUNCTION soulbah.change_reason()
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$ SELECT nullif(current_setting('soulbah.change_reason', true), '') $function$
;

-- soulbah.feature_flags_track()
CREATE OR REPLACE FUNCTION soulbah.feature_flags_track()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    NEW.version := OLD.version + 1;
    NEW.updated_at := now();
    NEW.updated_by := soulbah.change_actor();
    INSERT INTO soulbah.feature_flags_history (key, old_state, new_state, version, changed_by, reason)
    VALUES (OLD.key, to_jsonb(OLD), to_jsonb(NEW), NEW.version, NEW.updated_by, soulbah.change_reason());
    RETURN NEW;
  ELSIF TG_OP = 'INSERT' THEN
    INSERT INTO soulbah.feature_flags_history (key, old_state, new_state, version, changed_by, reason)
    VALUES (NEW.key, NULL, to_jsonb(NEW), NEW.version, soulbah.change_actor(), soulbah.change_reason());
    RETURN NEW;
  END IF;
  INSERT INTO soulbah.feature_flags_history (key, old_state, new_state, version, changed_by, reason)
  VALUES (OLD.key, to_jsonb(OLD), NULL, OLD.version + 1, soulbah.change_actor(), soulbah.change_reason());
  RETURN OLD;
END $function$
;

-- soulbah.guardrails_track()
CREATE OR REPLACE FUNCTION soulbah.guardrails_track()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
DECLARE why text := soulbah.change_reason();
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO soulbah.guardrail_versions (guardrail_id, version, old_level, new_level, old_value, new_value, changed_by, justification)
    VALUES (NEW.id, NEW.version, NULL, NEW.level, NULL, NEW.value, soulbah.change_actor(), why);
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.value IS DISTINCT FROM OLD.value OR NEW.level IS DISTINCT FROM OLD.level
       OR NEW.critical IS DISTINCT FROM OLD.critical OR NEW.immutable IS DISTINCT FROM OLD.immutable THEN
      IF (OLD.critical OR NEW.critical) AND why IS NULL THEN
        RAISE EXCEPTION 'soulbah.guardrails : justification requise pour modifier un garde-fou critique (SET LOCAL soulbah.change_reason)'
          USING ERRCODE = 'check_violation';
      END IF;
      NEW.version := OLD.version + 1;
      NEW.updated_at := now();
      NEW.updated_by := soulbah.change_actor();
      INSERT INTO soulbah.guardrail_versions (guardrail_id, version, old_level, new_level, old_value, new_value, changed_by, justification)
      VALUES (OLD.id, NEW.version, OLD.level, NEW.level, OLD.value, NEW.value, NEW.updated_by, why);
    END IF;
    RETURN NEW;
  END IF;
  INSERT INTO soulbah.guardrail_versions (guardrail_id, version, old_level, new_level, old_value, new_value, changed_by, justification)
  VALUES (OLD.id, OLD.version + 1, OLD.level, NULL, OLD.value, NULL, soulbah.change_actor(), why);
  RETURN OLD;
END $function$
;

-- soulbah.health_events_apply()
CREATE OR REPLACE FUNCTION soulbah.health_events_apply()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  INSERT INTO soulbah.system_health (component, status, detail, checked_at)
  VALUES (NEW.component, NEW.status, NEW.detail || jsonb_build_object('check_key', NEW.check_key, 'latency_ms', NEW.latency_ms), NEW.observed_at)
  ON CONFLICT (component) DO UPDATE
    SET status = EXCLUDED.status, detail = EXCLUDED.detail, checked_at = EXCLUDED.checked_at
    WHERE soulbah.system_health.checked_at IS NULL OR soulbah.system_health.checked_at <= EXCLUDED.checked_at;
  RETURN NEW;
END $function$
;

-- soulbah.improvement_deployments_guard()
CREATE OR REPLACE FUNCTION soulbah.improvement_deployments_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
DECLARE st soulbah.system_state%ROWTYPE; ap soulbah.improvement_approvals%ROWTYPE;
BEGIN
  SELECT * INTO ap FROM soulbah.improvement_approvals WHERE id = NEW.approval_id;
  IF ap.candidate_id IS DISTINCT FROM NEW.candidate_id OR ap.decision <> 'approved' THEN
    RAISE EXCEPTION 'soulbah.improvement_deployments : approbation absente, refusée ou d''un autre candidat' USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM soulbah.improvement_approvals r WHERE r.candidate_id = NEW.candidate_id AND r.decision = 'revoked' AND r.id > ap.id) THEN
    RAISE EXCEPTION 'soulbah.improvement_deployments : approbation révoquée' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.status IN ('deployed', 'verified') AND (TG_OP = 'INSERT' OR OLD.status NOT IN ('deployed', 'verified')) THEN
    IF NOT EXISTS (SELECT 1 FROM soulbah.improvement_candidates c WHERE c.id = NEW.candidate_id AND c.status IN ('approved', 'deployed')) THEN
      RAISE EXCEPTION 'soulbah.improvement_deployments : le candidat n''est pas approuvé' USING ERRCODE = 'check_violation';
    END IF;
    SELECT * INTO st FROM soulbah.system_state WHERE id = 1;
    IF st.self_improvement = 'OFF' OR st.safe_mode OR st.emergency_stop THEN
      RAISE EXCEPTION 'soulbah.improvement_deployments : auto-amélioration désactivée (system_state.self_improvement = %, safe_mode = %, emergency_stop = %)',
        st.self_improvement, st.safe_mode, st.emergency_stop USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.environment_name = 'PRODUCTION' AND st.production_changes = 'OFF' THEN
      RAISE EXCEPTION 'soulbah.improvement_deployments : changements de production désactivés (system_state.production_changes = OFF)' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.incidents_log_status()
CREATE OR REPLACE FUNCTION soulbah.incidents_log_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO soulbah.incident_events (incident_id, kind, actor, message, detail)
    VALUES (NEW.id, 'detected', NEW.detected_by, NEW.title, jsonb_build_object('severity', NEW.severity, 'kind', NEW.kind));
  ELSIF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO soulbah.incident_events (incident_id, kind, actor, message, detail)
    VALUES (NEW.id, 'status_change', COALESCE(soulbah.change_actor(), current_user), COALESCE(soulbah.change_reason(), ''),
            jsonb_build_object('from', OLD.status, 'to', NEW.status));
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.is_autonomy_level(p text)
CREATE OR REPLACE FUNCTION soulbah.is_autonomy_level(p text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT p IN ('OBSERVE', 'ASSIST', 'LAB', 'SAFE_AUTO', 'ADVANCED_AUTO', 'PRODUCTION_GUARDED') $function$
;

-- soulbah.is_environment(p text)
CREATE OR REPLACE FUNCTION soulbah.is_environment(p text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT p IN ('LOCAL', 'DEV', 'TEST', 'STAGING', 'PRODUCTION') $function$
;

-- soulbah.is_json_array(p jsonb)
CREATE OR REPLACE FUNCTION soulbah.is_json_array(p jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT p IS NOT NULL AND jsonb_typeof(p) = 'array' $function$
;

-- soulbah.is_json_object(p jsonb)
CREATE OR REPLACE FUNCTION soulbah.is_json_object(p jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT p IS NOT NULL AND jsonb_typeof(p) = 'object' $function$
;

-- soulbah.is_security_level(p text)
CREATE OR REPLACE FUNCTION soulbah.is_security_level(p text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT p IN ('L0', 'L1', 'L2', 'L3') $function$
;

-- soulbah.is_severity(p text)
CREATE OR REPLACE FUNCTION soulbah.is_severity(p text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT p IN ('INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL') $function$
;

-- soulbah.memory_contradictions_apply()
CREATE OR REPLACE FUNCTION soulbah.memory_contradictions_apply()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF NEW.status = 'resolved_a' THEN
    UPDATE soulbah.memory_items SET status = 'INVALID' WHERE id = NEW.memory_b AND status <> 'ARCHIVED';
  ELSIF NEW.status = 'resolved_b' THEN
    UPDATE soulbah.memory_items SET status = 'INVALID' WHERE id = NEW.memory_a AND status <> 'ARCHIVED';
  ELSIF NEW.status = 'both_invalid' THEN
    UPDATE soulbah.memory_items SET status = 'INVALID' WHERE id IN (NEW.memory_a, NEW.memory_b) AND status <> 'ARCHIVED';
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.memory_items_revalidate()
CREATE OR REPLACE FUNCTION soulbah.memory_items_revalidate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF NEW.content IS DISTINCT FROM OLD.content OR NEW.content_artifact_id IS DISTINCT FROM OLD.content_artifact_id THEN
    NEW.version := OLD.version + 1;
    IF OLD.validation_status = 'validated' AND NEW.validation_status = 'validated' AND NEW.validated_at IS NOT DISTINCT FROM OLD.validated_at THEN
      NEW.validation_status := 'candidate';   -- un contenu modifié n'est plus validé tant qu'il n'est pas revalidé
      NEW.validated_by := NULL;
      NEW.validated_at := NULL;
    END IF;
  END IF;
  IF NEW.validation_status = 'validated' AND OLD.validation_status <> 'validated' AND NEW.validated_at IS NULL THEN
    NEW.validated_at := now();
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.memory_relationships_apply()
CREATE OR REPLACE FUNCTION soulbah.memory_relationships_apply()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF NEW.kind = 'supersedes' THEN
    UPDATE soulbah.memory_items SET status = 'SUPERSEDED' WHERE id = NEW.to_id AND status IN ('ACTIVE', 'STALE');
    UPDATE soulbah.memory_items SET supersedes_id = NEW.to_id WHERE id = NEW.from_id AND supersedes_id IS NULL;
  ELSIF NEW.kind = 'contradicts' THEN
    INSERT INTO soulbah.memory_contradictions (memory_a, memory_b, detected_by)
    VALUES (least(NEW.from_id, NEW.to_id), greatest(NEW.from_id, NEW.to_id), NEW.created_by)
    ON CONFLICT (memory_a, memory_b) DO NOTHING;
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.model_routing_rules_guard()
CREATE OR REPLACE FUNCTION soulbah.model_routing_rules_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF NEW.enabled AND NOT EXISTS (SELECT 1 FROM soulbah.model_versions v WHERE v.id = NEW.model_version_id AND v.status = 'active') THEN
    RAISE EXCEPTION 'soulbah.model_routing_rules : la cible doit être une version de modèle active' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.model_versions_guard()
CREATE OR REPLACE FUNCTION soulbah.model_versions_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF NEW.status IN ('active', 'shadow') AND (TG_OP = 'INSERT' OR OLD.status NOT IN ('active', 'shadow')) THEN
    IF NEW.sha256 IS NULL AND NEW.source_kind <> 'vendor_api' THEN
      RAISE EXCEPTION 'soulbah.model_versions : activation refusée — empreinte SHA-256 absente' USING ERRCODE = 'check_violation';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM soulbah.model_security_status s WHERE s.version_id = NEW.id AND s.status = 'approved') THEN
      RAISE EXCEPTION 'soulbah.model_versions : activation refusée — statut de sécurité non approuvé' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.policy_versions_freeze()
CREATE OR REPLACE FUNCTION soulbah.policy_versions_freeze()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF NEW.rules IS DISTINCT FROM OLD.rules OR NEW.version <> OLD.version OR NEW.policy_id <> OLD.policy_id THEN
    RAISE EXCEPTION 'soulbah.policy_versions : une version publiée ne se modifie pas (créer une nouvelle version)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.protect_immutable()
CREATE OR REPLACE FUNCTION soulbah.protect_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF (TG_OP = 'DELETE' AND OLD.immutable) OR (TG_OP = 'UPDATE' AND (OLD.immutable OR NEW.immutable)) THEN
    IF NOT soulbah.trusted_core_unlocked() THEN
      RAISE EXCEPTION 'soulbah.% : ligne protégée (Trusted Core) — modification refusée hors du chemin habilité',
        TG_TABLE_NAME USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $function$
;

-- soulbah.purge_resource_metrics(p_older_than interval)
CREATE OR REPLACE FUNCTION soulbah.purge_resource_metrics(p_older_than interval DEFAULT '30 days'::interval)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
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
END $function$
;

-- soulbah.retention_guard()
CREATE OR REPLACE FUNCTION soulbah.retention_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'soulbah.% est en ajout seul (UPDATE refusé)', TG_TABLE_NAME USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF coalesce(current_setting('soulbah.retention_purge', true), '') <> 'on' THEN
    RAISE EXCEPTION 'soulbah.% : suppression réservée à la purge de rétention (% refusé)', TG_TABLE_NAME, TG_OP USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN COALESCE(OLD, NEW);
END $function$
;

-- soulbah.schema_migration_runs_append_only()
CREATE OR REPLACE FUNCTION soulbah.schema_migration_runs_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$

BEGIN

  RAISE EXCEPTION 'soulbah.schema_migration_runs est en ajout seul (% refusé)', TG_OP;

END $function$
;

-- soulbah.security_findings_pattern_stats()
CREATE OR REPLACE FUNCTION soulbah.security_findings_pattern_stats()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF NEW.pattern_id IS NOT NULL AND (TG_OP = 'INSERT' OR OLD.pattern_id IS DISTINCT FROM NEW.pattern_id) THEN
    UPDATE soulbah.security_patterns p
       SET occurrences = p.occurrences + 1,
           first_seen_at = LEAST(COALESCE(p.first_seen_at, NEW.detected_at), NEW.detected_at),
           last_seen_at = GREATEST(COALESCE(p.last_seen_at, NEW.detected_at), NEW.detected_at),
           projects_affected = CASE WHEN NEW.project_id IS NULL OR p.projects_affected ? NEW.project_id::text THEN p.projects_affected
                                    ELSE p.projects_affected || to_jsonb(NEW.project_id::text) END
     WHERE p.id = NEW.pattern_id;
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.sessions_default_result()
CREATE OR REPLACE FUNCTION soulbah.sessions_default_result()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF NEW.status IN ('COMPLETED', 'FAILED', 'CANCELLED') AND NEW.result IS NULL THEN
    NEW.result := CASE NEW.status WHEN 'FAILED' THEN 'failure' WHEN 'CANCELLED' THEN 'cancelled' WHEN 'COMPLETED' THEN CASE WHEN NEW.simulated THEN 'partial' ELSE 'success' END END;
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.set_updated_at()
CREATE OR REPLACE FUNCTION soulbah.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $function$
;

-- soulbah.skill_versions_guard()
CREATE OR REPLACE FUNCTION soulbah.skill_versions_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF NEW.status = 'active' AND (TG_OP = 'INSERT' OR OLD.status <> 'active') THEN
    IF NOT EXISTS (SELECT 1 FROM soulbah.skill_tests t WHERE t.version_id = NEW.id AND t.last_result = 'passed')
       OR EXISTS (SELECT 1 FROM soulbah.skill_tests t WHERE t.version_id = NEW.id AND t.last_result = 'failed') THEN
      RAISE EXCEPTION 'soulbah.skill_versions : activation refusée — au moins un test passé et aucun test en échec'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.system_settings_track()
CREATE OR REPLACE FUNCTION soulbah.system_settings_track()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.value IS DISTINCT FROM OLD.value OR NEW.immutable IS DISTINCT FROM OLD.immutable
       OR NEW.critical IS DISTINCT FROM OLD.critical THEN
      NEW.version := OLD.version + 1;
      NEW.updated_at := now();
      NEW.updated_by := soulbah.change_actor();
      INSERT INTO soulbah.system_settings_history (key, old_value, new_value, version, changed_by, reason)
      VALUES (OLD.key, OLD.value, NEW.value, NEW.version, NEW.updated_by, soulbah.change_reason());
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'INSERT' THEN
    INSERT INTO soulbah.system_settings_history (key, old_value, new_value, version, changed_by, reason)
    VALUES (NEW.key, NULL, NEW.value, NEW.version, soulbah.change_actor(), soulbah.change_reason());
    RETURN NEW;
  END IF;
  INSERT INTO soulbah.system_settings_history (key, old_value, new_value, version, changed_by, reason)
  VALUES (OLD.key, OLD.value, NULL, OLD.version + 1, soulbah.change_actor(), soulbah.change_reason());
  RETURN OLD;
END $function$
;

-- soulbah.system_state_track()
CREATE OR REPLACE FUNCTION soulbah.system_state_track()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'soulbah.system_state : la ligne unique ne se supprime pas' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    NEW.version := OLD.version + 1;
    NEW.updated_at := now();
    NEW.updated_by := soulbah.change_actor();
    IF NEW.emergency_stop AND NOT OLD.emergency_stop THEN NEW.emergency_stop_at := now(); END IF;
    INSERT INTO soulbah.system_state_history (version, old_state, new_state, changed_by, reason)
    VALUES (NEW.version, to_jsonb(OLD), to_jsonb(NEW), NEW.updated_by, soulbah.change_reason());
    RETURN NEW;
  END IF;
  INSERT INTO soulbah.system_state_history (version, old_state, new_state, changed_by, reason)
  VALUES (NEW.version, NULL, to_jsonb(NEW), soulbah.change_actor(), soulbah.change_reason());
  RETURN NEW;
END $function$
;

-- soulbah.task_dependencies_check_cycle()
CREATE OR REPLACE FUNCTION soulbah.task_dependencies_check_cycle()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
DECLARE
  s_task  uuid;
  s_dep   uuid;
  cyc     boolean;
BEGIN
  SELECT session_id INTO s_task FROM soulbah.tasks WHERE id = NEW.task_id;
  SELECT session_id INTO s_dep  FROM soulbah.tasks WHERE id = NEW.depends_on_task_id;
  IF s_task IS NULL OR s_dep IS NULL OR s_task <> s_dep THEN
    RAISE EXCEPTION 'soulbah.task_dependencies : % et % ne sont pas dans la même session', NEW.task_id, NEW.depends_on_task_id
      USING ERRCODE = 'check_violation';
  END IF;
  PERFORM 1 FROM soulbah.sessions WHERE id = s_task FOR UPDATE;

  -- Cycle si, en remontant les dépendances existantes depuis depends_on_task_id, on
  -- retrouve task_id (profondeur bornée : un DAG légitime fait au plus quelques dizaines de nœuds).
  WITH RECURSIVE up(id, depth) AS (
    SELECT NEW.depends_on_task_id, 1
    UNION ALL
    SELECT d.depends_on_task_id, up.depth + 1
      FROM soulbah.task_dependencies d
      JOIN up ON d.task_id = up.id
     WHERE up.depth < 1000
  )
  SELECT EXISTS (SELECT 1 FROM up WHERE up.id = NEW.task_id) INTO cyc;
  IF cyc THEN
    RAISE EXCEPTION 'soulbah.task_dependencies : cycle de dépendances refusé (% dépendrait de % qui en dépend déjà)',
      NEW.task_id, NEW.depends_on_task_id USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.tasks_check_transition()
CREATE OR REPLACE FUNCTION soulbah.tasks_check_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;
  IF NEW.status = 'CANCELLED' AND OLD.status NOT IN ('COMPLETED', 'FAILED', 'CANCELLED') THEN
    RETURN NEW;
  END IF;
  IF (OLD.status, NEW.status) IN (
       ('PENDING', 'READY'), ('PENDING', 'BLOCKED'),
       ('READY', 'RUNNING'),
       ('RUNNING', 'WAITING'), ('RUNNING', 'BLOCKED'), ('RUNNING', 'VALIDATING'),
       ('RUNNING', 'RETRYING'), ('RUNNING', 'FAILED'),
       ('WAITING', 'RUNNING'), ('WAITING', 'BLOCKED'), ('WAITING', 'RETRYING'), ('WAITING', 'FAILED'),
       ('BLOCKED', 'READY'), ('BLOCKED', 'PENDING'), ('BLOCKED', 'FAILED'),
       ('VALIDATING', 'COMPLETED'), ('VALIDATING', 'RETRYING'), ('VALIDATING', 'FAILED'),
       ('RETRYING', 'READY'),
       ('FAILED', 'READY')) THEN
    IF OLD.status = 'READY' AND NEW.status = 'RUNNING' AND NEW.attempt <> OLD.attempt + 1 THEN
      RAISE EXCEPTION 'soulbah.tasks % : READY → RUNNING exige attempt = % (reçu %)', OLD.id, OLD.attempt + 1, NEW.attempt
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'soulbah.tasks % : transition % → % interdite (audit §9.4)', OLD.id, OLD.status, NEW.status
    USING ERRCODE = 'check_violation';
END $function$
;

-- soulbah.tool_candidates_guard()
CREATE OR REPLACE FUNCTION soulbah.tool_candidates_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF NEW.status = 'promoted' AND (TG_OP = 'INSERT' OR OLD.status <> 'promoted') THEN
    IF NOT EXISTS (
      SELECT 1 FROM soulbah.tool_builds b
       WHERE b.candidate_id = NEW.id AND b.status = 'succeeded'
         AND EXISTS (SELECT 1 FROM soulbah.tool_tests t WHERE t.build_id = b.id)
         AND NOT EXISTS (SELECT 1 FROM soulbah.tool_tests t WHERE t.build_id = b.id AND t.status <> 'passed')
         AND EXISTS (SELECT 1 FROM soulbah.tool_security_reviews r WHERE r.build_id = b.id AND r.reviewer_type = 'human' AND r.verdict = 'approved')) THEN
      RAISE EXCEPTION 'soulbah.tool_candidates : promotion refusée — il faut un build réussi, tous ses tests passés et une revue de sécurité humaine approuvée'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.training_runs_guard()
CREATE OR REPLACE FUNCTION soulbah.training_runs_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM soulbah.training_configs c WHERE c.id = NEW.config_id AND c.approved_by IS NOT NULL AND c.approved_at IS NOT NULL) THEN
    RAISE EXCEPTION 'soulbah.training_runs : configuration d''entraînement non approuvée' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.status IN ('running', 'completed') AND NOT EXISTS (
       SELECT 1 FROM soulbah.training_configs c JOIN soulbah.dataset_versions d ON d.id = c.dataset_version_id WHERE c.id = NEW.config_id AND d.frozen) THEN
    RAISE EXCEPTION 'soulbah.training_runs : le jeu de données doit être gelé avant l''entraînement' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $function$
;

-- soulbah.trusted_core_unlocked()
CREATE OR REPLACE FUNCTION soulbah.trusted_core_unlocked()
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$ SELECT coalesce(current_setting('soulbah.trusted_core', true), '') = 'unlocked' $function$
;

-- soulbah.verify_audit_chain(OUT ok boolean, OUT checked bigint, OUT broken_at bigint)
CREATE OR REPLACE FUNCTION soulbah.verify_audit_chain(OUT ok boolean, OUT checked bigint, OUT broken_at bigint)
 RETURNS record
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'soulbah', 'pg_temp'
AS $function$
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
END $function$
;

-- soulbah.writes_allowed()
CREATE OR REPLACE FUNCTION soulbah.writes_allowed()
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$ SELECT NOT (emergency_stop OR safe_mode) FROM soulbah.system_state WHERE id = 1 $function$
;
