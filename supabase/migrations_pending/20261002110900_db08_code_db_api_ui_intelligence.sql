-- =============================================================================
-- DB LOT 8 — Code, Database, API et UI intelligence + parcours utilisateurs : références et métadonnées du code
-- (jamais son contenu), architecture des bases autorisées, services et endpoints, écrans et actions, parcours.
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110900_db08_code_db_api_ui_intelligence.down.sql (index reconstructible par le Project Brain)
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03, db07. Volumes attendus : milliers de fichiers et symboles par projet → index sur
-- toutes les clés étrangères et les recherches par nom.
-- =============================================================================

-- 1. Code --------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.code_files (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id      uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  repository_id   uuid NOT NULL REFERENCES soulbah.project_repositories(id) ON DELETE CASCADE,
  path            text NOT NULL CONSTRAINT code_files_path_length CHECK (length(path) BETWEEN 1 AND 1000),
  language        text CONSTRAINT code_files_language_length CHECK (language IS NULL OR length(language) <= 40),
  size_bytes      bigint CONSTRAINT code_files_size_positive CHECK (size_bytes IS NULL OR size_bytes >= 0),
  line_count      integer CONSTRAINT code_files_lines_positive CHECK (line_count IS NULL OR line_count >= 0),
  content_hash    text CONSTRAINT code_files_hash_format CHECK (content_hash IS NULL OR content_hash ~ '^[0-9a-f]{64}$'),
  last_commit     text,
  index_state     text NOT NULL DEFAULT 'indexed' CONSTRAINT code_files_index_state_check CHECK (index_state IN ('indexed', 'stale', 'excluded', 'failed')),
  excluded_reason text,
  indexed_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT code_files_unique UNIQUE (repository_id, path)
);
COMMENT ON TABLE soulbah.code_files IS 'Fichiers des dépôts autorisés : chemin, langage, taille, empreinte, état d''indexation (le contenu reste sur disque).';
ALTER TABLE soulbah.code_files ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.code_files', '{"repository_id": "uuid", "path": "text", "content_hash": "text", "index_state": "text"}');
CREATE INDEX IF NOT EXISTS idx_code_files_project ON soulbah.code_files (project_id, index_state);
CREATE INDEX IF NOT EXISTS idx_code_files_hash ON soulbah.code_files (content_hash);
DROP TRIGGER IF EXISTS code_files_set_updated_at ON soulbah.code_files;
CREATE TRIGGER code_files_set_updated_at BEFORE UPDATE ON soulbah.code_files FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.code_symbols (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id      uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  file_id         uuid NOT NULL REFERENCES soulbah.code_files(id) ON DELETE CASCADE,
  kind            text NOT NULL CONSTRAINT code_symbols_kind_check CHECK (kind IN (
                    'module', 'class', 'function', 'method', 'interface', 'type', 'enum', 'variable', 'constant',
                    'component', 'route_handler', 'migration', 'sql_function', 'sql_table', 'test', 'other')),
  name            text NOT NULL CONSTRAINT code_symbols_name_length CHECK (length(name) BETWEEN 1 AND 300),
  qualified_name  text NOT NULL CONSTRAINT code_symbols_qualified_length CHECK (length(qualified_name) BETWEEN 1 AND 600),
  signature       text CONSTRAINT code_symbols_signature_length CHECK (signature IS NULL OR length(signature) <= 2000),
  line_start      integer NOT NULL CONSTRAINT code_symbols_line_start_positive CHECK (line_start >= 1),
  line_end        integer CONSTRAINT code_symbols_line_end_positive CHECK (line_end IS NULL OR line_end >= line_start),
  exported        boolean NOT NULL DEFAULT false,
  docstring       text CONSTRAINT code_symbols_docstring_length CHECK (docstring IS NULL OR length(docstring) <= 4000),
  content_hash    text CONSTRAINT code_symbols_hash_format CHECK (content_hash IS NULL OR content_hash ~ '^[0-9a-f]{64}$'),
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT code_symbols_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT code_symbols_unique UNIQUE (file_id, qualified_name, line_start)
);
COMMENT ON TABLE soulbah.code_symbols IS 'Symboles extraits par AST (classes, fonctions, composants, routes, fonctions SQL…) : nom qualifié, signature, position, export.';
ALTER TABLE soulbah.code_symbols ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_code_symbols_project_name ON soulbah.code_symbols (project_id, name);
CREATE INDEX IF NOT EXISTS idx_code_symbols_qualified ON soulbah.code_symbols (qualified_name);
CREATE INDEX IF NOT EXISTS idx_code_symbols_kind ON soulbah.code_symbols (project_id, kind);
DROP TRIGGER IF EXISTS code_symbols_set_updated_at ON soulbah.code_symbols;
CREATE TRIGGER code_symbols_set_updated_at BEFORE UPDATE ON soulbah.code_symbols FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.code_dependencies (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id    uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  from_file_id  uuid NOT NULL REFERENCES soulbah.code_files(id) ON DELETE CASCADE,
  to_file_id    uuid REFERENCES soulbah.code_files(id) ON DELETE CASCADE,
  to_module     text CONSTRAINT code_dependencies_module_length CHECK (to_module IS NULL OR length(to_module) <= 300),
  kind          text NOT NULL DEFAULT 'import' CONSTRAINT code_dependencies_kind_check CHECK (kind IN ('import', 'require', 'include', 'dynamic', 'type_only')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT code_dependencies_target CHECK (to_file_id IS NOT NULL OR to_module IS NOT NULL),
  CONSTRAINT code_dependencies_unique UNIQUE NULLS NOT DISTINCT (from_file_id, to_file_id, to_module, kind)
);
COMMENT ON TABLE soulbah.code_dependencies IS 'Dépendances entre fichiers (interne : to_file_id) ou vers un module externe (to_module).';
ALTER TABLE soulbah.code_dependencies ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_code_dependencies_to ON soulbah.code_dependencies (to_file_id);
CREATE INDEX IF NOT EXISTS idx_code_dependencies_project ON soulbah.code_dependencies (project_id);

CREATE TABLE IF NOT EXISTS soulbah.code_references (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id      uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  from_symbol_id  uuid NOT NULL REFERENCES soulbah.code_symbols(id) ON DELETE CASCADE,
  to_symbol_id    uuid REFERENCES soulbah.code_symbols(id) ON DELETE CASCADE,
  to_name         text CONSTRAINT code_references_to_name_length CHECK (to_name IS NULL OR length(to_name) <= 600),
  kind            text NOT NULL CONSTRAINT code_references_kind_check CHECK (kind IN ('call', 'read', 'write', 'instantiate', 'extend', 'implement', 'decorate', 'reference')),
  line            integer CONSTRAINT code_references_line_positive CHECK (line IS NULL OR line >= 1),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT code_references_target CHECK (to_symbol_id IS NOT NULL OR to_name IS NOT NULL)
);
COMMENT ON TABLE soulbah.code_references IS 'Références entre symboles (appels, lectures, écritures, héritage…) : qui appelle quoi — base de l''analyse d''impact (§6).';
ALTER TABLE soulbah.code_references ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_code_references_from ON soulbah.code_references (from_symbol_id);
CREATE INDEX IF NOT EXISTS idx_code_references_to ON soulbah.code_references (to_symbol_id);
CREATE INDEX IF NOT EXISTS idx_code_references_project ON soulbah.code_references (project_id);

CREATE TABLE IF NOT EXISTS soulbah.code_change_events (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- Journal en ajout seul : RESTRICT vers projet et dépôt (se désactivent, ne se suppriment pas) ; file_id sans
  -- FK car les lignes de code_files sont supprimées et recréées à chaque réindexation (le chemin est conservé).
  project_id     uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE RESTRICT,
  repository_id  uuid REFERENCES soulbah.project_repositories(id) ON DELETE RESTRICT,
  file_id        uuid,
  path           text CONSTRAINT code_change_events_path_length CHECK (path IS NULL OR length(path) <= 1000),
  kind           text NOT NULL CONSTRAINT code_change_events_kind_check CHECK (kind IN (
                   'created', 'modified', 'deleted', 'renamed', 'commit', 'merge', 'dependency_update', 'migration', 'deployment', 'reindex')),
  app_commit     text,
  detail         jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT code_change_events_detail_object CHECK (soulbah.is_json_object(detail)),
  detected_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.code_change_events IS 'Événements vus par le ProjectWatcher (§15) : fichier changé, commit, fusion, mise à jour de dépendance, migration, déploiement ; ajout seul.';
ALTER TABLE soulbah.code_change_events ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_code_change_events_project ON soulbah.code_change_events (project_id, id);
CREATE INDEX IF NOT EXISTS idx_code_change_events_file ON soulbah.code_change_events (file_id);
CREATE INDEX IF NOT EXISTS idx_code_change_events_repository ON soulbah.code_change_events (repository_id);
DROP TRIGGER IF EXISTS code_change_events_append_only ON soulbah.code_change_events;
CREATE TRIGGER code_change_events_append_only BEFORE UPDATE OR DELETE ON soulbah.code_change_events FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS code_change_events_no_truncate ON soulbah.code_change_events;
CREATE TRIGGER code_change_events_no_truncate BEFORE TRUNCATE ON soulbah.code_change_events FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE TABLE IF NOT EXISTS soulbah.code_index_state (
  repository_id         uuid PRIMARY KEY REFERENCES soulbah.project_repositories(id) ON DELETE CASCADE,
  status                text NOT NULL DEFAULT 'idle' CONSTRAINT code_index_state_status_check CHECK (status IN ('idle', 'indexing', 'incremental', 'failed')),
  last_full_index_at    timestamptz,
  last_incremental_at   timestamptz,
  last_commit           text,
  files_total           integer NOT NULL DEFAULT 0 CONSTRAINT code_index_state_files_total_positive CHECK (files_total >= 0),
  files_indexed         integer NOT NULL DEFAULT 0 CONSTRAINT code_index_state_files_indexed_positive CHECK (files_indexed >= 0),
  symbols_total         integer NOT NULL DEFAULT 0 CONSTRAINT code_index_state_symbols_positive CHECK (symbols_total >= 0),
  error                 text,
  updated_at            timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.code_index_state IS 'État de l''index de chaque dépôt (dernier scan complet, dernier incrément, commit, compteurs) — indexation incrémentale (§14).';
ALTER TABLE soulbah.code_index_state ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS code_index_state_set_updated_at ON soulbah.code_index_state;
CREATE TRIGGER code_index_state_set_updated_at BEFORE UPDATE ON soulbah.code_index_state FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- 2. Bases de données des projets ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.db_sources (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id        uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  name              text NOT NULL CONSTRAINT db_sources_name_length CHECK (length(name) BETWEEN 1 AND 200),
  kind              text NOT NULL CONSTRAINT db_sources_kind_check CHECK (kind IN ('postgres', 'supabase', 'mysql', 'sqlite', 'other')),
  environment_name  text NOT NULL REFERENCES soulbah.environments(name),
  connection_ref    text CONSTRAINT db_sources_connection_ref_length CHECK (connection_ref IS NULL OR length(connection_ref) <= 200),
  host_label        text CONSTRAINT db_sources_host_label_length CHECK (host_label IS NULL OR length(host_label) <= 200),
  read_only         boolean NOT NULL DEFAULT true,
  authorized        boolean NOT NULL DEFAULT false,
  last_snapshot_at  timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT db_sources_unique UNIQUE (project_id, name),
  -- connection_ref est le NOM d'un secret du coffre, jamais une URL avec mot de passe.
  CONSTRAINT db_sources_no_credentials CHECK (connection_ref IS NULL OR connection_ref !~* '(://|password=|pwd=)')
);
COMMENT ON TABLE soulbah.db_sources IS 'Bases des projets (par environnement) : référence de connexion = nom d''un secret du coffre (jamais d''identifiants ici) ; lecture seule par défaut ; autorisation explicite.';
ALTER TABLE soulbah.db_sources ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_db_sources_env ON soulbah.db_sources (environment_name);
DROP TRIGGER IF EXISTS db_sources_set_updated_at ON soulbah.db_sources;
CREATE TRIGGER db_sources_set_updated_at BEFORE UPDATE ON soulbah.db_sources FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'project_environments_db_source_fkey') THEN
    ALTER TABLE soulbah.project_environments ADD CONSTRAINT project_environments_db_source_fkey
      FOREIGN KEY (db_source_id) REFERENCES soulbah.db_sources(id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_project_environments_db_source ON soulbah.project_environments (db_source_id);

CREATE TABLE IF NOT EXISTS soulbah.db_snapshots (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id            uuid NOT NULL REFERENCES soulbah.db_sources(id) ON DELETE CASCADE,
  server_version       text,
  schema_hash          text CONSTRAINT db_snapshots_hash_format CHECK (schema_hash IS NULL OR schema_hash ~ '^[0-9a-f]{64}$'),
  object_counts        jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT db_snapshots_counts_object CHECK (soulbah.is_json_object(object_counts)),
  catalog_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  taken_at             timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.db_snapshots IS 'Instantanés du catalogue d''une base (empreinte, version, comptes ; catalogue complet en artefact) — base des diffs de schéma.';
ALTER TABLE soulbah.db_snapshots ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_db_snapshots_source ON soulbah.db_snapshots (source_id, taken_at DESC);
CREATE INDEX IF NOT EXISTS idx_db_snapshots_artifact ON soulbah.db_snapshots (catalog_artifact_id);

CREATE TABLE IF NOT EXISTS soulbah.db_schemas (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id   uuid NOT NULL REFERENCES soulbah.db_sources(id) ON DELETE CASCADE,
  name        text NOT NULL CONSTRAINT db_schemas_name_length CHECK (length(name) BETWEEN 1 AND 200),
  owner       text,
  managed_by  text NOT NULL DEFAULT 'app' CONSTRAINT db_schemas_managed_by_check CHECK (managed_by IN ('app', 'supabase', 'extension', 'system', 'unknown')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT db_schemas_unique UNIQUE (source_id, name)
);
ALTER TABLE soulbah.db_schemas ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.db_schemas IS 'Schémas d''une base et leur gestionnaire (application, Supabase, extension).';

CREATE TABLE IF NOT EXISTS soulbah.db_tables (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  schema_id     uuid NOT NULL REFERENCES soulbah.db_schemas(id) ON DELETE CASCADE,
  name          text NOT NULL CONSTRAINT db_tables_name_length CHECK (length(name) BETWEEN 1 AND 200),
  kind          text NOT NULL DEFAULT 'table' CONSTRAINT db_tables_kind_check CHECK (kind IN ('table', 'view', 'matview', 'foreign', 'partition')),
  rls_enabled   boolean,
  row_estimate  bigint,
  size_bytes    bigint,
  comment       text,
  sensitivity   text NOT NULL DEFAULT 'unknown' CONSTRAINT db_tables_sensitivity_check CHECK (sensitivity IN ('unknown', 'public', 'internal', 'confidential', 'secret')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT db_tables_unique UNIQUE (schema_id, name)
);
ALTER TABLE soulbah.db_tables ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.db_tables IS 'Tables et vues d''une base : RLS, volumes, sensibilité des données (§42, §65).';
DROP TRIGGER IF EXISTS db_tables_set_updated_at ON soulbah.db_tables;
CREATE TRIGGER db_tables_set_updated_at BEFORE UPDATE ON soulbah.db_tables FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.db_columns (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  table_id      uuid NOT NULL REFERENCES soulbah.db_tables(id) ON DELETE CASCADE,
  name          text NOT NULL CONSTRAINT db_columns_name_length CHECK (length(name) BETWEEN 1 AND 200),
  position      integer NOT NULL CONSTRAINT db_columns_position_positive CHECK (position >= 1),
  data_type     text NOT NULL,
  nullable      boolean NOT NULL DEFAULT true,
  default_expr  text,
  is_pk         boolean NOT NULL DEFAULT false,
  sensitivity   text NOT NULL DEFAULT 'unknown' CONSTRAINT db_columns_sensitivity_check CHECK (sensitivity IN ('unknown', 'public', 'internal', 'confidential', 'secret')),
  comment       text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT db_columns_unique UNIQUE (table_id, name)
);
ALTER TABLE soulbah.db_columns ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.db_columns IS 'Colonnes : type, nullité, défaut, clé primaire, sensibilité.';

CREATE TABLE IF NOT EXISTS soulbah.db_relations (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id      uuid NOT NULL REFERENCES soulbah.db_sources(id) ON DELETE CASCADE,
  from_table_id  uuid NOT NULL REFERENCES soulbah.db_tables(id) ON DELETE CASCADE,
  to_table_id    uuid NOT NULL REFERENCES soulbah.db_tables(id) ON DELETE CASCADE,
  kind           text NOT NULL DEFAULT 'foreign_key' CONSTRAINT db_relations_kind_check CHECK (kind IN ('foreign_key', 'logical', 'inferred')),
  name           text,
  columns        jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT db_relations_columns_array CHECK (soulbah.is_json_array(columns)),
  ref_columns    jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT db_relations_ref_columns_array CHECK (soulbah.is_json_array(ref_columns)),
  on_delete      text,
  validated      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT db_relations_unique UNIQUE NULLS NOT DISTINCT (from_table_id, to_table_id, name, kind)
);
ALTER TABLE soulbah.db_relations ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.db_relations IS 'Relations entre tables : clés étrangères déclarées, logiques (code) ou inférées.';
CREATE INDEX IF NOT EXISTS idx_db_relations_to ON soulbah.db_relations (to_table_id);
CREATE INDEX IF NOT EXISTS idx_db_relations_source ON soulbah.db_relations (source_id);

CREATE TABLE IF NOT EXISTS soulbah.db_indexes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  table_id    uuid NOT NULL REFERENCES soulbah.db_tables(id) ON DELETE CASCADE,
  name        text NOT NULL,
  definition  text NOT NULL,
  is_unique   boolean NOT NULL DEFAULT false,
  is_primary  boolean NOT NULL DEFAULT false,
  columns     jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT db_indexes_columns_array CHECK (soulbah.is_json_array(columns)),
  size_bytes  bigint,
  scans       bigint,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT db_indexes_unique UNIQUE (table_id, name)
);
ALTER TABLE soulbah.db_indexes ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.db_indexes IS 'Index d''une table (définition, unicité, taille, usage) — base de l''audit de performance (§88).';

CREATE TABLE IF NOT EXISTS soulbah.db_policies (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  table_id    uuid NOT NULL REFERENCES soulbah.db_tables(id) ON DELETE CASCADE,
  name        text NOT NULL,
  command     text NOT NULL,
  roles       jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT db_policies_roles_array CHECK (soulbah.is_json_array(roles)),
  using_expr  text,
  check_expr  text,
  permissive  boolean NOT NULL DEFAULT true,
  risk        text NOT NULL DEFAULT 'unknown' CONSTRAINT db_policies_risk_check CHECK (risk IN ('unknown', 'ok', 'review', 'risky')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT db_policies_unique UNIQUE (table_id, name)
);
ALTER TABLE soulbah.db_policies ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.db_policies IS 'Policies RLS relevées (commande, rôles, expressions) et niveau de risque évalué (§42).';

CREATE TABLE IF NOT EXISTS soulbah.db_functions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  schema_id         uuid NOT NULL REFERENCES soulbah.db_schemas(id) ON DELETE CASCADE,
  name              text NOT NULL,
  args              text NOT NULL DEFAULT '',
  returns           text,
  language          text,
  security_definer  boolean NOT NULL DEFAULT false,
  search_path_set   boolean,
  exposed_via_api   boolean,
  source_hash       text,
  risk              text NOT NULL DEFAULT 'unknown' CONSTRAINT db_functions_risk_check CHECK (risk IN ('unknown', 'ok', 'review', 'risky')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT db_functions_unique UNIQUE (schema_id, name, args)
);
ALTER TABLE soulbah.db_functions ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.db_functions IS 'Fonctions et procédures : SECURITY DEFINER, search_path, exposition par l''API, risque.';

CREATE TABLE IF NOT EXISTS soulbah.db_triggers (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  table_id       uuid NOT NULL REFERENCES soulbah.db_tables(id) ON DELETE CASCADE,
  name           text NOT NULL,
  definition     text NOT NULL,
  function_name  text,
  enabled        boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT db_triggers_unique UNIQUE (table_id, name)
);
ALTER TABLE soulbah.db_triggers ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.db_triggers IS 'Triggers d''une table et fonction appelée.';

-- Lien code ↔ base (§7) : quel fichier ou symbole lit, écrit ou modifie quelle table.
CREATE TABLE IF NOT EXISTS soulbah.db_table_usages (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  table_id   uuid NOT NULL REFERENCES soulbah.db_tables(id) ON DELETE CASCADE,
  file_id    uuid REFERENCES soulbah.code_files(id) ON DELETE CASCADE,
  symbol_id  uuid REFERENCES soulbah.code_symbols(id) ON DELETE CASCADE,
  kind       text NOT NULL CONSTRAINT db_table_usages_kind_check CHECK (kind IN ('read', 'write', 'ddl', 'rpc', 'unknown')),
  evidence   text CONSTRAINT db_table_usages_evidence_length CHECK (evidence IS NULL OR length(evidence) <= 2000),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT db_table_usages_source CHECK (file_id IS NOT NULL OR symbol_id IS NOT NULL),
  CONSTRAINT db_table_usages_unique UNIQUE NULLS NOT DISTINCT (table_id, file_id, symbol_id, kind)
);
ALTER TABLE soulbah.db_table_usages ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.db_table_usages IS 'Code ↔ base : fichiers et symboles qui utilisent chaque table (lecture, écriture, DDL, RPC).';
CREATE INDEX IF NOT EXISTS idx_db_table_usages_file ON soulbah.db_table_usages (file_id);
CREATE INDEX IF NOT EXISTS idx_db_table_usages_symbol ON soulbah.db_table_usages (symbol_id);

-- 3. API ----------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.api_services (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id       uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  component_id     uuid REFERENCES soulbah.project_components(id) ON DELETE SET NULL,
  name             text NOT NULL CONSTRAINT api_services_name_length CHECK (length(name) BETWEEN 1 AND 200),
  kind             text NOT NULL DEFAULT 'rest' CONSTRAINT api_services_kind_check CHECK (kind IN ('rest', 'graphql', 'rpc', 'websocket', 'webhook', 'grpc', 'other')),
  base_path        text,
  base_url_by_env  jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT api_services_urls_object CHECK (soulbah.is_json_object(base_url_by_env)),
  auth_scheme      text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT api_services_unique UNIQUE (project_id, name)
);
ALTER TABLE soulbah.api_services ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.api_services IS 'Services exposant une API (REST, GraphQL, RPC, websocket, webhooks) et leur schéma d''authentification.';
CREATE INDEX IF NOT EXISTS idx_api_services_component ON soulbah.api_services (component_id);
DROP TRIGGER IF EXISTS api_services_set_updated_at ON soulbah.api_services;
CREATE TRIGGER api_services_set_updated_at BEFORE UPDATE ON soulbah.api_services FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.api_endpoints (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id         uuid NOT NULL REFERENCES soulbah.api_services(id) ON DELETE CASCADE,
  method             text NOT NULL CONSTRAINT api_endpoints_method_check CHECK (method IN ('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS', 'HEAD', 'ANY', 'SUBSCRIBE')),
  path               text NOT NULL CONSTRAINT api_endpoints_path_length CHECK (length(path) BETWEEN 1 AND 500),
  handler_symbol_id  uuid REFERENCES soulbah.code_symbols(id) ON DELETE SET NULL,
  auth_required      boolean,
  roles_required     jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT api_endpoints_roles_array CHECK (soulbah.is_json_array(roles_required)),
  rate_limited       boolean,
  input_schema       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT api_endpoints_input_object CHECK (soulbah.is_json_object(input_schema)),
  output_schema      jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT api_endpoints_output_object CHECK (soulbah.is_json_object(output_schema)),
  risk               text NOT NULL DEFAULT 'unknown' CONSTRAINT api_endpoints_risk_check CHECK (risk IN ('unknown', 'ok', 'review', 'risky')),
  last_seen_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT api_endpoints_unique UNIQUE (service_id, method, path)
);
ALTER TABLE soulbah.api_endpoints ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.api_endpoints IS 'Endpoints : méthode, chemin, handler, authentification, rôles, limitation de débit, schémas, risque (§45).';
CREATE INDEX IF NOT EXISTS idx_api_endpoints_handler ON soulbah.api_endpoints (handler_symbol_id);
CREATE INDEX IF NOT EXISTS idx_api_endpoints_risk ON soulbah.api_endpoints (risk) WHERE risk IN ('review', 'risky');
DROP TRIGGER IF EXISTS api_endpoints_set_updated_at ON soulbah.api_endpoints;
CREATE TRIGGER api_endpoints_set_updated_at BEFORE UPDATE ON soulbah.api_endpoints FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.api_dependencies (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  endpoint_id      uuid NOT NULL REFERENCES soulbah.api_endpoints(id) ON DELETE CASCADE,
  depends_on_kind  text NOT NULL CONSTRAINT api_dependencies_kind_check CHECK (depends_on_kind IN ('endpoint', 'table', 'db_function', 'external_service', 'queue', 'storage', 'model', 'secret')),
  depends_on_id    uuid,
  depends_on_ref   text CONSTRAINT api_dependencies_ref_length CHECK (depends_on_ref IS NULL OR length(depends_on_ref) <= 500),
  usage            text NOT NULL CONSTRAINT api_dependencies_usage_check CHECK (usage IN ('reads', 'writes', 'calls', 'publishes', 'consumes')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT api_dependencies_target CHECK (depends_on_id IS NOT NULL OR depends_on_ref IS NOT NULL),
  CONSTRAINT api_dependencies_unique UNIQUE NULLS NOT DISTINCT (endpoint_id, depends_on_kind, depends_on_id, depends_on_ref, usage)
);
ALTER TABLE soulbah.api_dependencies ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.api_dependencies IS 'Ce dont dépend un endpoint : autres endpoints, tables, fonctions SQL, services externes, files, stockage, modèles.';

CREATE TABLE IF NOT EXISTS soulbah.api_consumers (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  endpoint_id    uuid NOT NULL REFERENCES soulbah.api_endpoints(id) ON DELETE CASCADE,
  consumer_kind  text NOT NULL CONSTRAINT api_consumers_kind_check CHECK (consumer_kind IN ('ui_route', 'ui_component', 'service', 'job', 'external', 'agent', 'unknown')),
  consumer_id    uuid,
  consumer_ref   text CONSTRAINT api_consumers_ref_length CHECK (consumer_ref IS NULL OR length(consumer_ref) <= 500),
  evidence       text CONSTRAINT api_consumers_evidence_length CHECK (evidence IS NULL OR length(evidence) <= 2000),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT api_consumers_target CHECK (consumer_id IS NOT NULL OR consumer_ref IS NOT NULL),
  CONSTRAINT api_consumers_unique UNIQUE NULLS NOT DISTINCT (endpoint_id, consumer_kind, consumer_id, consumer_ref)
);
ALTER TABLE soulbah.api_consumers ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.api_consumers IS 'Qui appelle chaque endpoint (écran, composant, service, tâche, externe, agent) — un endpoint sans consommateur connu est une zone inconnue.';

CREATE TABLE IF NOT EXISTS soulbah.api_security_rules (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  endpoint_id  uuid REFERENCES soulbah.api_endpoints(id) ON DELETE CASCADE,
  service_id   uuid REFERENCES soulbah.api_services(id) ON DELETE CASCADE,
  rule         text NOT NULL CONSTRAINT api_security_rules_rule_check CHECK (rule IN (
                 'auth_required', 'role_required', 'rate_limit', 'input_validation', 'output_filtering', 'cors', 'csrf',
                 'idempotency', 'audit', 'tenant_isolation', 'secrets_not_logged')),
  expected     jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT api_security_rules_expected_object CHECK (soulbah.is_json_object(expected)),
  observed     jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT api_security_rules_observed_object CHECK (soulbah.is_json_object(observed)),
  status       text NOT NULL DEFAULT 'unknown' CONSTRAINT api_security_rules_status_check CHECK (status IN ('unknown', 'satisfied', 'violated', 'not_applicable')),
  evidence     text CONSTRAINT api_security_rules_evidence_length CHECK (evidence IS NULL OR length(evidence) <= 4000),
  checked_at   timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT api_security_rules_scope CHECK (endpoint_id IS NOT NULL OR service_id IS NOT NULL)
);
ALTER TABLE soulbah.api_security_rules ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.api_security_rules IS 'Règles de sécurité attendues et observées sur un service ou un endpoint (authentification, rôles, débit, validation, isolation des tenants…).';
CREATE INDEX IF NOT EXISTS idx_api_security_rules_endpoint ON soulbah.api_security_rules (endpoint_id);
CREATE INDEX IF NOT EXISTS idx_api_security_rules_service ON soulbah.api_security_rules (service_id);
CREATE INDEX IF NOT EXISTS idx_api_security_rules_violated ON soulbah.api_security_rules (status) WHERE status = 'violated';

-- 4. Interfaces ---------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.ui_surfaces (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id    uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  component_id  uuid REFERENCES soulbah.project_components(id) ON DELETE SET NULL,
  name          text NOT NULL CONSTRAINT ui_surfaces_name_length CHECK (length(name) BETWEEN 1 AND 200),
  kind          text NOT NULL DEFAULT 'web' CONSTRAINT ui_surfaces_kind_check CHECK (kind IN ('web', 'admin', 'mobile', 'desktop', 'cli')),
  base_path     text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ui_surfaces_unique UNIQUE (project_id, name)
);
ALTER TABLE soulbah.ui_surfaces ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.ui_surfaces IS 'Interfaces d''un projet (web, console admin, mobile…).';
CREATE INDEX IF NOT EXISTS idx_ui_surfaces_component ON soulbah.ui_surfaces (component_id);
DROP TRIGGER IF EXISTS ui_surfaces_set_updated_at ON soulbah.ui_surfaces;
CREATE TRIGGER ui_surfaces_set_updated_at BEFORE UPDATE ON soulbah.ui_surfaces FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.ui_routes (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  surface_id      uuid NOT NULL REFERENCES soulbah.ui_surfaces(id) ON DELETE CASCADE,
  path            text NOT NULL CONSTRAINT ui_routes_path_length CHECK (length(path) BETWEEN 1 AND 500),
  name            text,
  file_id         uuid REFERENCES soulbah.code_files(id) ON DELETE SET NULL,
  auth_required   boolean,
  roles_required  jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT ui_routes_roles_array CHECK (soulbah.is_json_array(roles_required)),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ui_routes_unique UNIQUE (surface_id, path)
);
ALTER TABLE soulbah.ui_routes ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.ui_routes IS 'Routes et écrans d''une interface, fichier source, permissions.';
CREATE INDEX IF NOT EXISTS idx_ui_routes_file ON soulbah.ui_routes (file_id);
DROP TRIGGER IF EXISTS ui_routes_set_updated_at ON soulbah.ui_routes;
CREATE TRIGGER ui_routes_set_updated_at BEFORE UPDATE ON soulbah.ui_routes FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.ui_components (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  surface_id  uuid NOT NULL REFERENCES soulbah.ui_surfaces(id) ON DELETE CASCADE,
  name        text NOT NULL CONSTRAINT ui_components_name_length CHECK (length(name) BETWEEN 1 AND 200),
  kind        text NOT NULL DEFAULT 'widget' CONSTRAINT ui_components_kind_check CHECK (kind IN ('page', 'layout', 'widget', 'form', 'dialog', 'other')),
  file_id     uuid REFERENCES soulbah.code_files(id) ON DELETE SET NULL,
  symbol_id   uuid REFERENCES soulbah.code_symbols(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ui_components_unique UNIQUE NULLS NOT DISTINCT (surface_id, name, file_id)
);
ALTER TABLE soulbah.ui_components ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.ui_components IS 'Composants d''interface (pages, formulaires, dialogues) et leur symbole de code.';
CREATE INDEX IF NOT EXISTS idx_ui_components_file ON soulbah.ui_components (file_id);
CREATE INDEX IF NOT EXISTS idx_ui_components_symbol ON soulbah.ui_components (symbol_id);
DROP TRIGGER IF EXISTS ui_components_set_updated_at ON soulbah.ui_components;
CREATE TRIGGER ui_components_set_updated_at BEFORE UPDATE ON soulbah.ui_components FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.ui_actions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  component_id  uuid REFERENCES soulbah.ui_components(id) ON DELETE CASCADE,
  route_id      uuid REFERENCES soulbah.ui_routes(id) ON DELETE CASCADE,
  name          text NOT NULL CONSTRAINT ui_actions_name_length CHECK (length(name) BETWEEN 1 AND 200),
  kind          text NOT NULL DEFAULT 'button' CONSTRAINT ui_actions_kind_check CHECK (kind IN ('button', 'link', 'form_submit', 'gesture', 'keyboard', 'auto', 'other')),
  label         text,
  permission    text,
  states        jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT ui_actions_states_array CHECK (soulbah.is_json_array(states)),
  errors        jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT ui_actions_errors_array CHECK (soulbah.is_json_array(errors)),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ui_actions_scope CHECK (component_id IS NOT NULL OR route_id IS NOT NULL)
);
ALTER TABLE soulbah.ui_actions ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.ui_actions IS 'Actions d''un écran (boutons, liens, soumissions), permission requise, états et erreurs possibles (§8).';
CREATE INDEX IF NOT EXISTS idx_ui_actions_component ON soulbah.ui_actions (component_id);
CREATE INDEX IF NOT EXISTS idx_ui_actions_route ON soulbah.ui_actions (route_id);

CREATE TABLE IF NOT EXISTS soulbah.ui_api_links (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  endpoint_id   uuid NOT NULL REFERENCES soulbah.api_endpoints(id) ON DELETE CASCADE,
  action_id     uuid REFERENCES soulbah.ui_actions(id) ON DELETE CASCADE,
  component_id  uuid REFERENCES soulbah.ui_components(id) ON DELETE CASCADE,
  route_id      uuid REFERENCES soulbah.ui_routes(id) ON DELETE CASCADE,
  evidence      text CONSTRAINT ui_api_links_evidence_length CHECK (evidence IS NULL OR length(evidence) <= 2000),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ui_api_links_source CHECK (action_id IS NOT NULL OR component_id IS NOT NULL OR route_id IS NOT NULL),
  CONSTRAINT ui_api_links_unique UNIQUE NULLS NOT DISTINCT (endpoint_id, action_id, component_id, route_id)
);
ALTER TABLE soulbah.ui_api_links ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.ui_api_links IS 'Interface ↔ API : quel écran, composant ou action appelle quel endpoint.';
CREATE INDEX IF NOT EXISTS idx_ui_api_links_action ON soulbah.ui_api_links (action_id);
CREATE INDEX IF NOT EXISTS idx_ui_api_links_component ON soulbah.ui_api_links (component_id);
CREATE INDEX IF NOT EXISTS idx_ui_api_links_route ON soulbah.ui_api_links (route_id);

-- 5. Parcours utilisateurs (§9) ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.user_flows (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id   uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  key          text NOT NULL CONSTRAINT user_flows_key_format CHECK (key ~ '^[a-z0-9][a-z0-9_.-]{0,119}$'),
  name         text NOT NULL CONSTRAINT user_flows_name_length CHECK (length(name) BETWEEN 1 AND 300),
  description  text NOT NULL DEFAULT '' CONSTRAINT user_flows_description_length CHECK (length(description) <= 4000),
  actor        text NOT NULL DEFAULT 'utilisateur' CONSTRAINT user_flows_actor_length CHECK (length(actor) BETWEEN 1 AND 100),
  status       text NOT NULL DEFAULT 'draft' CONSTRAINT user_flows_status_check CHECK (status IN ('draft', 'verified', 'stale')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_flows_unique UNIQUE (project_id, key)
);
ALTER TABLE soulbah.user_flows ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.user_flows IS 'Parcours (ex. Marketplace → Produit → Panier → Commande → Paiement → Livraison → Wallet vendeur) ; verified = chaque étape reliée à ses composants techniques.';
DROP TRIGGER IF EXISTS user_flows_set_updated_at ON soulbah.user_flows;
CREATE TRIGGER user_flows_set_updated_at BEFORE UPDATE ON soulbah.user_flows FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.user_flow_steps (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flow_id       uuid NOT NULL REFERENCES soulbah.user_flows(id) ON DELETE CASCADE,
  position      integer NOT NULL CONSTRAINT user_flow_steps_position_positive CHECK (position >= 1),
  name          text NOT NULL CONSTRAINT user_flow_steps_name_length CHECK (length(name) BETWEEN 1 AND 300),
  route_id      uuid REFERENCES soulbah.ui_routes(id) ON DELETE SET NULL,
  component_id  uuid REFERENCES soulbah.ui_components(id) ON DELETE SET NULL,
  endpoint_id   uuid REFERENCES soulbah.api_endpoints(id) ON DELETE SET NULL,
  table_id      uuid REFERENCES soulbah.db_tables(id) ON DELETE SET NULL,
  notes         text NOT NULL DEFAULT '' CONSTRAINT user_flow_steps_notes_length CHECK (length(notes) <= 4000),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_flow_steps_unique UNIQUE (flow_id, position)
);
ALTER TABLE soulbah.user_flow_steps ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.user_flow_steps IS 'Étapes d''un parcours et composants techniques derrière chacune (écran, composant, endpoint, table).';
CREATE INDEX IF NOT EXISTS idx_user_flow_steps_route ON soulbah.user_flow_steps (route_id);
CREATE INDEX IF NOT EXISTS idx_user_flow_steps_component ON soulbah.user_flow_steps (component_id);
CREATE INDEX IF NOT EXISTS idx_user_flow_steps_endpoint ON soulbah.user_flow_steps (endpoint_id);
CREATE INDEX IF NOT EXISTS idx_user_flow_steps_table ON soulbah.user_flow_steps (table_id);

CREATE TABLE IF NOT EXISTS soulbah.user_flow_dependencies (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flow_id             uuid NOT NULL REFERENCES soulbah.user_flows(id) ON DELETE CASCADE,
  depends_on_flow_id  uuid NOT NULL REFERENCES soulbah.user_flows(id) ON DELETE CASCADE,
  kind                text NOT NULL DEFAULT 'requires' CONSTRAINT user_flow_dependencies_kind_check CHECK (kind IN ('requires', 'triggers', 'optional')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_flow_dependencies_not_self CHECK (flow_id <> depends_on_flow_id),
  CONSTRAINT user_flow_dependencies_unique UNIQUE (flow_id, depends_on_flow_id, kind)
);
ALTER TABLE soulbah.user_flow_dependencies ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE soulbah.user_flow_dependencies IS 'Dépendances entre parcours (un parcours en requiert ou en déclenche un autre).';
CREATE INDEX IF NOT EXISTS idx_user_flow_dependencies_to ON soulbah.user_flow_dependencies (depends_on_flow_id);

-- 6. Droits --------------------------------------------------------------------------------------------
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['code_files', 'code_symbols', 'code_dependencies', 'code_references', 'code_change_events', 'code_index_state',
                           'db_sources', 'db_snapshots', 'db_schemas', 'db_tables', 'db_columns', 'db_relations', 'db_indexes', 'db_policies',
                           'db_functions', 'db_triggers', 'db_table_usages', 'api_services', 'api_endpoints', 'api_dependencies', 'api_consumers',
                           'api_security_rules', 'ui_surfaces', 'ui_routes', 'ui_components', 'ui_actions', 'ui_api_links',
                           'user_flows', 'user_flow_steps', 'user_flow_dependencies'] LOOP
    EXECUTE format('REVOKE ALL ON soulbah.%I FROM PUBLIC', t);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON soulbah.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;
