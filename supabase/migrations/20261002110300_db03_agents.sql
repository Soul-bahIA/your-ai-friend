-- =============================================================================
-- DB LOT 3 — Agents : registre des définitions d'agents (versionné), capacités, permissions, affectations,
-- état, métriques ; exécutions (REUSE soulbah.agents, soulbah.tasks, soulbah.actions, soulbah.tool_calls) ;
-- supervision (échecs, watchdog, relectures croisées, quarantaines).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110300_db03_agents.down.sql (supprime aussi les colonnes ajoutées à soulbah.agents et soulbah.tasks)
-- soulbah:transaction=single
-- Dépend de : db01, db02.
-- Le registre s'appelle agent_definitions : soulbah.agents (V2) désigne déjà une INSTANCE d'agent par tâche.
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.agent_definitions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                text NOT NULL UNIQUE CONSTRAINT agent_definitions_name_format CHECK (name ~ '^[a-z][a-z0-9_]{0,63}$'),
  display_name        text NOT NULL CONSTRAINT agent_definitions_display_length CHECK (length(display_name) BETWEEN 1 AND 120),
  mission             text NOT NULL DEFAULT '' CONSTRAINT agent_definitions_mission_length CHECK (length(mission) <= 4000),
  executor            text NOT NULL DEFAULT 'runtime' CONSTRAINT agent_definitions_executor_check CHECK (executor IN ('runtime', 'p1')),
  status              text NOT NULL DEFAULT 'active'
                      CONSTRAINT agent_definitions_status_check CHECK (status IN ('draft', 'active', 'suspended', 'quarantined', 'retired')),
  max_security_level  text NOT NULL DEFAULT 'L1' CONSTRAINT agent_definitions_level_check CHECK (soulbah.is_security_level(max_security_level)),
  model_preference    text NOT NULL DEFAULT 'AUTO' CONSTRAINT agent_definitions_model_length CHECK (length(model_preference) BETWEEN 1 AND 200),
  memory_scope        text NOT NULL DEFAULT 'project' CONSTRAINT agent_definitions_memory_scope_check CHECK (memory_scope IN ('session', 'project', 'user', 'global')),
  knowledge_scope     jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT agent_definitions_knowledge_array CHECK (soulbah.is_json_array(knowledge_scope)),
  resource_limits     jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT agent_definitions_limits_object CHECK (soulbah.is_json_object(resource_limits)),
  max_runtime_s       integer NOT NULL DEFAULT 900 CONSTRAINT agent_definitions_runtime_positive CHECK (max_runtime_s BETWEEN 1 AND 86400),
  max_tool_calls      integer NOT NULL DEFAULT 200 CONSTRAINT agent_definitions_tool_calls_positive CHECK (max_tool_calls BETWEEN 1 AND 100000),
  max_retries         integer NOT NULL DEFAULT 2 CONSTRAINT agent_definitions_retries_range CHECK (max_retries BETWEEN 0 AND 10),
  current_version_id  uuid,
  immutable           boolean NOT NULL DEFAULT false,
  created_by          text NOT NULL DEFAULT current_user,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.agent_definitions IS 'Registre des agents (modifiable depuis le Control Center) : mission, exécutant, plafonds, limites. Une exécution = une ligne de soulbah.agents.';
ALTER TABLE soulbah.agent_definitions ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS agent_definitions_set_updated_at ON soulbah.agent_definitions;
CREATE TRIGGER agent_definitions_set_updated_at BEFORE UPDATE ON soulbah.agent_definitions FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
DROP TRIGGER IF EXISTS agent_definitions_protect ON soulbah.agent_definitions;
CREATE TRIGGER agent_definitions_protect BEFORE UPDATE OR DELETE ON soulbah.agent_definitions FOR EACH ROW EXECUTE FUNCTION soulbah.protect_immutable();

