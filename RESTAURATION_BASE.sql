-- =============================================================================
-- SOULBAH AI — SCRIPT DE RESTAURATION COMPLÈTE DU SCHÉMA
-- =============================================================================
-- Fichier GÉNÉRÉ : concaténation, dans l'ordre, de TOUTES les migrations de
-- supabase/migrations/ (ne pas éditer à la main — modifier/ajouter une migration
-- puis régénérer ce fichier).
--
-- USAGE
--   * Méthode recommandée : `supabase link --project-ref <ref>` puis `supabase db push`
--     (applique uniquement les migrations manquantes et tient l'historique à jour).
--   * Sinon : coller ce fichier dans Supabase > SQL Editor et l'exécuter.
--
-- ATTENTION
--   * À exécuter sur un projet Supabase NEUF et VIDE (schéma public vierge).
--     Les premières migrations utilisent CREATE TABLE / CREATE POLICY sans
--     IF NOT EXISTS : rejouer ce script sur une base existante échouera.
--   * Le script s'exécute dans UNE transaction : en cas d'erreur, rien n'est appliqué.
--   * Prérequis Supabase : schéma auth, rôles authenticated/anon, publication
--     supabase_realtime et extension pgvector (disponible par défaut sur Supabase).
--   * Ne restaure QUE le schéma. Les données se restaurent depuis une sauvegarde
--     (scripts/backup_db.sh / scripts/backup_db.ps1 → pg_restore / psql).
--
-- Régénération (git-bash) :
--   bash scripts/build_restore_sql.sh
-- =============================================================================

BEGIN;


-- >>>>>>>>>> 20260218031213_fc7d9650-ca05-4801-a5f5-67d083ff843d.sql <<<<<<<<<<


-- Roles enum
CREATE TYPE public.app_role AS ENUM ('admin', 'moderator', 'user');

-- Profiles table
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL UNIQUE,
  display_name TEXT,
  avatar_url TEXT,
  bio TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view all profiles" ON public.profiles FOR SELECT TO authenticated USING (true);
CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own profile" ON public.profiles FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

-- User roles table
CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  role app_role NOT NULL DEFAULT 'user',
  UNIQUE (user_id, role)
);

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- Security definer function for role checks
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role app_role)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role
  )
$$;

CREATE POLICY "Users can view own roles" ON public.user_roles FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Admins can manage roles" ON public.user_roles FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin'));

-- Formations table
CREATE TABLE public.formations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  lessons_count INTEGER DEFAULT 0,
  duration TEXT,
  status TEXT NOT NULL DEFAULT 'En cours',
  content JSONB DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.formations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own formations" ON public.formations FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users can create formations" ON public.formations FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own formations" ON public.formations FOR UPDATE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users can delete own formations" ON public.formations FOR DELETE TO authenticated USING (auth.uid() = user_id);

-- Applications table
CREATE TABLE public.applications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  app_type TEXT DEFAULT 'Web App',
  tech_stack TEXT,
  status TEXT NOT NULL DEFAULT 'En test',
  source_code JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.applications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own apps" ON public.applications FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users can create apps" ON public.applications FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own apps" ON public.applications FOR UPDATE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users can delete own apps" ON public.applications FOR DELETE TO authenticated USING (auth.uid() = user_id);

-- System logs table
CREATE TABLE public.system_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  module TEXT NOT NULL,
  event TEXT NOT NULL,
  level TEXT NOT NULL DEFAULT 'info',
  details JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.system_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own logs" ON public.system_logs FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own logs" ON public.system_logs FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

-- System modules status table
CREATE TABLE public.modules_status (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  module_name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'idle',
  stats TEXT,
  last_active TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, module_name)
);

ALTER TABLE public.modules_status ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own modules" ON public.modules_status FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users can manage own modules" ON public.modules_status FOR ALL TO authenticated USING (auth.uid() = user_id);

-- Enable realtime for logs
ALTER PUBLICATION supabase_realtime ADD TABLE public.system_logs;

-- Auto-create profile and default role on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (user_id, display_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'display_name', NEW.email));
  
  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, 'user');
  
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Updated_at trigger function
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

