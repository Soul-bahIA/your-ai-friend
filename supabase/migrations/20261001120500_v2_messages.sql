-- =============================================================================
-- V2 — 6/12 : messages structurés entre agents et plan de contrôle — audit §9.5, §12.
-- Idempotente, additive. public.chat_messages (chat utilisateur) est intacte.
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.messages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id      uuid NOT NULL REFERENCES soulbah.sessions(id) ON DELETE CASCADE,
  task_id         uuid REFERENCES soulbah.tasks(id) ON DELETE SET NULL,
  from_agent_id   uuid REFERENCES soulbah.agents(id) ON DELETE SET NULL,
  to_agent_id     uuid REFERENCES soulbah.agents(id) ON DELETE SET NULL,
  -- Destinataire par rôle (quand aucun agent précis) : planner, qa_reviewer, user, control_plane…
  to_role         text CONSTRAINT messages_to_role_format CHECK (to_role IS NULL OR to_role ~ '^[a-z][a-z0-9_]{0,63}$'),
  type            text NOT NULL CONSTRAINT messages_type_check CHECK (type IN
                    ('TASK_REQUEST', 'TASK_RESULT', 'QUESTION', 'BLOCKER', 'EVIDENCE',
                     'REVIEW_REQUEST', 'REVIEW_RESULT', 'ERROR', 'KNOWLEDGE_FOUND')),
  correlation_id  uuid,
  reply_to        uuid REFERENCES soulbah.messages(id) ON DELETE SET NULL,
  -- Charge utile (schéma JSON par type, validé par node-api) ; ≤ 64 Ko (§9.5).
  payload         jsonb NOT NULL DEFAULT '{}'::jsonb
                  CONSTRAINT messages_payload_object CHECK (soulbah.is_json_object(payload))
                  CONSTRAINT messages_payload_size CHECK (pg_column_size(payload) <= 65536),
  requires_ack    boolean NOT NULL DEFAULT false,
  acked_at        timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE soulbah.messages ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_messages_session ON soulbah.messages (session_id, created_at);
CREATE INDEX IF NOT EXISTS idx_messages_task ON soulbah.messages (task_id, created_at) WHERE task_id IS NOT NULL;
-- Livraison aux workers (keepalive) : messages non acquittés par destinataire.
CREATE INDEX IF NOT EXISTS idx_messages_pending_ack ON soulbah.messages (to_agent_id, created_at)
  WHERE requires_ack AND acked_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_messages_correlation ON soulbah.messages (correlation_id) WHERE correlation_id IS NOT NULL;
