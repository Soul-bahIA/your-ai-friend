-- =============================================================================
-- DB LOT 4 — Permissions nommées, rôles, Policy Engine (versionné), décisions, niveaux d'autonomie,
-- garde-fous (niveaux SAFE/STANDARD/ADVANCED/CUSTOM, versions, affectations, événements).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110400_db04_policies_guardrails.down.sql (historiques perdus : les exporter avant)
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03.
-- Principe (§55-56, §113) : un agent ne s'accorde jamais une permission ; les politiques et garde-fous
-- critiques sont immuables (Trusted Core) ; chaque changement est historisé avec sa justification.
-- =============================================================================

-- 1. Permissions nommées et rôles (§28) ------------------------------------------------------------------
-- Nom « permission_definitions » : soulbah.permissions (V2) existe déjà et désigne les DEMANDES d'approbation.
CREATE TABLE IF NOT EXISTS soulbah.permission_definitions (
  name         text PRIMARY KEY CONSTRAINT permission_definitions_name_format CHECK (name ~ '^[a-z_]+\.[a-z_]+$'),
  category     text NOT NULL CONSTRAINT permission_definitions_category_format CHECK (category ~ '^[a-z_]{1,40}$'),
  description  text NOT NULL DEFAULT '' CONSTRAINT permission_definitions_description_length CHECK (length(description) <= 500),
  critical     boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.permission_definitions IS 'Permissions nommées (filesystem.write, database.migrate, production.deploy…) ; critical = validation PDG selon la politique.';
ALTER TABLE soulbah.permission_definitions ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.permission_definitions', '{"name": "text", "category": "text", "critical": "boolean"}');
INSERT INTO soulbah.permission_definitions (name, category, description, critical) VALUES
  ('filesystem.read', 'filesystem', 'Lire des fichiers dans les dossiers autorisés', false),
  ('filesystem.write', 'filesystem', 'Créer, modifier ou déplacer des fichiers dans les dossiers autorisés', false),
  ('terminal.execute', 'terminal', 'Exécuter une commande de la liste fermée (git, npm, python, node, pytest)', false),
  ('git.read', 'git', 'Lire l''historique et l''état d''un dépôt', false),
  ('git.write', 'git', 'Créer des worktrees, commiter, fusionner après relecture', false),
  ('git.push', 'git', 'Pousser vers un dépôt distant', true),
  ('database.read', 'database', 'Lire une base autorisée', false),
  ('database.write', 'database', 'Écrire dans une base autorisée (hors schéma)', true),
  ('database.migrate', 'database', 'Appliquer une migration de schéma', true),
  ('database.admin', 'database', 'Rôles, droits, extensions, sauvegardes', true),
  ('security.scan', 'security', 'Analyser défensivement code, dépendances, configuration', false),
  ('security.patch', 'security', 'Produire un correctif de sécurité en sandbox', false),
  ('production.read', 'production', 'Lire l''état d''un environnement de production', false),
  ('production.deploy', 'production', 'Déployer en production', true),
  ('network.internet', 'network', 'Accéder à Internet (documentation, recherche)', false),
  ('network.external_ai', 'network', 'Envoyer des données à une API d''IA externe', true),
  ('computer.control', 'computer', 'Piloter souris, clavier, fenêtres, applications', false),
  ('memory.write', 'memory', 'Proposer ou valider une mémoire', false),
  ('knowledge.write', 'knowledge', 'Écrire dans la base de connaissances', false),
  ('research.run', 'research', 'Lancer une recherche', false),
  ('self_improvement.propose', 'self_improvement', 'Proposer une amélioration', false),
  ('self_improvement.test', 'self_improvement', 'Tester un candidat dans le laboratoire', false),
  ('self_improvement.activate', 'self_improvement', 'Activer une amélioration', true),
  ('agents.manage', 'agents', 'Créer, modifier, suspendre des agents', true),
  ('policies.manage', 'policies', 'Modifier politiques et garde-fous', true),
  ('secrets.rotate', 'secrets', 'Faire tourner un secret', true),
  ('payments.execute', 'payments', 'Toute opération financière', true),
  ('model.download', 'models', 'Télécharger un modèle', true),
  ('model.activate', 'models', 'Activer un modèle dans le routeur', true),
  ('image.generate', 'media', 'Générer des images', false)
ON CONFLICT (name) DO NOTHING;

CREATE TABLE IF NOT EXISTS soulbah.roles (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL UNIQUE CONSTRAINT roles_name_format CHECK (name ~ '^[a-z][a-z0-9_]{0,63}$'),
  description  text NOT NULL DEFAULT '' CONSTRAINT roles_description_length CHECK (length(description) <= 500),
  rank         smallint NOT NULL DEFAULT 10 CONSTRAINT roles_rank_range CHECK (rank BETWEEN 0 AND 100),
  immutable    boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.roles IS 'Rôles d''autorisation du Control Center (pdg, super_admin, admin, user) ; rank ordonne les autorités.';
ALTER TABLE soulbah.roles ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.roles', '{"name": "text", "rank": "smallint", "immutable": "boolean"}');
DROP TRIGGER IF EXISTS roles_protect ON soulbah.roles;
CREATE TRIGGER roles_protect BEFORE UPDATE OR DELETE ON soulbah.roles FOR EACH ROW EXECUTE FUNCTION soulbah.protect_immutable();
INSERT INTO soulbah.roles (name, description, rank, immutable) VALUES
  ('pdg', 'Autorité la plus élevée : seul à pouvoir lever une protection critique', 100, true),
  ('super_admin', 'Administrateur explicitement habilité par le PDG', 90, true),
  ('admin', 'Administration courante', 50, true),
  ('user', 'Utilisateur de l''application', 10, true)
ON CONFLICT (name) DO NOTHING;

CREATE TABLE IF NOT EXISTS soulbah.role_permissions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  role_id           uuid NOT NULL REFERENCES soulbah.roles(id) ON DELETE CASCADE,
  permission        text NOT NULL REFERENCES soulbah.permission_definitions(name) ON DELETE CASCADE,
  environment_name  text REFERENCES soulbah.environments(name),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT role_permissions_unique UNIQUE NULLS NOT DISTINCT (role_id, permission, environment_name)
);
COMMENT ON TABLE soulbah.role_permissions IS 'Permissions d''un rôle, éventuellement limitées à un environnement (NULL = tous).';
ALTER TABLE soulbah.role_permissions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_role_permissions_permission ON soulbah.role_permissions (permission);
CREATE INDEX IF NOT EXISTS idx_role_permissions_env ON soulbah.role_permissions (environment_name);

CREATE TABLE IF NOT EXISTS soulbah.principal_roles (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  principal_type    text NOT NULL CONSTRAINT principal_roles_type_check CHECK (principal_type IN ('user', 'agent')),
  principal_id      uuid NOT NULL,
  role_id           uuid NOT NULL REFERENCES soulbah.roles(id) ON DELETE CASCADE,
  environment_name  text REFERENCES soulbah.environments(name),
  granted_by        text NOT NULL DEFAULT current_user,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT principal_roles_unique UNIQUE NULLS NOT DISTINCT (principal_type, principal_id, role_id, environment_name)
);
COMMENT ON TABLE soulbah.principal_roles IS 'Rôles attribués à un utilisateur (auth.users) ou à un agent (agent_definitions), éventuellement par environnement.';
ALTER TABLE soulbah.principal_roles ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_principal_roles_principal ON soulbah.principal_roles (principal_type, principal_id);
CREATE INDEX IF NOT EXISTS idx_principal_roles_role ON soulbah.principal_roles (role_id);
CREATE INDEX IF NOT EXISTS idx_principal_roles_env ON soulbah.principal_roles (environment_name);

CREATE TABLE IF NOT EXISTS soulbah.resource_policies (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resource_type   text NOT NULL CONSTRAINT resource_policies_resource_type_check CHECK (resource_type IN ('project', 'repository', 'environment', 'table', 'path', 'tool', 'model')),
  resource_id     text NOT NULL CONSTRAINT resource_policies_resource_id_length CHECK (length(resource_id) BETWEEN 1 AND 500),
  principal_type  text NOT NULL CONSTRAINT resource_policies_principal_type_check CHECK (principal_type IN ('user', 'agent', 'role')),
  principal_id    text NOT NULL CONSTRAINT resource_policies_principal_id_length CHECK (length(principal_id) BETWEEN 1 AND 200),
  permission      text NOT NULL REFERENCES soulbah.permission_definitions(name) ON DELETE CASCADE,
  effect          text NOT NULL CONSTRAINT resource_policies_effect_check CHECK (effect IN ('allow', 'deny', 'approval')),
  conditions      jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT resource_policies_conditions_object CHECK (soulbah.is_json_object(conditions)),
  created_by      text NOT NULL DEFAULT current_user,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT resource_policies_unique UNIQUE (resource_type, resource_id, principal_type, principal_id, permission)
);
COMMENT ON TABLE soulbah.resource_policies IS 'Règles par ressource (projet, dépôt, environnement, table, chemin, outil, modèle) : qui peut quoi, avec quelles conditions.';
ALTER TABLE soulbah.resource_policies ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_resource_policies_permission ON soulbah.resource_policies (permission);

-- 2. Policy Engine versionné (§53) -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.policies (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key                 text NOT NULL UNIQUE CONSTRAINT policies_key_format CHECK (key ~ '^[a-z][a-z0-9_.]{0,99}$'),
  name                text NOT NULL CONSTRAINT policies_name_length CHECK (length(name) BETWEEN 1 AND 200),
  category            text NOT NULL CONSTRAINT policies_category_format CHECK (category ~ '^[a-z_]{1,40}$'),
  description         text NOT NULL DEFAULT '' CONSTRAINT policies_description_length CHECK (length(description) <= 4000),
  status              text NOT NULL DEFAULT 'draft' CONSTRAINT policies_status_check CHECK (status IN ('draft', 'active', 'retired')),
  current_version_id  uuid,
  immutable           boolean NOT NULL DEFAULT false,
  created_by          text NOT NULL DEFAULT current_user,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.policies IS 'Politiques du Policy Engine (qui peut faire quoi, sur quel projet, dans quel environnement, avec quelle validation).';
ALTER TABLE soulbah.policies ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.policies', '{"key": "text", "status": "text", "current_version_id": "uuid", "immutable": "boolean"}');
DROP TRIGGER IF EXISTS policies_set_updated_at ON soulbah.policies;
CREATE TRIGGER policies_set_updated_at BEFORE UPDATE ON soulbah.policies FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
DROP TRIGGER IF EXISTS policies_protect ON soulbah.policies;
CREATE TRIGGER policies_protect BEFORE UPDATE OR DELETE ON soulbah.policies FOR EACH ROW EXECUTE FUNCTION soulbah.protect_immutable();

CREATE TABLE IF NOT EXISTS soulbah.policy_versions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_id     uuid NOT NULL REFERENCES soulbah.policies(id) ON DELETE RESTRICT,
  version       integer NOT NULL CONSTRAINT policy_versions_version_positive CHECK (version >= 1),
  rules         jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT policy_versions_rules_array CHECK (soulbah.is_json_array(rules)),
  created_by    text NOT NULL DEFAULT current_user,
  reason        text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  activated_at  timestamptz,
  CONSTRAINT policy_versions_unique UNIQUE (policy_id, version)
);
COMMENT ON TABLE soulbah.policy_versions IS 'Versions d''une politique (ajout seul) : règles, auteur, justification, activation.';
ALTER TABLE soulbah.policy_versions ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS policy_versions_append_only ON soulbah.policy_versions;
CREATE TRIGGER policy_versions_append_only BEFORE DELETE ON soulbah.policy_versions FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS policy_versions_no_truncate ON soulbah.policy_versions;
CREATE TRIGGER policy_versions_no_truncate BEFORE TRUNCATE ON soulbah.policy_versions FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();
-- Seule l'activation est modifiable (activated_at) ; les règles d'une version ne changent jamais.
CREATE OR REPLACE FUNCTION soulbah.policy_versions_freeze()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.rules IS DISTINCT FROM OLD.rules OR NEW.version <> OLD.version OR NEW.policy_id <> OLD.policy_id THEN
    RAISE EXCEPTION 'soulbah.policy_versions : une version publiée ne se modifie pas (créer une nouvelle version)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS policy_versions_freeze ON soulbah.policy_versions;
CREATE TRIGGER policy_versions_freeze BEFORE UPDATE ON soulbah.policy_versions FOR EACH ROW EXECUTE FUNCTION soulbah.policy_versions_freeze();
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'policies_current_version_fkey') THEN
    ALTER TABLE soulbah.policies ADD CONSTRAINT policies_current_version_fkey
      FOREIGN KEY (current_version_id) REFERENCES soulbah.policy_versions(id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_policies_current_version ON soulbah.policies (current_version_id);

CREATE TABLE IF NOT EXISTS soulbah.policy_rules (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id        uuid NOT NULL REFERENCES soulbah.policy_versions(id) ON DELETE CASCADE,
  permission        text NOT NULL REFERENCES soulbah.permission_definitions(name) ON DELETE CASCADE,
  principal_type    text NOT NULL DEFAULT 'any' CONSTRAINT policy_rules_principal_type_check CHECK (principal_type IN ('any', 'user', 'agent', 'role')),
  principal_id      text,
  project_id        uuid REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  environment_name  text REFERENCES soulbah.environments(name),
  effect            text NOT NULL CONSTRAINT policy_rules_effect_check CHECK (effect IN ('allow', 'deny', 'approval', 'double_approval')),
  conditions        jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT policy_rules_conditions_object CHECK (soulbah.is_json_object(conditions)),
  priority          integer NOT NULL DEFAULT 100,
  created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.policy_rules IS 'Règles d''une version de politique : permission × principal × projet × environnement → allow / deny / approval / double_approval.';
ALTER TABLE soulbah.policy_rules ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_policy_rules_version ON soulbah.policy_rules (version_id, priority);
CREATE INDEX IF NOT EXISTS idx_policy_rules_permission ON soulbah.policy_rules (permission, environment_name);
CREATE INDEX IF NOT EXISTS idx_policy_rules_project ON soulbah.policy_rules (project_id);

CREATE TABLE IF NOT EXISTS soulbah.policy_bindings (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_id         uuid NOT NULL REFERENCES soulbah.policies(id) ON DELETE CASCADE,
  principal_type    text NOT NULL DEFAULT 'any' CONSTRAINT policy_bindings_principal_type_check CHECK (principal_type IN ('any', 'user', 'agent', 'role')),
  principal_id      text,
  project_id        uuid REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  environment_name  text REFERENCES soulbah.environments(name),
  created_by        text NOT NULL DEFAULT current_user,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT policy_bindings_unique UNIQUE NULLS NOT DISTINCT (policy_id, principal_type, principal_id, project_id, environment_name)
);
COMMENT ON TABLE soulbah.policy_bindings IS 'Portée d''une politique : à qui, sur quel projet, dans quel environnement elle s''applique.';
ALTER TABLE soulbah.policy_bindings ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_policy_bindings_project ON soulbah.policy_bindings (project_id);
CREATE INDEX IF NOT EXISTS idx_policy_bindings_env ON soulbah.policy_bindings (environment_name);

CREATE TABLE IF NOT EXISTS soulbah.policy_decisions (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  principal_type     text NOT NULL CONSTRAINT policy_decisions_principal_type_check CHECK (principal_type IN ('user', 'agent', 'system')),
  principal_id       text NOT NULL CONSTRAINT policy_decisions_principal_id_length CHECK (length(principal_id) BETWEEN 1 AND 200),
  permission         text NOT NULL,
  project_id         uuid,
  environment_name   text,
  decision           text NOT NULL CONSTRAINT policy_decisions_decision_check CHECK (decision IN ('allow', 'deny', 'approval_required')),
  policy_version_id  uuid,
  rule_id            uuid,
  reason             text NOT NULL DEFAULT '' CONSTRAINT policy_decisions_reason_length CHECK (length(reason) <= 2000),
  request            jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT policy_decisions_request_object CHECK (soulbah.is_json_object(request)),
  evidence           jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT policy_decisions_evidence_object CHECK (soulbah.is_json_object(evidence)),
  task_id            uuid,
  decided_at         timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.policy_decisions IS 'Chaque décision du Policy Engine (ajout seul) : qui a demandé quoi, où, verdict, politique et règle appliquées, preuve.';
ALTER TABLE soulbah.policy_decisions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_policy_decisions_principal ON soulbah.policy_decisions (principal_type, principal_id, id);
CREATE INDEX IF NOT EXISTS idx_policy_decisions_decision ON soulbah.policy_decisions (decision, id);
CREATE INDEX IF NOT EXISTS idx_policy_decisions_task ON soulbah.policy_decisions (task_id) WHERE task_id IS NOT NULL;
DROP TRIGGER IF EXISTS policy_decisions_append_only ON soulbah.policy_decisions;
CREATE TRIGGER policy_decisions_append_only BEFORE UPDATE OR DELETE ON soulbah.policy_decisions FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS policy_decisions_no_truncate ON soulbah.policy_decisions;
CREATE TRIGGER policy_decisions_no_truncate BEFORE TRUNCATE ON soulbah.policy_decisions FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

-- 3. Niveaux d'autonomie (§25) : règle courante + historique --------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.autonomy_rules (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_id     uuid REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  project_id        uuid REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  environment_name  text NOT NULL REFERENCES soulbah.environments(name),
  level             text NOT NULL CONSTRAINT autonomy_rules_level_check CHECK (soulbah.is_autonomy_level(level)),
  set_by            text NOT NULL DEFAULT current_user,
  reason            text,
  version           integer NOT NULL DEFAULT 1,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT autonomy_rules_unique UNIQUE NULLS NOT DISTINCT (definition_id, project_id, environment_name),
  -- PRODUCTION_GUARDED est le seul niveau admis en PRODUCTION au-delà d'OBSERVE / ASSIST.
  CONSTRAINT autonomy_rules_production_guarded CHECK (environment_name <> 'PRODUCTION' OR level IN ('OBSERVE', 'ASSIST', 'PRODUCTION_GUARDED'))
);
COMMENT ON TABLE soulbah.autonomy_rules IS 'Niveau d''autonomie courant (OBSERVE, ASSIST, LAB, SAFE_AUTO, ADVANCED_AUTO, PRODUCTION_GUARDED) par agent, projet et environnement ; NULL = tous.';
ALTER TABLE soulbah.autonomy_rules ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_autonomy_rules_project ON soulbah.autonomy_rules (project_id, environment_name);

CREATE TABLE IF NOT EXISTS soulbah.autonomy_rules_history (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rule_id     uuid NOT NULL,
  old_level   text,
  new_level   text,
  version     integer NOT NULL,
  changed_by  text NOT NULL,
  reason      text,
  changed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.autonomy_rules_history IS 'Historique des niveaux d''autonomie (ajout seul).';
ALTER TABLE soulbah.autonomy_rules_history ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS autonomy_rules_history_append_only ON soulbah.autonomy_rules_history;
CREATE TRIGGER autonomy_rules_history_append_only BEFORE UPDATE OR DELETE ON soulbah.autonomy_rules_history FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS autonomy_rules_history_no_truncate ON soulbah.autonomy_rules_history;
CREATE TRIGGER autonomy_rules_history_no_truncate BEFORE TRUNCATE ON soulbah.autonomy_rules_history FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE OR REPLACE FUNCTION soulbah.autonomy_rules_track()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
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
END $$;
DROP TRIGGER IF EXISTS autonomy_rules_track ON soulbah.autonomy_rules;
CREATE TRIGGER autonomy_rules_track BEFORE INSERT OR UPDATE OR DELETE ON soulbah.autonomy_rules FOR EACH ROW EXECUTE FUNCTION soulbah.autonomy_rules_track();

-- 4. Garde-fous (§7-8, §55-57) ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.guardrails (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key          text NOT NULL UNIQUE CONSTRAINT guardrails_key_format CHECK (key ~ '^[a-z][a-z0-9_.]{0,99}$'),
  category     text NOT NULL CONSTRAINT guardrails_category_check CHECK (category IN (
                 'filesystem', 'terminal', 'database', 'git', 'network', 'computer_control', 'production', 'secrets',
                 'payments', 'security', 'self_improvement', 'agent_communication')),
  name         text NOT NULL CONSTRAINT guardrails_name_length CHECK (length(name) BETWEEN 1 AND 200),
  description  text NOT NULL DEFAULT '' CONSTRAINT guardrails_description_length CHECK (length(description) <= 4000),
  level        text NOT NULL DEFAULT 'SAFE' CONSTRAINT guardrails_level_check CHECK (level IN ('SAFE', 'STANDARD', 'ADVANCED', 'CUSTOM')),
  value        jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT guardrails_value_object CHECK (soulbah.is_json_object(value)),
  critical     boolean NOT NULL DEFAULT false,
  immutable    boolean NOT NULL DEFAULT false,
  version      integer NOT NULL DEFAULT 1,
  updated_by   text NOT NULL DEFAULT current_user,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.guardrails IS 'Garde-fous visibles et configurables par catégorie ; niveau SAFE/STANDARD/ADVANCED/CUSTOM ; critical = double validation ; immutable = Trusted Core.';
ALTER TABLE soulbah.guardrails ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.guardrails', '{"key": "text", "category": "text", "level": "text", "value": "jsonb", "critical": "boolean", "immutable": "boolean", "version": "integer"}');

CREATE TABLE IF NOT EXISTS soulbah.guardrail_versions (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  guardrail_id   uuid NOT NULL,
  version        integer NOT NULL,
  old_level      text,
  new_level      text,
  old_value      jsonb,
  new_value      jsonb,
  changed_by     text NOT NULL,
  justification  text,
  changed_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.guardrail_versions IS 'Chaque modification de garde-fou (ajout seul) : ancienne et nouvelle valeur, auteur, justification (§56).';
ALTER TABLE soulbah.guardrail_versions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_guardrail_versions_guardrail ON soulbah.guardrail_versions (guardrail_id, version);
DROP TRIGGER IF EXISTS guardrail_versions_append_only ON soulbah.guardrail_versions;
CREATE TRIGGER guardrail_versions_append_only BEFORE UPDATE OR DELETE ON soulbah.guardrail_versions FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS guardrail_versions_no_truncate ON soulbah.guardrail_versions;
CREATE TRIGGER guardrail_versions_no_truncate BEFORE TRUNCATE ON soulbah.guardrail_versions FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE OR REPLACE FUNCTION soulbah.guardrails_track()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
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
END $$;
DROP TRIGGER IF EXISTS guardrails_protect ON soulbah.guardrails;
CREATE TRIGGER guardrails_protect BEFORE UPDATE OR DELETE ON soulbah.guardrails FOR EACH ROW EXECUTE FUNCTION soulbah.protect_immutable();
DROP TRIGGER IF EXISTS guardrails_track ON soulbah.guardrails;
CREATE TRIGGER guardrails_track BEFORE INSERT OR UPDATE OR DELETE ON soulbah.guardrails FOR EACH ROW EXECUTE FUNCTION soulbah.guardrails_track();

CREATE TABLE IF NOT EXISTS soulbah.guardrail_assignments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  guardrail_id      uuid NOT NULL REFERENCES soulbah.guardrails(id) ON DELETE CASCADE,
  definition_id     uuid REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  project_id        uuid REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  environment_name  text REFERENCES soulbah.environments(name),
  level             text CONSTRAINT guardrail_assignments_level_check CHECK (level IS NULL OR level IN ('SAFE', 'STANDARD', 'ADVANCED', 'CUSTOM')),
  value             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT guardrail_assignments_value_object CHECK (soulbah.is_json_object(value)),
  created_by        text NOT NULL DEFAULT current_user,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT guardrail_assignments_unique UNIQUE NULLS NOT DISTINCT (guardrail_id, definition_id, project_id, environment_name)
);
COMMENT ON TABLE soulbah.guardrail_assignments IS 'Surcharge d''un garde-fou pour un agent, un projet ou un environnement (jamais au-delà de la valeur globale critique : vérifié par l''application).';
ALTER TABLE soulbah.guardrail_assignments ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_guardrail_assignments_definition ON soulbah.guardrail_assignments (definition_id);
CREATE INDEX IF NOT EXISTS idx_guardrail_assignments_project ON soulbah.guardrail_assignments (project_id);
CREATE INDEX IF NOT EXISTS idx_guardrail_assignments_env ON soulbah.guardrail_assignments (environment_name);

CREATE TABLE IF NOT EXISTS soulbah.guardrail_events (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  guardrail_id    uuid REFERENCES soulbah.guardrails(id) ON DELETE RESTRICT,
  kind            text NOT NULL CONSTRAINT guardrail_events_kind_check CHECK (kind IN ('changed', 'blocked', 'bypass_attempt', 'approval_requested', 'approved', 'denied')),
  principal_type  text NOT NULL CONSTRAINT guardrail_events_principal_type_check CHECK (principal_type IN ('user', 'agent', 'system')),
  principal_id    text NOT NULL,
  task_id         uuid,
  detail          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT guardrail_events_detail_object CHECK (soulbah.is_json_object(detail)),
  created_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.guardrail_events IS 'Événements des garde-fous (blocages, tentatives de contournement, demandes et décisions), ajout seul.';
ALTER TABLE soulbah.guardrail_events ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_guardrail_events_guardrail ON soulbah.guardrail_events (guardrail_id, id);
CREATE INDEX IF NOT EXISTS idx_guardrail_events_kind ON soulbah.guardrail_events (kind, id);
DROP TRIGGER IF EXISTS guardrail_events_append_only ON soulbah.guardrail_events;
CREATE TRIGGER guardrail_events_append_only BEFORE UPDATE OR DELETE ON soulbah.guardrail_events FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS guardrail_events_no_truncate ON soulbah.guardrail_events;
CREATE TRIGGER guardrail_events_no_truncate BEFORE TRUNCATE ON soulbah.guardrail_events FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

-- 5. Semences : garde-fous de base (niveau SAFE partout), politique de base --------------------------------
INSERT INTO soulbah.guardrails (key, category, name, description, level, value, critical, immutable) VALUES
  ('filesystem.scope', 'filesystem', 'Fichiers : dossiers autorisés seulement', 'Lecture et écriture confinées aux dossiers autorisés du PC ; liste noire (.env, .git, clés).', 'SAFE', '{"allow_outside_workspace": false}', false, false),
  ('terminal.allowlist', 'terminal', 'Terminal : liste fermée de programmes', 'git, npm, python, node, pytest ; confirmation humaine à chaque commande.', 'SAFE', '{"programs": ["git", "npm", "python", "node", "pytest"], "confirm_each": true}', false, false),
  ('database.changes', 'database', 'Base de données : migrations préparées, jamais appliquées seules', 'Les migrations sont préparées et testées sur copie ; application selon le niveau d''autonomie et l''environnement.', 'SAFE', '{"auto_migrate": {"LOCAL": true, "DEV": false, "TEST": false, "STAGING": false, "PRODUCTION": false}}', true, true),
  ('git.push', 'git', 'Git : push toujours confirmé', 'Push L3 confirmé par un humain ; jamais forcé.', 'SAFE', '{"require_confirmation": true, "force_push": false}', false, false),
  ('network.access', 'network', 'Réseau : Internet et IA externes refusés par défaut', 'Deux interrupteurs indépendants ; aucune donnée vers une IA externe quand External AI = OFF.', 'SAFE', '{"internet": false, "external_ai": false}', true, true),
  ('computer_control.input', 'computer_control', 'Contrôle de l''ordinateur : saisies sur confirmation', 'Souris, clavier et téléphone sur confirmation ; arrêt d''urgence toujours possible.', 'SAFE', '{"confirm_input": true}', false, false),
  ('production.changes', 'production', 'Production : aucun changement automatique', 'OFF, APPROVAL_REQUIRED ou LIMITED_AUTO ; barrière de sécurité avant tout déploiement.', 'SAFE', '{"mode": "OFF"}', true, true),
  ('secrets.handling', 'secrets', 'Secrets : jamais en clair', 'Jamais dans les prompts persistants, la mémoire, les journaux lisibles ni les captures.', 'SAFE', '{"redact": true, "vault_only": true}', true, true),
  ('payments.operations', 'payments', 'Paiements : interdits aux agents', 'Toute opération financière exige une validation PDG.', 'SAFE', '{"agents_allowed": false}', true, true),
  ('security.autopilot', 'security', 'Security Autopilot : OFF', 'OFF, MONITOR, FIX_IN_LAB, FIX_AND_TEST, SAFE_AUTO ; jamais de correctif direct en production.', 'SAFE', '{"mode": "OFF", "direct_production_patch": false}', true, true),
  ('self_improvement.mode', 'self_improvement', 'Auto-amélioration : OFF', 'OFF, PROPOSE_ONLY, LAB_AUTO, SAFE_AUTO ; jamais de modification du noyau actif ni des protections.', 'SAFE', '{"mode": "OFF", "can_modify_trusted_core": false}', true, true),
  ('agent_communication.bus', 'agent_communication', 'Communication entre agents : messages structurés', 'Bus typé (findings, tâches, preuves) ; jamais de conversation libre.', 'SAFE', '{"structured_only": true}', false, false)
ON CONFLICT (key) DO NOTHING;

-- La semence de la politique de base est immuable : la migration (chemin habilité, validée par un humain
-- avant application) se déverrouille le temps de la semence, puis se reverrouille.
SET LOCAL soulbah.trusted_core = 'unlocked';
INSERT INTO soulbah.policies (key, name, category, description, status, immutable)
VALUES ('baseline.safe', 'Politique de base SAFE', 'baseline',
        'Règles de départ : lecture libre dans le périmètre autorisé ; écritures en LOCAL/DEV ; toute action critique en approbation ; production et IA externes refusées aux agents.',
        'active', true)
ON CONFLICT (key) DO NOTHING;
INSERT INTO soulbah.policy_versions (policy_id, version, rules, reason, activated_at)
SELECT id, 1, '[]'::jsonb, 'Version initiale (DB LOT 4).', now() FROM soulbah.policies WHERE key = 'baseline.safe'
ON CONFLICT (policy_id, version) DO NOTHING;
INSERT INTO soulbah.policy_rules (version_id, permission, principal_type, environment_name, effect, priority)
SELECT v.id, r.permission, 'agent', r.env, r.effect, r.prio
FROM soulbah.policy_versions v JOIN soulbah.policies p ON p.id = v.policy_id AND p.key = 'baseline.safe' AND v.version = 1,
LATERAL (VALUES
  ('filesystem.read', NULL, 'allow', 10), ('git.read', NULL, 'allow', 10), ('database.read', NULL, 'allow', 10),
  ('security.scan', NULL, 'allow', 10), ('production.read', NULL, 'allow', 10),
  ('filesystem.write', 'LOCAL', 'allow', 20), ('filesystem.write', 'DEV', 'allow', 20), ('filesystem.write', 'PRODUCTION', 'deny', 5),
  ('terminal.execute', 'LOCAL', 'approval', 20), ('terminal.execute', 'DEV', 'approval', 20), ('terminal.execute', 'PRODUCTION', 'deny', 5),
  ('git.write', 'LOCAL', 'allow', 20), ('git.write', 'DEV', 'allow', 20), ('git.write', 'PRODUCTION', 'deny', 5),
  ('git.push', NULL, 'approval', 20),
  ('database.write', NULL, 'approval', 20), ('database.migrate', 'LOCAL', 'approval', 20), ('database.migrate', 'PRODUCTION', 'double_approval', 5),
  ('database.admin', NULL, 'deny', 5),
  ('production.deploy', NULL, 'double_approval', 5),
  ('network.internet', NULL, 'deny', 5), ('network.external_ai', NULL, 'deny', 5),
  ('computer.control', NULL, 'approval', 20),
  ('memory.write', NULL, 'allow', 10), ('knowledge.write', NULL, 'approval', 20), ('research.run', NULL, 'approval', 20),
  ('self_improvement.propose', NULL, 'allow', 10), ('self_improvement.test', NULL, 'approval', 20), ('self_improvement.activate', NULL, 'deny', 5),
  ('agents.manage', NULL, 'deny', 5), ('policies.manage', NULL, 'deny', 5), ('secrets.rotate', NULL, 'deny', 5),
  ('payments.execute', NULL, 'deny', 5), ('model.download', NULL, 'approval', 20), ('model.activate', NULL, 'approval', 20),
  ('image.generate', NULL, 'approval', 20)
) AS r(permission, env, effect, prio)
WHERE NOT EXISTS (SELECT 1 FROM soulbah.policy_rules x WHERE x.version_id = v.id AND x.permission = r.permission
                  AND x.environment_name IS NOT DISTINCT FROM r.env AND x.principal_type = 'agent');
UPDATE soulbah.policies p SET current_version_id = v.id
  FROM soulbah.policy_versions v WHERE v.policy_id = p.id AND v.version = 1 AND p.key = 'baseline.safe' AND p.current_version_id IS NULL;
INSERT INTO soulbah.policy_bindings (policy_id, principal_type)
SELECT id, 'any' FROM soulbah.policies WHERE key = 'baseline.safe' ON CONFLICT DO NOTHING;
SET LOCAL soulbah.trusted_core = '';

-- Les rôles PDG et super_admin portent toutes les permissions ; admin toutes sauf les critiques ; user aucune.
INSERT INTO soulbah.role_permissions (role_id, permission)
SELECT r.id, p.name FROM soulbah.roles r CROSS JOIN soulbah.permission_definitions p
WHERE r.name IN ('pdg', 'super_admin') OR (r.name = 'admin' AND NOT p.critical)
ON CONFLICT DO NOTHING;

DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON soulbah.permission_definitions, soulbah.roles, soulbah.role_permissions, soulbah.principal_roles, soulbah.resource_policies,
    soulbah.policies, soulbah.policy_versions, soulbah.policy_rules, soulbah.policy_bindings, soulbah.policy_decisions,
    soulbah.autonomy_rules, soulbah.autonomy_rules_history, soulbah.guardrails, soulbah.guardrail_versions,
    soulbah.guardrail_assignments, soulbah.guardrail_events FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.permission_definitions, soulbah.roles, soulbah.role_permissions, soulbah.principal_roles, '
                     'soulbah.resource_policies, soulbah.policies, soulbah.policy_versions, soulbah.policy_rules, soulbah.policy_bindings, '
                     'soulbah.policy_decisions, soulbah.autonomy_rules, soulbah.autonomy_rules_history, soulbah.guardrails, '
                     'soulbah.guardrail_versions, soulbah.guardrail_assignments, soulbah.guardrail_events FROM %I', r);
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.policy_versions_freeze(), soulbah.autonomy_rules_track(), soulbah.guardrails_track() FROM %I', r);
    END IF;
  END LOOP;
END $$;