CREATE TRIGGER update_profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_formations_updated_at BEFORE UPDATE ON public.formations FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_applications_updated_at BEFORE UPDATE ON public.applications FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


-- >>>>>>>>>> 20260218041438_db569e91-d5f0-4b0d-88e0-872ff733fd0a.sql <<<<<<<<<<


-- Table pour stocker les conversations du chat
CREATE TABLE public.chat_conversations (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  title TEXT NOT NULL DEFAULT 'Nouvelle conversation',
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

ALTER TABLE public.chat_conversations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own conversations" ON public.chat_conversations FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can create conversations" ON public.chat_conversations FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own conversations" ON public.chat_conversations FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Users can delete own conversations" ON public.chat_conversations FOR DELETE USING (auth.uid() = user_id);

CREATE TRIGGER update_chat_conversations_updated_at BEFORE UPDATE ON public.chat_conversations FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Table pour les messages de chat
CREATE TABLE public.chat_messages (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  conversation_id UUID NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
  content TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own messages" ON public.chat_messages FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can create messages" ON public.chat_messages FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can delete own messages" ON public.chat_messages FOR DELETE USING (auth.uid() = user_id);

-- Table base de connaissances
CREATE TABLE public.knowledge_base (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT 'general',
  source TEXT,
  tags TEXT[] DEFAULT '{}',
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

ALTER TABLE public.knowledge_base ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own knowledge" ON public.knowledge_base FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can create knowledge" ON public.knowledge_base FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own knowledge" ON public.knowledge_base FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Users can delete own knowledge" ON public.knowledge_base FOR DELETE USING (auth.uid() = user_id);

CREATE TRIGGER update_knowledge_base_updated_at BEFORE UPDATE ON public.knowledge_base FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE INDEX idx_knowledge_base_tags ON public.knowledge_base USING GIN(tags);
CREATE INDEX idx_knowledge_base_category ON public.knowledge_base(category);
CREATE INDEX idx_chat_messages_conversation ON public.chat_messages(conversation_id);


-- >>>>>>>>>> 20260218121217_e64522cf-01fb-446a-901b-f30e6194531b.sql <<<<<<<<<<


-- Table pour stocker les schémas de tables utilisateur
CREATE TABLE public.user_schemas (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid NOT NULL,
  table_name text NOT NULL,
  columns jsonb NOT NULL DEFAULT '[]'::jsonb,
  description text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  UNIQUE(user_id, table_name)
);

-- Table pour stocker les données des tables utilisateur
CREATE TABLE public.user_table_data (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid NOT NULL,
  schema_id uuid NOT NULL REFERENCES public.user_schemas(id) ON DELETE CASCADE,
  row_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Table pour l'historique des migrations
CREATE TABLE public.user_migrations (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid NOT NULL,
  schema_id uuid NOT NULL REFERENCES public.user_schemas(id) ON DELETE CASCADE,
  migration_type text NOT NULL,
  migration_details jsonb NOT NULL DEFAULT '{}'::jsonb,
  applied_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.user_schemas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_table_data ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_migrations ENABLE ROW LEVEL SECURITY;

-- RLS policies for user_schemas
CREATE POLICY "Users can view own schemas" ON public.user_schemas FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can create schemas" ON public.user_schemas FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own schemas" ON public.user_schemas FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Users can delete own schemas" ON public.user_schemas FOR DELETE USING (auth.uid() = user_id);

-- RLS policies for user_table_data
CREATE POLICY "Users can view own data" ON public.user_table_data FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own data" ON public.user_table_data FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own data" ON public.user_table_data FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Users can delete own data" ON public.user_table_data FOR DELETE USING (auth.uid() = user_id);

-- RLS policies for user_migrations
CREATE POLICY "Users can view own migrations" ON public.user_migrations FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can create migrations" ON public.user_migrations FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Triggers for updated_at
CREATE TRIGGER update_user_schemas_updated_at BEFORE UPDATE ON public.user_schemas FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_user_table_data_updated_at BEFORE UPDATE ON public.user_table_data FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


-- >>>>>>>>>> 20260218152103_e6ec4c1b-542d-4f94-866b-6d4012de265a.sql <<<<<<<<<<


-- Table de tâches pour la communication Web App ↔ Agent Local
CREATE TABLE public.agent_tasks (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  task_type TEXT NOT NULL, -- 'screen_recording', 'demo_execution', 'video_production', 'tts_generation'
  status TEXT NOT NULL DEFAULT 'pending', -- 'pending', 'in_progress', 'completed', 'failed', 'cancelled'
  priority INTEGER NOT NULL DEFAULT 5, -- 1 (highest) to 10 (lowest)
  payload JSONB NOT NULL DEFAULT '{}'::jsonb, -- Instructions for the agent
  result JSONB DEFAULT NULL, -- Result from the agent
  error_message TEXT DEFAULT NULL,
  started_at TIMESTAMP WITH TIME ZONE DEFAULT NULL,
  completed_at TIMESTAMP WITH TIME ZONE DEFAULT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.agent_tasks ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can view own tasks" ON public.agent_tasks
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can create tasks" ON public.agent_tasks
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own tasks" ON public.agent_tasks
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own tasks" ON public.agent_tasks
  FOR DELETE USING (auth.uid() = user_id);

-- Trigger for updated_at
CREATE TRIGGER update_agent_tasks_updated_at
  BEFORE UPDATE ON public.agent_tasks
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Enable realtime for task status tracking
ALTER PUBLICATION supabase_realtime ADD TABLE public.agent_tasks;

-- Index for agent polling
CREATE INDEX idx_agent_tasks_status ON public.agent_tasks (status, priority, created_at);
CREATE INDEX idx_agent_tasks_user_status ON public.agent_tasks (user_id, status);


-- >>>>>>>>>> 20260703000000_agent_keys.sql <<<<<<<<<<

-- Clés d'accès de l'agent local (worker qui contrôle le poste).
-- On ne stocke QUE le hash SHA-256 de la clé ; la clé en clair n'est affichée
-- qu'une seule fois à sa création. Le backend valide en hashant la clé reçue
-- (en-tête x-agent-key) et retrouve le user_id via le hash — le user_id n'est
-- plus transmis en clair par l'agent.

CREATE TABLE IF NOT EXISTS public.agent_keys (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  key_hash     TEXT NOT NULL UNIQUE,
  label        TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_used_at TIMESTAMPTZ
);

ALTER TABLE public.agent_keys ENABLE ROW LEVEL SECURITY;

-- L'utilisateur gère uniquement ses propres clés (via l'app, JWT).
-- Le backend, lui, lit par hash avec la clé de service (hors RLS) pour la validation.
CREATE POLICY "Users manage own agent keys" ON public.agent_keys
  FOR ALL TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_agent_keys_hash ON public.agent_keys (key_hash);
CREATE INDEX IF NOT EXISTS idx_agent_keys_user ON public.agent_keys (user_id);


-- >>>>>>>>>> 20260704000000_agent_memory.sql <<<<<<<<<<

-- Mémoire d'exécution de l'agent : erreurs rencontrées, solutions validées,
-- bonnes pratiques issues de l'auto-amélioration. Réinjectée dans la planification
-- (moteur de raisonnement) pour éviter de répéter les mêmes échecs.

CREATE TABLE IF NOT EXISTS public.agent_memory (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  type         TEXT NOT NULL CHECK (type IN ('error', 'solution', 'practice')),
  goal         TEXT NOT NULL,
  content      TEXT NOT NULL,
  metadata     JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.agent_memory ENABLE ROW LEVEL SECURITY;

-- Gérée par le backend (connexion directe) ; policy pour un accès direct éventuel.
CREATE POLICY "Users manage own agent memory" ON public.agent_memory
  FOR ALL TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_agent_memory_user ON public.agent_memory (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_memory_type ON public.agent_memory (user_id, type);
CREATE INDEX IF NOT EXISTS idx_agent_memory_goal_trgm ON public.agent_memory (user_id, goal);


-- >>>>>>>>>> 20260704120000_formation_video_url.sql <<<<<<<<<<

-- URL de la vidéo MP4 produite pour une formation (narration + diapos + montage).
ALTER TABLE public.formations ADD COLUMN IF NOT EXISTS video_url TEXT;


-- >>>>>>>>>> 20260704130000_agent_allowed_dirs.sql <<<<<<<<<<

-- Dossiers autorisés (whitelist) de chaque agent local, annoncés par l'agent
-- au démarrage (POST /api/agent-tasks/announce). Le planificateur les injecte
-- dans le contexte de plan_goal pour ne générer que des chemins valides.

ALTER TABLE public.agent_keys
  ADD COLUMN IF NOT EXISTS allowed_dirs JSONB NOT NULL DEFAULT '[]'::jsonb;


-- >>>>>>>>>> 20260706000000_knowledge_base_pro.sql <<<<<<<<<<

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


-- >>>>>>>>>> 20260706100000_formation_curriculum.sql <<<<<<<<<<

-- Curriculum riche des formations (modules → chapitres, quiz, cas, projets, glossaire,
-- FAQ, plan de démonstration, analyse). Le champ `content` conserve la vue "leçons" à
-- plat pour la compat vidéo/UI ; `curriculum` porte la structure professionnelle complète.
ALTER TABLE public.formations ADD COLUMN IF NOT EXISTS curriculum JSONB;


-- >>>>>>>>>> 20260706110000_formation_pdf_url.sql <<<<<<<<<<

-- URL du support PDF produit pour une formation (servi statiquement sous /media).
ALTER TABLE public.formations ADD COLUMN IF NOT EXISTS pdf_url TEXT;


-- >>>>>>>>>> 20260706120000_agent_memory_levels.sql <<<<<<<<<<

-- Mémoire multi-niveaux + validation.
-- `level` : niveau de mémoire (extensible) — working | project | user | technical |
--            documentary | workflow | error | optimization.
-- `status`: proposed | validated | rejected — une optimisation est PROPOSÉE puis
--            validée avant d'être réinjectée dans la planification (traçable, réversible).
ALTER TABLE public.agent_memory
  ADD COLUMN IF NOT EXISTS level      TEXT NOT NULL DEFAULT 'workflow',
  ADD COLUMN IF NOT EXISTS status     TEXT NOT NULL DEFAULT 'validated',
  ADD COLUMN IF NOT EXISTS project_id UUID,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_agent_memory_level ON public.agent_memory (user_id, level);
CREATE INDEX IF NOT EXISTS idx_agent_memory_status ON public.agent_memory (user_id, status);


-- >>>>>>>>>> 20260706130000_agent_events.sql <<<<<<<<<<

-- Poste de pilotage temps réel : évènements émis par l'agent pendant l'exécution
-- (timeline live + captures d'écran live) et contrôle de l'exécution (pause/stop).

-- Flux d'évènements de l'agent (chaque étape, capture, erreur, correction…).
CREATE TABLE IF NOT EXISTS public.agent_events (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id    UUID NOT NULL,
  user_id    UUID NOT NULL,
  type       TEXT NOT NULL,   -- task_started|step_started|step_done|step_failed|screenshot|task_completed|task_failed|info
  message    TEXT,
  data       JSONB NOT NULL DEFAULT '{}'::jsonb,  -- ex. {index, step_type, image_b64, duration_s}
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.agent_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users view own agent events" ON public.agent_events
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_agent_events_task ON public.agent_events (task_id, created_at);
CREATE INDEX IF NOT EXISTS idx_agent_events_user ON public.agent_events (user_id, created_at DESC);

-- Contrôle de l'exécution posé par l'utilisateur, lu par l'agent entre les étapes.
ALTER TABLE public.agent_tasks ADD COLUMN IF NOT EXISTS control TEXT NOT NULL DEFAULT 'none';  -- none|pause|stop

-- Diffusion temps réel (Supabase Realtime) des évènements vers l'UI.
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.agent_events;
EXCEPTION
  WHEN duplicate_object THEN NULL;  -- déjà dans la publication
  WHEN undefined_object THEN NULL;  -- publication absente (env non-Supabase)
END $$;


-- >>>>>>>>>> 20260706140000_formations_realtime.sql <<<<<<<<<<

-- Diffusion temps réel des formations (génération asynchrone : la carte se met à jour
-- toute seule quand le statut/contenu change).
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.formations;
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_object THEN NULL;
END $$;


-- >>>>>>>>>> 20260706150000_knowledge_embeddings.sql <<<<<<<<<<

-- Recherche sémantique (RAG) de la base de connaissances via pgvector.
-- Embeddings OpenAI text-embedding-3-small (1536 dimensions). La recherche par
-- distance cosinus (<=>) complète la recherche plein-texte : elle retrouve les
-- connaissances par le SENS, pas seulement par les mots-clés.
CREATE EXTENSION IF NOT EXISTS vector;

ALTER TABLE public.knowledge_base ADD COLUMN IF NOT EXISTS embedding vector(1536);

-- Index HNSW pour la similarité cosinus (rapide sur de gros volumes).
CREATE INDEX IF NOT EXISTS idx_knowledge_base_embedding
  ON public.knowledge_base USING hnsw (embedding vector_cosine_ops);


-- >>>>>>>>>> 20260707000000_agent_tasks_requeue.sql <<<<<<<<<<

-- Reprise des tâches interrompues : un agent tué en pleine exécution laisse
-- sa tâche bloquée en 'in_progress'. On compte les reprises pour plafonner
-- (au-delà de 3, la tâche est marquée 'failed' au lieu de boucler).
ALTER TABLE public.agent_tasks
  ADD COLUMN IF NOT EXISTS requeue_count integer NOT NULL DEFAULT 0;


-- >>>>>>>>>> 20261001000000_hardening.sql <<<<<<<<<<

-- =============================================================================
-- Durcissement du schéma (sécurité, intégrité, performances).
-- Migration IDEMPOTENTE : peut être rejouée sans erreur (IF [NOT] EXISTS, blocs DO).
--
--  1. agent_tasks : plus de création/modification directe via PostgREST (RLS) —
--     les tâches passent exclusivement par l'API Node (connexion privilégiée).
--  2. CHECK sur agent_tasks.status / agent_tasks.control.
--  3. Clés étrangères user_id → auth.users(id) ON DELETE CASCADE.
--     Ajoutées NOT VALID (ne bloquent pas sur d'éventuelles lignes orphelines
--     existantes), puis validation tentée : un échec est seulement signalé (NOTICE).
--  4. Index manquants (user_id, schema_id, file d'attente de l'agent…).
--  5. Nettoyage d'index (nom trompeur, doublon de contrainte UNIQUE).
--  6. Table analysis_requests (route backend /api/analyze), avec RLS propriétaire.
--  7. Trigger updated_at d'agent_tasks : un changement de `control` seul (pause/stop)
--     ne compte plus comme un « signe de vie » de l'agent.
--  8. profiles : lecture limitée à son propre profil.
-- =============================================================================


-- 1) agent_tasks : RLS ------------------------------------------------------------
-- L'app web lit (SELECT/Realtime) et supprime ses tâches ; elle ne les crée ni ne
-- les modifie directement (création : POST /api/agent-tasks, contrôle :
-- POST /api/agent-tasks/:id/control). Laisser INSERT/UPDATE ouverts permettait
-- d'injecter un payload arbitraire exécuté par l'agent local en contournant l'API.
DROP POLICY IF EXISTS "Users can create tasks" ON public.agent_tasks;
DROP POLICY IF EXISTS "Users can update own tasks" ON public.agent_tasks;


-- 2) CHECK constraints -----------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'agent_tasks_status_check'
                   AND conrelid = 'public.agent_tasks'::regclass) THEN
    ALTER TABLE public.agent_tasks
      ADD CONSTRAINT agent_tasks_status_check
      CHECK (status IN ('pending', 'in_progress', 'completed', 'failed', 'cancelled')) NOT VALID;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'agent_tasks_control_check'
                   AND conrelid = 'public.agent_tasks'::regclass) THEN
    ALTER TABLE public.agent_tasks
      ADD CONSTRAINT agent_tasks_control_check
      CHECK (control IN ('none', 'pause', 'stop')) NOT VALID;
  END IF;
END $$;

DO $$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY ARRAY['agent_tasks_status_check', 'agent_tasks_control_check'] LOOP
    BEGIN
      EXECUTE format('ALTER TABLE public.agent_tasks VALIDATE CONSTRAINT %I', c);
    EXCEPTION WHEN check_violation THEN
      RAISE NOTICE 'Contrainte % non validée : des lignes existantes la violent', c;
    END;
  END LOOP;
END $$;


-- 3) Clés étrangères ---------------------------------------------------------------
DO $$
DECLARE
  t       text;
  attnum  smallint;
  cname   text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'agent_tasks', 'chat_conversations', 'chat_messages', 'knowledge_base',
    'user_schemas', 'user_table_data', 'user_migrations', 'knowledge_versions',
    'agent_events'
  ] LOOP
    IF to_regclass('public.' || t) IS NULL THEN
      CONTINUE;
    END IF;

    SELECT a.attnum INTO attnum
      FROM pg_attribute a
     WHERE a.attrelid = ('public.' || t)::regclass
       AND a.attname = 'user_id' AND NOT a.attisdropped;
    IF attnum IS NULL THEN
      CONTINUE;
    END IF;

    -- Déjà une FK sur user_id vers auth.users ?
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE contype = 'f'
                  AND conrelid = ('public.' || t)::regclass
                  AND confrelid = 'auth.users'::regclass
                  AND conkey = ARRAY[attnum]) THEN
      CONTINUE;
    END IF;

    cname := t || '_user_id_fkey';
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = cname AND conrelid = ('public.' || t)::regclass) THEN
      CONTINUE;
    END IF;

    EXECUTE format(
      'ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (user_id) '
      'REFERENCES auth.users(id) ON DELETE CASCADE NOT VALID', t, cname);

    BEGIN
      EXECUTE format('ALTER TABLE public.%I VALIDATE CONSTRAINT %I', t, cname);
    EXCEPTION WHEN foreign_key_violation THEN
      RAISE NOTICE 'FK % non validée : lignes orphelines dans public.%', cname, t;
    END;
  END LOOP;

  -- Pas de FK agent_events.task_id → agent_tasks(id) : la progression des
  -- formations écrit aussi des évènements avec task_id = id de la formation.
  -- Les évènements orphelins sont purgés par la maintenance du backend Node.
END $$;


-- 4) Index manquants --------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_formations_user          ON public.formations (user_id);
CREATE INDEX IF NOT EXISTS idx_applications_user        ON public.applications (user_id);
CREATE INDEX IF NOT EXISTS idx_chat_conversations_user  ON public.chat_conversations (user_id);
CREATE INDEX IF NOT EXISTS idx_knowledge_base_user      ON public.knowledge_base (user_id);
CREATE INDEX IF NOT EXISTS idx_system_logs_user_created ON public.system_logs (user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_user_table_data_schema   ON public.user_table_data (schema_id);
CREATE INDEX IF NOT EXISTS idx_user_migrations_schema   ON public.user_migrations (schema_id);
-- File de l'agent (poll / requeue des tâches périmées) : remplace (user_id, status).
CREATE INDEX IF NOT EXISTS idx_agent_tasks_user_status_updated
  ON public.agent_tasks (user_id, status, updated_at);
DROP INDEX IF EXISTS public.idx_agent_tasks_user_status;
-- agent_events(task_id, created_at) : déjà couvert par idx_agent_events_task.
CREATE INDEX IF NOT EXISTS idx_agent_events_task ON public.agent_events (task_id, created_at);


-- 5) Nettoyage d'index ------------------------------------------------------------
-- idx_agent_memory_goal_trgm est un simple B-tree (user_id, goal), pas un index trigramme.
ALTER INDEX IF EXISTS public.idx_agent_memory_goal_trgm RENAME TO idx_agent_memory_user_goal;

