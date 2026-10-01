-- =============================================================================
-- V2 — 9/12 : mémoire — extension de public.agent_memory et vue soulbah.memories
-- (audit §12, T11, contrat LOT 1 §9). Idempotente, additive, aucune ligne modifiée.
-- =============================================================================

ALTER TABLE public.agent_memory
  ADD COLUMN IF NOT EXISTS session_id      uuid,
  ADD COLUMN IF NOT EXISTS scope           text NOT NULL DEFAULT 'user',
  ADD COLUMN IF NOT EXISTS source_task_id  uuid,
  ADD COLUMN IF NOT EXISTS evidence_ids    jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS confidence      real NOT NULL DEFAULT 0.5,
  ADD COLUMN IF NOT EXISTS validated_by    uuid,
  ADD COLUMN IF NOT EXISTS validated_at    timestamptz,
  ADD COLUMN IF NOT EXISTS expires_at      timestamptz,
  ADD COLUMN IF NOT EXISTS is_simulation   boolean NOT NULL DEFAULT false;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_memory_session_fk') THEN
    ALTER TABLE public.agent_memory ADD CONSTRAINT agent_memory_session_fk
      FOREIGN KEY (session_id) REFERENCES soulbah.sessions(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_memory_source_task_fk') THEN
    ALTER TABLE public.agent_memory ADD CONSTRAINT agent_memory_source_task_fk
      FOREIGN KEY (source_task_id) REFERENCES soulbah.tasks(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_memory_scope_check') THEN
    ALTER TABLE public.agent_memory ADD CONSTRAINT agent_memory_scope_check
      CHECK (scope IN ('session', 'project', 'user', 'global')) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_memory_confidence_range') THEN
    ALTER TABLE public.agent_memory ADD CONSTRAINT agent_memory_confidence_range
      CHECK (confidence >= 0 AND confidence <= 1) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_memory_evidence_array') THEN
    ALTER TABLE public.agent_memory ADD CONSTRAINT agent_memory_evidence_array
      CHECK (soulbah.is_json_array(evidence_ids)) NOT VALID;
  END IF;
  -- Contrat §9 / audit §12 : « validated » exige une preuve ou un validateur. La forme V1
  -- (metadata.validated_by, routes/agentMemory.ts) reste acceptée jusqu'au LOT 8.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_memory_validated_requires_proof') THEN
    ALTER TABLE public.agent_memory ADD CONSTRAINT agent_memory_validated_requires_proof
      CHECK (status <> 'validated'
             OR validated_by IS NOT NULL
             OR (metadata ? 'validated_by')
             OR (jsonb_typeof(evidence_ids) = 'array' AND jsonb_array_length(evidence_ids) > 0)) NOT VALID;
  END IF;
END $$;
DO $$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY ARRAY['agent_memory_scope_check', 'agent_memory_confidence_range',
                           'agent_memory_evidence_array', 'agent_memory_validated_requires_proof'] LOOP
    BEGIN
      EXECUTE format('ALTER TABLE public.agent_memory VALIDATE CONSTRAINT %I', c);
    EXCEPTION WHEN check_violation THEN
      RAISE NOTICE 'Contrainte % non validée : des lignes existantes la violent (lues comme « proposed » par soulbah.memories)', c;
    END;
  END LOOP;
END $$;

CREATE INDEX IF NOT EXISTS idx_agent_memory_scope ON public.agent_memory (user_id, scope, status);
CREATE INDEX IF NOT EXISTS idx_agent_memory_session ON public.agent_memory (session_id) WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_agent_memory_expires ON public.agent_memory (expires_at) WHERE expires_at IS NOT NULL;

-- Vue : statut EFFECTIF. Une ligne « validated » sans validateur ni preuve (écrite par
-- l'ancien évaluateur) est lue comme « proposed », sans modification de données.
CREATE OR REPLACE VIEW soulbah.memories AS
SELECT m.id,
       m.user_id,
       m.session_id,
       m.scope,
       m.type,
       m.level,
       m.goal,
       m.content,
       m.metadata,
       m.project_id,
       m.source_task_id,
       m.evidence_ids,
       m.confidence,
       CASE
         WHEN m.status = 'validated'
              AND m.validated_by IS NULL
              AND NOT (m.metadata ? 'validated_by')
              AND (jsonb_typeof(m.evidence_ids) <> 'array' OR jsonb_array_length(m.evidence_ids) = 0)
           THEN 'proposed'
         ELSE m.status
       END AS status,
       m.status AS stored_status,
       COALESCE(m.validated_by, NULLIF(m.metadata ->> 'validated_by', '')::uuid) AS validated_by,
       COALESCE(m.validated_at, NULLIF(m.metadata ->> 'validated_at', '')::timestamptz) AS validated_at,
       m.expires_at,
       m.is_simulation,
       m.created_at,
       m.updated_at
  FROM public.agent_memory m
 WHERE m.expires_at IS NULL OR m.expires_at > now();
