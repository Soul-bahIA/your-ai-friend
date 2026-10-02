-- =============================================================================
-- DB LOT 2 — Projects : registre des projets (Soulbah, 224Solutions, 224Connect…), dépôts, environnements,
-- composants, dépendances, versions.
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110200_db02_projects.down.sql (retirer d'abord les lots suivants qui référencent projects)
-- soulbah:transaction=single
-- Dépend de : db01 (environments, aides).
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.projects (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug           text NOT NULL UNIQUE CONSTRAINT projects_slug_format CHECK (slug ~ '^[a-z0-9][a-z0-9_-]{0,62}$'),
  name           text NOT NULL CONSTRAINT projects_name_length CHECK (length(name) BETWEEN 1 AND 200),
  kind           text NOT NULL DEFAULT 'application'
                 CONSTRAINT projects_kind_check CHECK (kind IN ('soulbah', 'application', 'service', 'library', 'infrastructure', 'other')),
  description    text NOT NULL DEFAULT '' CONSTRAINT projects_description_length CHECK (length(description) <= 4000),
  status         text NOT NULL DEFAULT 'active' CONSTRAINT projects_status_check CHECK (status IN ('active', 'paused', 'archived')),
  authorized     boolean NOT NULL DEFAULT true,
  owner_user_id  uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  settings       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT projects_settings_object CHECK (soulbah.is_json_object(settings)),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.projects IS 'Projets connus de Soulbah (lui-même, 224Solutions, 224Connect…) ; authorized = périmètre explicitement autorisé par le PDG.';
ALTER TABLE soulbah.projects ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.projects', '{"slug": "text", "kind": "text", "authorized": "boolean"}');
DROP TRIGGER IF EXISTS projects_set_updated_at ON soulbah.projects;
CREATE TRIGGER projects_set_updated_at BEFORE UPDATE ON soulbah.projects FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
INSERT INTO soulbah.projects (slug, name, kind, description) VALUES
  ('soulbah', 'Soulbah IA', 'soulbah', 'La plateforme elle-même (plan de contrôle, routeur de modèles, agent).'),
  ('224solutions', '224Solutions', 'application', 'Marketplace, transport, livraison, wallet et paiements. Code source à fournir.'),
  ('224connect', '224Connect', 'application', 'Réseau social (PWA, API Fastify, service FastAPI, 2 projets Supabase).')
ON CONFLICT (slug) DO NOTHING;

CREATE TABLE IF NOT EXISTS soulbah.project_repositories (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id           uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  name                 text NOT NULL CONSTRAINT project_repositories_name_length CHECK (length(name) BETWEEN 1 AND 200),
  location             text NOT NULL CONSTRAINT project_repositories_location_length CHECK (length(location) BETWEEN 1 AND 1000),
  kind                 text NOT NULL DEFAULT 'local_path' CONSTRAINT project_repositories_kind_check CHECK (kind IN ('local_path', 'git_remote')),
  vcs                  text NOT NULL DEFAULT 'git' CONSTRAINT project_repositories_vcs_check CHECK (vcs IN ('git', 'none')),
  default_branch       text,
  authorized           boolean NOT NULL DEFAULT true,
  access               text NOT NULL DEFAULT 'read_only' CONSTRAINT project_repositories_access_check CHECK (access IN ('read_only', 'read_write')),
  excluded_patterns    jsonb NOT NULL DEFAULT '[".env*", ".git/**", "**/.claude/**", "**/*credentials*", "**/*.pem", "**/*.key", "**/node_modules/**", "**/.venv/**"]'::jsonb
                       CONSTRAINT project_repositories_excluded_array CHECK (soulbah.is_json_array(excluded_patterns)),
  last_indexed_commit  text,
  last_indexed_at      timestamptz,
  metadata             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_repositories_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_repositories_unique UNIQUE (project_id, name)
);
COMMENT ON TABLE soulbah.project_repositories IS 'Dépôts d''un projet (chemin local ou dépôt distant) ; excluded_patterns = fichiers jamais lus ni indexés (secrets).';
ALTER TABLE soulbah.project_repositories ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS project_repositories_set_updated_at ON soulbah.project_repositories;
CREATE TRIGGER project_repositories_set_updated_at BEFORE UPDATE ON soulbah.project_repositories FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.project_environments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id        uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  environment_name  text NOT NULL REFERENCES soulbah.environments(name),
  base_url          text CONSTRAINT project_environments_url_length CHECK (base_url IS NULL OR length(base_url) <= 1000),
  db_source_id      uuid,
  deployment        jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_environments_deployment_object CHECK (soulbah.is_json_object(deployment)),
  is_active         boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_environments_unique UNIQUE (project_id, environment_name)
);
COMMENT ON TABLE soulbah.project_environments IS 'Environnements déployés d''un projet (DEV, STAGING, PRODUCTION…) : URL, source de base (db_sources, DB LOT 8), déploiement.';
ALTER TABLE soulbah.project_environments ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_environments_env ON soulbah.project_environments (environment_name);
DROP TRIGGER IF EXISTS project_environments_set_updated_at ON soulbah.project_environments;
CREATE TRIGGER project_environments_set_updated_at BEFORE UPDATE ON soulbah.project_environments FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.project_components (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id     uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  repository_id  uuid REFERENCES soulbah.project_repositories(id) ON DELETE SET NULL,
  key            text NOT NULL CONSTRAINT project_components_key_format CHECK (key ~ '^[a-z0-9][a-z0-9_.-]{0,99}$'),
  name           text NOT NULL CONSTRAINT project_components_name_length CHECK (length(name) BETWEEN 1 AND 200),
  kind           text NOT NULL CONSTRAINT project_components_kind_check
                 CHECK (kind IN ('frontend', 'backend', 'api', 'database', 'worker', 'mobile', 'infrastructure', 'library', 'other')),
  path           text CONSTRAINT project_components_path_length CHECK (path IS NULL OR length(path) <= 1000),
  description    text NOT NULL DEFAULT '' CONSTRAINT project_components_description_length CHECK (length(description) <= 4000),
  metadata       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_components_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_components_unique UNIQUE (project_id, key)
);
COMMENT ON TABLE soulbah.project_components IS 'Composants d''un projet (frontend, backend, API, base, worker…) et leur emplacement.';
ALTER TABLE soulbah.project_components ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_components_repository ON soulbah.project_components (repository_id);
DROP TRIGGER IF EXISTS project_components_set_updated_at ON soulbah.project_components;
CREATE TRIGGER project_components_set_updated_at BEFORE UPDATE ON soulbah.project_components FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.project_dependencies (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id            uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  component_id          uuid REFERENCES soulbah.project_components(id) ON DELETE SET NULL,
  ecosystem             text NOT NULL CONSTRAINT project_dependencies_ecosystem_check
                        CHECK (ecosystem IN ('npm', 'pypi', 'cargo', 'go', 'maven', 'nuget', 'gem', 'docker', 'other')),
  name                  text NOT NULL CONSTRAINT project_dependencies_name_length CHECK (length(name) BETWEEN 1 AND 300),
  version               text NOT NULL CONSTRAINT project_dependencies_version_length CHECK (length(version) BETWEEN 1 AND 100),
  source                text CONSTRAINT project_dependencies_source_length CHECK (source IS NULL OR length(source) <= 1000),
  is_dev                boolean NOT NULL DEFAULT false,
  vulnerabilities       jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT project_dependencies_vulns_array CHECK (soulbah.is_json_array(vulnerabilities)),
  vulnerability_status  text NOT NULL DEFAULT 'unknown'
                        CONSTRAINT project_dependencies_vuln_status_check CHECK (vulnerability_status IN ('unknown', 'clean', 'vulnerable', 'mitigated')),
  first_seen_at         timestamptz NOT NULL DEFAULT now(),
  last_seen_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_dependencies_unique UNIQUE NULLS NOT DISTINCT (project_id, component_id, ecosystem, name, version)
);
COMMENT ON TABLE soulbah.project_dependencies IS 'Inventaire des dépendances (paquet, version, écosystème) et vulnérabilités connues (sources autorisées).';
ALTER TABLE soulbah.project_dependencies ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_dependencies_vuln ON soulbah.project_dependencies (project_id, vulnerability_status);
CREATE INDEX IF NOT EXISTS idx_project_dependencies_component ON soulbah.project_dependencies (component_id);

CREATE TABLE IF NOT EXISTS soulbah.project_versions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id        uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  version           text NOT NULL CONSTRAINT project_versions_version_length CHECK (length(version) BETWEEN 1 AND 100),
  app_commit        text,
  environment_name  text REFERENCES soulbah.environments(name),
  released_at       timestamptz,
  notes             text NOT NULL DEFAULT '' CONSTRAINT project_versions_notes_length CHECK (length(notes) <= 4000),
  metadata          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_versions_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_versions_unique UNIQUE NULLS NOT DISTINCT (project_id, version, environment_name)
);
COMMENT ON TABLE soulbah.project_versions IS 'Versions livrées d''un projet par environnement (commit, date).';
ALTER TABLE soulbah.project_versions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_versions_env ON soulbah.project_versions (environment_name);

DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON soulbah.projects, soulbah.project_repositories, soulbah.project_environments, soulbah.project_components,
    soulbah.project_dependencies, soulbah.project_versions FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.projects, soulbah.project_repositories, soulbah.project_environments, '
                     'soulbah.project_components, soulbah.project_dependencies, soulbah.project_versions FROM %I', r);
    END IF;
  END LOOP;
END $$;