-- idx_agent_keys_hash double l'index créé par la contrainte UNIQUE (key_hash).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
     WHERE c.conrelid = 'public.agent_keys'::regclass
       AND c.contype = 'u'
       AND array_length(c.conkey, 1) = 1
       AND a.attname = 'key_hash'
  ) THEN
    DROP INDEX IF EXISTS public.idx_agent_keys_hash;
  END IF;
END $$;


-- 6) analysis_requests (backend POST /api/analyze) ---------------------------------
CREATE TABLE IF NOT EXISTS public.analysis_requests (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  input_text  TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'pending',   -- pending | processing | done | error
  result      JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Si la table existait déjà (schéma backend/postgres/init.sql), on ajoute user_id.
ALTER TABLE public.analysis_requests
  ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'analysis_requests_status_check'
                   AND conrelid = 'public.analysis_requests'::regclass) THEN
    ALTER TABLE public.analysis_requests
      ADD CONSTRAINT analysis_requests_status_check
      CHECK (status IN ('pending', 'processing', 'done', 'error')) NOT VALID;
  END IF;
  BEGIN
    ALTER TABLE public.analysis_requests VALIDATE CONSTRAINT analysis_requests_status_check;
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'Contrainte analysis_requests_status_check non validée';
  END;
END $$;

CREATE INDEX IF NOT EXISTS idx_analysis_requests_user       ON public.analysis_requests (user_id);
CREATE INDEX IF NOT EXISTS idx_analysis_requests_status     ON public.analysis_requests (status);
CREATE INDEX IF NOT EXISTS idx_analysis_requests_created_at ON public.analysis_requests (created_at DESC);