CREATE TABLE IF NOT EXISTS soulbah.agent_definition_versions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_id  uuid NOT NULL REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  version        text NOT NULL CONSTRAINT agent_definition_versions_semver CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  prompt         text NOT NULL DEFAULT '' CONSTRAINT agent_definition_versions_prompt_length CHECK (length(prompt) <= 60000),
  tools          jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT agent_definition_versions_tools_array CHECK (soulbah.is_json_array(tools)),
  permissions    jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT agent_definition_versions_permissions_array CHECK (soulbah.is_json_array(permissions)),
  model          text NOT NULL DEFAULT 'AUTO',
  skills         jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT agent_definition_versions_skills_array CHECK (soulbah.is_json_array(skills)),
  changelog      text NOT NULL DEFAULT '' CONSTRAINT agent_definition_versions_changelog_length CHECK (length(changelog) <= 4000),
  status         text NOT NULL DEFAULT 'draft' CONSTRAINT agent_definition_versions_status_check CHECK (status IN ('draft', 'canary', 'active', 'retired')),
  created_by     text NOT NULL DEFAULT current_user,
  created_at     timestamptz NOT NULL DEFAULT now(),
  activated_at   timestamptz,
  CONSTRAINT agent_definition_versions_unique UNIQUE (definition_id, version)
);
COMMENT ON TABLE soulbah.agent_definition_versions IS 'Historique des versions d''un agent (prompt, outils, permissions, modèle, skills) ; canary avant remplacement (§73).';
ALTER TABLE soulbah.agent_definition_versions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_agent_definition_versions_status ON soulbah.agent_definition_versions (definition_id, status);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_definitions_current_version_fkey') THEN
    ALTER TABLE soulbah.agent_definitions ADD CONSTRAINT agent_definitions_current_version_fkey
      FOREIGN KEY (current_version_id) REFERENCES soulbah.agent_definition_versions(id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_agent_definitions_current_version ON soulbah.agent_definitions (current_version_id);

CREATE TABLE IF NOT EXISTS soulbah.agent_capabilities (
  definition_id  uuid NOT NULL REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  capability     text NOT NULL CONSTRAINT agent_capabilities_format CHECK (capability ~ '^[a-z][a-z0-9_.]{0,99}$'),
  enabled        boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (definition_id, capability)
);
COMMENT ON TABLE soulbah.agent_capabilities IS 'Capacités déclarées d''un agent (coding, vision, computer_control, research…), activables.';
ALTER TABLE soulbah.agent_capabilities ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.agent_permissions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_id     uuid NOT NULL REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  permission        text NOT NULL CONSTRAINT agent_permissions_format CHECK (permission ~ '^[a-z_]+\.[a-z_]+$'),
  environment_name  text NOT NULL REFERENCES soulbah.environments(name),
  decision          text NOT NULL CONSTRAINT agent_permissions_decision_check CHECK (decision IN ('allow', 'deny', 'approval')),
  granted_by        text NOT NULL DEFAULT current_user,
  reason            text,
  version           integer NOT NULL DEFAULT 1,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT agent_permissions_unique UNIQUE (definition_id, permission, environment_name)
);
COMMENT ON TABLE soulbah.agent_permissions IS 'Permissions nommées accordées à un agent PAR environnement (DEV ≠ PRODUCTION) ; le moteur de politiques (DB LOT 4) tranche.';
ALTER TABLE soulbah.agent_permissions ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS agent_permissions_set_updated_at ON soulbah.agent_permissions;
CREATE TRIGGER agent_permissions_set_updated_at BEFORE UPDATE ON soulbah.agent_permissions FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.agent_assignments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_id     uuid NOT NULL REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  project_id        uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  environment_name  text NOT NULL REFERENCES soulbah.environments(name),
  autonomy_level    text NOT NULL DEFAULT 'OBSERVE' CONSTRAINT agent_assignments_autonomy_check CHECK (soulbah.is_autonomy_level(autonomy_level)),
  enabled           boolean NOT NULL DEFAULT true,
  created_by        text NOT NULL DEFAULT current_user,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT agent_assignments_unique UNIQUE (definition_id, project_id, environment_name)
);
COMMENT ON TABLE soulbah.agent_assignments IS 'Affectation d''un agent à un projet et un environnement avec son niveau d''autonomie (OBSERVE … PRODUCTION_GUARDED).';
ALTER TABLE soulbah.agent_assignments ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_agent_assignments_project ON soulbah.agent_assignments (project_id, environment_name);
DROP TRIGGER IF EXISTS agent_assignments_set_updated_at ON soulbah.agent_assignments;
CREATE TRIGGER agent_assignments_set_updated_at BEFORE UPDATE ON soulbah.agent_assignments FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.agent_status (
  definition_id      uuid PRIMARY KEY REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  status             text NOT NULL DEFAULT 'idle' CONSTRAINT agent_status_check CHECK (status IN ('idle', 'busy', 'suspended', 'quarantined', 'error')),
  current_load       integer NOT NULL DEFAULT 0 CONSTRAINT agent_status_load_positive CHECK (current_load >= 0),
  last_heartbeat_at  timestamptz,
  last_run_at        timestamptz,
  last_error         text,
  quarantined_at     timestamptz,
  updated_at         timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.agent_status IS 'État courant de chaque agent (charge, dernière exécution, dernière erreur, quarantaine).';
ALTER TABLE soulbah.agent_status ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS agent_status_set_updated_at ON soulbah.agent_status;
CREATE TRIGGER agent_status_set_updated_at BEFORE UPDATE ON soulbah.agent_status FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.agent_metrics (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  definition_id        uuid NOT NULL REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  period_start         timestamptz NOT NULL,
  period_end           timestamptz NOT NULL,
  runs                 integer NOT NULL DEFAULT 0,
  successes            integer NOT NULL DEFAULT 0,
  failures             integer NOT NULL DEFAULT 0,
  retries              integer NOT NULL DEFAULT 0,
  avg_duration_ms      integer,
  p95_duration_ms      integer,
  tool_calls           integer NOT NULL DEFAULT 0,
  human_interventions  integer NOT NULL DEFAULT 0,
  input_tokens         bigint NOT NULL DEFAULT 0,
  output_tokens        bigint NOT NULL DEFAULT 0,
  cost_usd             numeric(12, 6),
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT agent_metrics_period CHECK (period_end > period_start),
  CONSTRAINT agent_metrics_unique UNIQUE (definition_id, period_start, period_end)
);
COMMENT ON TABLE soulbah.agent_metrics IS 'Mesures par agent et par période (réussites, échecs, reprises, durées, interventions humaines, coût) — §70.';
ALTER TABLE soulbah.agent_metrics ENABLE ROW LEVEL SECURITY;

-- Exécutions : REUSE de soulbah.agents (instance par tâche) et soulbah.tasks, étendus.
SELECT soulbah.assert_table_shape('soulbah.agents', '{"role": "text", "status": "text", "session_id": "uuid"}');
ALTER TABLE soulbah.agents
  ADD COLUMN IF NOT EXISTS definition_id uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS version_id    uuid REFERENCES soulbah.agent_definition_versions(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS outcome       text,
  ADD COLUMN IF NOT EXISTS finished_at   timestamptz;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agents_outcome_check') THEN
    ALTER TABLE soulbah.agents ADD CONSTRAINT agents_outcome_check
      CHECK (outcome IS NULL OR outcome IN ('success', 'failure', 'cancelled', 'timeout'));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_agents_definition ON soulbah.agents (definition_id, created_at);
COMMENT ON COLUMN soulbah.agents.definition_id IS 'Agent du registre dont cette exécution est une instance (agent_runs).';

SELECT soulbah.assert_table_shape('soulbah.tasks', '{"role": "text", "status": "text", "session_id": "uuid"}');
ALTER TABLE soulbah.tasks
  ADD COLUMN IF NOT EXISTS agent_definition_id uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_agent_definition ON soulbah.tasks (agent_definition_id) WHERE agent_definition_id IS NOT NULL;

-- Supervision ---------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.agent_failures (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id          uuid REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  attempt          integer CONSTRAINT agent_failures_attempt_positive CHECK (attempt IS NULL OR attempt >= 0),
  definition_id    uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  kind             text NOT NULL CONSTRAINT agent_failures_kind_check
                   CHECK (kind IN ('error', 'timeout', 'loop', 'policy_refused', 'evaluation_failed', 'crash', 'other')),
  message          text NOT NULL CONSTRAINT agent_failures_message_length CHECK (length(message) BETWEEN 1 AND 4000),
  probable_cause   text,
  root_cause       text,
  strategy_change  text,
  retried          boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.agent_failures IS 'Échecs d''agents : cause probable, cause racine, stratégie corrigée ; la leçon validée est liée à la mémoire (DB LOT 5) — §22, §35.';
ALTER TABLE soulbah.agent_failures ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_agent_failures_task ON soulbah.agent_failures (task_id);
CREATE INDEX IF NOT EXISTS idx_agent_failures_definition ON soulbah.agent_failures (definition_id, created_at);

CREATE TABLE IF NOT EXISTS soulbah.agent_watchdog_events (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- Journal en ajout seul : FK RESTRICT vers le catalogue (jamais supprimé), pas de FK vers les lignes
  -- opérationnelles purgées (agents, tâches) — convention de soulbah.audit_logs.
  definition_id  uuid REFERENCES soulbah.agent_definitions(id) ON DELETE RESTRICT,
  agent_id       uuid,
  task_id        uuid,
  kind           text NOT NULL CONSTRAINT agent_watchdog_events_kind_check CHECK (kind IN (
                   'hang', 'loop', 'repeated_action', 'excessive_resources', 'frequent_errors',
                   'capability_hallucination', 'missing_evidence', 'conflict', 'permission_escalation_attempt',
                   'unusual_access', 'unusual_command', 'security_disable_attempt', 'exfiltration_suspected')),
  severity       text NOT NULL CONSTRAINT agent_watchdog_events_severity_check CHECK (soulbah.is_severity(severity)),
  detail         jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT agent_watchdog_events_detail_object CHECK (soulbah.is_json_object(detail)),
  action_taken   text NOT NULL DEFAULT 'none' CONSTRAINT agent_watchdog_events_action_check CHECK (action_taken IN ('none', 'warned', 'stopped', 'quarantined', 'escalated')),
  created_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.agent_watchdog_events IS 'Événements du watchdog (boucles, blocages, tentatives d''élévation, accès inhabituels…), ajout seul — §21, §45.';
ALTER TABLE soulbah.agent_watchdog_events ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_agent_watchdog_events_definition ON soulbah.agent_watchdog_events (definition_id, id);
CREATE INDEX IF NOT EXISTS idx_agent_watchdog_events_task ON soulbah.agent_watchdog_events (task_id);
CREATE INDEX IF NOT EXISTS idx_agent_watchdog_events_agent ON soulbah.agent_watchdog_events (agent_id);
DROP TRIGGER IF EXISTS agent_watchdog_events_append_only ON soulbah.agent_watchdog_events;
CREATE TRIGGER agent_watchdog_events_append_only BEFORE UPDATE OR DELETE ON soulbah.agent_watchdog_events FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS agent_watchdog_events_no_truncate ON soulbah.agent_watchdog_events;
CREATE TRIGGER agent_watchdog_events_no_truncate BEFORE TRUNCATE ON soulbah.agent_watchdog_events FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE TABLE IF NOT EXISTS soulbah.agent_peer_reviews (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id                 uuid NOT NULL REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  attempt                 integer NOT NULL CONSTRAINT agent_peer_reviews_attempt_positive CHECK (attempt >= 0),
  reviewer_definition_id  uuid NOT NULL REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  author_definition_id    uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  lens                    text NOT NULL CONSTRAINT agent_peer_reviews_lens_check CHECK (lens IN ('quality', 'security', 'tests', 'architecture', 'evidence')),
  verdict                 text NOT NULL CONSTRAINT agent_peer_reviews_verdict_check CHECK (verdict IN ('approved', 'changes_requested', 'rejected')),
  findings                jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT agent_peer_reviews_findings_array CHECK (soulbah.is_json_array(findings)),
  evidence_ids            jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT agent_peer_reviews_evidence_array CHECK (soulbah.is_json_array(evidence_ids)),
  created_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT agent_peer_reviews_not_self CHECK (author_definition_id IS NULL OR reviewer_definition_id <> author_definition_id)
);
COMMENT ON TABLE soulbah.agent_peer_reviews IS 'Relectures croisées (un agent ne juge jamais seul son propre travail critique) — §20, §33.';
ALTER TABLE soulbah.agent_peer_reviews ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_agent_peer_reviews_task ON soulbah.agent_peer_reviews (task_id, attempt);
CREATE INDEX IF NOT EXISTS idx_agent_peer_reviews_reviewer ON soulbah.agent_peer_reviews (reviewer_definition_id);
CREATE INDEX IF NOT EXISTS idx_agent_peer_reviews_author ON soulbah.agent_peer_reviews (author_definition_id);

CREATE TABLE IF NOT EXISTS soulbah.agent_quarantines (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_id  uuid NOT NULL REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  reason         text NOT NULL CONSTRAINT agent_quarantines_reason_length CHECK (length(reason) BETWEEN 1 AND 4000),
  event_id       bigint REFERENCES soulbah.agent_watchdog_events(id) ON DELETE SET NULL,
  status         text NOT NULL DEFAULT 'active' CONSTRAINT agent_quarantines_status_check CHECK (status IN ('active', 'lifted')),
  created_by     text NOT NULL DEFAULT current_user,
  created_at     timestamptz NOT NULL DEFAULT now(),
  lifted_by      text,
  lifted_at      timestamptz,
  lifted_reason  text,
  CONSTRAINT agent_quarantines_lift_complete CHECK (status = 'active' OR (lifted_by IS NOT NULL AND lifted_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.agent_quarantines IS 'Quarantaines d''agents (§46) : l''agent perd ses permissions sensibles jusqu''à l''analyse ; la levée est tracée.';
ALTER TABLE soulbah.agent_quarantines ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_agent_quarantines_definition ON soulbah.agent_quarantines (definition_id, status);
CREATE INDEX IF NOT EXISTS idx_agent_quarantines_event ON soulbah.agent_quarantines (event_id);

-- Une quarantaine active met l'agent en quarantaine ; sa levée le ramène suspendu (réactivation explicite).
CREATE OR REPLACE FUNCTION soulbah.agent_quarantine_apply()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
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
END $$;
DROP TRIGGER IF EXISTS agent_quarantines_apply ON soulbah.agent_quarantines;
CREATE TRIGGER agent_quarantines_apply AFTER INSERT OR UPDATE ON soulbah.agent_quarantines FOR EACH ROW EXECUTE FUNCTION soulbah.agent_quarantine_apply();

-- Semence : les 7 rôles V2 (shared/roles/roles.json), versions et outils identiques au code -------
INSERT INTO soulbah.agent_definitions (name, display_name, mission, executor, max_security_level) VALUES
  ('desktop_operator', 'Computer Agent', 'Pilote le bureau Windows (souris, clavier, fenêtres, applications, VS Code) ; observe (capture ou inspection d''interface) avant d''agir.', 'runtime', 'L2'),
  ('coder', 'Developer Agent', 'Lit, écrit et exécute du code dans SA worktree git ; fusionne vers l''intégration avec tests verts après relecture QA.', 'runtime', 'L2'),
  ('researcher', 'Research Agent', 'Collecte des faits : workspace, pages web publiques (lecture seule), état des fenêtres ; aucun effet.', 'runtime', 'L1'),
  ('video_editor', 'Video Agent', 'Enregistre l''écran, produit la narration avec une voix locale et monte les vidéos de démonstration.', 'runtime', 'L2'),
  ('phone_operator', 'Phone Agent', 'Pilote un téléphone Android connecté (adb).', 'runtime', 'L2'),
  ('qa_reviewer', 'QA Agent', 'Relit le travail d''une autre tâche à partir de ses preuves et de son évaluation (exécuté par le plan de contrôle).', 'p1', 'L0'),
  ('content_writer', 'Knowledge Agent', 'Rédige du contenu (modules de formation, synthèses) via le routeur de modèles (exécuté par le plan de contrôle).', 'p1', 'L0')
ON CONFLICT (name) DO NOTHING;

INSERT INTO soulbah.agent_definition_versions (definition_id, version, tools, status, changelog, activated_at)
SELECT d.id, v.version, v.tools::jsonb, 'active', 'Version importée de shared/roles/roles.json (LOT 11/12 V2).', now()
FROM (VALUES
  ('desktop_operator', '1.2.0', '["screenshot","click","double_click","right_click","move_mouse","drag","scroll","type_text","hotkey","window","open_app","wait","ui_snapshot","vscode_open","speak_text","read_file","list_dir","record_screen","start_recording_bg","stop_recording_bg"]'),
  ('coder', '1.1.0', '["run_command","git_worktree","git_commit","git_merge","read_file","list_dir","write_file","make_dir","move_file","browser_get","wait"]'),
  ('researcher', '1.1.0', '["read_file","list_dir","browser_get","ui_snapshot","wait","screenshot"]'),
  ('video_editor', '1.1.0', '["record_screen","start_recording_bg","stop_recording_bg","edit_video","resolve_montage","speak_text","read_file","list_dir","write_file","make_dir","move_file","wait"]'),
  ('phone_operator', '1.0.0', '["phone_list_devices","phone_screenshot","phone_tap","phone_swipe","phone_type","phone_key","phone_open_app","wait"]'),
  ('qa_reviewer', '1.0.0', '[]'),
  ('content_writer', '1.0.0', '[]')
) AS v(name, version, tools)
JOIN soulbah.agent_definitions d ON d.name = v.name
ON CONFLICT (definition_id, version) DO NOTHING;

UPDATE soulbah.agent_definitions d
   SET current_version_id = v.id
  FROM soulbah.agent_definition_versions v
 WHERE v.definition_id = d.id AND v.status = 'active' AND d.current_version_id IS NULL;

INSERT INTO soulbah.agent_status (definition_id, status)
SELECT id, 'idle' FROM soulbah.agent_definitions ON CONFLICT (definition_id) DO NOTHING;

DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON soulbah.agent_definitions, soulbah.agent_definition_versions, soulbah.agent_capabilities, soulbah.agent_permissions,
    soulbah.agent_assignments, soulbah.agent_status, soulbah.agent_metrics, soulbah.agent_failures, soulbah.agent_watchdog_events,
    soulbah.agent_peer_reviews, soulbah.agent_quarantines FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.agent_definitions, soulbah.agent_definition_versions, soulbah.agent_capabilities, '
                     'soulbah.agent_permissions, soulbah.agent_assignments, soulbah.agent_status, soulbah.agent_metrics, '
                     'soulbah.agent_failures, soulbah.agent_watchdog_events, soulbah.agent_peer_reviews, soulbah.agent_quarantines FROM %I', r);
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.agent_quarantine_apply() FROM %I', r);
    END IF;
  END LOOP;
END $$;
