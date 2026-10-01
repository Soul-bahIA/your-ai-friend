-- Base de connaissances "pro" de SoulBah AI.
-- Étend la table knowledge_base existante avec les champs nécessaires à une base
-- propriétaire évolutive (description, mots-clés, résumé, source structurée, niveau
-- de confiance, version, liens), ajoute l'historique de versions (restauration) et
-- un référentiel de domaines extensible.
--
-- IMPORTANT (migration future Supabase → Google Cloud) : la logique métier passe par
-- une couche d'abstraction de stockage côté backend (services/knowledge). Ce schéma
-- reste volontairement portable : types simples, liens/sources en JSONB.

-- 1) Colonnes enrichies sur knowledge_base (idempotent) -----------------------------
ALTER TABLE public.knowledge_base
  ADD COLUMN IF NOT EXISTS description      TEXT,
  ADD COLUMN IF NOT EXISTS summary          TEXT,
  ADD COLUMN IF NOT EXISTS domain           TEXT NOT NULL DEFAULT 'general',
  ADD COLUMN IF NOT EXISTS keywords         TEXT[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS sources          JSONB NOT NULL DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS confidence       REAL NOT NULL DEFAULT 0.5,
  ADD COLUMN IF NOT EXISTS version          INT NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS links            JSONB NOT NULL DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS content_hash     TEXT,
  ADD COLUMN IF NOT EXISTS last_verified_at TIMESTAMPTZ;

-- Borne le niveau de confiance à [0,1] (ajoutée séparément pour rester idempotent).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'knowledge_base_confidence_range'
  ) THEN
    ALTER TABLE public.knowledge_base
      ADD CONSTRAINT knowledge_base_confidence_range
      CHECK (confidence >= 0 AND confidence <= 1);
  END IF;
END $$;

-- Recherche : index plein-texte simple sur titre + contenu + résumé, et sur domaine/mots-clés.
CREATE INDEX IF NOT EXISTS idx_knowledge_base_domain ON public.knowledge_base(domain);
CREATE INDEX IF NOT EXISTS idx_knowledge_base_keywords ON public.knowledge_base USING GIN(keywords);
CREATE INDEX IF NOT EXISTS idx_knowledge_base_hash ON public.knowledge_base(content_hash);
CREATE INDEX IF NOT EXISTS idx_knowledge_base_fts ON public.knowledge_base
  USING GIN (to_tsvector('french', coalesce(title,'') || ' ' || coalesce(summary,'') || ' ' || coalesce(content,'')));

-- 2) Historique de versions (conflits + restauration) -------------------------------
CREATE TABLE IF NOT EXISTS public.knowledge_versions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_id    UUID NOT NULL REFERENCES public.knowledge_base(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL,
  version     INT NOT NULL,
  snapshot    JSONB NOT NULL,          -- copie complète de l'entrée à cette version
  change_note TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.knowledge_versions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users view own knowledge versions" ON public.knowledge_versions
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users create own knowledge versions" ON public.knowledge_versions
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users delete own knowledge versions" ON public.knowledge_versions
  FOR DELETE TO authenticated USING (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_knowledge_versions_entry ON public.knowledge_versions(entry_id, version DESC);

-- 3) Référentiel de domaines extensible ---------------------------------------------
-- Global (lecture par tout utilisateur authentifié) ; les domaines "système" ne sont
-- pas supprimables. De nouveaux domaines peuvent être ajoutés à tout moment.
CREATE TABLE IF NOT EXISTS public.knowledge_domains (
  slug       TEXT PRIMARY KEY,
  label      TEXT NOT NULL,
  is_system  BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.knowledge_domains ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone authenticated reads domains" ON public.knowledge_domains
  FOR SELECT TO authenticated USING (true);

INSERT INTO public.knowledge_domains (slug, label, is_system) VALUES
  ('general',           'Général',                 true),
  ('programmation',     'Programmation',           true),
  ('intelligence-artificielle', 'Intelligence artificielle', true),
  ('marketing-digital', 'Marketing digital',       true),
  ('developpement-web', 'Développement web',       true),
  ('developpement-mobile', 'Développement mobile', true),
  ('cybersecurite',     'Cybersécurité',           true),
  ('bases-de-donnees',  'Bases de données',        true),
  ('cloud-computing',   'Cloud computing',         true),
  ('devops',            'DevOps',                  true),
  ('design',            'Design',                  true),
  ('creation-de-contenu', 'Création de contenu',   true),
  ('entrepreneuriat',   'Entrepreneuriat',         true),
  ('finance',           'Finance',                 true),
  ('gestion-entreprise', 'Gestion d''entreprise',  true)
ON CONFLICT (slug) DO NOTHING;
