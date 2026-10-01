-- Schéma initial, exécuté automatiquement au premier démarrage du conteneur Postgres.

CREATE TABLE IF NOT EXISTS analysis_requests (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID,                              -- propriétaire (JWT Supabase) ; NULL = ligne historique
    input_text  TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending',   -- pending | processing | done | error
    result      JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Bases déjà initialisées avant l'ajout de user_id.
ALTER TABLE analysis_requests ADD COLUMN IF NOT EXISTS user_id UUID;

CREATE INDEX IF NOT EXISTS idx_analysis_requests_status
    ON analysis_requests (status);

CREATE INDEX IF NOT EXISTS idx_analysis_requests_created_at
    ON analysis_requests (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_analysis_requests_user
    ON analysis_requests (user_id, created_at DESC);
