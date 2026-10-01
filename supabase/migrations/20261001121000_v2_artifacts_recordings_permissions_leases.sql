-- =============================================================================
-- V2 — 11/12 : artefacts (sha256), enregistrements vidéo, permissions (grants et demandes
-- d'approbation), verrous de ressources — audit §9.7, §9.8, §9.10, §12.
-- Idempotente, additive.
-- =============================================================================

-- Artefacts : adressés par sha256, un fichier par (utilisateur, hash). Plus aucun base64 en base.
CREATE TABLE IF NOT EXISTS soulbah.artifacts (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  session_id       uuid REFERENCES soulbah.sessions(id) ON DELETE SET NULL,
  task_id          uuid REFERENCES soulbah.tasks(id) ON DELETE SET NULL,
  sha256           text NOT NULL CONSTRAINT artifacts_sha256_format CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  mime             text NOT NULL DEFAULT 'application/octet-stream',
  size_bytes       bigint NOT NULL CONSTRAINT artifacts_size_positive CHECK (size_bytes >= 0),
  -- Emplacement de stockage (chemin du volume média, URI…) : jamais le contenu.
  uri              text NOT NULL,
  kind             text NOT NULL DEFAULT 'file' CONSTRAINT artifacts_kind_check CHECK (kind IN ('file', 'screenshot', 'video', 'log', 'report', 'diff')),
  retention_class  text NOT NULL DEFAULT 'task' CONSTRAINT artifacts_retention_check CHECK (retention_class IN ('ephemeral', 'task', 'session', 'permanent')),
  metadata         jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT artifacts_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT artifacts_unique_per_user UNIQUE (user_id, sha256)
);
ALTER TABLE soulbah.artifacts ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_artifacts_task ON soulbah.artifacts (task_id) WHERE task_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_artifacts_retention ON soulbah.artifacts (retention_class, created_at);

-- Enregistrements d'écran : durée, fps effectif, probe (h264/aac) — LOT 14.
CREATE TABLE IF NOT EXISTS soulbah.recordings (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  task_id          uuid REFERENCES soulbah.tasks(id) ON DELETE SET NULL,
  artifact_id      uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  path             text NOT NULL,
  status           text NOT NULL DEFAULT 'recording' CONSTRAINT recordings_status_check CHECK (status IN ('recording', 'stopped', 'failed')),
  duration_s       real CONSTRAINT recordings_duration_positive CHECK (duration_s IS NULL OR duration_s >= 0),
  fps_requested    real CONSTRAINT recordings_fps_req_positive CHECK (fps_requested IS NULL OR fps_requested > 0),
  fps_effective    real CONSTRAINT recordings_fps_eff_positive CHECK (fps_effective IS NULL OR fps_effective >= 0),
  probe            jsonb CONSTRAINT recordings_probe_object CHECK (probe IS NULL OR soulbah.is_json_object(probe)),
  started_at       timestamptz NOT NULL DEFAULT now(),
  stopped_at       timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE soulbah.recordings ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_recordings_task ON soulbah.recordings (task_id) WHERE task_id IS NOT NULL;

-- Permissions : grants de session (L1/L2) et demandes d'approbation par action (L2/L3),
-- liées au payload présenté (payload_sha256) ; le jeton HMAC (LOT 6) n'est stocké que haché.
CREATE TABLE IF NOT EXISTS soulbah.permissions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  session_id         uuid REFERENCES soulbah.sessions(id) ON DELETE CASCADE,
  task_id            uuid REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  action_id          uuid REFERENCES soulbah.actions(id) ON DELETE SET NULL,
  kind               text NOT NULL CONSTRAINT permissions_kind_check CHECK (kind IN ('grant', 'request')),
  security_level     text NOT NULL CONSTRAINT permissions_level_check CHECK (soulbah.is_security_level(security_level)),
  -- Portée du grant : {"tools":["type_text"],"resources":["desktop.input:*"]}.
  scope              jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT permissions_scope_object CHECK (soulbah.is_json_object(scope)),
  payload_sha256     text CONSTRAINT permissions_payload_hash_format CHECK (payload_sha256 IS NULL OR payload_sha256 ~ '^[0-9a-f]{64}$'),
  payload_presented  jsonb CONSTRAINT permissions_payload_object CHECK (payload_presented IS NULL OR soulbah.is_json_object(payload_presented)),
  status             text NOT NULL DEFAULT 'pending' CONSTRAINT permissions_status_check CHECK (status IN ('pending', 'approved', 'denied', 'expired', 'revoked')),
  decided_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  decided_at         timestamptz,
  expires_at         timestamptz,
  token_hash         text CONSTRAINT permissions_token_hash_format CHECK (token_hash IS NULL OR token_hash ~ '^[0-9a-f]{64}$'),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  -- Une demande L3 porte toujours le payload complet (§9.10 : jamais en lot).
  CONSTRAINT permissions_l3_requires_payload CHECK (kind <> 'request' OR security_level <> 'L3' OR payload_sha256 IS NOT NULL),
  CONSTRAINT permissions_decision_consistent CHECK ((status IN ('approved', 'denied')) = (decided_at IS NOT NULL))
);
ALTER TABLE soulbah.permissions ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.permissions;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.permissions
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
CREATE INDEX IF NOT EXISTS idx_permissions_pending ON soulbah.permissions (user_id, created_at) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_permissions_session ON soulbah.permissions (session_id, status) WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_permissions_task ON soulbah.permissions (task_id) WHERE task_id IS NOT NULL;

-- Verrous de ressources (§9.7) : exclusivité garantie par un index unique partiel.
CREATE TABLE IF NOT EXISTS soulbah.resource_leases (
  resource_key     text NOT NULL CONSTRAINT resource_leases_key_format CHECK (resource_key ~ '^[a-z][a-z0-9_.-]*(:[^\s]+)*$'),
  holder_task_id   uuid NOT NULL REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  mode             text NOT NULL DEFAULT 'exclusive' CONSTRAINT resource_leases_mode_check CHECK (mode IN ('exclusive', 'shared')),
  expires_at       timestamptz NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (resource_key, holder_task_id)
);
ALTER TABLE soulbah.resource_leases ENABLE ROW LEVEL SECURITY;
CREATE UNIQUE INDEX IF NOT EXISTS uq_resource_leases_exclusive ON soulbah.resource_leases (resource_key) WHERE mode = 'exclusive';
CREATE INDEX IF NOT EXISTS idx_resource_leases_expires ON soulbah.resource_leases (expires_at);
CREATE INDEX IF NOT EXISTS idx_resource_leases_holder ON soulbah.resource_leases (holder_task_id);