ALTER TABLE public.analysis_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users view own analysis requests"   ON public.analysis_requests;
DROP POLICY IF EXISTS "Users create own analysis requests" ON public.analysis_requests;
DROP POLICY IF EXISTS "Users update own analysis requests" ON public.analysis_requests;
DROP POLICY IF EXISTS "Users delete own analysis requests" ON public.analysis_requests;

CREATE POLICY "Users view own analysis requests" ON public.analysis_requests
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users create own analysis requests" ON public.analysis_requests
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users update own analysis requests" ON public.analysis_requests
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users delete own analysis requests" ON public.analysis_requests
  FOR DELETE TO authenticated USING (auth.uid() = user_id);


-- 7) Trigger updated_at d'agent_tasks ---------------------------------------------
-- updated_at sert de heartbeat (requeue des tâches in_progress périmées). Un ordre
-- pause/stop posé par l'utilisateur ne doit pas faire croire que l'agent est vivant :
--   - une autre colonne que control/updated_at change  → updated_at = now()
--   - seul control change (même si updated_at est fixé)  → updated_at conservé
--   - rien d'autre ne change (heartbeat « touch »)       → updated_at = now()
CREATE OR REPLACE FUNCTION public.agent_tasks_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF (to_jsonb(NEW) - 'control' - 'updated_at') IS DISTINCT FROM
     (to_jsonb(OLD) - 'control' - 'updated_at') THEN
    NEW.updated_at := now();
  ELSIF NEW.control IS DISTINCT FROM OLD.control THEN
    NEW.updated_at := OLD.updated_at;
  ELSE
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS update_agent_tasks_updated_at ON public.agent_tasks;
CREATE TRIGGER update_agent_tasks_updated_at
  BEFORE UPDATE ON public.agent_tasks
  FOR EACH ROW EXECUTE FUNCTION public.agent_tasks_set_updated_at();


-- 8) profiles : lecture de son propre profil uniquement ----------------------------
-- Le frontend ne lit que le profil de l'utilisateur connecté (src/pages/Settings.tsx).
DROP POLICY IF EXISTS "Users can view all profiles" ON public.profiles;
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
CREATE POLICY "Users can view own profile" ON public.profiles
  FOR SELECT TO authenticated USING (auth.uid() = user_id);


COMMIT;
