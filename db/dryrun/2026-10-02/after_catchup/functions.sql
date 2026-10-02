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
