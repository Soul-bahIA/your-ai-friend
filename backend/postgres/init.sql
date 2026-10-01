-- Schéma initial, exécuté automatiquement au premier démarrage du conteneur Postgres.

CREATE TABLE IF NOT EXISTS analysis_requests (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    input_text  TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending',   -- pending | processing | done | error
    result      JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_analysis_requests_status
    ON analysis_requests (status);

CREATE INDEX IF NOT EXISTS idx_analysis_requests_created_at
    ON analysis_requests (created_at DESC);
