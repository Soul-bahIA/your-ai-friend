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
--     Les 4 migrations de février 2026 utilisent CREATE TABLE / CREATE POLICY sans
--     IF NOT EXISTS : rejouer ce script sur une base existante échouera.
--     JAMAIS sur le projet existant : utiliser `supabase db push` (docs/SUPABASE_REPRISE.md).
--     Les migrations à partir de 20260703000000 sont rejouables ; c'est vérifié par
--     scripts/ci/apply_migrations.sh (job CI `db`).
--   * Le script s'exécute dans UNE transaction : en cas d'erreur, rien n'est appliqué.
--   * Prérequis Supabase : schéma auth, rôles authenticated/anon, publication
--     supabase_realtime, extensions pgvector et pg_trgm (disponibles sur Supabase).
--   * Ne restaure QUE le schéma (droits et policies compris). Les données se
--     restaurent ENSUITE depuis une sauvegarde (scripts/backup_db.sh / .ps1) :
--     pg_restore --data-only, puis scripts/sql/post_restore_checks.sql
--     (procédure : README.md, section « Sauvegardes »).
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
--
-- [LOT 1 / T47] Garde de rejeu ajoutée a posteriori. Cette migration est peut-être déjà
-- appliquée sur Supabase : `supabase db push` ne la rejouera pas (historique par
-- version), et sur une base neuve le résultat est IDENTIQUE à l'original (la table
-- vient d'être créée, elle n'a aucune policy → la policy est créée). Seul un rejeu
-- (CI : migrations ×2, restauration partielle) devient sûr.
-- Garde volontairement « aucune policy sur la table » plutôt que DROP + CREATE :
-- 20261001090000_lot1_fixes.sql remplace cette policy FOR ALL par SELECT + DELETE, puis
-- 20261001100000_lot1_verif.sql par SELECT seul ; un rejeu de ce fichier ne doit pas
-- rouvrir d'écriture au client.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname = 'public' AND tablename = 'agent_keys') THEN
    CREATE POLICY "Users manage own agent keys" ON public.agent_keys
      FOR ALL TO authenticated
      USING (auth.uid() = user_id)
      WITH CHECK (auth.uid() = user_id);
  END IF;
END $$;

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
--
-- [LOT 1 / T47] Gardes de rejeu ajoutées a posteriori, sans changer le schéma obtenu
-- sur une base neuve (table sans policy → policy créée ; index absent → créé).
-- Déjà appliquée → `supabase db push` ne rejoue pas ce fichier ; rejeu (CI ×2) → no-op.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname = 'public' AND tablename = 'agent_memory') THEN
    CREATE POLICY "Users manage own agent memory" ON public.agent_memory
      FOR ALL TO authenticated
      USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_agent_memory_user ON public.agent_memory (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_memory_type ON public.agent_memory (user_id, type);
-- 20261001000000_hardening.sql renomme cet index en idx_agent_memory_user_goal : ne pas
-- le recréer sous l'ancien nom lors d'un rejeu (sinon le RENAME de hardening échoue).
DO $$
BEGIN
  IF to_regclass('public.idx_agent_memory_user_goal') IS NULL THEN
    CREATE INDEX IF NOT EXISTS idx_agent_memory_goal_trgm ON public.agent_memory (user_id, goal);
  END IF;
END $$;


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

-- [LOT 1 / T47] Gardes de rejeu ajoutées a posteriori (ici et pour knowledge_domains),
-- sans changer le schéma obtenu : sur une base neuve la table n'a aucune policy → les
-- policies sont créées à l'identique ; déjà appliquée → `supabase db push` ne rejoue
-- pas ce fichier ; rejeu (CI ×2) → no-op. Garde « aucune policy sur la table » plutôt
-- que DROP + CREATE : 20261001090000_lot1_fixes.sql resserre la policy d'INSERT et un
-- rejeu de ce fichier ne doit pas la rouvrir.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname = 'public' AND tablename = 'knowledge_versions') THEN
    CREATE POLICY "Users view own knowledge versions" ON public.knowledge_versions
      FOR SELECT TO authenticated USING (auth.uid() = user_id);
    CREATE POLICY "Users create own knowledge versions" ON public.knowledge_versions
      FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
    CREATE POLICY "Users delete own knowledge versions" ON public.knowledge_versions
      FOR DELETE TO authenticated USING (auth.uid() = user_id);
  END IF;
END $$;

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

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname = 'public' AND tablename = 'knowledge_domains') THEN
    CREATE POLICY "Anyone authenticated reads domains" ON public.knowledge_domains
      FOR SELECT TO authenticated USING (true);
  END IF;
END $$;

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

-- [LOT 1 / T47] Garde de rejeu ajoutée a posteriori, sans changer le schéma obtenu :
-- sur une base neuve la table n'a aucune policy → création identique à l'original ;
-- déjà appliquée → `supabase db push` ne rejoue pas ce fichier ; rejeu (CI ×2) → no-op.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname = 'public' AND tablename = 'agent_events') THEN
    CREATE POLICY "Users view own agent events" ON public.agent_events
      FOR SELECT TO authenticated USING (auth.uid() = user_id);
  END IF;
END $$;

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


-- >>>>>>>>>> 20261001090000_lot1_fixes.sql <<<<<<<<<<

-- =============================================================================
-- LOT 1 — Corrections de schéma issues de l'audit LOT 0 (docs/SOULBAH_V2_LOT0_AUDIT.md)
-- Migration ADDITIVE et IDEMPOTENTE (style de 20261001000000_hardening.sql) :
-- IF [NOT] EXISTS, DROP POLICY IF EXISTS puis CREATE, contraintes NOT VALID puis
-- VALIDATE dans un bloc d'exception. Aucune donnée supprimée ni modifiée.
--
--  1. agent_tasks : ciblage d'un PC (contrat LOT 1 §7, T16) — colonnes nullables
--     target_agent_key_id / claimed_by_key_id → agent_keys(id) ON DELETE SET NULL,
--     index partiel de poll (T46) et index des deux FK.
--  2. Trigger updated_at d'agent_tasks (T45) : poser `control` (même valeur ou non)
--     ne prolonge plus le bail ; le heartbeat (UPDATE … SET updated_at = now()) oui.
--  3. has_role (S19) : plus exécutable par anon ; nouvelle fonction is_admin().
--  4. Policies (S20) : agent_keys en lecture + suppression seulement côté client ;
--     les INSERT vérifient la propriété de la ligne parente (chat_messages,
--     knowledge_versions, user_table_data, user_migrations).
--  5. modules_status marquée DÉPRÉCIÉE (T48) — jamais supprimée.
--  6. agent_memory : CHECK sur status et level (S11).
--
-- Règles « Jamais » de l'audit (§12) respectées : le CHECK de statut d'agent_tasks
-- n'est pas touché, aucune FK sur agent_events.task_id, rien n'est renommé ni supprimé.
-- =============================================================================


-- 1) agent_tasks : ciblage d'un PC + index de poll -------------------------------
-- target_agent_key_id : PC (clé agent) visé par la tâche ; NULL = n'importe lequel des
--                       agents de l'utilisateur.
-- claimed_by_key_id   : clé agent qui a réclamé la tâche (écrit par le claim).
-- Révoquer/supprimer une clé ne supprime pas l'historique : la référence passe à NULL.
ALTER TABLE public.agent_tasks
  ADD COLUMN IF NOT EXISTS target_agent_key_id uuid,
  ADD COLUMN IF NOT EXISTS claimed_by_key_id   uuid;

COMMENT ON COLUMN public.agent_tasks.target_agent_key_id IS
  'Clé agent (PC) ciblée ; NULL = tout agent de l''utilisateur. Le poll ne renvoie que target IS NULL OR = clé appelante.';
COMMENT ON COLUMN public.agent_tasks.claimed_by_key_id IS
  'Clé agent ayant réclamé la tâche (écrit par le claim). NULL si jamais réclamée ou clé supprimée.';

DO $$
DECLARE
  col   text;
  cname text;
BEGIN
  FOREACH col IN ARRAY ARRAY['target_agent_key_id', 'claimed_by_key_id'] LOOP
    cname := 'agent_tasks_' || col || '_fkey';
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = cname
                      AND conrelid = 'public.agent_tasks'::regclass) THEN
      EXECUTE format(
        'ALTER TABLE public.agent_tasks ADD CONSTRAINT %I FOREIGN KEY (%I) '
        'REFERENCES public.agent_keys(id) ON DELETE SET NULL NOT VALID', cname, col);
    END IF;

    BEGIN
      EXECUTE format('ALTER TABLE public.agent_tasks VALIDATE CONSTRAINT %I', cname);
    EXCEPTION WHEN foreign_key_violation THEN
      RAISE NOTICE 'FK % non validée : public.agent_tasks.% référence des clés inexistantes', cname, col;
    END;
  END LOOP;
END $$;

-- Poll de l'agent (T46) : WHERE user_id = $1 AND status = 'pending'
--                         ORDER BY priority, created_at LIMIT 5
CREATE INDEX IF NOT EXISTS idx_agent_tasks_poll
  ON public.agent_tasks (user_id, priority, created_at)
  WHERE status = 'pending';
-- FK : filtre du poll par clé + ON DELETE SET NULL sans parcours complet de la table.
CREATE INDEX IF NOT EXISTS idx_agent_tasks_target_key
  ON public.agent_tasks (target_agent_key_id)
  WHERE target_agent_key_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_agent_tasks_claimed_key
  ON public.agent_tasks (claimed_by_key_id)
  WHERE claimed_by_key_id IS NOT NULL;


-- 2) Trigger updated_at d'agent_tasks (T45) -----------------------------------------
-- updated_at sert de bail / signe de vie (remise en file des tâches in_progress muettes).
-- Avant : POST /api/agent-tasks/:id/control exécute
--   UPDATE agent_tasks SET control = $1, updated_at = now() …
-- et, quand la valeur de control ne change pas, la ligne est identique à part
-- updated_at : le trigger y voyait un heartbeat et prolongeait le bail.
-- Le heartbeat (UPDATE agent_tasks SET updated_at = now() …) et un envoi répété de
-- control produisent la même ligne : seule la LISTE SET les distingue. D'où deux triggers :
--
--   a) update_agent_tasks_updated_at (toute UPDATE) — inchangé sur le fond :
--        - une colonne autre que control/updated_at change  → updated_at = now()
--        - seul control change                               → updated_at conservé
--        - rien ne change (heartbeat « touch »)              → updated_at = now()
--   b) update_agent_tasks_updated_at_control (UPDATE OF control : `control` figure
--      dans la liste SET, que sa valeur change ou non) :
--        - aucune colonne autre que control/updated_at ne change → updated_at conservé
--
-- (b) DOIT s'exécuter APRÈS (a) : PostgreSQL déclenche les triggers BEFORE d'un même
-- évènement par ordre alphabétique de nom ('…_updated_at' < '…_updated_at_control').
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

CREATE OR REPLACE FUNCTION public.agent_tasks_keep_updated_at_on_control()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF (to_jsonb(NEW) - 'control' - 'updated_at') IS NOT DISTINCT FROM
     (to_jsonb(OLD) - 'control' - 'updated_at') THEN
    NEW.updated_at := OLD.updated_at;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS update_agent_tasks_updated_at ON public.agent_tasks;
CREATE TRIGGER update_agent_tasks_updated_at
  BEFORE UPDATE ON public.agent_tasks
  FOR EACH ROW EXECUTE FUNCTION public.agent_tasks_set_updated_at();

DROP TRIGGER IF EXISTS update_agent_tasks_updated_at_control ON public.agent_tasks;
CREATE TRIGGER update_agent_tasks_updated_at_control
  BEFORE UPDATE OF control ON public.agent_tasks
  FOR EACH ROW EXECUTE FUNCTION public.agent_tasks_keep_updated_at_on_control();


-- 3) has_role / is_admin (S19) ------------------------------------------------------
-- has_role(_user_id, _role) répond pour n'importe quel utilisateur, y compris pour
-- anon. Une fonction reçoit EXECUTE pour PUBLIC à sa création : révoquer seulement
-- « FROM anon » laisserait anon passer par PUBLIC. On révoque donc PUBLIC + anon et on
-- ré-accorde explicitement authenticated (policy « Admins can manage roles », encore
-- utilisée) et service_role. Le propriétaire (postgres, utilisé par node-api :
-- routes/knowledge.ts) garde son droit. NE PAS révoquer authenticated ici (vague G4).
REVOKE EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) FROM anon;
GRANT  EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) TO authenticated, service_role;

-- is_admin() : sans argument, ne répond que pour l'appelant (auth.uid()).
-- search_path vide : tous les objets sont qualifiés (pas de détournement par search_path).
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.user_roles
     WHERE user_id = auth.uid()
       AND role = 'admin'::public.app_role
  )
$$;

COMMENT ON FUNCTION public.is_admin() IS
  'Vrai si l''utilisateur courant (auth.uid()) a le rôle admin. Remplace has_role(auth.uid(), ''admin'') dans les policies.';

REVOKE EXECUTE ON FUNCTION public.is_admin() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.is_admin() FROM anon;
GRANT  EXECUTE ON FUNCTION public.is_admin() TO authenticated, service_role;

-- Même sémantique qu'avant (FOR ALL, USING = has_role(auth.uid(), 'admin')), mais via
-- is_admin() : la future révocation de has_role pour authenticated (G4) ne la cassera pas.
DROP POLICY IF EXISTS "Admins can manage roles" ON public.user_roles;
CREATE POLICY "Admins can manage roles" ON public.user_roles
  FOR ALL TO authenticated USING (public.is_admin());


-- 4) Policies (S20) -----------------------------------------------------------------
-- 4a) agent_keys : les clés sont créées et mises à jour par node-api
--     (POST /api/agent-keys, announce, last_used_at). Le navigateur passe par l'API
--     (frontend/src/pages/Security.tsx) : aucune écriture directe vérifiée par grep.
--     Le client garde la lecture et la suppression (révocation) de ses propres clés.
DROP POLICY IF EXISTS "Users manage own agent keys" ON public.agent_keys;
DROP POLICY IF EXISTS "Users view own agent keys"   ON public.agent_keys;
DROP POLICY IF EXISTS "Users delete own agent keys" ON public.agent_keys;
CREATE POLICY "Users view own agent keys" ON public.agent_keys
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users delete own agent keys" ON public.agent_keys
  FOR DELETE TO authenticated USING (auth.uid() = user_id);

-- 4b) INSERT inter-locataires : user_id = auth.uid() ne suffit pas, la ligne parente
--     (conversation, entrée de connaissance, schéma) doit aussi appartenir à l'appelant.
--     Le nom des policies est conservé.
DROP POLICY IF EXISTS "Users can create messages" ON public.chat_messages;
CREATE POLICY "Users can create messages" ON public.chat_messages
  FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (SELECT 1 FROM public.chat_conversations c
                 WHERE c.id = chat_messages.conversation_id
                   AND c.user_id = auth.uid())
  );

DROP POLICY IF EXISTS "Users create own knowledge versions" ON public.knowledge_versions;
CREATE POLICY "Users create own knowledge versions" ON public.knowledge_versions
  FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (SELECT 1 FROM public.knowledge_base kb
                 WHERE kb.id = knowledge_versions.entry_id
                   AND kb.user_id = auth.uid())
  );

-- Même défaut sur la base dynamique (schema_id d'un autre utilisateur). Aucune écriture
-- directe côté client (tout passe par POST /api/database) : resserrement sans impact.
DROP POLICY IF EXISTS "Users can insert own data" ON public.user_table_data;
CREATE POLICY "Users can insert own data" ON public.user_table_data
  FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (SELECT 1 FROM public.user_schemas s
                 WHERE s.id = user_table_data.schema_id
                   AND s.user_id = auth.uid())
  );

DROP POLICY IF EXISTS "Users can update own data" ON public.user_table_data;
CREATE POLICY "Users can update own data" ON public.user_table_data
  FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (SELECT 1 FROM public.user_schemas s
                 WHERE s.id = user_table_data.schema_id
                   AND s.user_id = auth.uid())
  );

DROP POLICY IF EXISTS "Users can create migrations" ON public.user_migrations;
CREATE POLICY "Users can create migrations" ON public.user_migrations
  FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (SELECT 1 FROM public.user_schemas s
                 WHERE s.id = user_migrations.schema_id
                   AND s.user_id = auth.uid())
  );


-- 5) modules_status : schéma mort (T48) ---------------------------------------------
-- Aucune lecture ni écriture dans frontend/, backend/ ou agent/. Conservée (règle
-- « Jamais » : ne pas supprimer), seulement marquée.
COMMENT ON TABLE public.modules_status IS
  'DÉPRÉCIÉ (LOT 1, T48) : table inutilisée par le code (frontend, node-api, agent). Conservée sans suppression ; ne pas l''utiliser pour de nouveaux développements.';


-- 6) agent_memory : valeurs autorisées (S11) ---------------------------------------
-- status : workflow proposed → validated | rejected (contrat LOT 1 §9).
-- level  : niveaux acceptés par node-api (routes/agentMemory.ts, LEVELS).
-- NOT VALID : n'échoue pas sur d'éventuelles lignes historiques ; validation tentée
-- ensuite, un échec est seulement signalé (NOTICE).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'agent_memory_status_check'
                    AND conrelid = 'public.agent_memory'::regclass) THEN
    ALTER TABLE public.agent_memory
      ADD CONSTRAINT agent_memory_status_check
      CHECK (status IN ('proposed', 'validated', 'rejected')) NOT VALID;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'agent_memory_level_check'
                    AND conrelid = 'public.agent_memory'::regclass) THEN
    ALTER TABLE public.agent_memory
      ADD CONSTRAINT agent_memory_level_check
      CHECK (level IN ('working', 'project', 'user', 'technical',
                       'documentary', 'workflow', 'error', 'optimization')) NOT VALID;
  END IF;
END $$;

DO $$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY ARRAY['agent_memory_status_check', 'agent_memory_level_check'] LOOP
    BEGIN
      EXECUTE format('ALTER TABLE public.agent_memory VALIDATE CONSTRAINT %I', c);
    EXCEPTION WHEN check_violation THEN
      RAISE NOTICE 'Contrainte % non validée : des lignes existantes la violent', c;
    END;
  END LOOP;
END $$;


-- >>>>>>>>>> 20261001100000_lot1_verif.sql <<<<<<<<<<

-- =============================================================================
-- LOT 1 — Suite de la vérification adverse (après 20261001090000_lot1_fixes.sql)
-- Migration ADDITIVE et IDEMPOTENTE (même style que hardening / lot1_fixes) :
-- IF [NOT] EXISTS, DROP POLICY IF EXISTS puis CREATE, CREATE OR REPLACE. Aucune donnée
-- supprimée ni modifiée (seuls une valeur par défaut, des policies, un droit EXECUTE,
-- un index et une fonction de trigger changent).
--
--  1. Trigger updated_at d'agent_tasks : le détachement d'une clé agent (FK
--     ON DELETE SET NULL de target_agent_key_id / claimed_by_key_id) ne prolonge plus
--     le bail d'une tâche in_progress.
--  2. agent_memory (S11, contrat §9) : défaut de status 'proposed' ; côté client
--     lecture + suppression seulement (plus d'INSERT/UPDATE direct par PostgREST).
--  3. agent_memory (T11) : index trigramme (pg_trgm, GIN) pour `goal ILIKE ANY(…)`.
--  4. Vague G2/G3 (audit §12, contrat §11) : l'UI n'écrit plus qu'au travers de l'API
--     → knowledge_base en lecture seule pour le client, plus de DELETE client sur
--     agent_tasks.
--  5. agent_keys : plus de DELETE client (la révocation passe par
--     DELETE /api/agent-keys/:id, qui annule d'abord les tâches du PC révoqué).
--  6. Vague G4 (S19) : has_role(uuid, app_role) n'est plus exécutable par authenticated
--     (toutes les policies utilisent is_admin()).
--
-- Prérequis côté application (vérifié par grep dans frontend/ et backend/console/ au
-- LOT 1) : aucune écriture directe dans knowledge_base, agent_tasks, agent_keys ou
-- agent_memory, et aucun appel RPC à has_role. Un ancien front encore déployé qui
-- écrirait directement ces tables échouerait (INSERT refusé, UPDATE/DELETE sans effet) :
-- redéployer le front du même commit (docs/SUPABASE_REPRISE.md §5).
--
-- Règles « Jamais » (audit §12) respectées : le CHECK de statut d'agent_tasks n'est pas
-- touché, aucune FK sur agent_events.task_id, rien n'est renommé ni supprimé.
-- =============================================================================


-- 1) Trigger updated_at d'agent_tasks : détachement de clé ----------------------------
-- Révoquer une clé (DELETE FROM agent_keys) déclenche l'action référentielle
-- ON DELETE SET NULL, c'est-à-dire un UPDATE d'agent_tasks qui ne change que
-- target_agent_key_id / claimed_by_key_id. Le trigger y voyait un « vrai » changement
-- et rafraîchissait updated_at : une tâche in_progress orpheline gagnait un bail complet.
-- Règles (dans l'ordre) :
--   - une colonne autre que control / updated_at / clés change      → updated_at = now()
--   - une clé est ÉCRITE (nouvelle valeur non NULL : claim)          → updated_at = now()
--   - une clé passe seulement à NULL (détachement, SET NULL)        → updated_at conservé
--   - seul control change                                           → updated_at conservé
--   - rien ne change (heartbeat « touch »)                          → updated_at = now()
-- Le second trigger (update_agent_tasks_updated_at_control, UPDATE OF control) est
-- inchangé : il ne s'applique que si control figure dans la liste SET.
CREATE OR REPLACE FUNCTION public.agent_tasks_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  key_cols CONSTANT text[] := ARRAY['target_agent_key_id', 'claimed_by_key_id'];
BEGIN
  IF (to_jsonb(NEW) - 'control' - 'updated_at' - key_cols) IS DISTINCT FROM
     (to_jsonb(OLD) - 'control' - 'updated_at' - key_cols) THEN
    NEW.updated_at := now();
  ELSIF (NEW.target_agent_key_id IS DISTINCT FROM OLD.target_agent_key_id
         AND NEW.target_agent_key_id IS NOT NULL)
     OR (NEW.claimed_by_key_id IS DISTINCT FROM OLD.claimed_by_key_id
         AND NEW.claimed_by_key_id IS NOT NULL) THEN
    NEW.updated_at := now();
  ELSIF NEW.target_agent_key_id IS DISTINCT FROM OLD.target_agent_key_id
     OR NEW.claimed_by_key_id IS DISTINCT FROM OLD.claimed_by_key_id THEN
    NEW.updated_at := OLD.updated_at;
  ELSIF NEW.control IS DISTINCT FROM OLD.control THEN
    NEW.updated_at := OLD.updated_at;
  ELSE
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$$;
-- Le trigger update_agent_tasks_updated_at (lot1_fixes §2) appelle déjà cette fonction.


-- 2) agent_memory : statut par défaut et policies (S11) ------------------------------
-- Défaut 'validated' hérité de 20260706120000 : toute insertion qui omet status (accès
-- direct, futur écrivain) contournait le contrat §9 (« validated » seulement par une
-- action explicite de l'utilisateur). Les lignes existantes ne sont pas modifiées.
ALTER TABLE public.agent_memory ALTER COLUMN status SET DEFAULT 'proposed';

-- Les écritures passent par node-api (writeMemory, POST/PATCH /api/agent-memory, qui
-- pose metadata.validated_by). Côté client : lecture et suppression de ses entrées.
-- Le rejeu de 20260704000000 ne recrée pas la policy FOR ALL (garde « aucune policy »).
DROP POLICY IF EXISTS "Users manage own agent memory" ON public.agent_memory;
DROP POLICY IF EXISTS "Users view own agent memory"   ON public.agent_memory;
DROP POLICY IF EXISTS "Users delete own agent memory" ON public.agent_memory;
CREATE POLICY "Users view own agent memory" ON public.agent_memory
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users delete own agent memory" ON public.agent_memory
  FOR DELETE TO authenticated USING (auth.uid() = user_id);


-- 3) agent_memory : index trigramme sur goal (T11) -----------------------------------
-- getMemoryContext (node-api) filtre par `goal ILIKE ANY('{%mot%,…}')` : sans index
-- trigramme, c'est un parcours de toutes les mémoires de l'utilisateur. pg_trgm est
-- disponible sur Supabase (extension « trusted ») ; installée dans le schéma
-- `extensions` quand il existe (convention Supabase), sinon dans le schéma par défaut.
-- La classe d'opérateurs est recherchée là où l'extension se trouve réellement (une
-- installation antérieure dans public reste valable).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
    IF to_regnamespace('extensions') IS NOT NULL THEN
      CREATE EXTENSION pg_trgm WITH SCHEMA extensions;
    ELSE
      CREATE EXTENSION pg_trgm;
    END IF;
  END IF;
END $$;

DO $$
DECLARE
  opclass text;
BEGIN
  IF to_regclass('public.idx_agent_memory_goal_gin_trgm') IS NULL THEN
    SELECT format('%I.%I', n.nspname, c.opcname) INTO opclass
      FROM pg_opclass c
      JOIN pg_namespace n ON n.oid = c.opcnamespace
      JOIN pg_am a        ON a.oid = c.opcmethod
     WHERE c.opcname = 'gin_trgm_ops' AND a.amname = 'gin'
     LIMIT 1;
    IF opclass IS NULL THEN
      RAISE EXCEPTION 'pg_trgm installée mais classe d''opérateurs gin_trgm_ops introuvable';
    END IF;
    EXECUTE format(
      'CREATE INDEX idx_agent_memory_goal_gin_trgm ON public.agent_memory USING gin (goal %s)',
      opclass);
  END IF;
END $$;


-- 4) Vague G2 / G3 : écritures client retirées (contrat §11, S9, C27) ----------------
-- knowledge_base : l'UI écrit via /api/knowledge (hash, version, embedding calculés par
-- le serveur) ; une écriture directe contournait les trois. La lecture reste ouverte.
DROP POLICY IF EXISTS "Users can create knowledge"     ON public.knowledge_base;
DROP POLICY IF EXISTS "Users can update own knowledge" ON public.knowledge_base;
DROP POLICY IF EXISTS "Users can delete own knowledge" ON public.knowledge_base;

-- agent_tasks : suppression via DELETE /api/agent-tasks/:id (tâches terminales
-- seulement ; une tâche en cours s'annule par /cancel). INSERT et UPDATE client sont
-- déjà retirés (20261001000000_hardening.sql §1). Lecture et Realtime inchangés.
DROP POLICY IF EXISTS "Users can delete own tasks" ON public.agent_tasks;


-- 5) agent_keys : révocation par l'API uniquement ------------------------------------
-- DELETE /api/agent-keys/:id annule, dans la même transaction, les tâches ciblant ce PC
-- ou réclamées par lui, puis supprime la clé. Un DELETE direct (PostgREST) sautait
-- cette étape : la FK ON DELETE SET NULL rendait ces tâches non ciblées, réclamables et
-- finalisables par n'importe quel autre PC de l'utilisateur. Le client garde la lecture.
DROP POLICY IF EXISTS "Users delete own agent keys" ON public.agent_keys;


-- 6) Vague G4 : has_role n'est plus exécutable par authenticated (S19) ----------------
-- Il répondait pour n'importe quel utilisateur (« X est-il admin ? »). Plus aucune policy
-- ne l'utilise (« Admins can manage roles » → is_admin(), lot1_fixes §3) et ni le front
-- ni la console ne l'appellent. Le propriétaire (postgres), service_role et soulbah_api
-- (scripts/sql/soulbah_api_grants.sql) gardent leur droit : routes/knowledge.ts.
-- Garde-fou : si une policy créée hors migrations (tableau de bord) l'utilise encore,
-- la révocation la casserait → elle est sautée avec un WARNING (à traiter à la main,
-- docs/SUPABASE_REPRISE.md §7).
DO $$
DECLARE
  users text;
BEGIN
  SELECT string_agg(format('%I.%I « %s »', schemaname, tablename, policyname), ', ')
    INTO users
    FROM pg_policies
   WHERE coalesce(qual, '') ~ '\mhas_role\s*\('
      OR coalesce(with_check, '') ~ '\mhas_role\s*\(';
  IF users IS NULL THEN
    REVOKE EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) FROM authenticated;
  ELSE
    RAISE WARNING 'G4 non appliquée : has_role est encore utilisée par %', users;
  END IF;
END $$;


-- >>>>>>>>>> 20261001120000_v2_schema.sql <<<<<<<<<<

-- =============================================================================
-- V2 — 1/12 : schéma `soulbah` (LOT 4, audit §9, §12).
-- Migration IDEMPOTENTE et ADDITIVE (rien n'est supprimé ni renommé ; public.* intact).
--
-- Le schéma `soulbah` est le plan de contrôle V2 : node-api en est le SEUL écrivain
-- (connexion privilégiée, rôle soulbah_api). Il n'est jamais exposé à PostgREST ni aux
-- clients : tout droit est révoqué pour PUBLIC, anon et authenticated, et aucune policy
-- n'ouvre l'accès (RLS activée sur chaque table, sans policy = refus).
-- Supabase : NE PAS ajouter `soulbah` aux « Exposed schemas » de l'API.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS soulbah;
COMMENT ON SCHEMA soulbah IS
  'Soulbah IA V2 — plan de contrôle (sessions, tâches, messages, preuves, audit). Écrit par node-api uniquement ; jamais exposé à PostgREST.';

REVOKE ALL ON SCHEMA soulbah FROM PUBLIC;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON SCHEMA soulbah FROM %I', r);
      -- Objets futurs créés par le rôle courant : aucun droit par défaut pour les clients.
      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah REVOKE ALL ON TABLES FROM %I', r);
      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah REVOKE ALL ON SEQUENCES FROM %I', r);
      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah REVOKE ALL ON FUNCTIONS FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- Horodatage de modification (même rôle que public.update_updated_at_column, propre au schéma).
CREATE OR REPLACE FUNCTION soulbah.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Niveaux de sécurité (audit §9.10) et aides de validation réutilisées par les CHECK.
CREATE OR REPLACE FUNCTION soulbah.is_security_level(p text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$ SELECT p IN ('L0', 'L1', 'L2', 'L3') $$;

CREATE OR REPLACE FUNCTION soulbah.is_json_array(p jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$ SELECT p IS NOT NULL AND jsonb_typeof(p) = 'array' $$;

CREATE OR REPLACE FUNCTION soulbah.is_json_object(p jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$ SELECT p IS NOT NULL AND jsonb_typeof(p) = 'object' $$;


-- >>>>>>>>>> 20261001120100_v2_users_sessions.sql <<<<<<<<<<

-- =============================================================================
-- V2 — 2/12 : réglages utilisateur et sessions (missions) — audit §9.4, §9.6, §12.
-- Idempotente, additive.
-- =============================================================================

-- Réglages par utilisateur (page Paramètres). max_parallel_agents : CHECK 1–32 (§9.6).
CREATE TABLE IF NOT EXISTS soulbah.user_settings (
  user_id              uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  max_parallel_agents  integer NOT NULL DEFAULT 6
                       CONSTRAINT user_settings_max_parallel_range CHECK (max_parallel_agents BETWEEN 1 AND 32),
  -- Plafond de niveau de sécurité autorisé sans approbation par action (L0–L3).
  max_security_level   text NOT NULL DEFAULT 'L2'
                       CONSTRAINT user_settings_level_check CHECK (soulbah.is_security_level(max_security_level)),
  -- Budget quotidien (USD) des appels de modèles ; NULL = illimité.
  daily_budget_usd     numeric(12, 4) CONSTRAINT user_settings_budget_positive CHECK (daily_budget_usd IS NULL OR daily_budget_usd >= 0),
  settings             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT user_settings_settings_object CHECK (soulbah.is_json_object(settings)),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE soulbah.user_settings ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.user_settings;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.user_settings
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- Sessions : une mission = un objectif, un plan (DAG) versionné, un cycle
-- DRAFT → PLANNING → AWAITING_APPROVAL → RUNNING/PAUSED → COMPLETED | FAILED | CANCELLED (§9.3).
CREATE TABLE IF NOT EXISTS soulbah.sessions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  goal                 text NOT NULL CONSTRAINT sessions_goal_length CHECK (length(goal) BETWEEN 1 AND 4000),
  status               text NOT NULL DEFAULT 'DRAFT'
                       CONSTRAINT sessions_status_check CHECK (status IN
                         ('DRAFT', 'PLANNING', 'AWAITING_APPROVAL', 'RUNNING', 'PAUSED', 'COMPLETED', 'FAILED', 'CANCELLED')),
  -- Environnement d'exécution (PC ciblé, workspace, variables non secrètes…).
  environment          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT sessions_environment_object CHECK (soulbah.is_json_object(environment)),
  max_security_level   text NOT NULL DEFAULT 'L2'
                       CONSTRAINT sessions_level_check CHECK (soulbah.is_security_level(max_security_level)),
  -- Surcharge par mission du parallélisme (NULL = réglage utilisateur / global).
  max_parallel_agents  integer CONSTRAINT sessions_max_parallel_range CHECK (max_parallel_agents IS NULL OR max_parallel_agents BETWEEN 1 AND 32),
  budget_usd           numeric(12, 4) CONSTRAINT sessions_budget_positive CHECK (budget_usd IS NULL OR budget_usd >= 0),
  spent_usd            numeric(12, 4) NOT NULL DEFAULT 0 CONSTRAINT sessions_spent_positive CHECK (spent_usd >= 0),
  plan                 jsonb,
  plan_version         integer NOT NULL DEFAULT 0 CONSTRAINT sessions_plan_version_positive CHECK (plan_version >= 0),
  -- Session simulée (dry-run) : n'écrit jamais de mémoire, jamais COMPLETED « pour de vrai » (§9.8).
  simulated            boolean NOT NULL DEFAULT false,
  error                text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  started_at           timestamptz,
  finished_at          timestamptz
);
ALTER TABLE soulbah.sessions ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.sessions;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.sessions
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
CREATE INDEX IF NOT EXISTS idx_sessions_user_status ON soulbah.sessions (user_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_active ON soulbah.sessions (status)
  WHERE status IN ('PLANNING', 'AWAITING_APPROVAL', 'RUNNING', 'PAUSED');


-- >>>>>>>>>> 20261001120200_v2_agents_runtimes.sql <<<<<<<<<<

-- =============================================================================
-- V2 — 3/12 : agents (rôles instanciés dans une session), runtimes (PC exécutants) et
-- extension de public.agent_keys — audit §9.2, §9.6, §12.
-- Idempotente, additive.
-- =============================================================================

-- agent_keys : une clé = un PC (V1) ou un runtime V2 (kind), avec portées, expiration et
-- capacités annoncées (slots, écran, téléphone, navigateur…).
ALTER TABLE public.agent_keys
  ADD COLUMN IF NOT EXISTS kind          text NOT NULL DEFAULT 'agent',
  ADD COLUMN IF NOT EXISTS scopes        jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS expires_at    timestamptz,
  ADD COLUMN IF NOT EXISTS capabilities  jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS last_seen_at  timestamptz;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_keys_kind_check'
                   AND conrelid = 'public.agent_keys'::regclass) THEN
    ALTER TABLE public.agent_keys ADD CONSTRAINT agent_keys_kind_check
      CHECK (kind IN ('agent', 'runtime')) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_keys_scopes_array'
                   AND conrelid = 'public.agent_keys'::regclass) THEN
    ALTER TABLE public.agent_keys ADD CONSTRAINT agent_keys_scopes_array
      CHECK (soulbah.is_json_array(scopes)) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_keys_capabilities_object'
                   AND conrelid = 'public.agent_keys'::regclass) THEN
    ALTER TABLE public.agent_keys ADD CONSTRAINT agent_keys_capabilities_object
      CHECK (soulbah.is_json_object(capabilities)) NOT VALID;
  END IF;
END $$;
DO $$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY ARRAY['agent_keys_kind_check', 'agent_keys_scopes_array', 'agent_keys_capabilities_object'] LOOP
    BEGIN
      EXECUTE format('ALTER TABLE public.agent_keys VALIDATE CONSTRAINT %I', c);
    EXCEPTION WHEN check_violation THEN
      RAISE NOTICE 'Contrainte % non validée : des lignes existantes la violent', c;
    END;
  END LOOP;
END $$;

-- Runtimes : processus superviseur d'un PC (LOT 8), lié à une clé agent.
CREATE TABLE IF NOT EXISTS soulbah.runtimes (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  agent_key_id   uuid NOT NULL REFERENCES public.agent_keys(id) ON DELETE CASCADE,
  hostname       text,
  version        text,
  -- Capacité du PC (SOULBAH_MAX_SLOTS), bornée comme les autres plafonds (§9.6).
  max_slots      integer NOT NULL DEFAULT 6 CONSTRAINT runtimes_max_slots_range CHECK (max_slots BETWEEN 1 AND 32),
  capabilities   jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT runtimes_capabilities_object CHECK (soulbah.is_json_object(capabilities)),
  status         text NOT NULL DEFAULT 'offline'
                 CONSTRAINT runtimes_status_check CHECK (status IN ('online', 'draining', 'offline')),
  lease_owner    text,
  last_seen_at   timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT runtimes_one_per_key UNIQUE (agent_key_id)
);
ALTER TABLE soulbah.runtimes ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.runtimes;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.runtimes
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
CREATE INDEX IF NOT EXISTS idx_runtimes_user ON soulbah.runtimes (user_id, status);

-- Agents : un rôle instancié dans une session (desktop_operator, coder, researcher, qa_reviewer…).
-- current_task_id est ajouté par 4/12 (la table tasks n'existe pas encore).
CREATE TABLE IF NOT EXISTS soulbah.agents (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id     uuid NOT NULL REFERENCES soulbah.sessions(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role           text NOT NULL CONSTRAINT agents_role_format CHECK (role ~ '^[a-z][a-z0-9_]{0,63}$'),
  role_version   text NOT NULL DEFAULT '1.0.0',
  name           text,
  status         text NOT NULL DEFAULT 'IDLE'
                 CONSTRAINT agents_status_check CHECK (status IN ('IDLE', 'BUSY', 'WAITING', 'STOPPED', 'FAILED')),
  runtime_id     uuid REFERENCES soulbah.runtimes(id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE soulbah.agents ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.agents;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.agents
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
CREATE INDEX IF NOT EXISTS idx_agents_session ON soulbah.agents (session_id, status);
-- Compteur « x/6 » : agents BUSY par utilisateur (§9.6).
CREATE INDEX IF NOT EXISTS idx_agents_busy ON soulbah.agents (user_id) WHERE status = 'BUSY';


-- >>>>>>>>>> 20261001120300_v2_tasks.sql <<<<<<<<<<

-- =============================================================================
-- V2 — 4/12 : tâches (10 états, baux, idempotence, critères) — audit §9.4, §9.8, §12.
-- Idempotente, additive. public.agent_tasks garde ses 5 statuts (CHECK intact) : seule la
-- colonne nullable v2_task_id est ajoutée (correspondance avec la tâche V2).
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.tasks (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id           uuid NOT NULL REFERENCES soulbah.sessions(id) ON DELETE CASCADE,
  user_id              uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  parent_task_id       uuid REFERENCES soulbah.tasks(id) ON DELETE SET NULL,
  -- Identifiant stable dans le plan (nœud du DAG), ex. « observe_1 ».
  node_key             text CONSTRAINT tasks_node_key_format CHECK (node_key IS NULL OR node_key ~ '^[a-z][a-z0-9_.-]{0,63}$'),
  title                text NOT NULL CONSTRAINT tasks_title_length CHECK (length(title) BETWEEN 1 AND 500),
  role                 text NOT NULL CONSTRAINT tasks_role_format CHECK (role ~ '^[a-z][a-z0-9_]{0,63}$'),
  status               text NOT NULL DEFAULT 'PENDING'
                       CONSTRAINT tasks_status_check CHECK (status IN
                         ('PENDING', 'READY', 'RUNNING', 'WAITING', 'BLOCKED', 'VALIDATING',
                          'RETRYING', 'COMPLETED', 'FAILED', 'CANCELLED')),
  -- Bail (§9.4) : attempt +1 à chaque READY → RUNNING ; lease_owner = runtime:slot.
  attempt              integer NOT NULL DEFAULT 0 CONSTRAINT tasks_attempt_positive CHECK (attempt >= 0),
  retry_count          integer NOT NULL DEFAULT 0 CONSTRAINT tasks_retry_positive CHECK (retry_count >= 0),
  max_retries          integer NOT NULL DEFAULT 2 CONSTRAINT tasks_max_retries_range CHECK (max_retries BETWEEN 0 AND 10),
  lease_owner          text,
  lease_expires_at     timestamptz,
  -- Clé d'idempotence fournie par le planificateur (unique par session).
  idempotency_key      text,
  security_level       text NOT NULL DEFAULT 'L1'
                       CONSTRAINT tasks_level_check CHECK (soulbah.is_security_level(security_level)),
  -- Ressources exclusives/partagées déclarées (§9.7) : [{"key":"desktop.input:<runtime>","mode":"exclusive"}].
  resources            jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT tasks_resources_array CHECK (soulbah.is_json_array(resources)),
  -- Spécification exécutable (étapes du catalogue d'outils, instructions du rôle…).
  spec                 jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT tasks_spec_object CHECK (soulbah.is_json_object(spec)),
  -- DSL de critères d'acceptation (§9.8) : [{"type":"file_exists","path":…,"required":true}].
  acceptance_criteria  jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT tasks_criteria_array CHECK (soulbah.is_json_array(acceptance_criteria)),
  result               jsonb,
  error                text,
  simulated            boolean NOT NULL DEFAULT false,
  blocked_reason       text,
  waiting_reason       text,
  priority             integer NOT NULL DEFAULT 5 CONSTRAINT tasks_priority_range CHECK (priority BETWEEN 1 AND 10),
  plan_version         integer NOT NULL DEFAULT 0 CONSTRAINT tasks_plan_version_positive CHECK (plan_version >= 0),
  -- RETRYING → READY quand next_attempt_at est atteint (backoff 30 s, 2 min, 8 min).
  next_attempt_at      timestamptz,
  -- BLOCKED → FAILED à l'échéance d'escalade (24 h par défaut).
  escalate_at          timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  started_at           timestamptz,
  finished_at          timestamptz,
  -- Une tâche simulée ne peut pas être COMPLETED (§9.4 « un run simulated ne passe jamais »).
  CONSTRAINT tasks_simulated_never_completed CHECK (NOT (simulated AND status = 'COMPLETED'))
);
ALTER TABLE soulbah.tasks ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.tasks;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.tasks
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE UNIQUE INDEX IF NOT EXISTS uq_tasks_idempotency ON soulbah.tasks (session_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_tasks_node_key ON soulbah.tasks (session_id, plan_version, node_key)
  WHERE node_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_session_status ON soulbah.tasks (session_id, status);
CREATE INDEX IF NOT EXISTS idx_tasks_user_status ON soulbah.tasks (user_id, status, created_at DESC);
-- File du scheduler (READY, par priorité puis ancienneté) et backoff des RETRYING.
CREATE INDEX IF NOT EXISTS idx_tasks_ready ON soulbah.tasks (priority, created_at) WHERE status = 'READY';
CREATE INDEX IF NOT EXISTS idx_tasks_retrying ON soulbah.tasks (next_attempt_at) WHERE status = 'RETRYING';
-- Reaper : baux expirés des tâches actives (§9.4 : passage direct en RETRYING).
CREATE INDEX IF NOT EXISTS idx_tasks_lease ON soulbah.tasks (lease_expires_at)
  WHERE status IN ('RUNNING', 'WAITING', 'VALIDATING');
CREATE INDEX IF NOT EXISTS idx_tasks_parent ON soulbah.tasks (parent_task_id) WHERE parent_task_id IS NOT NULL;

-- Machine à états (§9.4) : toute transition absente du tableau est refusée en base
-- (défense en profondeur ; node-api applique la même table). CANCELLED est atteignable
-- depuis tout état non terminal ; FAILED → READY = relance manuelle auditée.
CREATE OR REPLACE FUNCTION soulbah.tasks_check_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;
  IF NEW.status = 'CANCELLED' AND OLD.status NOT IN ('COMPLETED', 'FAILED', 'CANCELLED') THEN
    RETURN NEW;
  END IF;
  IF (OLD.status, NEW.status) IN (
       ('PENDING', 'READY'), ('PENDING', 'BLOCKED'),
       ('READY', 'RUNNING'),
       ('RUNNING', 'WAITING'), ('RUNNING', 'BLOCKED'), ('RUNNING', 'VALIDATING'),
       ('RUNNING', 'RETRYING'), ('RUNNING', 'FAILED'),
       ('WAITING', 'RUNNING'), ('WAITING', 'BLOCKED'), ('WAITING', 'RETRYING'), ('WAITING', 'FAILED'),
       ('BLOCKED', 'READY'), ('BLOCKED', 'PENDING'), ('BLOCKED', 'FAILED'),
       ('VALIDATING', 'COMPLETED'), ('VALIDATING', 'RETRYING'), ('VALIDATING', 'FAILED'),
       ('RETRYING', 'READY'),
       ('FAILED', 'READY')) THEN
    IF OLD.status = 'READY' AND NEW.status = 'RUNNING' AND NEW.attempt <> OLD.attempt + 1 THEN
      RAISE EXCEPTION 'soulbah.tasks % : READY → RUNNING exige attempt = % (reçu %)', OLD.id, OLD.attempt + 1, NEW.attempt
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'soulbah.tasks % : transition % → % interdite (audit §9.4)', OLD.id, OLD.status, NEW.status
    USING ERRCODE = 'check_violation';
END $$;
DROP TRIGGER IF EXISTS check_transition ON soulbah.tasks;
CREATE TRIGGER check_transition BEFORE UPDATE OF status ON soulbah.tasks
  FOR EACH ROW EXECUTE FUNCTION soulbah.tasks_check_transition();

-- agents.current_task_id (3/12 ne pouvait pas encore référencer tasks).
ALTER TABLE soulbah.agents ADD COLUMN IF NOT EXISTS current_task_id uuid;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agents_current_task_fk') THEN
    ALTER TABLE soulbah.agents ADD CONSTRAINT agents_current_task_fk
      FOREIGN KEY (current_task_id) REFERENCES soulbah.tasks(id) ON DELETE SET NULL;
  END IF;
END $$;

-- Pont V1 : la tâche agent_tasks créée pour exécuter une tâche V2 (legacy_adapter, LOT 8).
ALTER TABLE public.agent_tasks ADD COLUMN IF NOT EXISTS v2_task_id uuid;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_tasks_v2_task_fk') THEN
    ALTER TABLE public.agent_tasks ADD CONSTRAINT agent_tasks_v2_task_fk
      FOREIGN KEY (v2_task_id) REFERENCES soulbah.tasks(id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_agent_tasks_v2_task ON public.agent_tasks (v2_task_id) WHERE v2_task_id IS NOT NULL;


-- >>>>>>>>>> 20261001120400_v2_task_dependencies.sql <<<<<<<<<<

-- =============================================================================
-- V2 — 5/12 : dépendances entre tâches (arêtes du DAG) + trigger anti-cycle — audit §9.4, §12.
-- Idempotente, additive.
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.task_dependencies (
  task_id             uuid NOT NULL REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  depends_on_task_id  uuid NOT NULL REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  -- hard : bloque READY tant que la dépendance n'est pas COMPLETED (FAILED/CANCELLED → BLOCKED) ;
  -- soft : ordre préféré, jamais bloquant.
  kind                text NOT NULL DEFAULT 'hard' CONSTRAINT task_dependencies_kind_check CHECK (kind IN ('hard', 'soft')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (task_id, depends_on_task_id),
  CONSTRAINT task_dependencies_no_self CHECK (task_id <> depends_on_task_id)
);
ALTER TABLE soulbah.task_dependencies ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_task_dependencies_reverse ON soulbah.task_dependencies (depends_on_task_id);

-- Anti-cycle : A → B → A est refusé (critère de sortie LOT 4). Les deux tâches doivent
-- appartenir à la même session ; la session est verrouillée (FOR UPDATE) pour sérialiser
-- les insertions concurrentes d'un même DAG.
CREATE OR REPLACE FUNCTION soulbah.task_dependencies_check_cycle()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
DECLARE
  s_task  uuid;
  s_dep   uuid;
  cyc     boolean;
BEGIN
  SELECT session_id INTO s_task FROM soulbah.tasks WHERE id = NEW.task_id;
  SELECT session_id INTO s_dep  FROM soulbah.tasks WHERE id = NEW.depends_on_task_id;
  IF s_task IS NULL OR s_dep IS NULL OR s_task <> s_dep THEN
    RAISE EXCEPTION 'soulbah.task_dependencies : % et % ne sont pas dans la même session', NEW.task_id, NEW.depends_on_task_id
      USING ERRCODE = 'check_violation';
  END IF;
  PERFORM 1 FROM soulbah.sessions WHERE id = s_task FOR UPDATE;

  -- Cycle si, en remontant les dépendances existantes depuis depends_on_task_id, on
  -- retrouve task_id (profondeur bornée : un DAG légitime fait au plus quelques dizaines de nœuds).
  WITH RECURSIVE up(id, depth) AS (
    SELECT NEW.depends_on_task_id, 1
    UNION ALL
    SELECT d.depends_on_task_id, up.depth + 1
      FROM soulbah.task_dependencies d
      JOIN up ON d.task_id = up.id
     WHERE up.depth < 1000
  )
  SELECT EXISTS (SELECT 1 FROM up WHERE up.id = NEW.task_id) INTO cyc;
  IF cyc THEN
    RAISE EXCEPTION 'soulbah.task_dependencies : cycle de dépendances refusé (% dépendrait de % qui en dépend déjà)',
      NEW.task_id, NEW.depends_on_task_id USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS check_cycle ON soulbah.task_dependencies;
CREATE TRIGGER check_cycle BEFORE INSERT OR UPDATE ON soulbah.task_dependencies
  FOR EACH ROW EXECUTE FUNCTION soulbah.task_dependencies_check_cycle();


-- >>>>>>>>>> 20261001120500_v2_messages.sql <<<<<<<<<<

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


-- >>>>>>>>>> 20261001120600_v2_actions_tool_calls.sql <<<<<<<<<<

-- =============================================================================
-- V2 — 7/12 : actions (états planned → verified, idempotence) et appels d'outils / de
-- modèles (métrage) — audit §9.4, §9.8, §12. public.agent_events reste la télémétrie V1.
-- Idempotente, additive.
-- =============================================================================

-- Une action = une étape d'une tentative. Clé d'idempotence task_id:attempt:step_index (§9.8).
CREATE TABLE IF NOT EXISTS soulbah.actions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id              uuid NOT NULL REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  user_id              uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  attempt              integer NOT NULL CONSTRAINT actions_attempt_positive CHECK (attempt >= 0),
  step_index           integer NOT NULL CONSTRAINT actions_step_positive CHECK (step_index >= 0),
  -- Outil du catalogue (shared/tools/catalog.json) et paramètres (secrets déjà masqués).
  tool                 text NOT NULL CONSTRAINT actions_tool_format CHECK (tool ~ '^[a-z][a-z0-9_]{0,39}$'),
  params               jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT actions_params_object CHECK (soulbah.is_json_object(params)),
  security_level       text NOT NULL DEFAULT 'L1' CONSTRAINT actions_level_check CHECK (soulbah.is_security_level(security_level)),
  status               text NOT NULL DEFAULT 'planned'
                       CONSTRAINT actions_status_check CHECK (status IN
                         ('planned', 'attempted', 'executed', 'verified', 'failed', 'skipped', 'simulated')),
  -- Preuves typées (§9.8) : [{"kind":"exit_code","confidence":"high","value":0,"artifact_id":…}].
  evidence             jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT actions_evidence_array CHECK (soulbah.is_json_array(evidence)),
  evidence_confidence  text CONSTRAINT actions_confidence_check CHECK (evidence_confidence IS NULL OR evidence_confidence IN ('high', 'medium', 'low', 'none')),
  simulated            boolean NOT NULL DEFAULT false,
  error                text,
  started_at           timestamptz,
  finished_at          timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT actions_idempotency UNIQUE (task_id, attempt, step_index),
  -- Un dry-run ne devient jamais « vérifié » (§9.4 états d'une action).
  CONSTRAINT actions_simulated_never_verified CHECK (NOT (simulated AND status = 'verified')),
  CONSTRAINT actions_simulated_status CHECK (status <> 'simulated' OR simulated)
);
ALTER TABLE soulbah.actions ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.actions;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.actions
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
CREATE INDEX IF NOT EXISTS idx_actions_task ON soulbah.actions (task_id, attempt, step_index);

-- Métrage de chaque appel d'outil (exit_code) ou de modèle (jetons, coût, fournisseur) :
-- alimenté par node-api à partir de l'en-tête x-llm-usage de python-ia (LOT 5) et des
-- rapports d'actions du runtime (LOT 9).
CREATE TABLE IF NOT EXISTS soulbah.tool_calls (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  session_id      uuid REFERENCES soulbah.sessions(id) ON DELETE SET NULL,
  task_id         uuid REFERENCES soulbah.tasks(id) ON DELETE SET NULL,
  action_id       uuid REFERENCES soulbah.actions(id) ON DELETE SET NULL,
  kind            text NOT NULL CONSTRAINT tool_calls_kind_check CHECK (kind IN ('tool', 'model')),
  -- Outil (nom du catalogue) ou rôle/tâche du modèle (planner, evaluator, vision, chat…).
  name            text NOT NULL CONSTRAINT tool_calls_name_length CHECK (length(name) BETWEEN 1 AND 120),
  provider        text,
  model           text,
  status          text NOT NULL DEFAULT 'ok' CONSTRAINT tool_calls_status_check CHECK (status IN ('ok', 'error', 'timeout', 'refused')),
  exit_code       integer,
  http_status     integer CONSTRAINT tool_calls_http_status_range CHECK (http_status IS NULL OR http_status BETWEEN 100 AND 599),
  input_tokens    integer CONSTRAINT tool_calls_in_positive CHECK (input_tokens IS NULL OR input_tokens >= 0),
  output_tokens   integer CONSTRAINT tool_calls_out_positive CHECK (output_tokens IS NULL OR output_tokens >= 0),
  cost_usd        numeric(12, 6) CONSTRAINT tool_calls_cost_positive CHECK (cost_usd IS NULL OR cost_usd >= 0),
  latency_ms      integer CONSTRAINT tool_calls_latency_positive CHECK (latency_ms IS NULL OR latency_ms >= 0),
  error           text,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT tool_calls_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE soulbah.tool_calls ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_tool_calls_session ON soulbah.tool_calls (session_id, created_at) WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tool_calls_task ON soulbah.tool_calls (task_id, created_at) WHERE task_id IS NOT NULL;
-- Budgets : coût par utilisateur et par jour (LOT 5 / LOT 6).
CREATE INDEX IF NOT EXISTS idx_tool_calls_user_day ON soulbah.tool_calls (user_id, created_at) WHERE kind = 'model';


-- >>>>>>>>>> 20261001120700_v2_knowledge.sql <<<<<<<<<<

-- =============================================================================
-- V2 — 8/12 : connaissances — extension de public.knowledge_base (documents), vue
-- soulbah.knowledge_documents, table soulbah.knowledge_chunks (RAG hybride) — audit §12, T14, T38.
-- Idempotente, additive. La dimension de knowledge_base.embedding (vector(1536)) n'est
-- JAMAIS changée en place (« Jamais », §12) : les chunks portent un `embedding vector`
-- sans dimension fixe et un embedding_model par ligne.
-- =============================================================================

-- knowledge_base = knowledge_documents : source, statut d'ingestion et statut documentaire.
-- doc_status est NULLABLE SANS défaut : les lignes héritées ne sont pas modifiées, la vue
-- dérive leur statut (category = 'recherche' → finding, non validé ; sinon user).
ALTER TABLE public.knowledge_base
  ADD COLUMN IF NOT EXISTS source_uri       text,
  ADD COLUMN IF NOT EXISTS mime             text,
  ADD COLUMN IF NOT EXISTS ingest_status    text,
  ADD COLUMN IF NOT EXISTS embedding_model  text,
  ADD COLUMN IF NOT EXISTS last_written_at  timestamptz,
  ADD COLUMN IF NOT EXISTS doc_status       text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'knowledge_base_doc_status_check'
                   AND conrelid = 'public.knowledge_base'::regclass) THEN
    ALTER TABLE public.knowledge_base ADD CONSTRAINT knowledge_base_doc_status_check
      CHECK (doc_status IS NULL OR doc_status IN ('finding', 'user', 'validated', 'rejected', 'deprecated')) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'knowledge_base_ingest_status_check'
                   AND conrelid = 'public.knowledge_base'::regclass) THEN
    ALTER TABLE public.knowledge_base ADD CONSTRAINT knowledge_base_ingest_status_check
      CHECK (ingest_status IS NULL OR ingest_status IN ('pending', 'chunked', 'embedded', 'failed')) NOT VALID;
  END IF;
END $$;
DO $$
DECLARE c text;
BEGIN
  FOREACH c IN ARRAY ARRAY['knowledge_base_doc_status_check', 'knowledge_base_ingest_status_check'] LOOP
    BEGIN
      EXECUTE format('ALTER TABLE public.knowledge_base VALIDATE CONSTRAINT %I', c);
    EXCEPTION WHEN check_violation THEN
      RAISE NOTICE 'Contrainte % non validée : des lignes existantes la violent', c;
    END;
  END LOOP;
END $$;
CREATE INDEX IF NOT EXISTS idx_knowledge_base_doc_status ON public.knowledge_base (user_id, doc_status);

-- Vue : statut effectif des documents. Le RAG « connaissance validée » exclut les findings.
CREATE OR REPLACE VIEW soulbah.knowledge_documents AS
SELECT kb.id,
       kb.user_id,
       kb.title,
       kb.category,
       kb.domain,
       kb.source,
       kb.source_uri,
       kb.mime,
       kb.ingest_status,
       kb.embedding_model,
       kb.content_hash,
       kb.version,
       kb.confidence,
       COALESCE(kb.doc_status, CASE WHEN kb.category = 'recherche' THEN 'finding' ELSE 'user' END) AS doc_status,
       (kb.doc_status IS NULL) AS doc_status_derived,
       kb.last_verified_at,
       kb.last_written_at,
       kb.created_at,
       kb.updated_at
  FROM public.knowledge_base kb;

-- Chunks : unité de récupération (FTS + vecteur, fusion RRF au LOT 13).
CREATE TABLE IF NOT EXISTS soulbah.knowledge_chunks (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id      uuid NOT NULL REFERENCES public.knowledge_base(id) ON DELETE CASCADE,
  user_id          uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  chunk_index      integer NOT NULL CONSTRAINT knowledge_chunks_index_positive CHECK (chunk_index >= 0),
  content          text NOT NULL CONSTRAINT knowledge_chunks_content_length CHECK (length(content) BETWEEN 1 AND 20000),
  token_count      integer CONSTRAINT knowledge_chunks_tokens_positive CHECK (token_count IS NULL OR token_count >= 0),
  -- tsvector généré (FTS) ; configuration « simple » : multilingue, sans racinisation.
  tsv              tsvector GENERATED ALWAYS AS (to_tsvector('simple', content)) STORED,
  -- Vecteur SANS dimension fixe (T38) : le modèle est porté par la ligne.
  embedding        vector,
  embedding_model  text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT knowledge_chunks_unique UNIQUE (document_id, chunk_index),
  CONSTRAINT knowledge_chunks_model_with_embedding CHECK (embedding IS NULL OR embedding_model IS NOT NULL)
);
ALTER TABLE soulbah.knowledge_chunks ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_document ON soulbah.knowledge_chunks (document_id, chunk_index);
CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_user ON soulbah.knowledge_chunks (user_id);
CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_tsv ON soulbah.knowledge_chunks USING gin (tsv);
-- Index HNSW PARTIEL par modèle (une dimension fixée par le cast) — un index par modèle d'embedding.
CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_hnsw_te3s ON soulbah.knowledge_chunks
  USING hnsw ((embedding::vector(1536)) vector_cosine_ops)
  WHERE embedding_model = 'text-embedding-3-small';


-- >>>>>>>>>> 20261001120800_v2_memory.sql <<<<<<<<<<

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


-- >>>>>>>>>> 20261001120900_v2_skills_evaluations_checkpoints.sql <<<<<<<<<<

-- =============================================================================
-- V2 — 10/12 : skills versionnées, évaluations, checkpoints — audit §9.8, §9.9, §12.
-- Idempotente, additive.
-- =============================================================================

-- Skills : alimentée par le catalogue (shared/tools/catalog.json, LOT 2) et par les
-- procédures apprises (LOT 10). UNIQUE(name, version).
CREATE TABLE IF NOT EXISTS soulbah.skills (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text NOT NULL CONSTRAINT skills_name_format CHECK (name ~ '^[a-z][a-z0-9_]{0,39}$'),
  version         text NOT NULL CONSTRAINT skills_version_semver CHECK (version ~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'),
  -- catalog : outil du catalogue ; learned : procédure proposée (LOT 10/12, jamais promue sans approbation L3).
  source          text NOT NULL DEFAULT 'catalog' CONSTRAINT skills_source_check CHECK (source IN ('catalog', 'learned')),
  status          text NOT NULL DEFAULT 'active' CONSTRAINT skills_status_check CHECK (status IN ('proposed', 'active', 'deprecated', 'rejected')),
  security_level  text NOT NULL DEFAULT 'L1' CONSTRAINT skills_level_check CHECK (soulbah.is_security_level(security_level)),
  schema          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT skills_schema_object CHECK (soulbah.is_json_object(schema)),
  procedure       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT skills_procedure_object CHECK (soulbah.is_json_object(procedure)),
  permissions     jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT skills_permissions_object CHECK (soulbah.is_json_object(permissions)),
  examples        jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skills_examples_array CHECK (soulbah.is_json_array(examples)),
  known_errors    jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skills_known_errors_array CHECK (soulbah.is_json_array(known_errors)),
  tests           jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skills_tests_array CHECK (soulbah.is_json_array(tests)),
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skills_name_version UNIQUE (name, version)
);
ALTER TABLE soulbah.skills ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS set_updated_at ON soulbah.skills;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON soulbah.skills
  FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
CREATE INDEX IF NOT EXISTS idx_skills_status ON soulbah.skills (status, name);

-- Évaluations : résultat de la phase VALIDATING d'une tentative (critères DSL, preuves, verdict).
CREATE TABLE IF NOT EXISTS soulbah.evaluations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id         uuid NOT NULL REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  attempt         integer NOT NULL CONSTRAINT evaluations_attempt_positive CHECK (attempt >= 0),
  criteria        jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT evaluations_criteria_array CHECK (soulbah.is_json_array(criteria)),
  results         jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT evaluations_results_array CHECK (soulbah.is_json_array(results)),
  verdict         text NOT NULL CONSTRAINT evaluations_verdict_check CHECK (verdict IN ('success', 'partial', 'failure', 'abort', 'not_evaluable')),
  confidence      text NOT NULL DEFAULT 'none' CONSTRAINT evaluations_confidence_check CHECK (confidence IN ('high', 'medium', 'low', 'none')),
  evidence_ids    jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT evaluations_evidence_array CHECK (soulbah.is_json_array(evidence_ids)),
  -- Ce que le plan de contrôle a fait du verdict (contrat LOT 1 : action_taken).
  action_taken    text,
  evaluator       text NOT NULL DEFAULT 'rules' CONSTRAINT evaluations_evaluator_check CHECK (evaluator IN ('rules', 'llm', 'qa_reviewer', 'user')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  -- Une seule évaluation par tentative (VALIDATING durable, LOT 10).
  CONSTRAINT evaluations_once_per_attempt UNIQUE (task_id, attempt)
);
ALTER TABLE soulbah.evaluations ENABLE ROW LEVEL SECURITY;

-- Checkpoints : reprise depuis la dernière étape (§9.9) — curseur et variables d'une tentative.
CREATE TABLE IF NOT EXISTS soulbah.checkpoints (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id         uuid NOT NULL REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  attempt         integer NOT NULL CONSTRAINT checkpoints_attempt_positive CHECK (attempt >= 0),
  seq             integer NOT NULL CONSTRAINT checkpoints_seq_positive CHECK (seq >= 0),
  step_cursor     integer NOT NULL DEFAULT 0 CONSTRAINT checkpoints_cursor_positive CHECK (step_cursor >= 0),
  variables       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT checkpoints_variables_object CHECK (soulbah.is_json_object(variables)),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT checkpoints_unique UNIQUE (task_id, attempt, seq)
);
ALTER TABLE soulbah.checkpoints ENABLE ROW LEVEL SECURITY;


-- >>>>>>>>>> 20261001121000_v2_artifacts_recordings_permissions_leases.sql <<<<<<<<<<

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
  -- approved / denied portent une décision datée ; pending, expired et revoked (grant révoqué après
  -- approbation, demande expirée) peuvent avoir ou non decided_at.
  CONSTRAINT permissions_decision_consistent CHECK (status NOT IN ('approved', 'denied') OR decided_at IS NOT NULL)
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


-- >>>>>>>>>> 20261001121100_v2_audit.sql <<<<<<<<<<

-- =============================================================================
-- V2 — 12/12 : journal d'audit en AJOUT SEUL et CHAÎNÉ (prev_hash / row_hash) — audit §9.3, §12.
-- Idempotente, additive.
--
--  * Chaque ligne porte le hash de la précédente (tête de chaîne soulbah.audit_chain_head,
--    verrouillée FOR UPDATE : la chaîne est linéaire même sous concurrence) et son propre
--    hash SHA-256 (fonction native sha256(), aucune extension requise).
--  * UPDATE, DELETE et TRUNCATE sont refusés par trigger ; aucune purge.
--  * soulbah.verify_audit_chain() recalcule toute la chaîne : (ok, checked, broken_at).
--
-- Les autres points prévus par l'audit pour ce dernier fichier étaient déjà livrés au LOT 1 :
-- trigger agent_tasks_set_updated_at insensible à `control` (20261001090000 §2, 20261001100000 §1),
-- is_admin() sans argument et REVOKE has_role FROM anon (20261001090000 §3), policies
-- agent_keys / agent_memory en SELECT (+DELETE) côté client (20261001100000 §2, §5).
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.audit_logs (
  -- Attribué par le trigger BEFORE INSERT sous le verrou de la tête de chaîne : l'ordre des
  -- numéros est EXACTEMENT l'ordre de chaînage (une identité serait tirée avant le verrou).
  seq          bigint PRIMARY KEY,
  id           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  user_id      uuid,
  session_id   uuid,
  task_id      uuid,
  -- Qui : user:<uuid>, system:scheduler, runtime:<id>, agent:<role>…
  actor        text NOT NULL CONSTRAINT audit_logs_actor_length CHECK (length(actor) BETWEEN 1 AND 200),
  -- Quoi : task.transition, permission.approved, memory.validated, skill.promoted…
  action       text NOT NULL CONSTRAINT audit_logs_action_format CHECK (action ~ '^[a-z][a-z0-9_.]{0,99}$'),
  entity       text,
  entity_id    uuid,
  data         jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT audit_logs_data_object CHECK (soulbah.is_json_object(data)),
  prev_hash    text NOT NULL CONSTRAINT audit_logs_prev_hash_format CHECK (prev_hash ~ '^[0-9a-f]{64}$'),
  row_hash     text NOT NULL CONSTRAINT audit_logs_row_hash_format CHECK (row_hash ~ '^[0-9a-f]{64}$'),
  created_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE soulbah.audit_logs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_audit_logs_session ON soulbah.audit_logs (session_id, seq) WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_logs_task ON soulbah.audit_logs (task_id, seq) WHERE task_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_logs_user ON soulbah.audit_logs (user_id, seq) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON soulbah.audit_logs (action, seq);

CREATE TABLE IF NOT EXISTS soulbah.audit_chain_head (
  id          smallint PRIMARY KEY CONSTRAINT audit_chain_head_single CHECK (id = 1),
  last_seq    bigint NOT NULL DEFAULT 0,
  last_hash   text NOT NULL DEFAULT repeat('0', 64),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE soulbah.audit_chain_head ENABLE ROW LEVEL SECURITY;
INSERT INTO soulbah.audit_chain_head (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- Hash d'une ligne : prev_hash + champs canoniques (jsonb::text est canonique : clés triées).
CREATE OR REPLACE FUNCTION soulbah.audit_row_hash(
  p_prev text, p_id uuid, p_user uuid, p_session uuid, p_task uuid, p_actor text, p_action text,
  p_entity text, p_entity_id uuid, p_data jsonb, p_created timestamptz)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT encode(sha256(convert_to(
    p_prev || '|' || p_id::text || '|' || coalesce(p_user::text, '') || '|' || coalesce(p_session::text, '')
    || '|' || coalesce(p_task::text, '') || '|' || p_actor || '|' || p_action || '|' || coalesce(p_entity, '')
    || '|' || coalesce(p_entity_id::text, '') || '|' || p_data::text
    || '|' || to_char(p_created AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'UTF8')), 'hex')
$$;

CREATE OR REPLACE FUNCTION soulbah.audit_logs_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
DECLARE
  head soulbah.audit_chain_head%ROWTYPE;
BEGIN
  SELECT * INTO head FROM soulbah.audit_chain_head WHERE id = 1 FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO soulbah.audit_chain_head (id) VALUES (1) RETURNING * INTO head;
  END IF;
  NEW.created_at := coalesce(NEW.created_at, now());
  NEW.seq        := head.last_seq + 1;
  NEW.prev_hash  := head.last_hash;
  NEW.row_hash   := soulbah.audit_row_hash(NEW.prev_hash, NEW.id, NEW.user_id, NEW.session_id, NEW.task_id,
                                           NEW.actor, NEW.action, NEW.entity, NEW.entity_id, NEW.data, NEW.created_at);
  -- La tête avance ICI (trigger BEFORE, ligne par ligne) : un trigger AFTER ne s'exécute qu'en
  -- fin d'instruction et laisserait toutes les lignes d'un INSERT multi-lignes sur le même prev_hash.
  UPDATE soulbah.audit_chain_head
     SET last_seq = NEW.seq, last_hash = NEW.row_hash, updated_at = now()
   WHERE id = 1;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION soulbah.audit_logs_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'soulbah.audit_logs est en ajout seul : % refusé', TG_OP
    USING ERRCODE = 'insufficient_privilege';
END $$;

DROP TRIGGER IF EXISTS chain_before_insert ON soulbah.audit_logs;
CREATE TRIGGER chain_before_insert BEFORE INSERT ON soulbah.audit_logs
  FOR EACH ROW EXECUTE FUNCTION soulbah.audit_logs_before_insert();
DROP TRIGGER IF EXISTS immutable_rows ON soulbah.audit_logs;
CREATE TRIGGER immutable_rows BEFORE UPDATE OR DELETE ON soulbah.audit_logs
  FOR EACH ROW EXECUTE FUNCTION soulbah.audit_logs_immutable();
DROP TRIGGER IF EXISTS immutable_table ON soulbah.audit_logs;
CREATE TRIGGER immutable_table BEFORE TRUNCATE ON soulbah.audit_logs
  FOR EACH STATEMENT EXECUTE FUNCTION soulbah.audit_logs_immutable();

-- Vérification intégrale : première ligne dont prev_hash ou row_hash ne correspond pas.
CREATE OR REPLACE FUNCTION soulbah.verify_audit_chain(OUT ok boolean, OUT checked bigint, OUT broken_at bigint)
LANGUAGE plpgsql
STABLE
SET search_path = soulbah, pg_temp
AS $$
DECLARE
  r     record;
  prev  text := repeat('0', 64);
  n     bigint := 0;
  head  soulbah.audit_chain_head%ROWTYPE;
BEGIN
  FOR r IN SELECT * FROM soulbah.audit_logs ORDER BY seq LOOP
    IF r.prev_hash <> prev
       OR r.row_hash <> soulbah.audit_row_hash(r.prev_hash, r.id, r.user_id, r.session_id, r.task_id,
                                               r.actor, r.action, r.entity, r.entity_id, r.data, r.created_at) THEN
      ok := false; checked := n; broken_at := r.seq;
      RETURN;
    END IF;
    prev := r.row_hash;
    n := n + 1;
  END LOOP;
  SELECT * INTO head FROM soulbah.audit_chain_head WHERE id = 1;
  IF FOUND AND head.last_hash <> prev THEN
    ok := false; checked := n; broken_at := head.last_seq;
    RETURN;
  END IF;
  ok := true; checked := n; broken_at := NULL;
END $$;


-- >>>>>>>>>> 20261002100000_db00_migration_history.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 0b — Historique des migrations Soulbah (§8 MIGRATION HISTORY, §78 MIGRATION LOCK).
-- soulbah:rollback=PARTIAL
-- soulbah:recovery=20261002100000_db00_migration_history.down.sql supprime les deux tables : aucune donnée métier, mais l'historique enregistré est perdu (l'exporter avant).
-- soulbah:transaction=single
--
-- Idempotente et additive. Prépare la tenue d'un historique AVANT d'appliquer quoi que ce soit d'autre :
--   * soulbah.schema_migrations     : une ligne par migration (dernier état connu), empreinte SHA-256 du
--                                     fichier (fins de ligne normalisées en LF), durée, statut, auteur, commit,
--                                     possibilité de retour arrière (YES / PARTIAL / NO) et plan de reprise ;
--   * soulbah.schema_migration_runs : chaque tentative (application, mise en baseline, retour arrière,
--                                     vérification), réussie ou non, en AJOUT SEUL (UPDATE, DELETE et TRUNCATE
--                                     refusés par trigger) : un échec reste visible même si sa transaction a été
--                                     annulée (le gestionnaire l'écrit dans une transaction séparée).
-- Le verrou contre deux migrations concurrentes est un verrou consultatif de transaction pris par le
-- gestionnaire (scripts/db/migrate.py) : pg_advisory_xact_lock(hashtext('soulbah.schema_migrations')).
--
-- Le schéma soulbah est créé ici s'il n'existe pas encore (base restaurée sans V2) avec les mêmes
-- protections que la migration V2 1/12 (20261001120000_v2_schema.sql), qui reste compatible (IF NOT EXISTS).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS soulbah;
REVOKE ALL ON SCHEMA soulbah FROM PUBLIC;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON SCHEMA soulbah FROM %I', r);
    END IF;
  END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS soulbah.schema_migrations (
  version         text PRIMARY KEY CONSTRAINT schema_migrations_version_format CHECK (version ~ '^[0-9]{14}$'),
  name            text NOT NULL CONSTRAINT schema_migrations_name_length CHECK (length(name) BETWEEN 1 AND 200),
  checksum        text NOT NULL CONSTRAINT schema_migrations_checksum_format CHECK (checksum ~ '^[0-9a-f]{64}$'),
  source          text NOT NULL CONSTRAINT schema_migrations_source_check CHECK (source IN ('repo', 'pending', 'manual')),
  status          text NOT NULL CONSTRAINT schema_migrations_status_check
                    CHECK (status IN ('applied', 'baselined', 'rolled_back')),
  rollback        text NOT NULL DEFAULT 'NO' CONSTRAINT schema_migrations_rollback_check
                    CHECK (rollback IN ('YES', 'PARTIAL', 'NO')),
  recovery        text,
  executed_at     timestamptz NOT NULL DEFAULT now(),
  execution_ms    integer CONSTRAINT schema_migrations_execution_ms_check CHECK (execution_ms >= 0),
  applied_by      text NOT NULL DEFAULT current_user,
  app_commit      text,
  notes           text
);
COMMENT ON TABLE soulbah.schema_migrations IS
  'Soulbah DB LOT 0b : état de chaque migration (empreinte, durée, statut, retour arrière). Écrit par scripts/db/migrate.py.';
ALTER TABLE soulbah.schema_migrations ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.schema_migration_runs (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  version         text NOT NULL CONSTRAINT schema_migration_runs_version_format CHECK (version ~ '^[0-9]{14}$'),
  action          text NOT NULL CONSTRAINT schema_migration_runs_action_check
                    CHECK (action IN ('apply', 'baseline', 'rollback', 'verify')),
  status          text NOT NULL CONSTRAINT schema_migration_runs_status_check
                    CHECK (status IN ('succeeded', 'failed', 'skipped')),
  checksum        text CONSTRAINT schema_migration_runs_checksum_format CHECK (checksum IS NULL OR checksum ~ '^[0-9a-f]{64}$'),
  started_at      timestamptz NOT NULL DEFAULT now(),
  execution_ms    integer CONSTRAINT schema_migration_runs_execution_ms_check CHECK (execution_ms IS NULL OR execution_ms >= 0),
  error           text,
  run_by          text NOT NULL DEFAULT current_user,
  app_commit      text,
  details         jsonb NOT NULL DEFAULT '{}'::jsonb
                    CONSTRAINT schema_migration_runs_details_object CHECK (jsonb_typeof(details) = 'object')
);
COMMENT ON TABLE soulbah.schema_migration_runs IS
  'Soulbah DB LOT 0b : chaque tentative de migration, en ajout seul (UPDATE, DELETE, TRUNCATE refusés).';
ALTER TABLE soulbah.schema_migration_runs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_schema_migration_runs_version ON soulbah.schema_migration_runs (version, id);

CREATE OR REPLACE FUNCTION soulbah.schema_migration_runs_append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'soulbah.schema_migration_runs est en ajout seul (% refusé)', TG_OP;
END $$;

DROP TRIGGER IF EXISTS schema_migration_runs_no_update ON soulbah.schema_migration_runs;
CREATE TRIGGER schema_migration_runs_no_update
  BEFORE UPDATE OR DELETE ON soulbah.schema_migration_runs
  FOR EACH ROW EXECUTE FUNCTION soulbah.schema_migration_runs_append_only();
DROP TRIGGER IF EXISTS schema_migration_runs_no_truncate ON soulbah.schema_migration_runs;
CREATE TRIGGER schema_migration_runs_no_truncate
  BEFORE TRUNCATE ON soulbah.schema_migration_runs
  FOR EACH STATEMENT EXECUTE FUNCTION soulbah.schema_migration_runs_append_only();

-- Aucun accès client : ni PostgREST ni anon/authenticated.
REVOKE ALL ON soulbah.schema_migrations, soulbah.schema_migration_runs FROM PUBLIC;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.schema_migrations, soulbah.schema_migration_runs FROM %I', r);
    END IF;
  END LOOP;
END $$;


-- >>>>>>>>>> 20261002110100_db01_core.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 1 — Core : aides communes, environnements, réglages, état système, versions, santé, feature flags.
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110100_db01_core.down.sql (supprime les tables de ce lot ; les lots suivants en dépendent : les retirer d'abord)
-- soulbah:transaction=single
--
-- Idempotente et additive (docs/db/DB_MIGRATION_CONVENTIONS.md). Aucune table de ce lot n'est accessible
-- aux rôles clients : RLS activée sans policy, droits révoqués. Écrivain unique : node-api (soulbah_api).
-- =============================================================================

-- ---------------------------------------------------------------------------------------------
-- 1. Aides communes réutilisées par tous les lots
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION soulbah.append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'soulbah.% est en ajout seul (% refusé)', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'insufficient_privilege';
END $$;
COMMENT ON FUNCTION soulbah.append_only() IS 'Trigger : refuse UPDATE, DELETE et TRUNCATE (journaux, décisions, événements).';

-- §9 : vérifier la FORME d'une table existante au lieu de masquer une incompatibilité par IF NOT EXISTS.
-- p_columns : {"colonne": "type attendu (format_type)", …}. Lève une exception claire si une colonne manque
-- ou si son type diffère (comparaison insensible à la casse, « real[] » accepté pour « vector… » : pgvector
-- simulé sur les bases locales de test).
CREATE OR REPLACE FUNCTION soulbah.assert_table_shape(p_table regclass, p_columns jsonb)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  k text;
  expected text;
  actual text;
BEGIN
  IF p_columns IS NULL OR jsonb_typeof(p_columns) <> 'object' THEN
    RAISE EXCEPTION 'assert_table_shape(%) : objet JSON attendu', p_table;
  END IF;
  FOR k, expected IN SELECT key, value #>> '{}' FROM jsonb_each(p_columns) LOOP
    SELECT format_type(a.atttypid, a.atttypmod) INTO actual
      FROM pg_attribute a WHERE a.attrelid = p_table AND a.attname = k AND a.attnum > 0 AND NOT a.attisdropped;
    IF actual IS NULL THEN
      RAISE EXCEPTION 'table % : colonne « % » attendue (%), absente — structure incompatible, migration arrêtée',
        p_table, k, expected;
    END IF;
    IF lower(actual) <> lower(expected)
       AND NOT (lower(expected) LIKE 'vector%' AND lower(actual) = 'real[]') THEN
      RAISE EXCEPTION 'table % : colonne « % » de type %, attendu % — structure incompatible, migration arrêtée',
        p_table, k, actual, expected;
    END IF;
  END LOOP;
END $$;
COMMENT ON FUNCTION soulbah.assert_table_shape(regclass, jsonb) IS 'Vérifie colonnes et types d''une table existante (§9 : pas d''IF NOT EXISTS aveugle).';

CREATE OR REPLACE FUNCTION soulbah.is_environment(p text)
RETURNS boolean LANGUAGE sql IMMUTABLE
AS $$ SELECT p IN ('LOCAL', 'DEV', 'TEST', 'STAGING', 'PRODUCTION') $$;

CREATE OR REPLACE FUNCTION soulbah.is_autonomy_level(p text)
RETURNS boolean LANGUAGE sql IMMUTABLE
AS $$ SELECT p IN ('OBSERVE', 'ASSIST', 'LAB', 'SAFE_AUTO', 'ADVANCED_AUTO', 'PRODUCTION_GUARDED') $$;

CREATE OR REPLACE FUNCTION soulbah.is_severity(p text)
RETURNS boolean LANGUAGE sql IMMUTABLE
AS $$ SELECT p IN ('INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL') $$;

-- Trusted Core (§55, §113) : une transaction qui modifie une ligne « immutable » doit avoir posé
-- SET LOCAL soulbah.trusted_core = 'unlocked' — chemin réservé à l'autorité humaine habilitée dans node-api.
CREATE OR REPLACE FUNCTION soulbah.trusted_core_unlocked()
RETURNS boolean LANGUAGE sql STABLE
AS $$ SELECT coalesce(current_setting('soulbah.trusted_core', true), '') = 'unlocked' $$;

CREATE OR REPLACE FUNCTION soulbah.protect_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  IF (TG_OP = 'DELETE' AND OLD.immutable) OR (TG_OP = 'UPDATE' AND (OLD.immutable OR NEW.immutable)) THEN
    IF NOT soulbah.trusted_core_unlocked() THEN
      RAISE EXCEPTION 'soulbah.% : ligne protégée (Trusted Core) — modification refusée hors du chemin habilité',
        TG_TABLE_NAME USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION soulbah.protect_immutable() IS 'Trigger : les lignes immutable=true ne changent que sous soulbah.trusted_core = unlocked.';

-- Raison de changement portée par la transaction (SET LOCAL soulbah.change_reason = '…') pour les historiques.
CREATE OR REPLACE FUNCTION soulbah.change_reason()
RETURNS text LANGUAGE sql STABLE
AS $$ SELECT nullif(current_setting('soulbah.change_reason', true), '') $$;

CREATE OR REPLACE FUNCTION soulbah.change_actor()
RETURNS text LANGUAGE sql STABLE
AS $$ SELECT coalesce(nullif(current_setting('soulbah.actor', true), ''), current_user) $$;

-- ---------------------------------------------------------------------------------------------
-- 2. Environnements (§54 : une permission en DEV ne vaut jamais en PRODUCTION)
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.environments (
  name           text PRIMARY KEY CONSTRAINT environments_name_check CHECK (soulbah.is_environment(name)),
  rank           smallint NOT NULL CONSTRAINT environments_rank_check CHECK (rank BETWEEN 0 AND 9),
  is_production  boolean NOT NULL DEFAULT false,
  description    text NOT NULL DEFAULT '' CONSTRAINT environments_description_length CHECK (length(description) <= 500),
  created_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.environments IS 'Environnements cibles des actions et déploiements : LOCAL < DEV < TEST < STAGING < PRODUCTION.';
ALTER TABLE soulbah.environments ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.environments', '{"name": "text", "rank": "smallint", "is_production": "boolean"}');
INSERT INTO soulbah.environments (name, rank, is_production, description) VALUES
  ('LOCAL', 0, false, 'Poste du développeur : copies, essais, aucune donnée réelle'),
  ('DEV', 1, false, 'Développement partagé'),
  ('TEST', 2, false, 'Tests automatisés et bancs d''essai'),
  ('STAGING', 3, false, 'Préproduction : données proches de la production'),
  ('PRODUCTION', 4, true, 'Production : toute modification soumise aux politiques et garde-fous PDG')
ON CONFLICT (name) DO NOTHING;

-- ---------------------------------------------------------------------------------------------
-- 3. Réglages système, versionnés et historisés
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.system_settings (
  key          text PRIMARY KEY CONSTRAINT system_settings_key_format CHECK (key ~ '^[a-z][a-z0-9_.]{0,119}$'),
  value        jsonb NOT NULL,
  description  text NOT NULL DEFAULT '' CONSTRAINT system_settings_description_length CHECK (length(description) <= 1000),
  critical     boolean NOT NULL DEFAULT false,
  immutable    boolean NOT NULL DEFAULT false,
  version      integer NOT NULL DEFAULT 1 CONSTRAINT system_settings_version_positive CHECK (version >= 1),
  updated_by   text NOT NULL DEFAULT current_user,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.system_settings IS 'Réglages de Soulbah (clé → valeur JSON), versionnés ; critical = confirmation renforcée ; immutable = Trusted Core.';
ALTER TABLE soulbah.system_settings ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.system_settings', '{"key": "text", "value": "jsonb", "immutable": "boolean", "version": "integer"}');

CREATE TABLE IF NOT EXISTS soulbah.system_settings_history (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  key         text NOT NULL,
  old_value   jsonb,
  new_value   jsonb,
  version     integer NOT NULL,
  changed_by  text NOT NULL,
  reason      text,
  changed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.system_settings_history IS 'Historique des réglages (ajout seul) : ancien, nouveau, auteur, justification.';
ALTER TABLE soulbah.system_settings_history ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_system_settings_history_key ON soulbah.system_settings_history (key, id);
DROP TRIGGER IF EXISTS system_settings_history_append_only ON soulbah.system_settings_history;
CREATE TRIGGER system_settings_history_append_only
  BEFORE UPDATE OR DELETE ON soulbah.system_settings_history FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS system_settings_history_no_truncate ON soulbah.system_settings_history;
CREATE TRIGGER system_settings_history_no_truncate
  BEFORE TRUNCATE ON soulbah.system_settings_history FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE OR REPLACE FUNCTION soulbah.system_settings_track()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.value IS DISTINCT FROM OLD.value OR NEW.immutable IS DISTINCT FROM OLD.immutable
       OR NEW.critical IS DISTINCT FROM OLD.critical THEN
      NEW.version := OLD.version + 1;
      NEW.updated_at := now();
      NEW.updated_by := soulbah.change_actor();
      INSERT INTO soulbah.system_settings_history (key, old_value, new_value, version, changed_by, reason)
      VALUES (OLD.key, OLD.value, NEW.value, NEW.version, NEW.updated_by, soulbah.change_reason());
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'INSERT' THEN
    INSERT INTO soulbah.system_settings_history (key, old_value, new_value, version, changed_by, reason)
    VALUES (NEW.key, NULL, NEW.value, NEW.version, soulbah.change_actor(), soulbah.change_reason());
    RETURN NEW;
  END IF;
  INSERT INTO soulbah.system_settings_history (key, old_value, new_value, version, changed_by, reason)
  VALUES (OLD.key, OLD.value, NULL, OLD.version + 1, soulbah.change_actor(), soulbah.change_reason());
  RETURN OLD;
END $$;
DROP TRIGGER IF EXISTS system_settings_protect ON soulbah.system_settings;
CREATE TRIGGER system_settings_protect
  BEFORE UPDATE OR DELETE ON soulbah.system_settings FOR EACH ROW EXECUTE FUNCTION soulbah.protect_immutable();
DROP TRIGGER IF EXISTS system_settings_track ON soulbah.system_settings;
CREATE TRIGGER system_settings_track
  BEFORE INSERT OR UPDATE OR DELETE ON soulbah.system_settings FOR EACH ROW EXECUTE FUNCTION soulbah.system_settings_track();

-- ---------------------------------------------------------------------------------------------
-- 4. État système : STOP SOULBAH, SAFE MODE, interrupteurs maîtres (§48-54, §96-97) — une seule ligne
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.system_state (
  id                    smallint PRIMARY KEY CONSTRAINT system_state_single CHECK (id = 1),
  emergency_stop        boolean NOT NULL DEFAULT false,
  emergency_stop_reason text,
  emergency_stop_at     timestamptz,
  safe_mode             boolean NOT NULL DEFAULT false,
  safe_mode_reason      text,
  internet_allowed      boolean NOT NULL DEFAULT false,
  external_ai_allowed   boolean NOT NULL DEFAULT false,
  computer_control      boolean NOT NULL DEFAULT true,
  memory_write          boolean NOT NULL DEFAULT true,
  production_changes    text NOT NULL DEFAULT 'OFF'
                        CONSTRAINT system_state_production_check CHECK (production_changes IN ('OFF', 'APPROVAL_REQUIRED', 'LIMITED_AUTO')),
  self_improvement      text NOT NULL DEFAULT 'OFF'
                        CONSTRAINT system_state_self_improvement_check CHECK (self_improvement IN ('OFF', 'PROPOSE_ONLY', 'LAB_AUTO', 'SAFE_AUTO')),
  security_autopilot    text NOT NULL DEFAULT 'OFF'
                        CONSTRAINT system_state_autopilot_check CHECK (security_autopilot IN ('OFF', 'MONITOR', 'FIX_IN_LAB', 'FIX_AND_TEST', 'SAFE_AUTO')),
  migrations            text NOT NULL DEFAULT 'PREPARE_ONLY'
                        CONSTRAINT system_state_migrations_check CHECK (migrations IN ('OFF', 'PREPARE_ONLY', 'AUTO_DEV', 'AUTO_TEST', 'AUTO_STAGING')),
  version               integer NOT NULL DEFAULT 1,
  updated_by            text NOT NULL DEFAULT current_user,
  updated_at            timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.system_state IS 'Interrupteurs maîtres du PDG (une ligne) : arrêt d''urgence, SAFE MODE, Internet, IA externes, production, auto-amélioration, Security Autopilot, migrations.';
ALTER TABLE soulbah.system_state ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.system_state', '{"emergency_stop": "boolean", "safe_mode": "boolean", "migrations": "text", "version": "integer"}');
INSERT INTO soulbah.system_state (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS soulbah.system_state_history (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  version     integer NOT NULL,
  old_state   jsonb,
  new_state   jsonb NOT NULL,
  changed_by  text NOT NULL,
  reason      text,
  changed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.system_state_history IS 'Chaque changement des interrupteurs maîtres (ajout seul).';
ALTER TABLE soulbah.system_state_history ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS system_state_history_append_only ON soulbah.system_state_history;
CREATE TRIGGER system_state_history_append_only
  BEFORE UPDATE OR DELETE ON soulbah.system_state_history FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS system_state_history_no_truncate ON soulbah.system_state_history;
CREATE TRIGGER system_state_history_no_truncate
  BEFORE TRUNCATE ON soulbah.system_state_history FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE OR REPLACE FUNCTION soulbah.system_state_track()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'soulbah.system_state : la ligne unique ne se supprime pas' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    NEW.version := OLD.version + 1;
    NEW.updated_at := now();
    NEW.updated_by := soulbah.change_actor();
    IF NEW.emergency_stop AND NOT OLD.emergency_stop THEN NEW.emergency_stop_at := now(); END IF;
    INSERT INTO soulbah.system_state_history (version, old_state, new_state, changed_by, reason)
    VALUES (NEW.version, to_jsonb(OLD), to_jsonb(NEW), NEW.updated_by, soulbah.change_reason());
    RETURN NEW;
  END IF;
  INSERT INTO soulbah.system_state_history (version, old_state, new_state, changed_by, reason)
  VALUES (NEW.version, NULL, to_jsonb(NEW), soulbah.change_actor(), soulbah.change_reason());
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS system_state_track ON soulbah.system_state;
CREATE TRIGGER system_state_track
  BEFORE INSERT OR UPDATE OR DELETE ON soulbah.system_state FOR EACH ROW EXECUTE FUNCTION soulbah.system_state_track();

-- Lecture rapide par les services (scheduler, gestionnaire de migrations, passerelle d'outils).
CREATE OR REPLACE FUNCTION soulbah.writes_allowed()
RETURNS boolean LANGUAGE sql STABLE
AS $$ SELECT NOT (emergency_stop OR safe_mode) FROM soulbah.system_state WHERE id = 1 $$;
COMMENT ON FUNCTION soulbah.writes_allowed() IS 'false si STOP SOULBAH ou SAFE MODE : les agents ne modifient rien (§96-97).';

-- ---------------------------------------------------------------------------------------------
-- 5. Versions des composants (§28 rollback : version précédente, configuration, benchmark, diff, date, raison)
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.system_versions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  component        text NOT NULL CONSTRAINT system_versions_component_format CHECK (component ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  version          text NOT NULL CONSTRAINT system_versions_version_length CHECK (length(version) BETWEEN 1 AND 100),
  app_commit       text,
  previous_version text,
  status           text NOT NULL DEFAULT 'active' CONSTRAINT system_versions_status_check CHECK (status IN ('candidate', 'active', 'rolled_back', 'retired')),
  config           jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT system_versions_config_object CHECK (soulbah.is_json_object(config)),
  rollback_info    jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT system_versions_rollback_object CHECK (soulbah.is_json_object(rollback_info)),
  reason           text,
  activated_by     text,
  activated_at     timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT system_versions_unique UNIQUE (component, version)
);
COMMENT ON TABLE soulbah.system_versions IS 'Versions actives et passées de chaque composant (agents, prompts, routeur, outils) avec informations de retour arrière.';
ALTER TABLE soulbah.system_versions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_system_versions_component ON soulbah.system_versions (component, status);

-- ---------------------------------------------------------------------------------------------
-- 6. Santé courante par composant (l'historique est au DB LOT 14)
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.system_health (
  component   text PRIMARY KEY CONSTRAINT system_health_component_format CHECK (component ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  status      text NOT NULL DEFAULT 'unknown' CONSTRAINT system_health_status_check CHECK (status IN ('healthy', 'degraded', 'down', 'unknown')),
  detail      jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT system_health_detail_object CHECK (soulbah.is_json_object(detail)),
  checked_at  timestamptz,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.system_health IS 'Dernier état connu de chaque composant : core, db, orchestrator, model_router, memory, knowledge, security, workers, internet.';
ALTER TABLE soulbah.system_health ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS system_health_set_updated_at ON soulbah.system_health;
CREATE TRIGGER system_health_set_updated_at BEFORE UPDATE ON soulbah.system_health FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- ---------------------------------------------------------------------------------------------
-- 7. Feature flags, historisés
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.feature_flags (
  key          text PRIMARY KEY CONSTRAINT feature_flags_key_format CHECK (key ~ '^[a-z][a-z0-9_.]{0,119}$'),
  enabled      boolean NOT NULL DEFAULT false,
  description  text NOT NULL DEFAULT '' CONSTRAINT feature_flags_description_length CHECK (length(description) <= 1000),
  scope        text NOT NULL DEFAULT 'global' CONSTRAINT feature_flags_scope_check CHECK (scope IN ('global', 'user', 'project', 'agent')),
  rollout      jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT feature_flags_rollout_object CHECK (soulbah.is_json_object(rollout)),
  immutable    boolean NOT NULL DEFAULT false,
  version      integer NOT NULL DEFAULT 1,
  updated_by   text NOT NULL DEFAULT current_user,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.feature_flags IS 'Fonctions activables (globales ou par utilisateur, projet, agent), versionnées.';
ALTER TABLE soulbah.feature_flags ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.feature_flags_history (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  key         text NOT NULL,
  old_state   jsonb,
  new_state   jsonb,
  version     integer NOT NULL,
  changed_by  text NOT NULL,
  reason      text,
  changed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.feature_flags_history IS 'Historique des feature flags (ajout seul).';
ALTER TABLE soulbah.feature_flags_history ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS feature_flags_history_append_only ON soulbah.feature_flags_history;
CREATE TRIGGER feature_flags_history_append_only
  BEFORE UPDATE OR DELETE ON soulbah.feature_flags_history FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS feature_flags_history_no_truncate ON soulbah.feature_flags_history;
CREATE TRIGGER feature_flags_history_no_truncate
  BEFORE TRUNCATE ON soulbah.feature_flags_history FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE OR REPLACE FUNCTION soulbah.feature_flags_track()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    NEW.version := OLD.version + 1;
    NEW.updated_at := now();
    NEW.updated_by := soulbah.change_actor();
    INSERT INTO soulbah.feature_flags_history (key, old_state, new_state, version, changed_by, reason)
    VALUES (OLD.key, to_jsonb(OLD), to_jsonb(NEW), NEW.version, NEW.updated_by, soulbah.change_reason());
    RETURN NEW;
  ELSIF TG_OP = 'INSERT' THEN
    INSERT INTO soulbah.feature_flags_history (key, old_state, new_state, version, changed_by, reason)
    VALUES (NEW.key, NULL, to_jsonb(NEW), NEW.version, soulbah.change_actor(), soulbah.change_reason());
    RETURN NEW;
  END IF;
  INSERT INTO soulbah.feature_flags_history (key, old_state, new_state, version, changed_by, reason)
  VALUES (OLD.key, to_jsonb(OLD), NULL, OLD.version + 1, soulbah.change_actor(), soulbah.change_reason());
  RETURN OLD;
END $$;
DROP TRIGGER IF EXISTS feature_flags_protect ON soulbah.feature_flags;
CREATE TRIGGER feature_flags_protect
  BEFORE UPDATE OR DELETE ON soulbah.feature_flags FOR EACH ROW EXECUTE FUNCTION soulbah.protect_immutable();
DROP TRIGGER IF EXISTS feature_flags_track ON soulbah.feature_flags;
CREATE TRIGGER feature_flags_track
  BEFORE INSERT OR UPDATE OR DELETE ON soulbah.feature_flags FOR EACH ROW EXECUTE FUNCTION soulbah.feature_flags_track();

-- ---------------------------------------------------------------------------------------------
-- 8. Aucun droit client sur les objets de ce lot
-- ---------------------------------------------------------------------------------------------
DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON soulbah.environments, soulbah.system_settings, soulbah.system_settings_history, soulbah.system_state,
    soulbah.system_state_history, soulbah.system_versions, soulbah.system_health, soulbah.feature_flags,
    soulbah.feature_flags_history FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.environments, soulbah.system_settings, soulbah.system_settings_history, '
                     'soulbah.system_state, soulbah.system_state_history, soulbah.system_versions, soulbah.system_health, '
                     'soulbah.feature_flags, soulbah.feature_flags_history FROM %I', r);
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.append_only(), soulbah.assert_table_shape(regclass, jsonb), '
                     'soulbah.protect_immutable(), soulbah.trusted_core_unlocked(), soulbah.writes_allowed(), '
                     'soulbah.change_reason(), soulbah.change_actor(), soulbah.system_settings_track(), '
                     'soulbah.system_state_track(), soulbah.feature_flags_track() FROM %I', r);
    END IF;
  END LOOP;
END $$;


-- >>>>>>>>>> 20261002110200_db02_projects.sql <<<<<<<<<<

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


-- >>>>>>>>>> 20261002110300_db03_agents.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 3 — Agents : registre des définitions d'agents (versionné), capacités, permissions, affectations,
-- état, métriques ; exécutions (REUSE soulbah.agents, soulbah.tasks, soulbah.actions, soulbah.tool_calls) ;
-- supervision (échecs, watchdog, relectures croisées, quarantaines).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110300_db03_agents.down.sql (supprime aussi les colonnes ajoutées à soulbah.agents et soulbah.tasks)
-- soulbah:transaction=single
-- Dépend de : db01, db02.
-- Le registre s'appelle agent_definitions : soulbah.agents (V2) désigne déjà une INSTANCE d'agent par tâche.
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.agent_definitions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                text NOT NULL UNIQUE CONSTRAINT agent_definitions_name_format CHECK (name ~ '^[a-z][a-z0-9_]{0,63}$'),
  display_name        text NOT NULL CONSTRAINT agent_definitions_display_length CHECK (length(display_name) BETWEEN 1 AND 120),
  mission             text NOT NULL DEFAULT '' CONSTRAINT agent_definitions_mission_length CHECK (length(mission) <= 4000),
  executor            text NOT NULL DEFAULT 'runtime' CONSTRAINT agent_definitions_executor_check CHECK (executor IN ('runtime', 'p1')),
  status              text NOT NULL DEFAULT 'active'
                      CONSTRAINT agent_definitions_status_check CHECK (status IN ('draft', 'active', 'suspended', 'quarantined', 'retired')),
  max_security_level  text NOT NULL DEFAULT 'L1' CONSTRAINT agent_definitions_level_check CHECK (soulbah.is_security_level(max_security_level)),
  model_preference    text NOT NULL DEFAULT 'AUTO' CONSTRAINT agent_definitions_model_length CHECK (length(model_preference) BETWEEN 1 AND 200),
  memory_scope        text NOT NULL DEFAULT 'project' CONSTRAINT agent_definitions_memory_scope_check CHECK (memory_scope IN ('session', 'project', 'user', 'global')),
  knowledge_scope     jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT agent_definitions_knowledge_array CHECK (soulbah.is_json_array(knowledge_scope)),
  resource_limits     jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT agent_definitions_limits_object CHECK (soulbah.is_json_object(resource_limits)),
  max_runtime_s       integer NOT NULL DEFAULT 900 CONSTRAINT agent_definitions_runtime_positive CHECK (max_runtime_s BETWEEN 1 AND 86400),
  max_tool_calls      integer NOT NULL DEFAULT 200 CONSTRAINT agent_definitions_tool_calls_positive CHECK (max_tool_calls BETWEEN 1 AND 100000),
  max_retries         integer NOT NULL DEFAULT 2 CONSTRAINT agent_definitions_retries_range CHECK (max_retries BETWEEN 0 AND 10),
  current_version_id  uuid,
  immutable           boolean NOT NULL DEFAULT false,
  created_by          text NOT NULL DEFAULT current_user,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.agent_definitions IS 'Registre des agents (modifiable depuis le Control Center) : mission, exécutant, plafonds, limites. Une exécution = une ligne de soulbah.agents.';
ALTER TABLE soulbah.agent_definitions ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS agent_definitions_set_updated_at ON soulbah.agent_definitions;
CREATE TRIGGER agent_definitions_set_updated_at BEFORE UPDATE ON soulbah.agent_definitions FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
DROP TRIGGER IF EXISTS agent_definitions_protect ON soulbah.agent_definitions;
CREATE TRIGGER agent_definitions_protect BEFORE UPDATE OR DELETE ON soulbah.agent_definitions FOR EACH ROW EXECUTE FUNCTION soulbah.protect_immutable();

CREATE TABLE IF NOT EXISTS soulbah.agent_definition_versions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_id  uuid NOT NULL REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  version        text NOT NULL CONSTRAINT agent_definition_versions_semver CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  prompt         text NOT NULL DEFAULT '' CONSTRAINT agent_definition_versions_prompt_length CHECK (length(prompt) <= 60000),
  tools          jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT agent_definition_versions_tools_array CHECK (soulbah.is_json_array(tools)),
  permissions    jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT agent_definition_versions_permissions_array CHECK (soulbah.is_json_array(permissions)),
  model          text NOT NULL DEFAULT 'AUTO',
  skills         jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT agent_definition_versions_skills_array CHECK (soulbah.is_json_array(skills)),
  changelog      text NOT NULL DEFAULT '' CONSTRAINT agent_definition_versions_changelog_length CHECK (length(changelog) <= 4000),
  status         text NOT NULL DEFAULT 'draft' CONSTRAINT agent_definition_versions_status_check CHECK (status IN ('draft', 'canary', 'active', 'retired')),
  created_by     text NOT NULL DEFAULT current_user,
  created_at     timestamptz NOT NULL DEFAULT now(),
  activated_at   timestamptz,
  CONSTRAINT agent_definition_versions_unique UNIQUE (definition_id, version)
);
COMMENT ON TABLE soulbah.agent_definition_versions IS 'Historique des versions d''un agent (prompt, outils, permissions, modèle, skills) ; canary avant remplacement (§73).';
ALTER TABLE soulbah.agent_definition_versions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_agent_definition_versions_status ON soulbah.agent_definition_versions (definition_id, status);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agent_definitions_current_version_fkey') THEN
    ALTER TABLE soulbah.agent_definitions ADD CONSTRAINT agent_definitions_current_version_fkey
      FOREIGN KEY (current_version_id) REFERENCES soulbah.agent_definition_versions(id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_agent_definitions_current_version ON soulbah.agent_definitions (current_version_id);

CREATE TABLE IF NOT EXISTS soulbah.agent_capabilities (
  definition_id  uuid NOT NULL REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  capability     text NOT NULL CONSTRAINT agent_capabilities_format CHECK (capability ~ '^[a-z][a-z0-9_.]{0,99}$'),
  enabled        boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (definition_id, capability)
);
COMMENT ON TABLE soulbah.agent_capabilities IS 'Capacités déclarées d''un agent (coding, vision, computer_control, research…), activables.';
ALTER TABLE soulbah.agent_capabilities ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.agent_permissions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_id     uuid NOT NULL REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  permission        text NOT NULL CONSTRAINT agent_permissions_format CHECK (permission ~ '^[a-z_]+\.[a-z_]+$'),
  environment_name  text NOT NULL REFERENCES soulbah.environments(name),
  decision          text NOT NULL CONSTRAINT agent_permissions_decision_check CHECK (decision IN ('allow', 'deny', 'approval')),
  granted_by        text NOT NULL DEFAULT current_user,
  reason            text,
  version           integer NOT NULL DEFAULT 1,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT agent_permissions_unique UNIQUE (definition_id, permission, environment_name)
);
COMMENT ON TABLE soulbah.agent_permissions IS 'Permissions nommées accordées à un agent PAR environnement (DEV ≠ PRODUCTION) ; le moteur de politiques (DB LOT 4) tranche.';
ALTER TABLE soulbah.agent_permissions ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS agent_permissions_set_updated_at ON soulbah.agent_permissions;
CREATE TRIGGER agent_permissions_set_updated_at BEFORE UPDATE ON soulbah.agent_permissions FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.agent_assignments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_id     uuid NOT NULL REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  project_id        uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  environment_name  text NOT NULL REFERENCES soulbah.environments(name),
  autonomy_level    text NOT NULL DEFAULT 'OBSERVE' CONSTRAINT agent_assignments_autonomy_check CHECK (soulbah.is_autonomy_level(autonomy_level)),
  enabled           boolean NOT NULL DEFAULT true,
  created_by        text NOT NULL DEFAULT current_user,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT agent_assignments_unique UNIQUE (definition_id, project_id, environment_name)
);
COMMENT ON TABLE soulbah.agent_assignments IS 'Affectation d''un agent à un projet et un environnement avec son niveau d''autonomie (OBSERVE … PRODUCTION_GUARDED).';
ALTER TABLE soulbah.agent_assignments ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_agent_assignments_project ON soulbah.agent_assignments (project_id, environment_name);
DROP TRIGGER IF EXISTS agent_assignments_set_updated_at ON soulbah.agent_assignments;
CREATE TRIGGER agent_assignments_set_updated_at BEFORE UPDATE ON soulbah.agent_assignments FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.agent_status (
  definition_id      uuid PRIMARY KEY REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  status             text NOT NULL DEFAULT 'idle' CONSTRAINT agent_status_check CHECK (status IN ('idle', 'busy', 'suspended', 'quarantined', 'error')),
  current_load       integer NOT NULL DEFAULT 0 CONSTRAINT agent_status_load_positive CHECK (current_load >= 0),
  last_heartbeat_at  timestamptz,
  last_run_at        timestamptz,
  last_error         text,
  quarantined_at     timestamptz,
  updated_at         timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.agent_status IS 'État courant de chaque agent (charge, dernière exécution, dernière erreur, quarantaine).';
ALTER TABLE soulbah.agent_status ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS agent_status_set_updated_at ON soulbah.agent_status;
CREATE TRIGGER agent_status_set_updated_at BEFORE UPDATE ON soulbah.agent_status FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.agent_metrics (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  definition_id        uuid NOT NULL REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  period_start         timestamptz NOT NULL,
  period_end           timestamptz NOT NULL,
  runs                 integer NOT NULL DEFAULT 0,
  successes            integer NOT NULL DEFAULT 0,
  failures             integer NOT NULL DEFAULT 0,
  retries              integer NOT NULL DEFAULT 0,
  avg_duration_ms      integer,
  p95_duration_ms      integer,
  tool_calls           integer NOT NULL DEFAULT 0,
  human_interventions  integer NOT NULL DEFAULT 0,
  input_tokens         bigint NOT NULL DEFAULT 0,
  output_tokens        bigint NOT NULL DEFAULT 0,
  cost_usd             numeric(12, 6),
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT agent_metrics_period CHECK (period_end > period_start),
  CONSTRAINT agent_metrics_unique UNIQUE (definition_id, period_start, period_end)
);
COMMENT ON TABLE soulbah.agent_metrics IS 'Mesures par agent et par période (réussites, échecs, reprises, durées, interventions humaines, coût) — §70.';
ALTER TABLE soulbah.agent_metrics ENABLE ROW LEVEL SECURITY;

-- Exécutions : REUSE de soulbah.agents (instance par tâche) et soulbah.tasks, étendus.
SELECT soulbah.assert_table_shape('soulbah.agents', '{"role": "text", "status": "text", "session_id": "uuid"}');
ALTER TABLE soulbah.agents
  ADD COLUMN IF NOT EXISTS definition_id uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS version_id    uuid REFERENCES soulbah.agent_definition_versions(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS outcome       text,
  ADD COLUMN IF NOT EXISTS finished_at   timestamptz;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'agents_outcome_check') THEN
    ALTER TABLE soulbah.agents ADD CONSTRAINT agents_outcome_check
      CHECK (outcome IS NULL OR outcome IN ('success', 'failure', 'cancelled', 'timeout'));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_agents_definition ON soulbah.agents (definition_id, created_at);
COMMENT ON COLUMN soulbah.agents.definition_id IS 'Agent du registre dont cette exécution est une instance (agent_runs).';

SELECT soulbah.assert_table_shape('soulbah.tasks', '{"role": "text", "status": "text", "session_id": "uuid"}');
ALTER TABLE soulbah.tasks
  ADD COLUMN IF NOT EXISTS agent_definition_id uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_agent_definition ON soulbah.tasks (agent_definition_id) WHERE agent_definition_id IS NOT NULL;

-- Supervision ---------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.agent_failures (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id          uuid REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  attempt          integer CONSTRAINT agent_failures_attempt_positive CHECK (attempt IS NULL OR attempt >= 0),
  definition_id    uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  kind             text NOT NULL CONSTRAINT agent_failures_kind_check
                   CHECK (kind IN ('error', 'timeout', 'loop', 'policy_refused', 'evaluation_failed', 'crash', 'other')),
  message          text NOT NULL CONSTRAINT agent_failures_message_length CHECK (length(message) BETWEEN 1 AND 4000),
  probable_cause   text,
  root_cause       text,
  strategy_change  text,
  retried          boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.agent_failures IS 'Échecs d''agents : cause probable, cause racine, stratégie corrigée ; la leçon validée est liée à la mémoire (DB LOT 5) — §22, §35.';
ALTER TABLE soulbah.agent_failures ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_agent_failures_task ON soulbah.agent_failures (task_id);
CREATE INDEX IF NOT EXISTS idx_agent_failures_definition ON soulbah.agent_failures (definition_id, created_at);

CREATE TABLE IF NOT EXISTS soulbah.agent_watchdog_events (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- Journal en ajout seul : FK RESTRICT vers le catalogue (jamais supprimé), pas de FK vers les lignes
  -- opérationnelles purgées (agents, tâches) — convention de soulbah.audit_logs.
  definition_id  uuid REFERENCES soulbah.agent_definitions(id) ON DELETE RESTRICT,
  agent_id       uuid,
  task_id        uuid,
  kind           text NOT NULL CONSTRAINT agent_watchdog_events_kind_check CHECK (kind IN (
                   'hang', 'loop', 'repeated_action', 'excessive_resources', 'frequent_errors',
                   'capability_hallucination', 'missing_evidence', 'conflict', 'permission_escalation_attempt',
                   'unusual_access', 'unusual_command', 'security_disable_attempt', 'exfiltration_suspected')),
  severity       text NOT NULL CONSTRAINT agent_watchdog_events_severity_check CHECK (soulbah.is_severity(severity)),
  detail         jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT agent_watchdog_events_detail_object CHECK (soulbah.is_json_object(detail)),
  action_taken   text NOT NULL DEFAULT 'none' CONSTRAINT agent_watchdog_events_action_check CHECK (action_taken IN ('none', 'warned', 'stopped', 'quarantined', 'escalated')),
  created_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.agent_watchdog_events IS 'Événements du watchdog (boucles, blocages, tentatives d''élévation, accès inhabituels…), ajout seul — §21, §45.';
ALTER TABLE soulbah.agent_watchdog_events ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_agent_watchdog_events_definition ON soulbah.agent_watchdog_events (definition_id, id);
CREATE INDEX IF NOT EXISTS idx_agent_watchdog_events_task ON soulbah.agent_watchdog_events (task_id);
CREATE INDEX IF NOT EXISTS idx_agent_watchdog_events_agent ON soulbah.agent_watchdog_events (agent_id);
DROP TRIGGER IF EXISTS agent_watchdog_events_append_only ON soulbah.agent_watchdog_events;
CREATE TRIGGER agent_watchdog_events_append_only BEFORE UPDATE OR DELETE ON soulbah.agent_watchdog_events FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS agent_watchdog_events_no_truncate ON soulbah.agent_watchdog_events;
CREATE TRIGGER agent_watchdog_events_no_truncate BEFORE TRUNCATE ON soulbah.agent_watchdog_events FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE TABLE IF NOT EXISTS soulbah.agent_peer_reviews (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id                 uuid NOT NULL REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  attempt                 integer NOT NULL CONSTRAINT agent_peer_reviews_attempt_positive CHECK (attempt >= 0),
  reviewer_definition_id  uuid NOT NULL REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  author_definition_id    uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  lens                    text NOT NULL CONSTRAINT agent_peer_reviews_lens_check CHECK (lens IN ('quality', 'security', 'tests', 'architecture', 'evidence')),
  verdict                 text NOT NULL CONSTRAINT agent_peer_reviews_verdict_check CHECK (verdict IN ('approved', 'changes_requested', 'rejected')),
  findings                jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT agent_peer_reviews_findings_array CHECK (soulbah.is_json_array(findings)),
  evidence_ids            jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT agent_peer_reviews_evidence_array CHECK (soulbah.is_json_array(evidence_ids)),
  created_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT agent_peer_reviews_not_self CHECK (author_definition_id IS NULL OR reviewer_definition_id <> author_definition_id)
);
COMMENT ON TABLE soulbah.agent_peer_reviews IS 'Relectures croisées (un agent ne juge jamais seul son propre travail critique) — §20, §33.';
ALTER TABLE soulbah.agent_peer_reviews ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_agent_peer_reviews_task ON soulbah.agent_peer_reviews (task_id, attempt);
CREATE INDEX IF NOT EXISTS idx_agent_peer_reviews_reviewer ON soulbah.agent_peer_reviews (reviewer_definition_id);
CREATE INDEX IF NOT EXISTS idx_agent_peer_reviews_author ON soulbah.agent_peer_reviews (author_definition_id);

CREATE TABLE IF NOT EXISTS soulbah.agent_quarantines (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_id  uuid NOT NULL REFERENCES soulbah.agent_definitions(id) ON DELETE CASCADE,
  reason         text NOT NULL CONSTRAINT agent_quarantines_reason_length CHECK (length(reason) BETWEEN 1 AND 4000),
  event_id       bigint REFERENCES soulbah.agent_watchdog_events(id) ON DELETE SET NULL,
  status         text NOT NULL DEFAULT 'active' CONSTRAINT agent_quarantines_status_check CHECK (status IN ('active', 'lifted')),
  created_by     text NOT NULL DEFAULT current_user,
  created_at     timestamptz NOT NULL DEFAULT now(),
  lifted_by      text,
  lifted_at      timestamptz,
  lifted_reason  text,
  CONSTRAINT agent_quarantines_lift_complete CHECK (status = 'active' OR (lifted_by IS NOT NULL AND lifted_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.agent_quarantines IS 'Quarantaines d''agents (§46) : l''agent perd ses permissions sensibles jusqu''à l''analyse ; la levée est tracée.';
ALTER TABLE soulbah.agent_quarantines ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_agent_quarantines_definition ON soulbah.agent_quarantines (definition_id, status);
CREATE INDEX IF NOT EXISTS idx_agent_quarantines_event ON soulbah.agent_quarantines (event_id);

-- Une quarantaine active met l'agent en quarantaine ; sa levée le ramène suspendu (réactivation explicite).
CREATE OR REPLACE FUNCTION soulbah.agent_quarantine_apply()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = soulbah, pg_temp
AS $$
BEGIN
  IF NEW.status = 'active' THEN
    UPDATE soulbah.agent_definitions SET status = 'quarantined' WHERE id = NEW.definition_id AND status <> 'retired';
    INSERT INTO soulbah.agent_status (definition_id, status, quarantined_at) VALUES (NEW.definition_id, 'quarantined', now())
    ON CONFLICT (definition_id) DO UPDATE SET status = 'quarantined', quarantined_at = now();
  ELSIF TG_OP = 'UPDATE' AND OLD.status = 'active' AND NEW.status = 'lifted'
        AND NOT EXISTS (SELECT 1 FROM soulbah.agent_quarantines q WHERE q.definition_id = NEW.definition_id AND q.status = 'active' AND q.id <> NEW.id) THEN
    UPDATE soulbah.agent_definitions SET status = 'suspended' WHERE id = NEW.definition_id AND status = 'quarantined';
    UPDATE soulbah.agent_status SET status = 'suspended', quarantined_at = NULL WHERE definition_id = NEW.definition_id;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS agent_quarantines_apply ON soulbah.agent_quarantines;
CREATE TRIGGER agent_quarantines_apply AFTER INSERT OR UPDATE ON soulbah.agent_quarantines FOR EACH ROW EXECUTE FUNCTION soulbah.agent_quarantine_apply();

-- Semence : les 7 rôles V2 (shared/roles/roles.json), versions et outils identiques au code -------
INSERT INTO soulbah.agent_definitions (name, display_name, mission, executor, max_security_level) VALUES
  ('desktop_operator', 'Computer Agent', 'Pilote le bureau Windows (souris, clavier, fenêtres, applications, VS Code) ; observe (capture ou inspection d''interface) avant d''agir.', 'runtime', 'L2'),
  ('coder', 'Developer Agent', 'Lit, écrit et exécute du code dans SA worktree git ; fusionne vers l''intégration avec tests verts après relecture QA.', 'runtime', 'L2'),
  ('researcher', 'Research Agent', 'Collecte des faits : workspace, pages web publiques (lecture seule), état des fenêtres ; aucun effet.', 'runtime', 'L1'),
  ('video_editor', 'Video Agent', 'Enregistre l''écran, produit la narration avec une voix locale et monte les vidéos de démonstration.', 'runtime', 'L2'),
  ('phone_operator', 'Phone Agent', 'Pilote un téléphone Android connecté (adb).', 'runtime', 'L2'),
  ('qa_reviewer', 'QA Agent', 'Relit le travail d''une autre tâche à partir de ses preuves et de son évaluation (exécuté par le plan de contrôle).', 'p1', 'L0'),
  ('content_writer', 'Knowledge Agent', 'Rédige du contenu (modules de formation, synthèses) via le routeur de modèles (exécuté par le plan de contrôle).', 'p1', 'L0')
ON CONFLICT (name) DO NOTHING;

INSERT INTO soulbah.agent_definition_versions (definition_id, version, tools, status, changelog, activated_at)
SELECT d.id, v.version, v.tools::jsonb, 'active', 'Version importée de shared/roles/roles.json (LOT 11/12 V2).', now()
FROM (VALUES
  ('desktop_operator', '1.2.0', '["screenshot","click","double_click","right_click","move_mouse","drag","scroll","type_text","hotkey","window","open_app","wait","ui_snapshot","vscode_open","speak_text","read_file","list_dir","record_screen","start_recording_bg","stop_recording_bg"]'),
  ('coder', '1.1.0', '["run_command","git_worktree","git_commit","git_merge","read_file","list_dir","write_file","make_dir","move_file","browser_get","wait"]'),
  ('researcher', '1.1.0', '["read_file","list_dir","browser_get","ui_snapshot","wait","screenshot"]'),
  ('video_editor', '1.1.0', '["record_screen","start_recording_bg","stop_recording_bg","edit_video","resolve_montage","speak_text","read_file","list_dir","write_file","make_dir","move_file","wait"]'),
  ('phone_operator', '1.0.0', '["phone_list_devices","phone_screenshot","phone_tap","phone_swipe","phone_type","phone_key","phone_open_app","wait"]'),
  ('qa_reviewer', '1.0.0', '[]'),
  ('content_writer', '1.0.0', '[]')
) AS v(name, version, tools)
JOIN soulbah.agent_definitions d ON d.name = v.name
ON CONFLICT (definition_id, version) DO NOTHING;

UPDATE soulbah.agent_definitions d
   SET current_version_id = v.id
  FROM soulbah.agent_definition_versions v
 WHERE v.definition_id = d.id AND v.status = 'active' AND d.current_version_id IS NULL;

INSERT INTO soulbah.agent_status (definition_id, status)
SELECT id, 'idle' FROM soulbah.agent_definitions ON CONFLICT (definition_id) DO NOTHING;

DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON soulbah.agent_definitions, soulbah.agent_definition_versions, soulbah.agent_capabilities, soulbah.agent_permissions,
    soulbah.agent_assignments, soulbah.agent_status, soulbah.agent_metrics, soulbah.agent_failures, soulbah.agent_watchdog_events,
    soulbah.agent_peer_reviews, soulbah.agent_quarantines FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.agent_definitions, soulbah.agent_definition_versions, soulbah.agent_capabilities, '
                     'soulbah.agent_permissions, soulbah.agent_assignments, soulbah.agent_status, soulbah.agent_metrics, '
                     'soulbah.agent_failures, soulbah.agent_watchdog_events, soulbah.agent_peer_reviews, soulbah.agent_quarantines FROM %I', r);
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.agent_quarantine_apply() FROM %I', r);
    END IF;
  END LOOP;
END $$;


-- >>>>>>>>>> 20261002110400_db04_policies_guardrails.sql <<<<<<<<<<

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


-- >>>>>>>>>> 20261002110500_db05_memory.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 5 — Memory Core : mémoire unifiée typée (WORKING, EPISODIC, SEMANTIC, PROJECT, RESEARCH, BUG, SOLUTION,
-- SECURITY, SKILL), provenance, confiance, validation, fraîcheur, versions, statuts, relations, contradictions.
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110500_db05_memory.down.sql (les mémoires V1 restent dans public.agent_memory ; les mémoires créées ensuite sont perdues)
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03. public.agent_memory et la vue soulbah.memories (V1/V2) restent inchangées.
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.memory_items (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type                 text NOT NULL CONSTRAINT memory_items_type_check
                       CHECK (type IN ('WORKING', 'EPISODIC', 'SEMANTIC', 'PROJECT', 'RESEARCH', 'BUG', 'SOLUTION', 'SECURITY', 'SKILL')),
  project_id           uuid REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  agent_definition_id  uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  user_id              uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  session_id           uuid REFERENCES soulbah.sessions(id) ON DELETE SET NULL,
  task_id              uuid REFERENCES soulbah.tasks(id) ON DELETE SET NULL,
  title                text NOT NULL CONSTRAINT memory_items_title_length CHECK (length(title) BETWEEN 1 AND 300),
  content              text NOT NULL DEFAULT '' CONSTRAINT memory_items_content_length CHECK (length(content) <= 20000),
  content_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  source               text NOT NULL CONSTRAINT memory_items_source_length CHECK (length(source) BETWEEN 1 AND 200),
  source_ref           text CONSTRAINT memory_items_source_ref_length CHECK (source_ref IS NULL OR length(source_ref) <= 500),
  provenance           jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT memory_items_provenance_object CHECK (soulbah.is_json_object(provenance)),
  confidence           real NOT NULL DEFAULT 0.5 CONSTRAINT memory_items_confidence_range CHECK (confidence >= 0 AND confidence <= 1),
  validation_status    text NOT NULL DEFAULT 'candidate' CONSTRAINT memory_items_validation_check CHECK (validation_status IN ('candidate', 'validated', 'rejected')),
  validated_by         text,
  validated_at         timestamptz,
  freshness_policy     text NOT NULL DEFAULT 'slow' CONSTRAINT memory_items_freshness_check CHECK (freshness_policy IN ('static', 'slow', 'fast', 'volatile')),
  retrieved_at         timestamptz,
  last_verified_at     timestamptz,
  version              integer NOT NULL DEFAULT 1 CONSTRAINT memory_items_version_positive CHECK (version >= 1),
  status               text NOT NULL DEFAULT 'ACTIVE' CONSTRAINT memory_items_status_check CHECK (status IN ('ACTIVE', 'STALE', 'SUPERSEDED', 'INVALID', 'ARCHIVED')),
  supersedes_id        uuid REFERENCES soulbah.memory_items(id) ON DELETE SET NULL,
  tags                 jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT memory_items_tags_array CHECK (soulbah.is_json_array(tags)),
  metadata             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT memory_items_metadata_object CHECK (soulbah.is_json_object(metadata)),
  -- Fiable = validée ET active : seule une mémoire fiable est injectée dans un plan (§69).
  reliable             boolean GENERATED ALWAYS AS (validation_status = 'validated' AND status = 'ACTIVE') STORED,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT memory_items_validated_requires_author CHECK (validation_status <> 'validated' OR validated_by IS NOT NULL),
  CONSTRAINT memory_items_content_or_artifact CHECK (length(content) > 0 OR content_artifact_id IS NOT NULL),
  CONSTRAINT memory_items_not_self_supersede CHECK (supersedes_id IS NULL OR supersedes_id <> id)
);
COMMENT ON TABLE soulbah.memory_items IS 'Mémoire unifiée de Soulbah : type, projet, agent, provenance, confiance, validation humaine ou par preuves, fraîcheur, version, statut. reliable = validée et active.';
ALTER TABLE soulbah.memory_items ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_memory_items_project_type ON soulbah.memory_items (project_id, type, status);
CREATE INDEX IF NOT EXISTS idx_memory_items_reliable ON soulbah.memory_items (type, updated_at) WHERE reliable;
CREATE INDEX IF NOT EXISTS idx_memory_items_agent ON soulbah.memory_items (agent_definition_id);
CREATE INDEX IF NOT EXISTS idx_memory_items_user ON soulbah.memory_items (user_id);
CREATE INDEX IF NOT EXISTS idx_memory_items_session ON soulbah.memory_items (session_id);
CREATE INDEX IF NOT EXISTS idx_memory_items_task ON soulbah.memory_items (task_id);
CREATE INDEX IF NOT EXISTS idx_memory_items_artifact ON soulbah.memory_items (content_artifact_id);
CREATE INDEX IF NOT EXISTS idx_memory_items_supersedes ON soulbah.memory_items (supersedes_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_items_source_ref ON soulbah.memory_items (source, source_ref) WHERE source_ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_memory_items_tags ON soulbah.memory_items USING gin (tags jsonb_path_ops);
DROP TRIGGER IF EXISTS memory_items_set_updated_at ON soulbah.memory_items;
CREATE TRIGGER memory_items_set_updated_at BEFORE UPDATE ON soulbah.memory_items FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- Version : toute modification du contenu d'une mémoire validée incrémente la version et repasse en candidate.
CREATE OR REPLACE FUNCTION soulbah.memory_items_revalidate()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.content IS DISTINCT FROM OLD.content OR NEW.content_artifact_id IS DISTINCT FROM OLD.content_artifact_id THEN
    NEW.version := OLD.version + 1;
    IF OLD.validation_status = 'validated' AND NEW.validation_status = 'validated' AND NEW.validated_at IS NOT DISTINCT FROM OLD.validated_at THEN
      NEW.validation_status := 'candidate';   -- un contenu modifié n'est plus validé tant qu'il n'est pas revalidé
      NEW.validated_by := NULL;
      NEW.validated_at := NULL;
    END IF;
  END IF;
  IF NEW.validation_status = 'validated' AND OLD.validation_status <> 'validated' AND NEW.validated_at IS NULL THEN
    NEW.validated_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS memory_items_revalidate ON soulbah.memory_items;
CREATE TRIGGER memory_items_revalidate BEFORE UPDATE ON soulbah.memory_items FOR EACH ROW EXECUTE FUNCTION soulbah.memory_items_revalidate();

CREATE TABLE IF NOT EXISTS soulbah.memory_relationships (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_id     uuid NOT NULL REFERENCES soulbah.memory_items(id) ON DELETE CASCADE,
  to_id       uuid NOT NULL REFERENCES soulbah.memory_items(id) ON DELETE CASCADE,
  kind        text NOT NULL CONSTRAINT memory_relationships_kind_check CHECK (kind IN ('supports', 'contradicts', 'supersedes', 'derived_from', 'related_to')),
  created_by  text NOT NULL DEFAULT current_user,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT memory_relationships_not_self CHECK (from_id <> to_id),
  CONSTRAINT memory_relationships_unique UNIQUE (from_id, to_id, kind)
);
COMMENT ON TABLE soulbah.memory_relationships IS 'Relations entre mémoires : supports, contradicts, supersedes, derived_from, related_to.';
ALTER TABLE soulbah.memory_relationships ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_memory_relationships_to ON soulbah.memory_relationships (to_id, kind);

-- §60 : « supersedes » marque l'ancienne mémoire SUPERSEDED ; « contradicts » ouvre une contradiction.
CREATE TABLE IF NOT EXISTS soulbah.memory_contradictions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  memory_a     uuid NOT NULL REFERENCES soulbah.memory_items(id) ON DELETE CASCADE,
  memory_b     uuid NOT NULL REFERENCES soulbah.memory_items(id) ON DELETE CASCADE,
  detected_by  text NOT NULL DEFAULT current_user,
  status       text NOT NULL DEFAULT 'open' CONSTRAINT memory_contradictions_status_check CHECK (status IN ('open', 'resolved_a', 'resolved_b', 'both_invalid', 'dismissed')),
  resolution   text,
  resolved_by  text,
  resolved_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT memory_contradictions_not_self CHECK (memory_a <> memory_b),
  CONSTRAINT memory_contradictions_unique UNIQUE (memory_a, memory_b),
  CONSTRAINT memory_contradictions_resolution_complete CHECK (status = 'open' OR (resolved_by IS NOT NULL AND resolved_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.memory_contradictions IS 'Contradictions détectées entre deux mémoires et leur résolution (§33, §60).';
ALTER TABLE soulbah.memory_contradictions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_memory_contradictions_b ON soulbah.memory_contradictions (memory_b);
CREATE INDEX IF NOT EXISTS idx_memory_contradictions_open ON soulbah.memory_contradictions (status) WHERE status = 'open';

CREATE OR REPLACE FUNCTION soulbah.memory_relationships_apply()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.kind = 'supersedes' THEN
    UPDATE soulbah.memory_items SET status = 'SUPERSEDED' WHERE id = NEW.to_id AND status IN ('ACTIVE', 'STALE');
    UPDATE soulbah.memory_items SET supersedes_id = NEW.to_id WHERE id = NEW.from_id AND supersedes_id IS NULL;
  ELSIF NEW.kind = 'contradicts' THEN
    INSERT INTO soulbah.memory_contradictions (memory_a, memory_b, detected_by)
    VALUES (least(NEW.from_id, NEW.to_id), greatest(NEW.from_id, NEW.to_id), NEW.created_by)
    ON CONFLICT (memory_a, memory_b) DO NOTHING;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS memory_relationships_apply ON soulbah.memory_relationships;
CREATE TRIGGER memory_relationships_apply AFTER INSERT ON soulbah.memory_relationships FOR EACH ROW EXECUTE FUNCTION soulbah.memory_relationships_apply();

-- Résolution d'une contradiction : la mémoire perdante est marquée INVALID (jamais les deux valides).
CREATE OR REPLACE FUNCTION soulbah.memory_contradictions_apply()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.status = 'resolved_a' THEN
    UPDATE soulbah.memory_items SET status = 'INVALID' WHERE id = NEW.memory_b AND status <> 'ARCHIVED';
  ELSIF NEW.status = 'resolved_b' THEN
    UPDATE soulbah.memory_items SET status = 'INVALID' WHERE id = NEW.memory_a AND status <> 'ARCHIVED';
  ELSIF NEW.status = 'both_invalid' THEN
    UPDATE soulbah.memory_items SET status = 'INVALID' WHERE id IN (NEW.memory_a, NEW.memory_b) AND status <> 'ARCHIVED';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS memory_contradictions_apply ON soulbah.memory_contradictions;
CREATE TRIGGER memory_contradictions_apply AFTER UPDATE OF status ON soulbah.memory_contradictions FOR EACH ROW EXECUTE FUNCTION soulbah.memory_contradictions_apply();

-- Leçon validée d'un échec d'agent (§35) → mémoire fiable.
ALTER TABLE soulbah.agent_failures ADD COLUMN IF NOT EXISTS lesson_memory_id uuid REFERENCES soulbah.memory_items(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_agent_failures_lesson ON soulbah.agent_failures (lesson_memory_id);

-- Données : les leçons V1 validées (public.agent_memory) deviennent visibles dans la mémoire unifiée, sans copie double.
SELECT soulbah.assert_table_shape('public.agent_memory', '{"goal": "text", "content": "text", "status": "text", "type": "text", "user_id": "uuid"}');
INSERT INTO soulbah.memory_items (type, user_id, title, content, source, source_ref, provenance, confidence, validation_status,
                                  validated_by, validated_at, metadata, created_at)
SELECT CASE m.type WHEN 'error' THEN 'BUG' WHEN 'solution' THEN 'SOLUTION' WHEN 'practice' THEN 'SEMANTIC' WHEN 'optimization' THEN 'SOLUTION' ELSE 'EPISODIC' END,
       m.user_id, left(coalesce(nullif(m.goal, ''), m.type || ' (V1)'), 300), left(m.content, 20000),
       'v1:agent_memory', m.id::text,
       jsonb_build_object('origin', 'public.agent_memory', 'level', m.level, 'type', m.type, 'source_task_id', m.source_task_id),
       coalesce(m.confidence, 0.5), 'validated', coalesce(m.validated_by::text, 'user:' || m.user_id::text),
       coalesce(m.validated_at, m.updated_at, m.created_at), coalesce(m.metadata, '{}'::jsonb), m.created_at
FROM public.agent_memory m
WHERE m.status = 'validated' AND coalesce(m.is_simulation, false) = false
ON CONFLICT (source, source_ref) WHERE source_ref IS NOT NULL DO NOTHING;

DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON soulbah.memory_items, soulbah.memory_relationships, soulbah.memory_contradictions FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.memory_items, soulbah.memory_relationships, soulbah.memory_contradictions FROM %I', r);
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.memory_items_revalidate(), soulbah.memory_relationships_apply(), soulbah.memory_contradictions_apply() FROM %I', r);
    END IF;
  END LOOP;
END $$;


-- >>>>>>>>>> 20261002110600_db06_knowledge_research.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 6 — Knowledge et research : modèles d'embeddings, sources et provenance, relations, validations,
-- sessions de recherche (requêtes, sources, findings, candidats de connaissance).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110600_db06_knowledge_research.down.sql (public.knowledge_base, knowledge_versions, soulbah.knowledge_chunks restent intacts)
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03, db05. REUSE : public.knowledge_base, public.knowledge_versions, public.knowledge_domains,
-- soulbah.knowledge_chunks, vue soulbah.knowledge_documents — inchangés ici (colonnes vectorielles : db06_vector).
-- =============================================================================

-- 1. Modèles d'embeddings (§38) : un vecteur porte toujours son modèle et sa dimension --------------------
CREATE TABLE IF NOT EXISTS soulbah.embedding_models (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL UNIQUE CONSTRAINT embedding_models_name_length CHECK (length(name) BETWEEN 1 AND 200),
  provider    text NOT NULL CONSTRAINT embedding_models_provider_check CHECK (provider IN ('local', 'cloud')),
  dimensions  integer NOT NULL CONSTRAINT embedding_models_dimensions_range CHECK (dimensions BETWEEN 1 AND 16000),
  version     text NOT NULL DEFAULT '1' CONSTRAINT embedding_models_version_length CHECK (length(version) BETWEEN 1 AND 50),
  status      text NOT NULL DEFAULT 'candidate' CONSTRAINT embedding_models_status_check CHECK (status IN ('candidate', 'active', 'reindexing', 'retired')),
  is_default  boolean NOT NULL DEFAULT false,
  metadata    jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT embedding_models_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.embedding_models IS 'Modèles d''embeddings connus (nom, fournisseur local/cloud, dimensions, version, statut) ; un seul modèle par défaut.';
ALTER TABLE soulbah.embedding_models ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.embedding_models', '{"name": "text", "dimensions": "integer", "status": "text", "is_default": "boolean"}');
CREATE UNIQUE INDEX IF NOT EXISTS idx_embedding_models_default ON soulbah.embedding_models (is_default) WHERE is_default;
DROP TRIGGER IF EXISTS embedding_models_set_updated_at ON soulbah.embedding_models;
CREATE TRIGGER embedding_models_set_updated_at BEFORE UPDATE ON soulbah.embedding_models FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();
INSERT INTO soulbah.embedding_models (name, provider, dimensions, version, status, metadata) VALUES
  ('text-embedding-3-small', 'cloud', 1536, '1', 'active', '{"vendor": "openai", "note": "modèle des embeddings existants (public.knowledge_base.embedding)"}'),
  ('nomic-embed-text-v1.5-q8_0', 'local', 768, '1.5', 'candidate', '{"license": "apache-2.0", "runtime": "llama.cpp", "note": "installé localement le 2026-10-01, pas encore branché"}')
ON CONFLICT (name) DO NOTHING;

-- 2. Sources et provenance (§33, §35) ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.knowledge_sources (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind              text NOT NULL CONSTRAINT knowledge_sources_kind_check
                    CHECK (kind IN ('web', 'document', 'repository', 'database', 'api', 'human', 'model', 'memory', 'test', 'log')),
  uri               text CONSTRAINT knowledge_sources_uri_length CHECK (uri IS NULL OR length(uri) <= 2000),
  title             text NOT NULL DEFAULT '' CONSTRAINT knowledge_sources_title_length CHECK (length(title) <= 500),
  project_id        uuid REFERENCES soulbah.projects(id) ON DELETE SET NULL,
  authority         text NOT NULL DEFAULT 'unknown' CONSTRAINT knowledge_sources_authority_check
                    CHECK (authority IN ('official_documentation', 'source_code', 'standard', 'forum', 'opinion', 'internal', 'unknown')),
  reliability       real NOT NULL DEFAULT 0.5 CONSTRAINT knowledge_sources_reliability_range CHECK (reliability >= 0 AND reliability <= 1),
  verified          boolean NOT NULL DEFAULT false,
  retrieved_at      timestamptz,
  last_verified_at  timestamptz,
  freshness_policy  text NOT NULL DEFAULT 'slow' CONSTRAINT knowledge_sources_freshness_check CHECK (freshness_policy IN ('static', 'slow', 'fast', 'volatile')),
  content_hash      text CONSTRAINT knowledge_sources_hash_format CHECK (content_hash IS NULL OR content_hash ~ '^[0-9a-f]{64}$'),
  metadata          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT knowledge_sources_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.knowledge_sources IS 'Sources de connaissance (page, document, dépôt, base, API, humain, modèle…) avec autorité, fiabilité, dates de récupération et de vérification, politique de fraîcheur.';
ALTER TABLE soulbah.knowledge_sources ENABLE ROW LEVEL SECURITY;
CREATE UNIQUE INDEX IF NOT EXISTS idx_knowledge_sources_kind_uri ON soulbah.knowledge_sources (kind, uri) WHERE uri IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_knowledge_sources_project ON soulbah.knowledge_sources (project_id);

CREATE TABLE IF NOT EXISTS soulbah.knowledge_provenance (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id    uuid NOT NULL REFERENCES soulbah.knowledge_sources(id) ON DELETE RESTRICT,
  target_kind  text NOT NULL CONSTRAINT knowledge_provenance_target_kind_check
               CHECK (target_kind IN ('knowledge_base', 'memory_item', 'research_finding', 'project_brain_document', 'security_pattern')),
  target_id    uuid NOT NULL,
  role         text NOT NULL DEFAULT 'origin' CONSTRAINT knowledge_provenance_role_check CHECK (role IN ('origin', 'supporting', 'contradicting')),
  excerpt      text CONSTRAINT knowledge_provenance_excerpt_length CHECK (excerpt IS NULL OR length(excerpt) <= 4000),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT knowledge_provenance_unique UNIQUE (source_id, target_kind, target_id, role)
);
COMMENT ON TABLE soulbah.knowledge_provenance IS 'Provenance : quelle source fonde quelle connaissance (entrée de la base, mémoire, finding, document du Project Brain). Une source référencée ne se supprime pas (RESTRICT) — « Pourquoi sais-tu cela ? ».';
ALTER TABLE soulbah.knowledge_provenance ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_knowledge_provenance_target ON soulbah.knowledge_provenance (target_kind, target_id);

CREATE TABLE IF NOT EXISTS soulbah.knowledge_relationships (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_kind   text NOT NULL CONSTRAINT knowledge_relationships_from_kind_check CHECK (from_kind IN ('knowledge_base', 'memory_item', 'research_finding', 'project_brain_document')),
  from_id     uuid NOT NULL,
  to_kind     text NOT NULL CONSTRAINT knowledge_relationships_to_kind_check CHECK (to_kind IN ('knowledge_base', 'memory_item', 'research_finding', 'project_brain_document')),
  to_id       uuid NOT NULL,
  kind        text NOT NULL CONSTRAINT knowledge_relationships_kind_check CHECK (kind IN ('related_to', 'supersedes', 'contradicts', 'derived_from', 'part_of', 'duplicates')),
  created_by  text NOT NULL DEFAULT current_user,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT knowledge_relationships_not_self CHECK (from_kind <> to_kind OR from_id <> to_id),
  CONSTRAINT knowledge_relationships_unique UNIQUE (from_kind, from_id, to_kind, to_id, kind)
);
COMMENT ON TABLE soulbah.knowledge_relationships IS 'Relations entre connaissances de toute nature (base, mémoire, finding, document) : related_to, supersedes, contradicts, derived_from, part_of, duplicates (déduplication §65).';
ALTER TABLE soulbah.knowledge_relationships ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_knowledge_relationships_to ON soulbah.knowledge_relationships (to_kind, to_id);

CREATE TABLE IF NOT EXISTS soulbah.knowledge_validations (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  target_kind     text NOT NULL CONSTRAINT knowledge_validations_target_kind_check CHECK (target_kind IN ('knowledge_base', 'memory_item', 'research_finding', 'project_brain_document', 'knowledge_source')),
  target_id       uuid NOT NULL,
  validator_type  text NOT NULL CONSTRAINT knowledge_validations_validator_type_check CHECK (validator_type IN ('human', 'agent', 'test', 'source_check', 'cross_check')),
  validator_id    text NOT NULL CONSTRAINT knowledge_validations_validator_id_length CHECK (length(validator_id) BETWEEN 1 AND 200),
  verdict         text NOT NULL CONSTRAINT knowledge_validations_verdict_check CHECK (verdict IN ('valid', 'invalid', 'stale', 'uncertain')),
  evidence        jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT knowledge_validations_evidence_object CHECK (soulbah.is_json_object(evidence)),
  notes           text CONSTRAINT knowledge_validations_notes_length CHECK (notes IS NULL OR length(notes) <= 4000),
  created_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.knowledge_validations IS 'Validations de connaissances (humain, agent, test, vérification de source), ajout seul : qui a jugé quoi, avec quelle preuve.';
ALTER TABLE soulbah.knowledge_validations ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_knowledge_validations_target ON soulbah.knowledge_validations (target_kind, target_id, id);
DROP TRIGGER IF EXISTS knowledge_validations_append_only ON soulbah.knowledge_validations;
CREATE TRIGGER knowledge_validations_append_only BEFORE UPDATE OR DELETE ON soulbah.knowledge_validations FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS knowledge_validations_no_truncate ON soulbah.knowledge_validations;
CREATE TRIGGER knowledge_validations_no_truncate BEFORE TRUNCATE ON soulbah.knowledge_validations FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

-- 3. Recherche (§29-32, §63-64) -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.research_sessions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id           uuid REFERENCES soulbah.projects(id) ON DELETE SET NULL,
  agent_definition_id  uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  user_id              uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  session_id           uuid REFERENCES soulbah.sessions(id) ON DELETE SET NULL,
  question             text NOT NULL CONSTRAINT research_sessions_question_length CHECK (length(question) BETWEEN 1 AND 2000),
  topic                text NOT NULL DEFAULT '' CONSTRAINT research_sessions_topic_length CHECK (length(topic) <= 200),
  mode                 text NOT NULL CONSTRAINT research_sessions_mode_check CHECK (mode IN ('offline', 'local_internet', 'hybrid')),
  status               text NOT NULL DEFAULT 'running' CONSTRAINT research_sessions_status_check CHECK (status IN ('running', 'completed', 'failed', 'cancelled')),
  cache_level          text CONSTRAINT research_sessions_cache_check CHECK (cache_level IS NULL OR cache_level IN ('session', 'project', 'research_memory', 'knowledge_base', 'local_docs', 'none')),
  summary              text NOT NULL DEFAULT '' CONSTRAINT research_sessions_summary_length CHECK (length(summary) <= 20000),
  reliability          real CONSTRAINT research_sessions_reliability_range CHECK (reliability IS NULL OR (reliability >= 0 AND reliability <= 1)),
  reusable             boolean,
  tags                 jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT research_sessions_tags_array CHECK (soulbah.is_json_array(tags)),
  created_at           timestamptz NOT NULL DEFAULT now(),
  finished_at          timestamptz
);
COMMENT ON TABLE soulbah.research_sessions IS 'Recherches menées par les agents : question, sujet, mode, niveau de cache consulté (§31), résumé, fiabilité, réutilisable (§64).';
ALTER TABLE soulbah.research_sessions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_research_sessions_project ON soulbah.research_sessions (project_id, created_at);
CREATE INDEX IF NOT EXISTS idx_research_sessions_agent ON soulbah.research_sessions (agent_definition_id);
CREATE INDEX IF NOT EXISTS idx_research_sessions_user ON soulbah.research_sessions (user_id);
CREATE INDEX IF NOT EXISTS idx_research_sessions_session ON soulbah.research_sessions (session_id);
CREATE INDEX IF NOT EXISTS idx_research_sessions_tags ON soulbah.research_sessions USING gin (tags jsonb_path_ops);

CREATE TABLE IF NOT EXISTS soulbah.research_queries (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  research_session_id  uuid NOT NULL REFERENCES soulbah.research_sessions(id) ON DELETE CASCADE,
  query                text NOT NULL CONSTRAINT research_queries_query_length CHECK (length(query) BETWEEN 1 AND 1000),
  engine               text NOT NULL CONSTRAINT research_queries_engine_length CHECK (length(engine) BETWEEN 1 AND 50),
  results_count        integer NOT NULL DEFAULT 0 CONSTRAINT research_queries_results_positive CHECK (results_count >= 0),
  cache_hit            boolean NOT NULL DEFAULT false,
  executed_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.research_queries IS 'Requêtes d''une recherche (moteur : tavily, serper, brave, knowledge_base, local_docs, memory…), cache consulté ou non.';
ALTER TABLE soulbah.research_queries ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_research_queries_session ON soulbah.research_queries (research_session_id);

CREATE TABLE IF NOT EXISTS soulbah.research_sources (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  research_session_id  uuid NOT NULL REFERENCES soulbah.research_sessions(id) ON DELETE CASCADE,
  source_id            uuid REFERENCES soulbah.knowledge_sources(id) ON DELETE SET NULL,
  url                  text CONSTRAINT research_sources_url_length CHECK (url IS NULL OR length(url) <= 2000),
  title                text NOT NULL DEFAULT '' CONSTRAINT research_sources_title_length CHECK (length(title) <= 500),
  authority            text NOT NULL DEFAULT 'unknown' CONSTRAINT research_sources_authority_check
                       CHECK (authority IN ('official_documentation', 'source_code', 'standard', 'forum', 'opinion', 'internal', 'unknown')),
  retrieved_at         timestamptz,
  verified             boolean NOT NULL DEFAULT false,
  published_at         timestamptz,
  excerpt              text CONSTRAINT research_sources_excerpt_length CHECK (excerpt IS NULL OR length(excerpt) <= 8000),
  reliability          real CONSTRAINT research_sources_reliability_range CHECK (reliability IS NULL OR (reliability >= 0 AND reliability <= 1)),
  created_at           timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.research_sources IS 'Sources consultées par une recherche, avec date de publication si connue, extrait conservé (jamais supprimé après résumé), vérification réelle.';
ALTER TABLE soulbah.research_sources ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_research_sources_session ON soulbah.research_sources (research_session_id);
CREATE INDEX IF NOT EXISTS idx_research_sources_source ON soulbah.research_sources (source_id);

CREATE TABLE IF NOT EXISTS soulbah.research_findings (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  research_session_id      uuid NOT NULL REFERENCES soulbah.research_sessions(id) ON DELETE CASCADE,
  statement                text NOT NULL CONSTRAINT research_findings_statement_length CHECK (length(statement) BETWEEN 1 AND 4000),
  confidence               real NOT NULL DEFAULT 0.5 CONSTRAINT research_findings_confidence_range CHECK (confidence >= 0 AND confidence <= 1),
  supporting_source_ids    jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT research_findings_supporting_array CHECK (soulbah.is_json_array(supporting_source_ids)),
  contradicting_source_ids jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT research_findings_contradicting_array CHECK (soulbah.is_json_array(contradicting_source_ids)),
  freshness_policy         text NOT NULL DEFAULT 'slow' CONSTRAINT research_findings_freshness_check CHECK (freshness_policy IN ('static', 'slow', 'fast', 'volatile')),
  retrieved_at             timestamptz NOT NULL DEFAULT now(),
  status                   text NOT NULL DEFAULT 'candidate' CONSTRAINT research_findings_status_check CHECK (status IN ('candidate', 'validated', 'rejected', 'stale')),
  created_at               timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.research_findings IS 'Faits établis par une recherche, avec sources pour et contre, confiance (jamais une preuve), fraîcheur, statut.';
ALTER TABLE soulbah.research_findings ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_research_findings_session ON soulbah.research_findings (research_session_id);

CREATE TABLE IF NOT EXISTS soulbah.research_knowledge_candidates (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  finding_id      uuid NOT NULL REFERENCES soulbah.research_findings(id) ON DELETE CASCADE,
  target_kind     text NOT NULL CONSTRAINT research_knowledge_candidates_target_kind_check CHECK (target_kind IN ('knowledge_base', 'memory_item')),
  target_id       uuid,
  status          text NOT NULL DEFAULT 'pending' CONSTRAINT research_knowledge_candidates_status_check CHECK (status IN ('pending', 'deduplicated', 'stored', 'rejected')),
  duplicate_of_kind text CONSTRAINT research_knowledge_candidates_dup_kind_check CHECK (duplicate_of_kind IS NULL OR duplicate_of_kind IN ('knowledge_base', 'memory_item')),
  duplicate_of_id uuid,
  decided_by      text,
  decided_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT research_knowledge_candidates_stored_target CHECK (status <> 'stored' OR target_id IS NOT NULL),
  CONSTRAINT research_knowledge_candidates_dedup_target CHECK (status <> 'deduplicated' OR duplicate_of_id IS NOT NULL)
);
COMMENT ON TABLE soulbah.research_knowledge_candidates IS 'Pipeline §30 : finding → candidat → déduplication → validation → stockage (ou rejet). Jamais de stockage direct.';
ALTER TABLE soulbah.research_knowledge_candidates ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_research_knowledge_candidates_finding ON soulbah.research_knowledge_candidates (finding_id);
CREATE INDEX IF NOT EXISTS idx_research_knowledge_candidates_status ON soulbah.research_knowledge_candidates (status) WHERE status = 'pending';

DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON soulbah.embedding_models, soulbah.knowledge_sources, soulbah.knowledge_provenance, soulbah.knowledge_relationships,
    soulbah.knowledge_validations, soulbah.research_sessions, soulbah.research_queries, soulbah.research_sources,
    soulbah.research_findings, soulbah.research_knowledge_candidates FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.embedding_models, soulbah.knowledge_sources, soulbah.knowledge_provenance, '
                     'soulbah.knowledge_relationships, soulbah.knowledge_validations, soulbah.research_sessions, soulbah.research_queries, '
                     'soulbah.research_sources, soulbah.research_findings, soulbah.research_knowledge_candidates FROM %I', r);
    END IF;
  END LOOP;
END $$;


-- >>>>>>>>>> 20261002110650_db06_vector_embeddings.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 6 (vecteurs) — colonnes et index vectoriels : les chunks et les mémoires portent leur modèle d'embedding
-- et sa dimension ; un index HNSW partiel PAR MODÈLE ; table des réindexations (§37-39).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110650_db06_vector_embeddings.down.sql (les vecteurs des mémoires sont perdus ; ceux des chunks restent)
-- soulbah:transaction=single
-- Dépend de : db05 (memory_items), db06 (embedding_models). pgvector : présent sur Supabase (0.8.0, schéma public) ;
-- absent du PostgreSQL local — le banc simule `vector` par real[] et saute les index HNSW (comme la CI).
-- =============================================================================

-- 1. knowledge_chunks (V2) : le modèle devient une référence, la dimension est portée par la ligne.
SELECT soulbah.assert_table_shape('soulbah.knowledge_chunks', '{"embedding_model": "text", "document_id": "uuid"}');
-- Type de la colonne vectorielle vérifié par son nom (pg_type.typname), indépendamment du schéma où vit pgvector
-- (public sur Supabase aujourd'hui, extensions demain — SEC-13) : assert_table_shape() compare format_type() sous
-- search_path = pg_catalog, qui qualifie les types d'extension (public.vector). real[] = stub local sans pgvector.
DO $$
DECLARE tn text;
BEGIN
  SELECT t.typname INTO tn FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
   WHERE a.attrelid = 'soulbah.knowledge_chunks'::regclass AND a.attname = 'embedding' AND NOT a.attisdropped;
  IF tn IS NULL OR tn NOT IN ('vector', '_float4') THEN
    RAISE EXCEPTION 'table soulbah.knowledge_chunks : colonne « embedding » de type %, attendu vector (pgvector) — structure incompatible, migration arrêtée', coalesce(tn, 'absente');
  END IF;
END $$;
ALTER TABLE soulbah.knowledge_chunks
  ADD COLUMN IF NOT EXISTS embedding_model_id uuid REFERENCES soulbah.embedding_models(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS embedding_dims     integer;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'knowledge_chunks_dims_range') THEN
    ALTER TABLE soulbah.knowledge_chunks ADD CONSTRAINT knowledge_chunks_dims_range CHECK (embedding_dims IS NULL OR embedding_dims BETWEEN 1 AND 16000);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_model_id ON soulbah.knowledge_chunks (embedding_model_id);
UPDATE soulbah.knowledge_chunks c
   SET embedding_model_id = m.id, embedding_dims = coalesce(c.embedding_dims, m.dimensions)
  FROM soulbah.embedding_models m
 WHERE c.embedding_model = m.name AND c.embedding_model_id IS NULL;
COMMENT ON COLUMN soulbah.knowledge_chunks.embedding_model_id IS 'Modèle qui a produit le vecteur ; jamais deux modèles dans un même index.';

-- 2. memory_items : vecteur optionnel, même règle.
ALTER TABLE soulbah.memory_items
  ADD COLUMN IF NOT EXISTS embedding          vector,
  ADD COLUMN IF NOT EXISTS embedding_model_id uuid REFERENCES soulbah.embedding_models(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS embedding_dims     integer;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'memory_items_embedding_requires_model') THEN
    ALTER TABLE soulbah.memory_items ADD CONSTRAINT memory_items_embedding_requires_model
      CHECK (embedding IS NULL OR (embedding_model_id IS NOT NULL AND embedding_dims IS NOT NULL));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'memory_items_dims_range') THEN
    ALTER TABLE soulbah.memory_items ADD CONSTRAINT memory_items_dims_range CHECK (embedding_dims IS NULL OR embedding_dims BETWEEN 1 AND 16000);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_memory_items_embedding_model ON soulbah.memory_items (embedding_model_id);

-- 3. Index HNSW partiels par modèle (une dimension fixée par le cast). Sautés sans pgvector.
CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_hnsw_nomic768 ON soulbah.knowledge_chunks USING hnsw ((embedding::vector(768)) vector_cosine_ops) WHERE embedding_model = 'nomic-embed-text-v1.5-q8_0';
CREATE INDEX IF NOT EXISTS idx_memory_items_hnsw_te3s ON soulbah.memory_items USING hnsw ((embedding::vector(1536)) vector_cosine_ops) WHERE embedding_dims = 1536;
CREATE INDEX IF NOT EXISTS idx_memory_items_hnsw_nomic768 ON soulbah.memory_items USING hnsw ((embedding::vector(768)) vector_cosine_ops) WHERE embedding_dims = 768;

-- 4. Réindexation contrôlée (§39) : ancien index → réindexation en arrière-plan → validation → bascule → nettoyage.
CREATE TABLE IF NOT EXISTS soulbah.knowledge_embedding_jobs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_id      uuid NOT NULL REFERENCES soulbah.embedding_models(id) ON DELETE CASCADE,
  target        text NOT NULL CONSTRAINT knowledge_embedding_jobs_target_check CHECK (target IN ('knowledge_chunks', 'memory_items')),
  status        text NOT NULL DEFAULT 'planned' CONSTRAINT knowledge_embedding_jobs_status_check
                CHECK (status IN ('planned', 'running', 'validating', 'switched', 'cleaned', 'failed', 'cancelled')),
  total_rows    integer NOT NULL DEFAULT 0 CONSTRAINT knowledge_embedding_jobs_total_positive CHECK (total_rows >= 0),
  done_rows     integer NOT NULL DEFAULT 0 CONSTRAINT knowledge_embedding_jobs_done_positive CHECK (done_rows >= 0),
  failed_rows   integer NOT NULL DEFAULT 0 CONSTRAINT knowledge_embedding_jobs_failed_positive CHECK (failed_rows >= 0),
  validation    jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT knowledge_embedding_jobs_validation_object CHECK (soulbah.is_json_object(validation)),
  error         text,
  started_at    timestamptz,
  finished_at   timestamptz,
  created_by    text NOT NULL DEFAULT current_user,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT knowledge_embedding_jobs_progress CHECK (done_rows + failed_rows <= total_rows OR total_rows = 0)
);
COMMENT ON TABLE soulbah.knowledge_embedding_jobs IS 'Réindexation vers un nouveau modèle d''embeddings, par lots avec reprise : jamais de bascule avant validation (Recall mesuré).';
ALTER TABLE soulbah.knowledge_embedding_jobs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_knowledge_embedding_jobs_model ON soulbah.knowledge_embedding_jobs (model_id, status);
DROP TRIGGER IF EXISTS knowledge_embedding_jobs_set_updated_at ON soulbah.knowledge_embedding_jobs;
CREATE TRIGGER knowledge_embedding_jobs_set_updated_at BEFORE UPDATE ON soulbah.knowledge_embedding_jobs FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON soulbah.knowledge_embedding_jobs FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.knowledge_embedding_jobs FROM %I', r);
    END IF;
  END LOOP;
END $$;


-- >>>>>>>>>> 20261002110800_db07_project_brain.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 7 — Project Brain : documents, composants logiques, relations typées entre nœuds, instantanés,
-- couverture mesurée, zones inconnues, décisions d'architecture, mémoire git.
-- soulbah:rollback=YES
-- soulbah:recovery=20261002110800_db07_project_brain.down.sql
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03. Les symboles de code sont au DB LOT 8 (code_symbols) : les relations du
-- Project Brain les référencent par (kind, id).
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.project_brain_documents (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id           uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  kind                 text NOT NULL CONSTRAINT project_brain_documents_kind_check
                       CHECK (kind IN ('architecture', 'module', 'decision', 'runbook', 'api', 'database', 'ui', 'flow', 'dependency', 'note', 'summary')),
  title                text NOT NULL CONSTRAINT project_brain_documents_title_length CHECK (length(title) BETWEEN 1 AND 300),
  path                 text CONSTRAINT project_brain_documents_path_length CHECK (path IS NULL OR length(path) <= 1000),
  content              text NOT NULL DEFAULT '' CONSTRAINT project_brain_documents_content_length CHECK (length(content) <= 60000),
  content_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  content_hash         text CONSTRAINT project_brain_documents_hash_format CHECK (content_hash IS NULL OR content_hash ~ '^[0-9a-f]{64}$'),
  source               text NOT NULL DEFAULT 'generated' CONSTRAINT project_brain_documents_source_check CHECK (source IN ('generated', 'imported', 'human')),
  generated_by         uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  confidence           real NOT NULL DEFAULT 0.5 CONSTRAINT project_brain_documents_confidence_range CHECK (confidence >= 0 AND confidence <= 1),
  status               text NOT NULL DEFAULT 'ACTIVE' CONSTRAINT project_brain_documents_status_check CHECK (status IN ('ACTIVE', 'STALE', 'SUPERSEDED', 'INVALID', 'ARCHIVED')),
  version              integer NOT NULL DEFAULT 1 CONSTRAINT project_brain_documents_version_positive CHECK (version >= 1),
  last_verified_at     timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_brain_documents_content_or_artifact CHECK (length(content) > 0 OR content_artifact_id IS NOT NULL)
);
COMMENT ON TABLE soulbah.project_brain_documents IS 'Connaissance technique structurée d''un projet (architecture, modules, décisions, API, base, UI, parcours) ; générée, importée ou humaine ; versionnée et datée.';
ALTER TABLE soulbah.project_brain_documents ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.project_brain_documents', '{"project_id": "uuid", "kind": "text", "status": "text", "version": "integer"}');
CREATE INDEX IF NOT EXISTS idx_project_brain_documents_project ON soulbah.project_brain_documents (project_id, kind, status);
CREATE UNIQUE INDEX IF NOT EXISTS idx_project_brain_documents_path ON soulbah.project_brain_documents (project_id, path) WHERE path IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_project_brain_documents_artifact ON soulbah.project_brain_documents (content_artifact_id);
CREATE INDEX IF NOT EXISTS idx_project_brain_documents_generated_by ON soulbah.project_brain_documents (generated_by);
DROP TRIGGER IF EXISTS project_brain_documents_set_updated_at ON soulbah.project_brain_documents;
CREATE TRIGGER project_brain_documents_set_updated_at BEFORE UPDATE ON soulbah.project_brain_documents FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.project_brain_components (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id    uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  component_id  uuid REFERENCES soulbah.project_components(id) ON DELETE SET NULL,
  key           text NOT NULL CONSTRAINT project_brain_components_key_format CHECK (key ~ '^[a-z0-9][a-z0-9_.-]{0,119}$'),
  name          text NOT NULL CONSTRAINT project_brain_components_name_length CHECK (length(name) BETWEEN 1 AND 200),
  kind          text NOT NULL CONSTRAINT project_brain_components_kind_check CHECK (kind IN ('domain', 'module', 'service', 'package', 'layer', 'external', 'other')),
  path          text CONSTRAINT project_brain_components_path_length CHECK (path IS NULL OR length(path) <= 1000),
  description   text NOT NULL DEFAULT '' CONSTRAINT project_brain_components_description_length CHECK (length(description) <= 4000),
  confidence    real NOT NULL DEFAULT 0.5 CONSTRAINT project_brain_components_confidence_range CHECK (confidence >= 0 AND confidence <= 1),
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_brain_components_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_brain_components_unique UNIQUE (project_id, key)
);
COMMENT ON TABLE soulbah.project_brain_components IS 'Composants logiques compris par Soulbah (domaines, modules, services) — la carte réelle des modules, vérifiée dans le code (§10-11).';
ALTER TABLE soulbah.project_brain_components ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_brain_components_component ON soulbah.project_brain_components (component_id);
DROP TRIGGER IF EXISTS project_brain_components_set_updated_at ON soulbah.project_brain_components;
CREATE TRIGGER project_brain_components_set_updated_at BEFORE UPDATE ON soulbah.project_brain_components FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.project_brain_relationships (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id  uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  from_kind   text NOT NULL CONSTRAINT project_brain_relationships_from_kind_check
              CHECK (from_kind IN ('document', 'component', 'file', 'symbol', 'table', 'endpoint', 'route', 'ui_component', 'flow', 'dependency', 'db_function')),
  from_id     uuid NOT NULL,
  to_kind     text NOT NULL CONSTRAINT project_brain_relationships_to_kind_check
              CHECK (to_kind IN ('document', 'component', 'file', 'symbol', 'table', 'endpoint', 'route', 'ui_component', 'flow', 'dependency', 'db_function')),
  to_id       uuid NOT NULL,
  kind        text NOT NULL CONSTRAINT project_brain_relationships_kind_check
              CHECK (kind IN ('uses', 'calls', 'imports', 'reads', 'writes', 'triggers', 'renders', 'navigates_to', 'depends_on', 'implements', 'documents', 'part_of', 'exposes', 'consumes')),
  weight      real NOT NULL DEFAULT 1 CONSTRAINT project_brain_relationships_weight_range CHECK (weight >= 0),
  evidence    jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_brain_relationships_evidence_object CHECK (soulbah.is_json_object(evidence)),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_brain_relationships_not_self CHECK (from_kind <> to_kind OR from_id <> to_id),
  CONSTRAINT project_brain_relationships_unique UNIQUE (from_kind, from_id, to_kind, to_id, kind)
);
COMMENT ON TABLE soulbah.project_brain_relationships IS 'Graphe de connaissance du projet : OrderService → calls → PaymentService → writes → transactions… (§5) ; base de l''analyse d''impact (§6).';
ALTER TABLE soulbah.project_brain_relationships ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_brain_relationships_to ON soulbah.project_brain_relationships (to_kind, to_id, kind);
CREATE INDEX IF NOT EXISTS idx_project_brain_relationships_project ON soulbah.project_brain_relationships (project_id);

CREATE TABLE IF NOT EXISTS soulbah.project_brain_snapshots (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id     uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  repository_id  uuid REFERENCES soulbah.project_repositories(id) ON DELETE SET NULL,
  app_commit     text,
  schema_hash    text CONSTRAINT project_brain_snapshots_hash_format CHECK (schema_hash IS NULL OR schema_hash ~ '^[0-9a-f]{64}$'),
  index_state    jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_brain_snapshots_index_object CHECK (soulbah.is_json_object(index_state)),
  coverage       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_brain_snapshots_coverage_object CHECK (soulbah.is_json_object(coverage)),
  stats          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_brain_snapshots_stats_object CHECK (soulbah.is_json_object(stats)),
  taken_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.project_brain_snapshots IS 'Instantanés du Project Brain (commit, empreinte, état de l''index, couverture, statistiques) pour comparer avant / après.';
ALTER TABLE soulbah.project_brain_snapshots ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_brain_snapshots_project ON soulbah.project_brain_snapshots (project_id, taken_at);
CREATE INDEX IF NOT EXISTS idx_project_brain_snapshots_repository ON soulbah.project_brain_snapshots (repository_id);

-- Couverture MESURÉE (§43 : jamais 100 % inventé) et zones inconnues (§44-45).
CREATE TABLE IF NOT EXISTS soulbah.project_brain_coverage (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id   uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  area         text NOT NULL CONSTRAINT project_brain_coverage_area_check CHECK (area IN ('code', 'database', 'api', 'ui', 'documentation', 'tests', 'flows', 'dependencies')),
  numerator    integer NOT NULL CONSTRAINT project_brain_coverage_numerator_positive CHECK (numerator >= 0),
  denominator  integer NOT NULL CONSTRAINT project_brain_coverage_denominator_positive CHECK (denominator >= 0),
  ratio        real GENERATED ALWAYS AS (CASE WHEN denominator = 0 THEN 0 ELSE least(1.0, numerator::real / denominator) END) STORED,
  method       text NOT NULL CONSTRAINT project_brain_coverage_method_length CHECK (length(method) BETWEEN 1 AND 500),
  snapshot_id  uuid REFERENCES soulbah.project_brain_snapshots(id) ON DELETE SET NULL,
  measured_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_brain_coverage_bounds CHECK (numerator <= denominator)
);
COMMENT ON TABLE soulbah.project_brain_coverage IS 'Couverture par domaine : numérateur / dénominateur mesurés et méthode (ex. fichiers indexés / fichiers du dépôt hors exclusions). Le ratio est calculé, jamais saisi.';
ALTER TABLE soulbah.project_brain_coverage ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_brain_coverage_project ON soulbah.project_brain_coverage (project_id, area, measured_at DESC);
CREATE INDEX IF NOT EXISTS idx_project_brain_coverage_snapshot ON soulbah.project_brain_coverage (snapshot_id);

CREATE TABLE IF NOT EXISTS soulbah.knowledge_gaps (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id   uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  kind         text NOT NULL CONSTRAINT knowledge_gaps_kind_check CHECK (kind IN (
                 'unindexed_file', 'table_without_relation', 'endpoint_without_consumer', 'module_without_tests',
                 'undocumented_code', 'unknown_module', 'stale_document', 'unresolved_dependency', 'other')),
  target_kind  text CONSTRAINT knowledge_gaps_target_kind_check CHECK (target_kind IS NULL OR target_kind IN ('file', 'symbol', 'table', 'endpoint', 'route', 'component', 'document', 'dependency')),
  target_id    uuid,
  target_ref   text CONSTRAINT knowledge_gaps_target_ref_length CHECK (target_ref IS NULL OR length(target_ref) <= 1000),
  severity     text NOT NULL DEFAULT 'LOW' CONSTRAINT knowledge_gaps_severity_check CHECK (soulbah.is_severity(severity)),
  status       text NOT NULL DEFAULT 'open' CONSTRAINT knowledge_gaps_status_check CHECK (status IN ('open', 'exploring', 'resolved', 'dismissed')),
  notes        text NOT NULL DEFAULT '' CONSTRAINT knowledge_gaps_notes_length CHECK (length(notes) <= 4000),
  detected_at  timestamptz NOT NULL DEFAULT now(),
  resolved_at  timestamptz,
  CONSTRAINT knowledge_gaps_target CHECK (target_id IS NOT NULL OR target_ref IS NOT NULL),
  CONSTRAINT knowledge_gaps_resolved_at CHECK (status NOT IN ('resolved', 'dismissed') OR resolved_at IS NOT NULL)
);
COMMENT ON TABLE soulbah.knowledge_gaps IS 'Zones mal comprises détectées par le KnowledgeGapDetector (§45) ; « je ne connais pas encore suffisamment ce module » — ouvrable en exploration (§46).';
ALTER TABLE soulbah.knowledge_gaps ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_knowledge_gaps_project_status ON soulbah.knowledge_gaps (project_id, status, severity);

-- Décisions d'architecture (§17) et mémoire git (§16).
CREATE TABLE IF NOT EXISTS soulbah.project_decisions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id     uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE CASCADE,
  title          text NOT NULL CONSTRAINT project_decisions_title_length CHECK (length(title) BETWEEN 1 AND 300),
  context        text NOT NULL DEFAULT '' CONSTRAINT project_decisions_context_length CHECK (length(context) <= 20000),
  decision       text NOT NULL CONSTRAINT project_decisions_decision_length CHECK (length(decision) BETWEEN 1 AND 20000),
  consequences   text NOT NULL DEFAULT '' CONSTRAINT project_decisions_consequences_length CHECK (length(consequences) <= 20000),
  status         text NOT NULL DEFAULT 'accepted' CONSTRAINT project_decisions_status_check CHECK (status IN ('proposed', 'accepted', 'superseded', 'deprecated')),
  supersedes_id  uuid REFERENCES soulbah.project_decisions(id) ON DELETE SET NULL,
  source         text NOT NULL DEFAULT 'human' CONSTRAINT project_decisions_source_check CHECK (source IN ('human', 'agent', 'imported')),
  decided_by     text NOT NULL DEFAULT current_user,
  decided_at     timestamptz NOT NULL DEFAULT now(),
  evidence       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT project_decisions_evidence_object CHECK (soulbah.is_json_object(evidence)),
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_decisions_not_self CHECK (supersedes_id IS NULL OR supersedes_id <> id)
);
COMMENT ON TABLE soulbah.project_decisions IS 'ArchitectureDecisionMemory : pourquoi Redis, pourquoi telle table, pourquoi telle règle de sécurité — avec contexte, décision, conséquences et remplacements.';
ALTER TABLE soulbah.project_decisions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_decisions_project ON soulbah.project_decisions (project_id, status);
CREATE INDEX IF NOT EXISTS idx_project_decisions_supersedes ON soulbah.project_decisions (supersedes_id);

CREATE TABLE IF NOT EXISTS soulbah.project_commits (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Journal en ajout seul : un projet ou un dépôt qui a des commits enregistrés ne se supprime pas (RESTRICT) ;
  -- il se désactive (authorized = false). session_id sans FK : les sessions V2 sont purgées, le journal survit.
  project_id     uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE RESTRICT,
  repository_id  uuid NOT NULL REFERENCES soulbah.project_repositories(id) ON DELETE RESTRICT,
  sha            text NOT NULL CONSTRAINT project_commits_sha_format CHECK (sha ~ '^[0-9a-f]{7,64}$'),
  author         text NOT NULL DEFAULT '' CONSTRAINT project_commits_author_length CHECK (length(author) <= 200),
  committed_at   timestamptz,
  message        text NOT NULL DEFAULT '' CONSTRAINT project_commits_message_length CHECK (length(message) <= 4000),
  files          jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT project_commits_files_array CHECK (soulbah.is_json_array(files)),
  reason         text CONSTRAINT project_commits_reason_length CHECK (reason IS NULL OR length(reason) <= 4000),
  tests_passed   boolean,
  incident_id    uuid,
  session_id     uuid,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_commits_unique UNIQUE (repository_id, sha)
);
COMMENT ON TABLE soulbah.project_commits IS 'Mémoire git : commits pertinents (fichiers, auteur, raison, tests, incident lié, mission) — « pourquoi ce code existe » ; ajout seul.';
ALTER TABLE soulbah.project_commits ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_project_commits_project ON soulbah.project_commits (project_id, committed_at DESC);
CREATE INDEX IF NOT EXISTS idx_project_commits_session ON soulbah.project_commits (session_id);
CREATE INDEX IF NOT EXISTS idx_project_commits_incident ON soulbah.project_commits (incident_id) WHERE incident_id IS NOT NULL;
DROP TRIGGER IF EXISTS project_commits_append_only ON soulbah.project_commits;
CREATE TRIGGER project_commits_append_only BEFORE DELETE ON soulbah.project_commits FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS project_commits_no_truncate ON soulbah.project_commits;
CREATE TRIGGER project_commits_no_truncate BEFORE TRUNCATE ON soulbah.project_commits FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

DO $$
DECLARE r text;
BEGIN
  REVOKE ALL ON soulbah.project_brain_documents, soulbah.project_brain_components, soulbah.project_brain_relationships,
    soulbah.project_brain_snapshots, soulbah.project_brain_coverage, soulbah.knowledge_gaps, soulbah.project_decisions,
    soulbah.project_commits FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON soulbah.project_brain_documents, soulbah.project_brain_components, soulbah.project_brain_relationships, '
                     'soulbah.project_brain_snapshots, soulbah.project_brain_coverage, soulbah.knowledge_gaps, soulbah.project_decisions, '
                     'soulbah.project_commits FROM %I', r);
    END IF;
  END LOOP;
END $$;


-- >>>>>>>>>> 20261002110900_db08_code_db_api_ui_intelligence.sql <<<<<<<<<<

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


-- >>>>>>>>>> 20261002111000_db09_skills_tools.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 9 — Skills Factory (REUSE + EXTEND soulbah.skills ; versions, étapes, prérequis, outils, tests, métriques,
-- candidats) et Tool Registry (outils, versions, permissions, santé, benchmarks ; constructeur d'outils : candidats,
-- builds, tests, revues de sécurité).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002111000_db09_skills_tools.down.sql (les colonnes ajoutées à soulbah.skills sont retirées)
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03, db04. Le registre des outils est synchronisé par node-api depuis
-- shared/tools/catalog.json (source unique) : aucune semence SQL.
-- =============================================================================

-- 1. Skills ---------------------------------------------------------------------------------------------
SELECT soulbah.assert_table_shape('soulbah.skills', '{"name": "text", "version": "text", "status": "text", "procedure": "jsonb", "source": "text"}');
ALTER TABLE soulbah.skills
  ADD COLUMN IF NOT EXISTS current_version_id uuid,
  ADD COLUMN IF NOT EXISTS category           text,
  ADD COLUMN IF NOT EXISTS description        text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS project_id         uuid REFERENCES soulbah.projects(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS risk_level         text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'skills_risk_level_check') THEN
    ALTER TABLE soulbah.skills ADD CONSTRAINT skills_risk_level_check CHECK (risk_level IS NULL OR soulbah.is_severity(risk_level));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'skills_description_length') THEN
    ALTER TABLE soulbah.skills ADD CONSTRAINT skills_description_length CHECK (length(description) <= 4000);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_skills_project ON soulbah.skills (project_id);
CREATE INDEX IF NOT EXISTS idx_skills_created_by ON soulbah.skills (created_by);

CREATE TABLE IF NOT EXISTS soulbah.skill_versions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  skill_id      uuid NOT NULL REFERENCES soulbah.skills(id) ON DELETE CASCADE,
  version       text NOT NULL CONSTRAINT skill_versions_semver CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  procedure     jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skill_versions_procedure_array CHECK (soulbah.is_json_array(procedure)),
  input_schema  jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT skill_versions_schema_object CHECK (soulbah.is_json_object(input_schema)),
  permissions   jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skill_versions_permissions_array CHECK (soulbah.is_json_array(permissions)),
  status        text NOT NULL DEFAULT 'candidate' CONSTRAINT skill_versions_status_check CHECK (status IN ('candidate', 'testing', 'validated', 'active', 'retired')),
  changelog     text NOT NULL DEFAULT '' CONSTRAINT skill_versions_changelog_length CHECK (length(changelog) <= 4000),
  created_by    text NOT NULL DEFAULT current_user,
  created_at    timestamptz NOT NULL DEFAULT now(),
  validated_by  text,
  validated_at  timestamptz,
  CONSTRAINT skill_versions_unique UNIQUE (skill_id, version),
  CONSTRAINT skill_versions_validated_author CHECK (status NOT IN ('validated', 'active') OR validated_by IS NOT NULL)
);
COMMENT ON TABLE soulbah.skill_versions IS 'Versions d''une compétence : procédure, schéma d''entrée, permissions ; active seulement après validation (§41, §68-69).';
ALTER TABLE soulbah.skill_versions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_skill_versions_status ON soulbah.skill_versions (skill_id, status);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'skills_current_version_fkey') THEN
    ALTER TABLE soulbah.skills ADD CONSTRAINT skills_current_version_fkey
      FOREIGN KEY (current_version_id) REFERENCES soulbah.skill_versions(id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_skills_current_version ON soulbah.skills (current_version_id);

CREATE TABLE IF NOT EXISTS soulbah.skill_steps (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id         uuid NOT NULL REFERENCES soulbah.skill_versions(id) ON DELETE CASCADE,
  position           integer NOT NULL CONSTRAINT skill_steps_position_positive CHECK (position >= 1),
  tool_name          text NOT NULL CONSTRAINT skill_steps_tool_format CHECK (tool_name ~ '^[a-z][a-z0-9_]{0,63}$'),
  params             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT skill_steps_params_object CHECK (soulbah.is_json_object(params)),
  condition          text CONSTRAINT skill_steps_condition_length CHECK (condition IS NULL OR length(condition) <= 1000),
  expected_evidence  jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skill_steps_evidence_array CHECK (soulbah.is_json_array(expected_evidence)),
  on_failure         text NOT NULL DEFAULT 'abort' CONSTRAINT skill_steps_on_failure_check CHECK (on_failure IN ('abort', 'retry', 'skip', 'escalate')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_steps_unique UNIQUE (version_id, position)
);
COMMENT ON TABLE soulbah.skill_steps IS 'Étapes ordonnées d''une version de compétence : outil, paramètres, condition, preuve attendue, conduite en cas d''échec.';
ALTER TABLE soulbah.skill_steps ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.skill_requirements (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id  uuid NOT NULL REFERENCES soulbah.skill_versions(id) ON DELETE CASCADE,
  kind        text NOT NULL CONSTRAINT skill_requirements_kind_check CHECK (kind IN ('tool', 'permission', 'capability', 'model', 'environment', 'project', 'os', 'network')),
  value       text NOT NULL CONSTRAINT skill_requirements_value_length CHECK (length(value) BETWEEN 1 AND 300),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_requirements_unique UNIQUE (version_id, kind, value)
);
COMMENT ON TABLE soulbah.skill_requirements IS 'Conditions d''emploi d''une compétence (outil, permission, capacité, modèle, environnement, projet, OS, réseau).';
ALTER TABLE soulbah.skill_requirements ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.skill_tools (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id  uuid NOT NULL REFERENCES soulbah.skill_versions(id) ON DELETE CASCADE,
  tool_name   text NOT NULL CONSTRAINT skill_tools_tool_format CHECK (tool_name ~ '^[a-z][a-z0-9_]{0,63}$'),
  required    boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_tools_unique UNIQUE (version_id, tool_name)
);
COMMENT ON TABLE soulbah.skill_tools IS 'Outils employés par une version de compétence.';
ALTER TABLE soulbah.skill_tools ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_skill_tools_tool ON soulbah.skill_tools (tool_name);

CREATE TABLE IF NOT EXISTS soulbah.skill_tests (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id    uuid NOT NULL REFERENCES soulbah.skill_versions(id) ON DELETE CASCADE,
  name          text NOT NULL CONSTRAINT skill_tests_name_length CHECK (length(name) BETWEEN 1 AND 200),
  kind          text NOT NULL DEFAULT 'integration' CONSTRAINT skill_tests_kind_check CHECK (kind IN ('unit', 'integration', 'golden', 'security', 'regression')),
  spec          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT skill_tests_spec_object CHECK (soulbah.is_json_object(spec)),
  last_result   text NOT NULL DEFAULT 'unknown' CONSTRAINT skill_tests_result_check CHECK (last_result IN ('unknown', 'passed', 'failed')),
  last_run_at   timestamptz,
  evidence_ids  jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skill_tests_evidence_array CHECK (soulbah.is_json_array(evidence_ids)),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_tests_unique UNIQUE (version_id, name)
);
COMMENT ON TABLE soulbah.skill_tests IS 'Tests d''une compétence et dernier résultat avec preuves.';
ALTER TABLE soulbah.skill_tests ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.skill_metrics (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  skill_id             uuid NOT NULL REFERENCES soulbah.skills(id) ON DELETE CASCADE,
  period_start         timestamptz NOT NULL,
  period_end           timestamptz NOT NULL,
  runs                 integer NOT NULL DEFAULT 0,
  successes            integer NOT NULL DEFAULT 0,
  failures             integer NOT NULL DEFAULT 0,
  avg_duration_ms      integer,
  human_interventions  integer NOT NULL DEFAULT 0,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_metrics_period CHECK (period_end > period_start),
  CONSTRAINT skill_metrics_unique UNIQUE (skill_id, period_start, period_end)
);
COMMENT ON TABLE soulbah.skill_metrics IS 'Mesures d''usage et de réussite d''une compétence par période.';
ALTER TABLE soulbah.skill_metrics ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.skill_candidates (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                 text NOT NULL CONSTRAINT skill_candidates_name_format CHECK (name ~ '^[a-z][a-z0-9_]{0,99}$'),
  source               text NOT NULL CONSTRAINT skill_candidates_source_check CHECK (source IN ('agent_learning', 'failure_analysis', 'human', 'research', 'imported')),
  proposed_by          uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  project_id           uuid REFERENCES soulbah.projects(id) ON DELETE SET NULL,
  procedure            jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skill_candidates_procedure_array CHECK (soulbah.is_json_array(procedure)),
  evidence             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT skill_candidates_evidence_object CHECK (soulbah.is_json_object(evidence)),
  tests_required       jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT skill_candidates_tests_array CHECK (soulbah.is_json_array(tests_required)),
  status               text NOT NULL DEFAULT 'proposed' CONSTRAINT skill_candidates_status_check CHECK (status IN ('proposed', 'testing', 'validated', 'promoted', 'rejected')),
  promoted_skill_id    uuid REFERENCES soulbah.skills(id) ON DELETE SET NULL,
  promoted_version_id  uuid REFERENCES soulbah.skill_versions(id) ON DELETE SET NULL,
  decided_by           text,
  decided_at           timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT skill_candidates_promoted CHECK (status <> 'promoted' OR (promoted_skill_id IS NOT NULL AND promoted_version_id IS NOT NULL)),
  CONSTRAINT skill_candidates_decided CHECK (status IN ('proposed', 'testing') OR (decided_by IS NOT NULL AND decided_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.skill_candidates IS 'Procédures candidates : jamais directement dans les compétences validées — candidate → tests → validation → promotion (§41, §69).';
ALTER TABLE soulbah.skill_candidates ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_skill_candidates_status ON soulbah.skill_candidates (status);
CREATE INDEX IF NOT EXISTS idx_skill_candidates_proposed_by ON soulbah.skill_candidates (proposed_by);
CREATE INDEX IF NOT EXISTS idx_skill_candidates_project ON soulbah.skill_candidates (project_id);
CREATE INDEX IF NOT EXISTS idx_skill_candidates_promoted_skill ON soulbah.skill_candidates (promoted_skill_id);
CREATE INDEX IF NOT EXISTS idx_skill_candidates_promoted_version ON soulbah.skill_candidates (promoted_version_id);

-- 2. Tool Registry ------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.tools (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text NOT NULL UNIQUE CONSTRAINT tools_name_format CHECK (name ~ '^[a-z][a-z0-9_]{0,63}$'),
  category         text NOT NULL CONSTRAINT tools_category_format CHECK (category ~ '^[a-z_]{1,40}$'),
  security_level   text NOT NULL CONSTRAINT tools_level_check CHECK (soulbah.is_security_level(security_level)),
  permission       text REFERENCES soulbah.permission_definitions(name) ON DELETE SET NULL,
  description      text NOT NULL DEFAULT '' CONSTRAINT tools_description_length CHECK (length(description) <= 2000),
  current_version  text,
  status           text NOT NULL DEFAULT 'active' CONSTRAINT tools_status_check CHECK (status IN ('active', 'deprecated', 'disabled', 'quarantined')),
  offline_ok       boolean NOT NULL DEFAULT true,
  source           text NOT NULL DEFAULT 'catalog' CONSTRAINT tools_source_check CHECK (source IN ('catalog', 'built')),
  manifest         jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT tools_manifest_object CHECK (soulbah.is_json_object(manifest)),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.tools IS 'Registre des outils : synchronisé depuis shared/tools/catalog.json (source unique) ; permission nommée, niveau, statut (quarantaine possible).';
ALTER TABLE soulbah.tools ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.tools', '{"name": "text", "security_level": "text", "status": "text", "manifest": "jsonb"}');
CREATE INDEX IF NOT EXISTS idx_tools_permission ON soulbah.tools (permission);
DROP TRIGGER IF EXISTS tools_set_updated_at ON soulbah.tools;
CREATE TRIGGER tools_set_updated_at BEFORE UPDATE ON soulbah.tools FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.tool_versions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tool_id     uuid NOT NULL REFERENCES soulbah.tools(id) ON DELETE CASCADE,
  version     text NOT NULL CONSTRAINT tool_versions_version_length CHECK (length(version) BETWEEN 1 AND 50),
  manifest    jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT tool_versions_manifest_object CHECK (soulbah.is_json_object(manifest)),
  checksum    text CONSTRAINT tool_versions_checksum_format CHECK (checksum IS NULL OR checksum ~ '^[0-9a-f]{64}$'),
  status      text NOT NULL DEFAULT 'active' CONSTRAINT tool_versions_status_check CHECK (status IN ('draft', 'active', 'retired')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tool_versions_unique UNIQUE (tool_id, version)
);
COMMENT ON TABLE soulbah.tool_versions IS 'Versions d''un outil (manifeste, empreinte).';
ALTER TABLE soulbah.tool_versions ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.tool_permissions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tool_id           uuid NOT NULL REFERENCES soulbah.tools(id) ON DELETE CASCADE,
  permission        text NOT NULL REFERENCES soulbah.permission_definitions(name) ON DELETE CASCADE,
  environment_name  text REFERENCES soulbah.environments(name),
  decision          text NOT NULL CONSTRAINT tool_permissions_decision_check CHECK (decision IN ('allow', 'deny', 'approval')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tool_permissions_unique UNIQUE NULLS NOT DISTINCT (tool_id, permission, environment_name)
);
COMMENT ON TABLE soulbah.tool_permissions IS 'Permissions exigées ou refusées par outil et environnement (passerelle d''outils, §39).';
ALTER TABLE soulbah.tool_permissions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_tool_permissions_permission ON soulbah.tool_permissions (permission);
CREATE INDEX IF NOT EXISTS idx_tool_permissions_env ON soulbah.tool_permissions (environment_name);

CREATE TABLE IF NOT EXISTS soulbah.tool_health (
  tool_id            uuid PRIMARY KEY REFERENCES soulbah.tools(id) ON DELETE CASCADE,
  status             text NOT NULL DEFAULT 'unknown' CONSTRAINT tool_health_status_check CHECK (status IN ('healthy', 'degraded', 'failing', 'unknown')),
  last_success_at    timestamptz,
  last_failure_at    timestamptz,
  failure_count_24h  integer NOT NULL DEFAULT 0 CONSTRAINT tool_health_failures_positive CHECK (failure_count_24h >= 0),
  avg_latency_ms     integer,
  detail             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT tool_health_detail_object CHECK (soulbah.is_json_object(detail)),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.tool_health IS 'Santé courante de chaque outil (succès, échecs récents, latence).';
ALTER TABLE soulbah.tool_health ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS tool_health_set_updated_at ON soulbah.tool_health;
CREATE TRIGGER tool_health_set_updated_at BEFORE UPDATE ON soulbah.tool_health FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.tool_benchmarks (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tool_id           uuid NOT NULL REFERENCES soulbah.tools(id) ON DELETE CASCADE,
  benchmark_run_id  uuid,
  metric            text NOT NULL CONSTRAINT tool_benchmarks_metric_format CHECK (metric ~ '^[a-z][a-z0-9_.]{0,99}$'),
  value             numeric(18, 6) NOT NULL,
  unit              text NOT NULL DEFAULT '' CONSTRAINT tool_benchmarks_unit_length CHECK (length(unit) <= 40),
  measured_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.tool_benchmarks IS 'Mesures d''un outil (latence, fiabilité, coût) ; benchmark_run_id renvoie aux exécutions du DB LOT 10.';
ALTER TABLE soulbah.tool_benchmarks ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_tool_benchmarks_tool ON soulbah.tool_benchmarks (tool_id, metric, measured_at DESC);

-- 3. Constructeur d'outils (§43 mission Control Center) ------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.tool_candidates (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name              text NOT NULL CONSTRAINT tool_candidates_name_format CHECK (name ~ '^[a-z][a-z0-9_]{0,63}$'),
  purpose           text NOT NULL CONSTRAINT tool_candidates_purpose_length CHECK (length(purpose) BETWEEN 1 AND 4000),
  proposed_by       uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  spec              jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT tool_candidates_spec_object CHECK (soulbah.is_json_object(spec)),
  status            text NOT NULL DEFAULT 'proposed' CONSTRAINT tool_candidates_status_check
                    CHECK (status IN ('proposed', 'building', 'testing', 'security_review', 'approved', 'rejected', 'promoted')),
  promoted_tool_id  uuid REFERENCES soulbah.tools(id) ON DELETE SET NULL,
  decided_by        text,
  decided_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tool_candidates_promoted CHECK (status <> 'promoted' OR promoted_tool_id IS NOT NULL),
  CONSTRAINT tool_candidates_decided CHECK (status NOT IN ('approved', 'rejected', 'promoted') OR (decided_by IS NOT NULL AND decided_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.tool_candidates IS 'Outils proposés par les agents ou le PDG : construction, tests, revue de sécurité, décision humaine avant promotion.';
ALTER TABLE soulbah.tool_candidates ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_tool_candidates_status ON soulbah.tool_candidates (status);
CREATE INDEX IF NOT EXISTS idx_tool_candidates_proposed_by ON soulbah.tool_candidates (proposed_by);
CREATE INDEX IF NOT EXISTS idx_tool_candidates_promoted ON soulbah.tool_candidates (promoted_tool_id);

CREATE TABLE IF NOT EXISTS soulbah.tool_builds (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id           uuid NOT NULL REFERENCES soulbah.tool_candidates(id) ON DELETE CASCADE,
  version                text NOT NULL CONSTRAINT tool_builds_version_length CHECK (length(version) BETWEEN 1 AND 50),
  artifact_id            uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  build_log_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  status                 text NOT NULL DEFAULT 'pending' CONSTRAINT tool_builds_status_check CHECK (status IN ('pending', 'running', 'succeeded', 'failed')),
  error                  text,
  started_at             timestamptz,
  finished_at            timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tool_builds_unique UNIQUE (candidate_id, version)
);
COMMENT ON TABLE soulbah.tool_builds IS 'Constructions d''un outil candidat (artefact produit, journal), en sandbox.';
ALTER TABLE soulbah.tool_builds ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_tool_builds_artifact ON soulbah.tool_builds (artifact_id);
CREATE INDEX IF NOT EXISTS idx_tool_builds_log ON soulbah.tool_builds (build_log_artifact_id);

CREATE TABLE IF NOT EXISTS soulbah.tool_tests (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  build_id      uuid NOT NULL REFERENCES soulbah.tool_builds(id) ON DELETE CASCADE,
  name          text NOT NULL CONSTRAINT tool_tests_name_length CHECK (length(name) BETWEEN 1 AND 200),
  kind          text NOT NULL DEFAULT 'sandbox' CONSTRAINT tool_tests_kind_check CHECK (kind IN ('unit', 'integration', 'security', 'sandbox')),
  status        text NOT NULL DEFAULT 'pending' CONSTRAINT tool_tests_status_check CHECK (status IN ('pending', 'passed', 'failed')),
  evidence_ids  jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT tool_tests_evidence_array CHECK (soulbah.is_json_array(evidence_ids)),
  created_at    timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz,
  CONSTRAINT tool_tests_unique UNIQUE (build_id, name)
);
COMMENT ON TABLE soulbah.tool_tests IS 'Tests d''une construction d''outil, avec preuves.';
ALTER TABLE soulbah.tool_tests ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.tool_security_reviews (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  build_id       uuid NOT NULL REFERENCES soulbah.tool_builds(id) ON DELETE RESTRICT,
  reviewer_type  text NOT NULL CONSTRAINT tool_security_reviews_reviewer_type_check CHECK (reviewer_type IN ('agent', 'human')),
  reviewer_id    text NOT NULL CONSTRAINT tool_security_reviews_reviewer_id_length CHECK (length(reviewer_id) BETWEEN 1 AND 200),
  verdict        text NOT NULL CONSTRAINT tool_security_reviews_verdict_check CHECK (verdict IN ('approved', 'rejected', 'changes_requested')),
  findings       jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT tool_security_reviews_findings_array CHECK (soulbah.is_json_array(findings)),
  created_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.tool_security_reviews IS 'Revues de sécurité d''une construction d''outil (ajout seul) ; une revue humaine est exigée avant promotion.';
ALTER TABLE soulbah.tool_security_reviews ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_tool_security_reviews_build ON soulbah.tool_security_reviews (build_id);
DROP TRIGGER IF EXISTS tool_security_reviews_append_only ON soulbah.tool_security_reviews;
CREATE TRIGGER tool_security_reviews_append_only BEFORE UPDATE OR DELETE ON soulbah.tool_security_reviews FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS tool_security_reviews_no_truncate ON soulbah.tool_security_reviews;
CREATE TRIGGER tool_security_reviews_no_truncate BEFORE TRUNCATE ON soulbah.tool_security_reviews FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

-- Promotion d'un candidat : exige un build réussi, ses tests passés et une revue de sécurité humaine approuvée.
CREATE OR REPLACE FUNCTION soulbah.tool_candidates_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.status = 'promoted' AND (TG_OP = 'INSERT' OR OLD.status <> 'promoted') THEN
    IF NOT EXISTS (
      SELECT 1 FROM soulbah.tool_builds b
       WHERE b.candidate_id = NEW.id AND b.status = 'succeeded'
         AND EXISTS (SELECT 1 FROM soulbah.tool_tests t WHERE t.build_id = b.id)
         AND NOT EXISTS (SELECT 1 FROM soulbah.tool_tests t WHERE t.build_id = b.id AND t.status <> 'passed')
         AND EXISTS (SELECT 1 FROM soulbah.tool_security_reviews r WHERE r.build_id = b.id AND r.reviewer_type = 'human' AND r.verdict = 'approved')) THEN
      RAISE EXCEPTION 'soulbah.tool_candidates : promotion refusée — il faut un build réussi, tous ses tests passés et une revue de sécurité humaine approuvée'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS tool_candidates_guard ON soulbah.tool_candidates;
CREATE TRIGGER tool_candidates_guard BEFORE INSERT OR UPDATE ON soulbah.tool_candidates FOR EACH ROW EXECUTE FUNCTION soulbah.tool_candidates_guard();

-- Même règle pour les compétences : une version ne devient active qu'avec au moins un test passé.
CREATE OR REPLACE FUNCTION soulbah.skill_versions_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.status = 'active' AND (TG_OP = 'INSERT' OR OLD.status <> 'active') THEN
    IF NOT EXISTS (SELECT 1 FROM soulbah.skill_tests t WHERE t.version_id = NEW.id AND t.last_result = 'passed')
       OR EXISTS (SELECT 1 FROM soulbah.skill_tests t WHERE t.version_id = NEW.id AND t.last_result = 'failed') THEN
      RAISE EXCEPTION 'soulbah.skill_versions : activation refusée — au moins un test passé et aucun test en échec'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS skill_versions_guard ON soulbah.skill_versions;
CREATE TRIGGER skill_versions_guard BEFORE INSERT OR UPDATE ON soulbah.skill_versions FOR EACH ROW EXECUTE FUNCTION soulbah.skill_versions_guard();

DO $$
DECLARE r text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['skill_versions', 'skill_steps', 'skill_requirements', 'skill_tools', 'skill_tests', 'skill_metrics', 'skill_candidates',
                           'tools', 'tool_versions', 'tool_permissions', 'tool_health', 'tool_benchmarks', 'tool_candidates', 'tool_builds',
                           'tool_tests', 'tool_security_reviews'] LOOP
    EXECUTE format('REVOKE ALL ON soulbah.%I FROM PUBLIC', t);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON soulbah.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.tool_candidates_guard(), soulbah.skill_versions_guard() FROM %I', r);
    END IF;
  END LOOP;
END $$;


-- >>>>>>>>>> 20261002111100_db10_models_benchmarks.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 10 — Modèles, benchmarks, jeux de données, entraînement (Intelligence Lab).
-- Registre des modèles (métadonnées : le fichier reste dans %LOCALAPPDATA%\Soulbah\models), versions, matériel,
-- statut de sécurité, capacités mesurées, règles et historique de routage, compétitions champion/challenger,
-- candidats (téléchargement toujours approuvé par un humain), mode ombre, benchmarks versionnés et gelés, tâches
-- de référence, jeux de données, configurations et exécutions d'entraînement (toujours approuvées).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002111100_db10_models_benchmarks.down.sql (les mesures seraient perdues : réexportables depuis le registre local)
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03, db06 (embedding_models), db09 (tool_benchmarks).
-- =============================================================================

-- 1. Modèles --------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.models (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL UNIQUE CONSTRAINT models_name_format CHECK (name ~ '^[a-z0-9][a-z0-9._-]{0,119}$'),
  display_name  text NOT NULL CONSTRAINT models_display_length CHECK (length(display_name) BETWEEN 1 AND 200),
  family        text NOT NULL CONSTRAINT models_family_length CHECK (length(family) BETWEEN 1 AND 100),
  kind          text NOT NULL CONSTRAINT models_kind_check CHECK (kind IN ('llm', 'embedding', 'reranker', 'vision', 'audio', 'classifier', 'other')),
  provider      text NOT NULL CONSTRAINT models_provider_check CHECK (provider IN ('local', 'cloud')),
  vendor        text CONSTRAINT models_vendor_length CHECK (vendor IS NULL OR length(vendor) <= 100),
  license       text CONSTRAINT models_license_length CHECK (license IS NULL OR length(license) <= 100),
  license_url   text CONSTRAINT models_license_url_length CHECK (license_url IS NULL OR length(license_url) <= 500),
  status        text NOT NULL DEFAULT 'candidate' CONSTRAINT models_status_check CHECK (status IN ('candidate', 'active', 'deprecated', 'retired', 'quarantined')),
  description   text NOT NULL DEFAULT '' CONSTRAINT models_description_length CHECK (length(description) <= 2000),
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT models_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.models IS 'Registre des modèles (métadonnées) : famille, genre, fournisseur local/cloud, licence, statut. Les fichiers restent dans le registre local.';
ALTER TABLE soulbah.models ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.models', '{"name": "text", "kind": "text", "provider": "text", "status": "text"}');
DROP TRIGGER IF EXISTS models_set_updated_at ON soulbah.models;
CREATE TRIGGER models_set_updated_at BEFORE UPDATE ON soulbah.models FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.model_versions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_id           uuid NOT NULL REFERENCES soulbah.models(id) ON DELETE CASCADE,
  version            text NOT NULL CONSTRAINT model_versions_version_length CHECK (length(version) BETWEEN 1 AND 100),
  registry_key       text UNIQUE CONSTRAINT model_versions_registry_key_length CHECK (registry_key IS NULL OR length(registry_key) <= 200),
  file_name          text CONSTRAINT model_versions_file_name_length CHECK (file_name IS NULL OR length(file_name) <= 300),
  sha256             text CONSTRAINT model_versions_sha256_format CHECK (sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes         bigint CONSTRAINT model_versions_size_positive CHECK (size_bytes IS NULL OR size_bytes >= 0),
  quantization       text CONSTRAINT model_versions_quant_length CHECK (quantization IS NULL OR length(quantization) <= 40),
  context_length     integer CONSTRAINT model_versions_context_positive CHECK (context_length IS NULL OR context_length > 0),
  parameters_b       numeric(8, 3) CONSTRAINT model_versions_params_positive CHECK (parameters_b IS NULL OR parameters_b > 0),
  runtime            text CONSTRAINT model_versions_runtime_length CHECK (runtime IS NULL OR length(runtime) <= 60),
  source_kind        text CONSTRAINT model_versions_source_kind_check CHECK (source_kind IS NULL OR source_kind IN ('huggingface', 'vendor_api', 'training', 'import', 'other')),
  source_ref         text CONSTRAINT model_versions_source_ref_length CHECK (source_ref IS NULL OR length(source_ref) <= 500),
  source_revision    text CONSTRAINT model_versions_source_rev_length CHECK (source_revision IS NULL OR length(source_revision) <= 120),
  status             text NOT NULL DEFAULT 'candidate' CONSTRAINT model_versions_status_check CHECK (status IN ('candidate', 'validated', 'active', 'shadow', 'retired')),
  installed          boolean NOT NULL DEFAULT false,
  installed_at       timestamptz,
  metadata           jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT model_versions_metadata_object CHECK (soulbah.is_json_object(metadata)),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_versions_unique UNIQUE (model_id, version)
);
COMMENT ON TABLE soulbah.model_versions IS 'Versions concrètes (fichier, empreinte, quantification, contexte, source épinglée) ; active seulement après statut de sécurité approuvé (trigger).';
ALTER TABLE soulbah.model_versions ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.model_versions', '{"model_id": "uuid", "sha256": "text", "status": "text", "installed": "boolean"}');
CREATE INDEX IF NOT EXISTS idx_model_versions_status ON soulbah.model_versions (model_id, status);
DROP TRIGGER IF EXISTS model_versions_set_updated_at ON soulbah.model_versions;
CREATE TRIGGER model_versions_set_updated_at BEFORE UPDATE ON soulbah.model_versions FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.model_hardware_requirements (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id           uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE CASCADE,
  profile              text NOT NULL DEFAULT 'cpu' CONSTRAINT model_hardware_profile_check CHECK (profile IN ('cpu', 'gpu', 'hybrid')),
  min_ram_mb           integer CONSTRAINT model_hardware_ram_positive CHECK (min_ram_mb IS NULL OR min_ram_mb >= 0),
  min_vram_mb          integer CONSTRAINT model_hardware_vram_positive CHECK (min_vram_mb IS NULL OR min_vram_mb >= 0),
  cpu_threads          integer CONSTRAINT model_hardware_threads_positive CHECK (cpu_threads IS NULL OR cpu_threads > 0),
  disk_mb              integer CONSTRAINT model_hardware_disk_positive CHECK (disk_mb IS NULL OR disk_mb >= 0),
  measured             boolean NOT NULL DEFAULT false,
  measured_tokens_per_s real CONSTRAINT model_hardware_tps_positive CHECK (measured_tokens_per_s IS NULL OR measured_tokens_per_s >= 0),
  measured_on          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT model_hardware_measured_on_object CHECK (soulbah.is_json_object(measured_on)),
  notes                text NOT NULL DEFAULT '' CONSTRAINT model_hardware_notes_length CHECK (length(notes) <= 2000),
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_hardware_requirements_unique UNIQUE (version_id, profile)
);
COMMENT ON TABLE soulbah.model_hardware_requirements IS 'Besoins matériels par version et profil (déclarés ou mesurés : RAM, VRAM, threads, débit) — pour choisir ce qui tourne sur la machine réelle.';
ALTER TABLE soulbah.model_hardware_requirements ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.model_security_status (
  version_id         uuid PRIMARY KEY REFERENCES soulbah.model_versions(id) ON DELETE CASCADE,
  status             text NOT NULL DEFAULT 'unknown' CONSTRAINT model_security_status_check CHECK (status IN ('unknown', 'checked', 'approved', 'rejected', 'quarantined')),
  checksum_verified  boolean,
  source_verified    boolean,
  license_ok         boolean,
  findings           jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT model_security_findings_array CHECK (soulbah.is_json_array(findings)),
  checked_by         text,
  checked_at         timestamptz,
  approved_by        text,
  approved_at        timestamptz,
  notes              text NOT NULL DEFAULT '' CONSTRAINT model_security_notes_length CHECK (length(notes) <= 4000),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_security_approved_by_human CHECK (status <> 'approved' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL AND checksum_verified IS TRUE AND license_ok IS TRUE))
);
COMMENT ON TABLE soulbah.model_security_status IS 'Statut de sécurité d''une version : empreinte, source et licence vérifiées, constats ; approved exige un approbateur humain, l''empreinte et la licence vérifiées.';
ALTER TABLE soulbah.model_security_status ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS model_security_status_set_updated_at ON soulbah.model_security_status;
CREATE TRIGGER model_security_status_set_updated_at BEFORE UPDATE ON soulbah.model_security_status FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- Une version ne devient active (ou ombre) qu'avec un statut de sécurité approuvé et une empreinte connue.
CREATE OR REPLACE FUNCTION soulbah.model_versions_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.status IN ('active', 'shadow') AND (TG_OP = 'INSERT' OR OLD.status NOT IN ('active', 'shadow')) THEN
    IF NEW.sha256 IS NULL AND NEW.source_kind <> 'vendor_api' THEN
      RAISE EXCEPTION 'soulbah.model_versions : activation refusée — empreinte SHA-256 absente' USING ERRCODE = 'check_violation';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM soulbah.model_security_status s WHERE s.version_id = NEW.id AND s.status = 'approved') THEN
      RAISE EXCEPTION 'soulbah.model_versions : activation refusée — statut de sécurité non approuvé' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS model_versions_guard ON soulbah.model_versions;
CREATE TRIGGER model_versions_guard BEFORE INSERT OR UPDATE ON soulbah.model_versions FOR EACH ROW EXECUTE FUNCTION soulbah.model_versions_guard();

-- 2. Benchmarks et tâches de référence -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.benchmarks (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                text NOT NULL UNIQUE CONSTRAINT benchmarks_name_format CHECK (name ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  domain              text NOT NULL CONSTRAINT benchmarks_domain_check CHECK (domain IN (
                        'reasoning', 'planning', 'code', 'code_review', 'sql', 'security', 'documentation', 'french', 'tools', 'memory', 'ui', 'embedding', 'mixed')),
  description         text NOT NULL DEFAULT '' CONSTRAINT benchmarks_description_length CHECK (length(description) <= 2000),
  current_version_id  uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.benchmarks IS 'Suites d''évaluation internes, par domaine ; chaque version est gelée pour que deux exécutions soient comparables.';
ALTER TABLE soulbah.benchmarks ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS benchmarks_set_updated_at ON soulbah.benchmarks;
CREATE TRIGGER benchmarks_set_updated_at BEFORE UPDATE ON soulbah.benchmarks FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.benchmark_versions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  benchmark_id  uuid NOT NULL REFERENCES soulbah.benchmarks(id) ON DELETE CASCADE,
  version       integer NOT NULL CONSTRAINT benchmark_versions_version_positive CHECK (version >= 1),
  spec          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT benchmark_versions_spec_object CHECK (soulbah.is_json_object(spec)),
  frozen        boolean NOT NULL DEFAULT false,
  checksum      text CONSTRAINT benchmark_versions_checksum_format CHECK (checksum IS NULL OR checksum ~ '^[0-9a-f]{64}$'),
  created_at    timestamptz NOT NULL DEFAULT now(),
  frozen_at     timestamptz,
  CONSTRAINT benchmark_versions_unique UNIQUE (benchmark_id, version),
  CONSTRAINT benchmark_versions_frozen_dated CHECK (NOT frozen OR frozen_at IS NOT NULL)
);
COMMENT ON TABLE soulbah.benchmark_versions IS 'Versions d''un benchmark ; une version gelée ne change plus (ses tâches non plus).';
ALTER TABLE soulbah.benchmark_versions ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'benchmarks_current_version_fkey') THEN
    ALTER TABLE soulbah.benchmarks ADD CONSTRAINT benchmarks_current_version_fkey
      FOREIGN KEY (current_version_id) REFERENCES soulbah.benchmark_versions(id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_benchmarks_current_version ON soulbah.benchmarks (current_version_id);

CREATE TABLE IF NOT EXISTS soulbah.golden_tasks (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key          text NOT NULL UNIQUE CONSTRAINT golden_tasks_key_format CHECK (key ~ '^[a-z][a-z0-9_.-]{0,119}$'),
  domain       text NOT NULL CONSTRAINT golden_tasks_domain_length CHECK (length(domain) BETWEEN 1 AND 60),
  project_id   uuid REFERENCES soulbah.projects(id) ON DELETE SET NULL,
  description  text NOT NULL CONSTRAINT golden_tasks_description_length CHECK (length(description) BETWEEN 1 AND 4000),
  input        jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT golden_tasks_input_object CHECK (soulbah.is_json_object(input)),
  difficulty   text NOT NULL DEFAULT 'medium' CONSTRAINT golden_tasks_difficulty_check CHECK (difficulty IN ('easy', 'medium', 'hard')),
  status       text NOT NULL DEFAULT 'draft' CONSTRAINT golden_tasks_status_check CHECK (status IN ('draft', 'active', 'retired')),
  created_by   text NOT NULL DEFAULT current_user,
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.golden_tasks IS 'Tâches de référence (réelles, issues des projets ou des incidents) servant d''étalon aux benchmarks et aux régressions.';
ALTER TABLE soulbah.golden_tasks ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_golden_tasks_project ON soulbah.golden_tasks (project_id);

CREATE TABLE IF NOT EXISTS soulbah.golden_task_expected_results (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  golden_task_id  uuid NOT NULL REFERENCES soulbah.golden_tasks(id) ON DELETE CASCADE,
  version         integer NOT NULL DEFAULT 1 CONSTRAINT golden_expected_version_positive CHECK (version >= 1),
  expected        jsonb NOT NULL CONSTRAINT golden_expected_object CHECK (soulbah.is_json_object(expected)),
  scoring         text NOT NULL DEFAULT 'exact' CONSTRAINT golden_expected_scoring_check CHECK (scoring IN ('exact', 'contains', 'json_schema', 'test_suite', 'rubric', 'human')),
  validated_by    text,
  validated_at    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT golden_task_expected_results_unique UNIQUE (golden_task_id, version)
);
COMMENT ON TABLE soulbah.golden_task_expected_results IS 'Résultat attendu versionné d''une tâche de référence et méthode de notation.';
ALTER TABLE soulbah.golden_task_expected_results ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.benchmark_tasks (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  benchmark_version_id  uuid NOT NULL REFERENCES soulbah.benchmark_versions(id) ON DELETE CASCADE,
  key                   text NOT NULL CONSTRAINT benchmark_tasks_key_format CHECK (key ~ '^[a-z][a-z0-9_.-]{0,119}$'),
  golden_task_id        uuid REFERENCES soulbah.golden_tasks(id) ON DELETE SET NULL,
  input                 jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT benchmark_tasks_input_object CHECK (soulbah.is_json_object(input)),
  expected              jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT benchmark_tasks_expected_object CHECK (soulbah.is_json_object(expected)),
  scoring               text NOT NULL DEFAULT 'exact' CONSTRAINT benchmark_tasks_scoring_check CHECK (scoring IN ('exact', 'contains', 'json_schema', 'test_suite', 'rubric', 'human')),
  weight                numeric(6, 3) NOT NULL DEFAULT 1 CONSTRAINT benchmark_tasks_weight_positive CHECK (weight > 0),
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT benchmark_tasks_unique UNIQUE (benchmark_version_id, key)
);
COMMENT ON TABLE soulbah.benchmark_tasks IS 'Tâches d''une version de benchmark (entrée, attendu, notation, poids).';
ALTER TABLE soulbah.benchmark_tasks ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_benchmark_tasks_golden ON soulbah.benchmark_tasks (golden_task_id);

-- Les tâches d'une version gelée ne changent plus.
CREATE OR REPLACE FUNCTION soulbah.benchmark_tasks_freeze()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
DECLARE v uuid;
BEGIN
  v := COALESCE(NEW.benchmark_version_id, OLD.benchmark_version_id);
  IF EXISTS (SELECT 1 FROM soulbah.benchmark_versions b WHERE b.id = v AND b.frozen) THEN
    RAISE EXCEPTION 'soulbah.benchmark_tasks : version de benchmark gelée — % refusé', TG_OP USING ERRCODE = 'check_violation';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
DROP TRIGGER IF EXISTS benchmark_tasks_freeze ON soulbah.benchmark_tasks;
CREATE TRIGGER benchmark_tasks_freeze BEFORE INSERT OR UPDATE OR DELETE ON soulbah.benchmark_tasks FOR EACH ROW EXECUTE FUNCTION soulbah.benchmark_tasks_freeze();

-- 3. Jeux de données ---------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.datasets (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                text NOT NULL UNIQUE CONSTRAINT datasets_name_format CHECK (name ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  purpose             text NOT NULL CONSTRAINT datasets_purpose_check CHECK (purpose IN ('evaluation', 'regression', 'training', 'fine_tuning', 'distillation')),
  domain              text NOT NULL DEFAULT 'mixed' CONSTRAINT datasets_domain_length CHECK (length(domain) BETWEEN 1 AND 60),
  -- Jamais de données secrètes dans un jeu de données (§65) ; les données confidentielles exigent une source consentie.
  sensitivity         text NOT NULL DEFAULT 'internal' CONSTRAINT datasets_sensitivity_check CHECK (sensitivity IN ('public', 'internal', 'confidential')),
  license             text CONSTRAINT datasets_license_length CHECK (license IS NULL OR length(license) <= 100),
  description         text NOT NULL DEFAULT '' CONSTRAINT datasets_description_length CHECK (length(description) <= 2000),
  current_version_id  uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.datasets IS 'Jeux de données (évaluation, régression, entraînement) : usage, domaine, sensibilité — jamais de secrets.';
ALTER TABLE soulbah.datasets ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS datasets_set_updated_at ON soulbah.datasets;
CREATE TRIGGER datasets_set_updated_at BEFORE UPDATE ON soulbah.datasets FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.dataset_versions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dataset_id   uuid NOT NULL REFERENCES soulbah.datasets(id) ON DELETE CASCADE,
  version      integer NOT NULL CONSTRAINT dataset_versions_version_positive CHECK (version >= 1),
  item_count   integer NOT NULL DEFAULT 0 CONSTRAINT dataset_versions_count_positive CHECK (item_count >= 0),
  checksum     text CONSTRAINT dataset_versions_checksum_format CHECK (checksum IS NULL OR checksum ~ '^[0-9a-f]{64}$'),
  artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  frozen       boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now(),
  frozen_at    timestamptz,
  CONSTRAINT dataset_versions_unique UNIQUE (dataset_id, version),
  CONSTRAINT dataset_versions_frozen_dated CHECK (NOT frozen OR frozen_at IS NOT NULL)
);
COMMENT ON TABLE soulbah.dataset_versions IS 'Versions d''un jeu de données (empreinte, artefact exporté, gel).';
ALTER TABLE soulbah.dataset_versions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_dataset_versions_artifact ON soulbah.dataset_versions (artifact_id);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'datasets_current_version_fkey') THEN
    ALTER TABLE soulbah.datasets ADD CONSTRAINT datasets_current_version_fkey
      FOREIGN KEY (current_version_id) REFERENCES soulbah.dataset_versions(id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_datasets_current_version ON soulbah.datasets (current_version_id);

CREATE TABLE IF NOT EXISTS soulbah.dataset_sources (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dataset_id  uuid NOT NULL REFERENCES soulbah.datasets(id) ON DELETE CASCADE,
  kind        text NOT NULL CONSTRAINT dataset_sources_kind_check CHECK (kind IN ('project_history', 'golden_tasks', 'incidents', 'research', 'synthetic', 'human', 'public_dataset')),
  ref         text NOT NULL CONSTRAINT dataset_sources_ref_length CHECK (length(ref) BETWEEN 1 AND 500),
  license     text CONSTRAINT dataset_sources_license_length CHECK (license IS NULL OR length(license) <= 100),
  consent_ok  boolean NOT NULL DEFAULT false,
  notes       text NOT NULL DEFAULT '' CONSTRAINT dataset_sources_notes_length CHECK (length(notes) <= 2000),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dataset_sources_unique UNIQUE (dataset_id, kind, ref)
);
COMMENT ON TABLE soulbah.dataset_sources IS 'Provenance des données (historique projet, tâches de référence, incidents, recherche, synthèse, humain, jeu public) et consentement.';
ALTER TABLE soulbah.dataset_sources ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.dataset_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id    uuid NOT NULL REFERENCES soulbah.dataset_versions(id) ON DELETE CASCADE,
  key           text NOT NULL CONSTRAINT dataset_items_key_length CHECK (length(key) BETWEEN 1 AND 200),
  source_id     uuid REFERENCES soulbah.dataset_sources(id) ON DELETE SET NULL,
  input         jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT dataset_items_input_object CHECK (soulbah.is_json_object(input)),
  expected      jsonb CONSTRAINT dataset_items_expected_object CHECK (expected IS NULL OR soulbah.is_json_object(expected)),
  quality_flag  text NOT NULL DEFAULT 'ok' CONSTRAINT dataset_items_quality_check CHECK (quality_flag IN ('ok', 'suspect', 'rejected')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dataset_items_unique UNIQUE (version_id, key)
);
COMMENT ON TABLE soulbah.dataset_items IS 'Éléments d''une version de jeu de données (entrée, attendu, source, qualité).';
ALTER TABLE soulbah.dataset_items ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_dataset_items_source ON soulbah.dataset_items (source_id);

CREATE TABLE IF NOT EXISTS soulbah.dataset_quality_checks (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id  uuid NOT NULL REFERENCES soulbah.dataset_versions(id) ON DELETE CASCADE,
  check_name  text NOT NULL CONSTRAINT dataset_quality_check_name_format CHECK (check_name ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  status      text NOT NULL CONSTRAINT dataset_quality_status_check CHECK (status IN ('passed', 'warning', 'failed')),
  detail      jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT dataset_quality_detail_object CHECK (soulbah.is_json_object(detail)),
  checked_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dataset_quality_checks_unique UNIQUE (version_id, check_name, checked_at)
);
COMMENT ON TABLE soulbah.dataset_quality_checks IS 'Contrôles de qualité d''une version (doublons, secrets, PII, déséquilibre, taille).';
ALTER TABLE soulbah.dataset_quality_checks ENABLE ROW LEVEL SECURITY;

-- 4. Exécutions et résultats ------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.benchmark_runs (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  benchmark_version_id  uuid NOT NULL REFERENCES soulbah.benchmark_versions(id) ON DELETE RESTRICT,
  subject_kind          text NOT NULL DEFAULT 'model' CONSTRAINT benchmark_runs_subject_kind_check CHECK (subject_kind IN ('model', 'agent', 'tool', 'skill', 'system')),
  model_version_id      uuid REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  subject_ref           text CONSTRAINT benchmark_runs_subject_ref_length CHECK (subject_ref IS NULL OR length(subject_ref) <= 300),
  external_ref          text UNIQUE CONSTRAINT benchmark_runs_external_ref_length CHECK (external_ref IS NULL OR length(external_ref) <= 300),
  status                text NOT NULL DEFAULT 'pending' CONSTRAINT benchmark_runs_status_check CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled')),
  environment           jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT benchmark_runs_environment_object CHECK (soulbah.is_json_object(environment)),
  hardware              jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT benchmark_runs_hardware_object CHECK (soulbah.is_json_object(hardware)),
  seed                  integer,
  score                 numeric(10, 4) CONSTRAINT benchmark_runs_score_positive CHECK (score IS NULL OR score >= 0),
  score_max             numeric(10, 4) CONSTRAINT benchmark_runs_score_max_positive CHECK (score_max IS NULL OR score_max > 0),
  triggered_by          text NOT NULL DEFAULT current_user,
  notes                 text NOT NULL DEFAULT '' CONSTRAINT benchmark_runs_notes_length CHECK (length(notes) <= 4000),
  started_at            timestamptz,
  finished_at           timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT benchmark_runs_subject CHECK ((subject_kind = 'model' AND model_version_id IS NOT NULL) OR (subject_kind <> 'model' AND subject_ref IS NOT NULL)),
  CONSTRAINT benchmark_runs_score_bounded CHECK (score IS NULL OR score_max IS NULL OR score <= score_max),
  CONSTRAINT benchmark_runs_completed_scored CHECK (status <> 'completed' OR (score IS NOT NULL AND score_max IS NOT NULL AND finished_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.benchmark_runs IS 'Exécution d''une version de benchmark sur un sujet (version de modèle, agent, outil, compétence, système) : environnement, matériel, score sur score_max — jamais de score sans exécution.';
ALTER TABLE soulbah.benchmark_runs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_benchmark_runs_version ON soulbah.benchmark_runs (benchmark_version_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_benchmark_runs_model ON soulbah.benchmark_runs (model_version_id);

CREATE TABLE IF NOT EXISTS soulbah.benchmark_results (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id              uuid NOT NULL REFERENCES soulbah.benchmark_runs(id) ON DELETE CASCADE,
  task_id             uuid NOT NULL REFERENCES soulbah.benchmark_tasks(id) ON DELETE RESTRICT,
  passed              boolean,
  score               numeric(10, 4) CONSTRAINT benchmark_results_score_positive CHECK (score IS NULL OR score >= 0),
  score_max           numeric(10, 4) CONSTRAINT benchmark_results_score_max_positive CHECK (score_max IS NULL OR score_max > 0),
  latency_ms          integer CONSTRAINT benchmark_results_latency_positive CHECK (latency_ms IS NULL OR latency_ms >= 0),
  tokens_in           integer CONSTRAINT benchmark_results_tokens_in_positive CHECK (tokens_in IS NULL OR tokens_in >= 0),
  tokens_out          integer CONSTRAINT benchmark_results_tokens_out_positive CHECK (tokens_out IS NULL OR tokens_out >= 0),
  output_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  output_excerpt      text CONSTRAINT benchmark_results_excerpt_length CHECK (output_excerpt IS NULL OR length(output_excerpt) <= 4000),
  error               text,
  detail              jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT benchmark_results_detail_object CHECK (soulbah.is_json_object(detail)),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT benchmark_results_unique UNIQUE (run_id, task_id),
  CONSTRAINT benchmark_results_score_bounded CHECK (score IS NULL OR score_max IS NULL OR score <= score_max)
);
COMMENT ON TABLE soulbah.benchmark_results IS 'Résultat par tâche d''une exécution (réussite, score, latence, jetons, sortie en artefact ou extrait).';
ALTER TABLE soulbah.benchmark_results ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_benchmark_results_task ON soulbah.benchmark_results (task_id);
CREATE INDEX IF NOT EXISTS idx_benchmark_results_artifact ON soulbah.benchmark_results (output_artifact_id);

CREATE TABLE IF NOT EXISTS soulbah.model_benchmarks (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_version_id      uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE CASCADE,
  benchmark_version_id  uuid NOT NULL REFERENCES soulbah.benchmark_versions(id) ON DELETE RESTRICT,
  run_id                uuid NOT NULL REFERENCES soulbah.benchmark_runs(id) ON DELETE CASCADE,
  score                 numeric(10, 4) NOT NULL CONSTRAINT model_benchmarks_score_positive CHECK (score >= 0),
  score_max             numeric(10, 4) NOT NULL CONSTRAINT model_benchmarks_score_max_positive CHECK (score_max > 0),
  passed_count          integer CONSTRAINT model_benchmarks_passed_positive CHECK (passed_count IS NULL OR passed_count >= 0),
  task_count            integer CONSTRAINT model_benchmarks_tasks_positive CHECK (task_count IS NULL OR task_count >= 0),
  measured_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_benchmarks_unique UNIQUE (run_id),
  CONSTRAINT model_benchmarks_score_bounded CHECK (score <= score_max),
  CONSTRAINT model_benchmarks_counts CHECK (passed_count IS NULL OR task_count IS NULL OR passed_count <= task_count)
);
COMMENT ON TABLE soulbah.model_benchmarks IS 'Scores agrégés d''une version de modèle par version de benchmark, toujours adossés à une exécution (run_id).';
ALTER TABLE soulbah.model_benchmarks ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_model_benchmarks_model ON soulbah.model_benchmarks (model_version_id, benchmark_version_id, measured_at DESC);
CREATE INDEX IF NOT EXISTS idx_model_benchmarks_benchmark ON soulbah.model_benchmarks (benchmark_version_id);

CREATE TABLE IF NOT EXISTS soulbah.model_capabilities (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id       uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE CASCADE,
  capability       text NOT NULL CONSTRAINT model_capabilities_format CHECK (capability ~ '^[a-z][a-z0-9_.]{0,59}$'),
  level            text NOT NULL DEFAULT 'unknown' CONSTRAINT model_capabilities_level_check CHECK (level IN ('unknown', 'none', 'weak', 'usable', 'strong')),
  measured         boolean NOT NULL DEFAULT false,
  evidence_run_id  uuid REFERENCES soulbah.benchmark_runs(id) ON DELETE SET NULL,
  notes            text NOT NULL DEFAULT '' CONSTRAINT model_capabilities_notes_length CHECK (length(notes) <= 2000),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_capabilities_unique UNIQUE (version_id, capability),
  CONSTRAINT model_capabilities_measured_evidence CHECK (NOT measured OR evidence_run_id IS NOT NULL)
);
COMMENT ON TABLE soulbah.model_capabilities IS 'Capacités d''une version (json_schema, planning, french, code_review, embedding…) : déclarées ou mesurées — mesuré exige une exécution de benchmark.';
ALTER TABLE soulbah.model_capabilities ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_model_capabilities_run ON soulbah.model_capabilities (evidence_run_id);
DROP TRIGGER IF EXISTS model_capabilities_set_updated_at ON soulbah.model_capabilities;
CREATE TRIGGER model_capabilities_set_updated_at BEFORE UPDATE ON soulbah.model_capabilities FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- 5. Routage ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.model_routing_rules (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                 text NOT NULL UNIQUE CONSTRAINT model_routing_rules_name_format CHECK (name ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  priority             integer NOT NULL DEFAULT 100 CONSTRAINT model_routing_rules_priority_range CHECK (priority BETWEEN 0 AND 10000),
  task_kind            text NOT NULL DEFAULT 'any' CONSTRAINT model_routing_rules_task_kind_check CHECK (task_kind IN ('any', 'chat', 'plan', 'code', 'review', 'summarize', 'classify', 'embed', 'rerank', 'extract')),
  network_mode         text NOT NULL DEFAULT 'ANY' CONSTRAINT model_routing_rules_mode_check CHECK (network_mode IN ('ANY', 'OFFLINE', 'LOCAL_INTERNET', 'HYBRID')),
  model_version_id     uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  fallback_version_id  uuid REFERENCES soulbah.model_versions(id) ON DELETE SET NULL,
  conditions           jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT model_routing_rules_conditions_object CHECK (soulbah.is_json_object(conditions)),
  enabled              boolean NOT NULL DEFAULT true,
  created_by           text NOT NULL DEFAULT current_user,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_routing_rules_fallback_differs CHECK (fallback_version_id IS NULL OR fallback_version_id <> model_version_id)
);
COMMENT ON TABLE soulbah.model_routing_rules IS 'Règles de routage (genre de tâche, mode réseau, conditions) vers une version active, avec repli ; se désactivent, ne se suppriment pas si un historique existe.';
ALTER TABLE soulbah.model_routing_rules ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_model_routing_rules_target ON soulbah.model_routing_rules (model_version_id);
CREATE INDEX IF NOT EXISTS idx_model_routing_rules_fallback ON soulbah.model_routing_rules (fallback_version_id);
CREATE INDEX IF NOT EXISTS idx_model_routing_rules_lookup ON soulbah.model_routing_rules (task_kind, network_mode, priority) WHERE enabled;
DROP TRIGGER IF EXISTS model_routing_rules_set_updated_at ON soulbah.model_routing_rules;
CREATE TRIGGER model_routing_rules_set_updated_at BEFORE UPDATE ON soulbah.model_routing_rules FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE OR REPLACE FUNCTION soulbah.model_routing_rules_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.enabled AND NOT EXISTS (SELECT 1 FROM soulbah.model_versions v WHERE v.id = NEW.model_version_id AND v.status = 'active') THEN
    RAISE EXCEPTION 'soulbah.model_routing_rules : la cible doit être une version de modèle active' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS model_routing_rules_guard ON soulbah.model_routing_rules;
CREATE TRIGGER model_routing_rules_guard BEFORE INSERT OR UPDATE ON soulbah.model_routing_rules FOR EACH ROW EXECUTE FUNCTION soulbah.model_routing_rules_guard();

CREATE TABLE IF NOT EXISTS soulbah.model_routing_history (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rule_id              uuid REFERENCES soulbah.model_routing_rules(id) ON DELETE RESTRICT,
  chosen_version_id    uuid REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  session_id           uuid,
  task_id              uuid,
  task_kind            text NOT NULL CONSTRAINT model_routing_history_task_kind_length CHECK (length(task_kind) BETWEEN 1 AND 40),
  network_mode         text NOT NULL CONSTRAINT model_routing_history_mode_length CHECK (length(network_mode) BETWEEN 1 AND 40),
  fallback_used        boolean NOT NULL DEFAULT false,
  reason               text NOT NULL DEFAULT '' CONSTRAINT model_routing_history_reason_length CHECK (length(reason) <= 1000),
  latency_ms           integer CONSTRAINT model_routing_history_latency_positive CHECK (latency_ms IS NULL OR latency_ms >= 0),
  tokens_in            integer CONSTRAINT model_routing_history_tokens_in_positive CHECK (tokens_in IS NULL OR tokens_in >= 0),
  tokens_out           integer CONSTRAINT model_routing_history_tokens_out_positive CHECK (tokens_out IS NULL OR tokens_out >= 0),
  outcome              text NOT NULL DEFAULT 'unknown' CONSTRAINT model_routing_history_outcome_check CHECK (outcome IN ('unknown', 'ok', 'error', 'timeout', 'refused', 'busy')),
  decided_at           timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.model_routing_history IS 'Journal (ajout seul) de chaque décision de routage : règle, version choisie, repli, latence, jetons, issue — base des mesures réelles.';
ALTER TABLE soulbah.model_routing_history ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_model_routing_history_version ON soulbah.model_routing_history (chosen_version_id, id);
CREATE INDEX IF NOT EXISTS idx_model_routing_history_rule ON soulbah.model_routing_history (rule_id);
CREATE INDEX IF NOT EXISTS idx_model_routing_history_task ON soulbah.model_routing_history (task_id);
DROP TRIGGER IF EXISTS model_routing_history_append_only ON soulbah.model_routing_history;
CREATE TRIGGER model_routing_history_append_only BEFORE UPDATE OR DELETE ON soulbah.model_routing_history FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS model_routing_history_no_truncate ON soulbah.model_routing_history;
CREATE TRIGGER model_routing_history_no_truncate BEFORE TRUNCATE ON soulbah.model_routing_history FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

-- 6. Candidats, compétitions, mode ombre -----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.model_candidates (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_id              uuid REFERENCES soulbah.models(id) ON DELETE SET NULL,
  version_id            uuid REFERENCES soulbah.model_versions(id) ON DELETE SET NULL,
  name                  text NOT NULL CONSTRAINT model_candidates_name_length CHECK (length(name) BETWEEN 1 AND 200),
  source                text NOT NULL CONSTRAINT model_candidates_source_check CHECK (source IN ('download', 'training', 'import', 'vendor_api')),
  source_ref            text CONSTRAINT model_candidates_source_ref_length CHECK (source_ref IS NULL OR length(source_ref) <= 500),
  size_bytes            bigint CONSTRAINT model_candidates_size_positive CHECK (size_bytes IS NULL OR size_bytes >= 0),
  rationale             text NOT NULL DEFAULT '' CONSTRAINT model_candidates_rationale_length CHECK (length(rationale) <= 4000),
  proposed_by           text NOT NULL DEFAULT current_user,
  status                text NOT NULL DEFAULT 'proposed' CONSTRAINT model_candidates_status_check CHECK (status IN (
                          'proposed', 'download_approved', 'downloading', 'installed', 'benchmarking', 'security_review', 'approved', 'rejected', 'promoted')),
  download_approved_by  text,
  download_approved_at  timestamptz,
  decided_by            text,
  decided_at            timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  -- Aucun téléchargement sans approbation humaine explicite (règle de la mission).
  CONSTRAINT model_candidates_download_approved CHECK (source <> 'download' OR status IN ('proposed', 'rejected') OR (download_approved_by IS NOT NULL AND download_approved_at IS NOT NULL)),
  CONSTRAINT model_candidates_decided CHECK (status NOT IN ('approved', 'rejected', 'promoted') OR (decided_by IS NOT NULL AND decided_at IS NOT NULL)),
  CONSTRAINT model_candidates_promoted CHECK (status <> 'promoted' OR version_id IS NOT NULL)
);
COMMENT ON TABLE soulbah.model_candidates IS 'Modèles candidats : un téléchargement exige une approbation humaine explicite ; promotion seulement après benchmarks et revue de sécurité.';
ALTER TABLE soulbah.model_candidates ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_model_candidates_status ON soulbah.model_candidates (status);
CREATE INDEX IF NOT EXISTS idx_model_candidates_model ON soulbah.model_candidates (model_id);
CREATE INDEX IF NOT EXISTS idx_model_candidates_version ON soulbah.model_candidates (version_id);
DROP TRIGGER IF EXISTS model_candidates_set_updated_at ON soulbah.model_candidates;
CREATE TRIGGER model_candidates_set_updated_at BEFORE UPDATE ON soulbah.model_candidates FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.model_competitions (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                   text NOT NULL UNIQUE CONSTRAINT model_competitions_name_format CHECK (name ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  task_kind              text NOT NULL DEFAULT 'any' CONSTRAINT model_competitions_task_kind_length CHECK (length(task_kind) BETWEEN 1 AND 40),
  champion_version_id    uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  challenger_version_id  uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  benchmark_version_id   uuid NOT NULL REFERENCES soulbah.benchmark_versions(id) ON DELETE RESTRICT,
  status                 text NOT NULL DEFAULT 'planned' CONSTRAINT model_competitions_status_check CHECK (status IN ('planned', 'running', 'completed', 'cancelled')),
  winner_version_id      uuid REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  decision               text NOT NULL DEFAULT '' CONSTRAINT model_competitions_decision_length CHECK (length(decision) <= 4000),
  decided_by             text,
  decided_at             timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_competitions_distinct CHECK (champion_version_id <> challenger_version_id),
  CONSTRAINT model_competitions_winner_valid CHECK (winner_version_id IS NULL OR winner_version_id IN (champion_version_id, challenger_version_id)),
  CONSTRAINT model_competitions_completed CHECK (status <> 'completed' OR (winner_version_id IS NOT NULL AND decided_by IS NOT NULL AND decided_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.model_competitions IS 'Champion contre challenger sur une version de benchmark gelée ; le vainqueur est l''un des deux et la décision est signée.';
ALTER TABLE soulbah.model_competitions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_model_competitions_champion ON soulbah.model_competitions (champion_version_id);
CREATE INDEX IF NOT EXISTS idx_model_competitions_challenger ON soulbah.model_competitions (challenger_version_id);
CREATE INDEX IF NOT EXISTS idx_model_competitions_benchmark ON soulbah.model_competitions (benchmark_version_id);
CREATE INDEX IF NOT EXISTS idx_model_competitions_winner ON soulbah.model_competitions (winner_version_id);

CREATE TABLE IF NOT EXISTS soulbah.model_comparison_results (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  competition_id    uuid NOT NULL REFERENCES soulbah.model_competitions(id) ON DELETE CASCADE,
  metric            text NOT NULL CONSTRAINT model_comparison_metric_format CHECK (metric ~ '^[a-z][a-z0-9_.]{0,99}$'),
  champion_run_id   uuid REFERENCES soulbah.benchmark_runs(id) ON DELETE SET NULL,
  challenger_run_id uuid REFERENCES soulbah.benchmark_runs(id) ON DELETE SET NULL,
  champion_value    numeric(18, 6) NOT NULL,
  challenger_value  numeric(18, 6) NOT NULL,
  higher_is_better  boolean NOT NULL DEFAULT true,
  better            text GENERATED ALWAYS AS (
                      CASE WHEN champion_value = challenger_value THEN 'tie'
                           WHEN (challenger_value > champion_value) = higher_is_better THEN 'challenger' ELSE 'champion' END) STORED,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT model_comparison_results_unique UNIQUE (competition_id, metric)
);
COMMENT ON TABLE soulbah.model_comparison_results IS 'Comparaison métrique par métrique d''une compétition, adossée aux exécutions ; le meilleur est calculé, pas saisi.';
ALTER TABLE soulbah.model_comparison_results ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_model_comparison_champion_run ON soulbah.model_comparison_results (champion_run_id);
CREATE INDEX IF NOT EXISTS idx_model_comparison_challenger_run ON soulbah.model_comparison_results (challenger_run_id);

CREATE TABLE IF NOT EXISTS soulbah.shadow_runs (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shadow_version_id           uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  primary_version_id          uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  session_id                  uuid,
  task_id                     uuid,
  task_kind                   text NOT NULL DEFAULT 'any' CONSTRAINT shadow_runs_task_kind_length CHECK (length(task_kind) BETWEEN 1 AND 40),
  input_hash                  text CONSTRAINT shadow_runs_input_hash_format CHECK (input_hash IS NULL OR input_hash ~ '^[0-9a-f]{64}$'),
  primary_output_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  shadow_output_artifact_id   uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  primary_latency_ms          integer CONSTRAINT shadow_runs_primary_latency_positive CHECK (primary_latency_ms IS NULL OR primary_latency_ms >= 0),
  shadow_latency_ms           integer CONSTRAINT shadow_runs_shadow_latency_positive CHECK (shadow_latency_ms IS NULL OR shadow_latency_ms >= 0),
  status                      text NOT NULL DEFAULT 'pending' CONSTRAINT shadow_runs_status_check CHECK (status IN ('pending', 'completed', 'failed', 'skipped')),
  created_at                  timestamptz NOT NULL DEFAULT now(),
  finished_at                 timestamptz,
  CONSTRAINT shadow_runs_distinct CHECK (shadow_version_id <> primary_version_id)
);
COMMENT ON TABLE soulbah.shadow_runs IS 'Mode ombre : le challenger reçoit la même entrée que le modèle principal ; sa sortie est enregistrée et comparée, jamais utilisée par la mission.';
ALTER TABLE soulbah.shadow_runs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_shadow_runs_shadow ON soulbah.shadow_runs (shadow_version_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_shadow_runs_primary ON soulbah.shadow_runs (primary_version_id);
CREATE INDEX IF NOT EXISTS idx_shadow_runs_task ON soulbah.shadow_runs (task_id);
CREATE INDEX IF NOT EXISTS idx_shadow_runs_primary_artifact ON soulbah.shadow_runs (primary_output_artifact_id);
CREATE INDEX IF NOT EXISTS idx_shadow_runs_shadow_artifact ON soulbah.shadow_runs (shadow_output_artifact_id);

CREATE TABLE IF NOT EXISTS soulbah.shadow_comparisons (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shadow_run_id  uuid NOT NULL REFERENCES soulbah.shadow_runs(id) ON DELETE CASCADE,
  comparator     text NOT NULL CONSTRAINT shadow_comparisons_comparator_check CHECK (comparator IN ('rules', 'llm', 'human')),
  verdict        text NOT NULL CONSTRAINT shadow_comparisons_verdict_check CHECK (verdict IN ('shadow_better', 'primary_better', 'equivalent', 'undetermined')),
  score          numeric(6, 3) CONSTRAINT shadow_comparisons_score_range CHECK (score IS NULL OR (score >= -1 AND score <= 1)),
  notes          text NOT NULL DEFAULT '' CONSTRAINT shadow_comparisons_notes_length CHECK (length(notes) <= 4000),
  created_by     text NOT NULL DEFAULT current_user,
  created_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.shadow_comparisons IS 'Verdict d''une comparaison ombre/principal (règles, LLM ou humain).';
ALTER TABLE soulbah.shadow_comparisons ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_shadow_comparisons_run ON soulbah.shadow_comparisons (shadow_run_id);

-- 7. Entraînement (toujours approuvé par un humain avant de tourner) ------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.training_configs (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                     text NOT NULL UNIQUE CONSTRAINT training_configs_name_format CHECK (name ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  base_model_version_id    uuid NOT NULL REFERENCES soulbah.model_versions(id) ON DELETE RESTRICT,
  dataset_version_id       uuid NOT NULL REFERENCES soulbah.dataset_versions(id) ON DELETE RESTRICT,
  method                   text NOT NULL CONSTRAINT training_configs_method_check CHECK (method IN ('lora', 'qlora', 'full', 'distillation', 'prompt_tuning', 'embedding_finetune')),
  hyperparameters          jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT training_configs_hparams_object CHECK (soulbah.is_json_object(hyperparameters)),
  hardware                 jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT training_configs_hardware_object CHECK (soulbah.is_json_object(hardware)),
  estimated_duration_min   integer CONSTRAINT training_configs_duration_positive CHECK (estimated_duration_min IS NULL OR estimated_duration_min >= 0),
  rationale                text NOT NULL DEFAULT '' CONSTRAINT training_configs_rationale_length CHECK (length(rationale) <= 4000),
  approved_by              text,
  approved_at              timestamptz,
  created_by               text NOT NULL DEFAULT current_user,
  created_at               timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.training_configs IS 'Configurations d''entraînement (modèle de base, jeu de données gelé, méthode, hyperparamètres, matériel) ; une exécution exige une configuration approuvée.';
ALTER TABLE soulbah.training_configs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_training_configs_base ON soulbah.training_configs (base_model_version_id);
CREATE INDEX IF NOT EXISTS idx_training_configs_dataset ON soulbah.training_configs (dataset_version_id);

CREATE TABLE IF NOT EXISTS soulbah.training_runs (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  config_id         uuid NOT NULL REFERENCES soulbah.training_configs(id) ON DELETE RESTRICT,
  status            text NOT NULL DEFAULT 'planned' CONSTRAINT training_runs_status_check CHECK (status IN ('planned', 'running', 'completed', 'failed', 'cancelled')),
  resource_usage    jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT training_runs_usage_object CHECK (soulbah.is_json_object(resource_usage)),
  logs_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  error             text,
  started_by        text NOT NULL DEFAULT current_user,
  started_at        timestamptz,
  finished_at       timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.training_runs IS 'Exécutions d''entraînement (ressources consommées, journal en artefact) — jamais sans configuration approuvée (trigger).';
ALTER TABLE soulbah.training_runs ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_training_runs_config ON soulbah.training_runs (config_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_training_runs_logs ON soulbah.training_runs (logs_artifact_id);

CREATE OR REPLACE FUNCTION soulbah.training_runs_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM soulbah.training_configs c WHERE c.id = NEW.config_id AND c.approved_by IS NOT NULL AND c.approved_at IS NOT NULL) THEN
    RAISE EXCEPTION 'soulbah.training_runs : configuration d''entraînement non approuvée' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.status IN ('running', 'completed') AND NOT EXISTS (
       SELECT 1 FROM soulbah.training_configs c JOIN soulbah.dataset_versions d ON d.id = c.dataset_version_id WHERE c.id = NEW.config_id AND d.frozen) THEN
    RAISE EXCEPTION 'soulbah.training_runs : le jeu de données doit être gelé avant l''entraînement' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS training_runs_guard ON soulbah.training_runs;
CREATE TRIGGER training_runs_guard BEFORE INSERT OR UPDATE ON soulbah.training_runs FOR EACH ROW EXECUTE FUNCTION soulbah.training_runs_guard();

CREATE TABLE IF NOT EXISTS soulbah.training_results (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id      uuid NOT NULL REFERENCES soulbah.training_runs(id) ON DELETE CASCADE,
  metric      text NOT NULL CONSTRAINT training_results_metric_format CHECK (metric ~ '^[a-z][a-z0-9_.]{0,99}$'),
  step        integer CONSTRAINT training_results_step_positive CHECK (step IS NULL OR step >= 0),
  value       numeric(18, 6) NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.training_results IS 'Métriques d''une exécution d''entraînement (perte, exactitude…) par étape.';
ALTER TABLE soulbah.training_results ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_training_results_run ON soulbah.training_results (run_id, metric, step);

CREATE TABLE IF NOT EXISTS soulbah.training_artifacts (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id            uuid NOT NULL REFERENCES soulbah.training_runs(id) ON DELETE CASCADE,
  kind              text NOT NULL CONSTRAINT training_artifacts_kind_check CHECK (kind IN ('adapter', 'checkpoint', 'merged_model', 'report', 'eval')),
  artifact_id       uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  sha256            text CONSTRAINT training_artifacts_sha256_format CHECK (sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes        bigint CONSTRAINT training_artifacts_size_positive CHECK (size_bytes IS NULL OR size_bytes >= 0),
  model_version_id  uuid REFERENCES soulbah.model_versions(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.training_artifacts IS 'Produits d''un entraînement (adaptateur, point de contrôle, modèle fusionné, rapport) ; model_version_id une fois enregistré comme version candidate.';
ALTER TABLE soulbah.training_artifacts ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_training_artifacts_run ON soulbah.training_artifacts (run_id);
CREATE INDEX IF NOT EXISTS idx_training_artifacts_artifact ON soulbah.training_artifacts (artifact_id);
CREATE INDEX IF NOT EXISTS idx_training_artifacts_version ON soulbah.training_artifacts (model_version_id);

-- 8. Liens avec les lots précédents --------------------------------------------------------------------------------
ALTER TABLE soulbah.embedding_models ADD COLUMN IF NOT EXISTS model_id uuid REFERENCES soulbah.models(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_embedding_models_model ON soulbah.embedding_models (model_id);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tool_benchmarks_run_fkey') THEN
    ALTER TABLE soulbah.tool_benchmarks ADD CONSTRAINT tool_benchmarks_run_fkey
      FOREIGN KEY (benchmark_run_id) REFERENCES soulbah.benchmark_runs(id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_tool_benchmarks_run ON soulbah.tool_benchmarks (benchmark_run_id);

-- 9. Semences : les deux modèles installés localement, tels que décrits par le registre local le 2026-10-02
-- (%LOCALAPPDATA%\Soulbah\models\registry.json) ; empreintes et sources épinglées réelles ; aucun n'est « actif »
-- ici car le statut de sécurité n'a pas été approuvé par un humain (checked, pas approved).
INSERT INTO soulbah.models (name, display_name, family, kind, provider, vendor, license, license_url, status, description, metadata) VALUES
  ('qwen2.5-1.5b-instruct', 'Qwen2.5 1.5B Instruct', 'qwen2.5', 'llm', 'local', 'Alibaba Qwen', 'apache-2.0',
   'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF', 'candidate',
   'Modèle de conversation et de planification compacte servi par llama.cpp sur CPU (1 slot, contexte 8192).',
   '{"roles": ["chat", "planning", "reasoning", "fast"], "registry": "local"}'),
  ('nomic-embed-text-v1.5', 'nomic-embed-text v1.5', 'nomic-embed', 'embedding', 'local', 'Nomic AI', 'apache-2.0',
   'https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF', 'candidate',
   'Modèle d''embeddings local (768 dimensions) installé, pas encore branché sur la base de connaissances.',
   '{"roles": ["embedding"], "registry": "local"}')
ON CONFLICT (name) DO NOTHING;

INSERT INTO soulbah.model_versions (model_id, version, registry_key, file_name, sha256, size_bytes, quantization, context_length, parameters_b, runtime,
                                    source_kind, source_ref, source_revision, status, installed, installed_at, metadata)
SELECT m.id, v.version, v.registry_key, v.file_name, v.sha256, v.size_bytes, v.quantization, v.context_length, v.parameters_b, 'llama.cpp',
       'huggingface', v.source_ref, v.source_revision, 'candidate', true, v.installed_at, v.metadata
FROM (VALUES
  ('qwen2.5-1.5b-instruct', '2.5-q4_k_m', 'qwen2.5-1.5b-instruct-q4_k_m', 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
   '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e', 1117320736::bigint, 'Q4_K_M', 32768, 1.5::numeric,
   'Qwen/Qwen2.5-1.5B-Instruct-GGUF', '91cad51170dc346986eccefdc2dd33a9da36ead9', '2026-10-01T20:31:36+00:00'::timestamptz,
   '{"json_schema": true, "vision": false, "license_accepted_at": "2026-10-01T20:31:36+00:00", "registry_status": "verified"}'::jsonb),
  ('nomic-embed-text-v1.5', '1.5-q8_0', 'nomic-embed-text-v1.5-q8_0', 'nomic-embed-text-v1.5.Q8_0.gguf',
   '3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7', 146146432::bigint, 'Q8_0', 8192, NULL::numeric,
   'nomic-ai/nomic-embed-text-v1.5-GGUF', '0188c9bf409793f810680a5a431e7b899c46104c', '2026-10-01T20:32:27+00:00'::timestamptz,
   '{"embedding_dim": 768, "license_accepted_at": "2026-10-01T20:32:27+00:00", "registry_status": "installed"}'::jsonb)
) AS v(model_name, version, registry_key, file_name, sha256, size_bytes, quantization, context_length, parameters_b, source_ref, source_revision, installed_at, metadata)
JOIN soulbah.models m ON m.name = v.model_name
ON CONFLICT (model_id, version) DO NOTHING;

INSERT INTO soulbah.model_hardware_requirements (version_id, profile, min_ram_mb, min_vram_mb, measured, notes)
SELECT v.id, 'cpu', h.ram_mb, 0, false, 'Estimation du registre local (ram_estimate_gb) ; débit mesuré 2 à 11,5 jetons/s sur le CPU de la machine de développement.'
FROM (VALUES ('qwen2.5-1.5b-instruct-q4_k_m', 1628), ('nomic-embed-text-v1.5-q8_0', 707)) AS h(registry_key, ram_mb)
JOIN soulbah.model_versions v ON v.registry_key = h.registry_key
ON CONFLICT (version_id, profile) DO NOTHING;

INSERT INTO soulbah.model_security_status (version_id, status, checksum_verified, source_verified, license_ok, checked_by, checked_at, notes)
SELECT v.id, 'checked', s.checksum_verified, true, true, 'system:model_registry', s.checked_at, s.notes
FROM (VALUES
  ('qwen2.5-1.5b-instruct-q4_k_m', true, '2026-10-01T20:31:36+00:00'::timestamptz, 'Empreinte SHA-256 vérifiée au téléchargement (registre : verified) ; source Hugging Face épinglée par révision ; licence Apache-2.0 acceptée. Approbation humaine en attente.'),
  ('nomic-embed-text-v1.5-q8_0', NULL::boolean, '2026-10-01T20:32:27+00:00'::timestamptz, 'Installé (registre : installed) ; vérification de l''empreinte non attestée par le registre ; source épinglée par révision ; licence Apache-2.0 acceptée. Approbation humaine en attente.')
) AS s(registry_key, checksum_verified, checked_at, notes)
JOIN soulbah.model_versions v ON v.registry_key = s.registry_key
ON CONFLICT (version_id) DO NOTHING;

UPDATE soulbah.embedding_models e SET model_id = m.id
FROM soulbah.models m WHERE m.name = 'nomic-embed-text-v1.5' AND e.name = 'nomic-embed-text-v1.5-q8_0' AND e.model_id IS NULL;

-- Benchmark de fumée local (5 tâches) et sa seule exécution connue (registre, 2026-10-02T09:48:35Z, qwen2.5 sur CPU).
INSERT INTO soulbah.benchmarks (name, domain, description) VALUES
  ('local_smoke', 'mixed', 'Fumée locale du lanceur : plan JSON, raisonnement, revue de code, question sur document, résumé en français — mesure de débit incluse.')
ON CONFLICT (name) DO NOTHING;
INSERT INTO soulbah.benchmark_versions (benchmark_id, version, spec, frozen, frozen_at)
SELECT b.id, 1, '{"source": "agent/local_models benchmark (registre local)", "tasks": 5, "scoring": "exact|contains"}', true, '2026-10-02T09:48:35+00:00'
FROM soulbah.benchmarks b WHERE b.name = 'local_smoke'
ON CONFLICT (benchmark_id, version) DO NOTHING;
UPDATE soulbah.benchmarks b SET current_version_id = v.id
FROM soulbah.benchmark_versions v WHERE v.benchmark_id = b.id AND v.version = 1 AND b.name = 'local_smoke' AND b.current_version_id IS NULL;
-- La version est gelée : les tâches sont insérées sous déverrouillage explicite du gel, dans cette seule migration.
DO $$
DECLARE bv uuid;
BEGIN
  SELECT v.id INTO bv FROM soulbah.benchmark_versions v JOIN soulbah.benchmarks b ON b.id = v.benchmark_id WHERE b.name = 'local_smoke' AND v.version = 1;
  IF (SELECT count(*) FROM soulbah.benchmark_tasks WHERE benchmark_version_id = bv) = 0 THEN
    ALTER TABLE soulbah.benchmark_tasks DISABLE TRIGGER benchmark_tasks_freeze;
    INSERT INTO soulbah.benchmark_tasks (benchmark_version_id, key, scoring, expected) VALUES
      (bv, 'plan_json', 'json_schema', '{"schema": "steps[] with tool/path/content"}'),
      (bv, 'reasoning', 'exact', '{"answer": "arithmetic result"}'),
      (bv, 'code_review', 'exact', '{"answer": "line number of the bug"}'),
      (bv, 'doc_qa', 'contains', '{"answer": "7 ans"}'),
      (bv, 'french_summary', 'rubric', '{"language": "fr", "max_sentences": 2}');
    ALTER TABLE soulbah.benchmark_tasks ENABLE TRIGGER benchmark_tasks_freeze;
  END IF;
END $$;
INSERT INTO soulbah.benchmark_runs (benchmark_version_id, subject_kind, model_version_id, external_ref, status, environment, hardware, score, score_max, triggered_by, started_at, finished_at, notes)
SELECT bv.id, 'model', mv.id, 'registry:qwen2.5-1.5b-instruct-q4_k_m:2026-10-02T09:48:35Z', 'completed',
       '{"base_url": "http://127.0.0.1:8091/v1", "runtime": "llama.cpp b11325", "slots": 1, "ctx": 8192}', '{"device": "cpu"}',
       4, 5, 'system:model_registry', '2026-10-02T09:48:35+00:00', '2026-10-02T09:48:35+00:00',
       'Résultats copiés du registre local (bloc benchmark) ; tâche reasoning échouée (réponse 47).'
FROM soulbah.benchmark_versions bv JOIN soulbah.benchmarks b ON b.id = bv.benchmark_id AND b.name = 'local_smoke' AND bv.version = 1
JOIN soulbah.model_versions mv ON mv.registry_key = 'qwen2.5-1.5b-instruct-q4_k_m'
ON CONFLICT (external_ref) DO NOTHING;
INSERT INTO soulbah.benchmark_results (run_id, task_id, passed, score, score_max, latency_ms, tokens_out, detail)
SELECT r.id, t.id, d.passed, CASE WHEN d.passed THEN 1 ELSE 0 END, 1, d.latency_ms, d.tokens_out, jsonb_build_object('tokens_per_s', d.tps)
FROM (VALUES ('plan_json', true, 15020, 46, 4.0), ('reasoning', false, 1060, 3, 5.5), ('code_review', true, 1170, 2, 7.1),
             ('doc_qa', true, 4750, 15, 3.9), ('french_summary', true, 5410, 38, 7.2)) AS d(key, passed, latency_ms, tokens_out, tps)
JOIN soulbah.benchmark_runs r ON r.external_ref = 'registry:qwen2.5-1.5b-instruct-q4_k_m:2026-10-02T09:48:35Z'
JOIN soulbah.benchmark_tasks t ON t.benchmark_version_id = r.benchmark_version_id AND t.key = d.key
ON CONFLICT (run_id, task_id) DO NOTHING;
INSERT INTO soulbah.model_benchmarks (model_version_id, benchmark_version_id, run_id, score, score_max, passed_count, task_count, measured_at)
SELECT r.model_version_id, r.benchmark_version_id, r.id, 4, 5, 4, 5, r.finished_at
FROM soulbah.benchmark_runs r WHERE r.external_ref = 'registry:qwen2.5-1.5b-instruct-q4_k_m:2026-10-02T09:48:35Z'
ON CONFLICT (run_id) DO NOTHING;
INSERT INTO soulbah.model_capabilities (version_id, capability, level, measured, evidence_run_id, notes)
SELECT mv.id, c.capability, c.level, c.measured, CASE WHEN c.measured THEN r.id END, c.notes
FROM soulbah.model_versions mv
JOIN soulbah.benchmark_runs r ON r.external_ref = 'registry:qwen2.5-1.5b-instruct-q4_k_m:2026-10-02T09:48:35Z'
CROSS JOIN (VALUES
  ('json_schema', 'usable', true, 'plan_json réussi ; planification DAG multi-agents non fiable (0/4, V3 LOT 4)'),
  ('reasoning', 'weak', true, 'tâche reasoning échouée'),
  ('code_review', 'usable', true, 'code_review réussi sur un cas trivial'),
  ('french', 'usable', true, 'doc_qa et french_summary réussis'),
  ('vision', 'none', false, 'déclaré par le registre')) AS c(capability, level, measured, notes)
WHERE mv.registry_key = 'qwen2.5-1.5b-instruct-q4_k_m'
ON CONFLICT (version_id, capability) DO NOTHING;
INSERT INTO soulbah.model_capabilities (version_id, capability, level, measured, notes)
SELECT mv.id, 'embedding', 'unknown', false, '768 dimensions déclarées ; pas encore branché ni mesuré'
FROM soulbah.model_versions mv WHERE mv.registry_key = 'nomic-embed-text-v1.5-q8_0'
ON CONFLICT (version_id, capability) DO NOTHING;

-- 10. Droits ------------------------------------------------------------------------------------------------------
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['models', 'model_versions', 'model_hardware_requirements', 'model_security_status', 'benchmarks', 'benchmark_versions',
                           'golden_tasks', 'golden_task_expected_results', 'benchmark_tasks', 'datasets', 'dataset_versions', 'dataset_sources',
                           'dataset_items', 'dataset_quality_checks', 'benchmark_runs', 'benchmark_results', 'model_benchmarks', 'model_capabilities',
                           'model_routing_rules', 'model_routing_history', 'model_candidates', 'model_competitions', 'model_comparison_results',
                           'shadow_runs', 'shadow_comparisons', 'training_configs', 'training_runs', 'training_results', 'training_artifacts'] LOOP
    EXECUTE format('REVOKE ALL ON soulbah.%I FROM PUBLIC', t);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON soulbah.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.model_versions_guard(), soulbah.benchmark_tasks_freeze(), soulbah.model_routing_rules_guard(), soulbah.training_runs_guard() FROM %I', r);
    END IF;
  END LOOP;
END $$;


-- >>>>>>>>>> 20261002111200_db11_security_immune.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 11 — Sécurité et Digital Immune System : motifs (sécurité et bugs), constats, incidents (toutes natures,
-- vue security_incidents), événements / actions / preuves / décisions / étapes de reprise, correctifs, tests de
-- régression, règles de détection, vues SOC, vue audit_events sur soulbah.audit_logs.
-- soulbah:rollback=YES
-- soulbah:recovery=20261002111200_db11_security_immune.down.sql (les constats et incidents enregistrés seraient perdus)
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03 (agent_quarantines), db07 (project_commits.incident_id).
-- =============================================================================

-- 1. Motifs ----------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.security_patterns (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key                text NOT NULL UNIQUE CONSTRAINT security_patterns_key_format CHECK (key ~ '^[a-z][a-z0-9_.-]{0,119}$'),
  pattern_kind       text NOT NULL CONSTRAINT security_patterns_kind_check CHECK (pattern_kind IN ('security', 'bug')),
  category           text NOT NULL CONSTRAINT security_patterns_category_check CHECK (category IN (
                       'injection', 'auth', 'authorization', 'rls', 'secrets', 'input_validation', 'race', 'data_loss', 'config',
                       'dependency', 'performance', 'logic', 'resource_leak', 'error_handling', 'concurrency', 'crypto', 'other')),
  title              text NOT NULL CONSTRAINT security_patterns_title_length CHECK (length(title) BETWEEN 1 AND 300),
  signature          text NOT NULL DEFAULT '' CONSTRAINT security_patterns_signature_length CHECK (length(signature) <= 4000),
  conditions         jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT security_patterns_conditions_object CHECK (soulbah.is_json_object(conditions)),
  root_cause         text NOT NULL DEFAULT '' CONSTRAINT security_patterns_root_cause_length CHECK (length(root_cause) <= 4000),
  fix_strategy       text NOT NULL DEFAULT '' CONSTRAINT security_patterns_fix_length CHECK (length(fix_strategy) <= 4000),
  test_strategy      text NOT NULL DEFAULT '' CONSTRAINT security_patterns_test_length CHECK (length(test_strategy) <= 4000),
  severity           text NOT NULL DEFAULT 'MEDIUM' CONSTRAINT security_patterns_severity_check CHECK (soulbah.is_severity(severity)),
  projects_affected  jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT security_patterns_projects_array CHECK (soulbah.is_json_array(projects_affected)),
  occurrences        integer NOT NULL DEFAULT 0 CONSTRAINT security_patterns_occurrences_positive CHECK (occurrences >= 0),
  first_seen_at      timestamptz,
  last_seen_at       timestamptz,
  source             text NOT NULL DEFAULT 'human' CONSTRAINT security_patterns_source_check CHECK (source IN ('human', 'learned', 'research', 'imported')),
  status             text NOT NULL DEFAULT 'draft' CONSTRAINT security_patterns_status_check CHECK (status IN ('draft', 'active', 'retired')),
  created_by         text NOT NULL DEFAULT current_user,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.security_patterns IS 'Mémoire immunitaire : motifs de vulnérabilités (security) et de bugs (bug) — signature, conditions, cause racine, correctif, test, projets touchés, première/dernière observation.';
ALTER TABLE soulbah.security_patterns ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.security_patterns', '{"key": "text", "pattern_kind": "text", "severity": "text", "occurrences": "integer"}');
CREATE INDEX IF NOT EXISTS idx_security_patterns_kind ON soulbah.security_patterns (pattern_kind, category) WHERE status = 'active';
DROP TRIGGER IF EXISTS security_patterns_set_updated_at ON soulbah.security_patterns;
CREATE TRIGGER security_patterns_set_updated_at BEFORE UPDATE ON soulbah.security_patterns FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- 2. Incidents (toutes natures) ---------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.incidents (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind                    text NOT NULL CONSTRAINT incidents_kind_check CHECK (kind IN ('security', 'reliability', 'performance', 'data', 'availability', 'agent_behaviour')),
  severity                text NOT NULL CONSTRAINT incidents_severity_check CHECK (soulbah.is_severity(severity)),
  title                   text NOT NULL CONSTRAINT incidents_title_length CHECK (length(title) BETWEEN 1 AND 300),
  summary                 text NOT NULL DEFAULT '' CONSTRAINT incidents_summary_length CHECK (length(summary) <= 8000),
  project_id              uuid REFERENCES soulbah.projects(id) ON DELETE RESTRICT,
  environment_name        text REFERENCES soulbah.environments(name),
  status                  text NOT NULL DEFAULT 'OPEN' CONSTRAINT incidents_status_check CHECK (status IN ('OPEN', 'CONTAINED', 'MITIGATED', 'RESOLVED', 'POSTMORTEM', 'CLOSED')),
  detected_by             text NOT NULL DEFAULT current_user CONSTRAINT incidents_detected_by_length CHECK (length(detected_by) BETWEEN 1 AND 200),
  detected_at             timestamptz NOT NULL DEFAULT now(),
  contained_at            timestamptz,
  resolved_at             timestamptz,
  closed_at               timestamptz,
  closed_by               text,
  root_cause              text NOT NULL DEFAULT '' CONSTRAINT incidents_root_cause_length CHECK (length(root_cause) <= 8000),
  impact                  text NOT NULL DEFAULT '' CONSTRAINT incidents_impact_length CHECK (length(impact) <= 4000),
  postmortem_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT incidents_closed_signed CHECK (status <> 'CLOSED' OR (closed_by IS NOT NULL AND closed_at IS NOT NULL)),
  CONSTRAINT incidents_resolved_dated CHECK (status NOT IN ('RESOLVED', 'POSTMORTEM', 'CLOSED') OR resolved_at IS NOT NULL)
);
COMMENT ON TABLE soulbah.incidents IS 'Incidents de toutes natures (sécurité, fiabilité, performance, données, disponibilité, comportement d''agent) ; la vue security_incidents en filtre la nature sécurité.';
ALTER TABLE soulbah.incidents ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.incidents', '{"kind": "text", "severity": "text", "status": "text", "closed_by": "text"}');
CREATE INDEX IF NOT EXISTS idx_incidents_open ON soulbah.incidents (severity, detected_at DESC) WHERE status NOT IN ('RESOLVED', 'POSTMORTEM', 'CLOSED');
CREATE INDEX IF NOT EXISTS idx_incidents_project ON soulbah.incidents (project_id);
CREATE INDEX IF NOT EXISTS idx_incidents_environment ON soulbah.incidents (environment_name);
CREATE INDEX IF NOT EXISTS idx_incidents_postmortem ON soulbah.incidents (postmortem_artifact_id);
DROP TRIGGER IF EXISTS incidents_set_updated_at ON soulbah.incidents;
CREATE TRIGGER incidents_set_updated_at BEFORE UPDATE ON soulbah.incidents FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE OR REPLACE VIEW soulbah.security_incidents AS
  SELECT * FROM soulbah.incidents WHERE kind = 'security';
COMMENT ON VIEW soulbah.security_incidents IS 'Incidents de nature sécurité (vue sur soulbah.incidents).';

-- 3. Constats ----------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.security_findings (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fingerprint             text NOT NULL UNIQUE CONSTRAINT security_findings_fingerprint_format CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
  project_id              uuid REFERENCES soulbah.projects(id) ON DELETE RESTRICT,
  repository_id           uuid,
  environment_name        text REFERENCES soulbah.environments(name),
  pattern_id              uuid REFERENCES soulbah.security_patterns(id) ON DELETE SET NULL,
  incident_id             uuid REFERENCES soulbah.incidents(id) ON DELETE SET NULL,
  kind                    text NOT NULL CONSTRAINT security_findings_kind_check CHECK (kind IN ('vulnerability', 'bug', 'misconfiguration', 'dependency', 'data_exposure', 'policy_violation', 'performance')),
  severity                text NOT NULL CONSTRAINT security_findings_severity_check CHECK (soulbah.is_severity(severity)),
  severity_justification  text NOT NULL DEFAULT '' CONSTRAINT security_findings_justification_length CHECK (length(severity_justification) <= 4000),
  confidence              real NOT NULL DEFAULT 0.5 CONSTRAINT security_findings_confidence_range CHECK (confidence >= 0 AND confidence <= 1),
  title                   text NOT NULL CONSTRAINT security_findings_title_length CHECK (length(title) BETWEEN 1 AND 300),
  description             text NOT NULL DEFAULT '' CONSTRAINT security_findings_description_length CHECK (length(description) <= 8000),
  location                jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT security_findings_location_object CHECK (soulbah.is_json_object(location)),
  evidence                jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT security_findings_evidence_array CHECK (soulbah.is_json_array(evidence)),
  status                  text NOT NULL DEFAULT 'DETECTED' CONSTRAINT security_findings_status_check CHECK (status IN (
                            'DETECTED', 'TRIAGED', 'CONFIRMED', 'FALSE_POSITIVE', 'FIX_PROPOSED', 'FIX_APPLIED', 'VERIFIED', 'WONT_FIX', 'REOPENED')),
  detected_by             text NOT NULL DEFAULT current_user CONSTRAINT security_findings_detected_by_length CHECK (length(detected_by) BETWEEN 1 AND 200),
  detected_at             timestamptz NOT NULL DEFAULT now(),
  triaged_by              text,
  triaged_at              timestamptz,
  verified_by             text,
  verified_at             timestamptz,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  -- Une sévérité haute se justifie ; « vérifié » est signé ; la confiance n'est pas une preuve (§ Intelligence Lab).
  CONSTRAINT security_findings_high_justified CHECK (severity NOT IN ('HIGH', 'CRITICAL') OR length(severity_justification) >= 20),
  CONSTRAINT security_findings_verified_signed CHECK (status <> 'VERIFIED' OR (verified_by IS NOT NULL AND verified_at IS NOT NULL)),
  CONSTRAINT security_findings_triaged_signed CHECK (status IN ('DETECTED', 'REOPENED') OR (triaged_by IS NOT NULL AND triaged_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.security_findings IS 'Constats dédoublonnés par empreinte : sévérité justifiée, confiance (≠ preuve), preuves, cycle DETECTED → TRIAGED → CONFIRMED → FIX_PROPOSED → FIX_APPLIED → VERIFIED (signé).';
ALTER TABLE soulbah.security_findings ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.security_findings', '{"fingerprint": "text", "severity": "text", "confidence": "real", "status": "text"}');
CREATE INDEX IF NOT EXISTS idx_security_findings_open ON soulbah.security_findings (severity, detected_at DESC) WHERE status NOT IN ('FALSE_POSITIVE', 'VERIFIED', 'WONT_FIX');
CREATE INDEX IF NOT EXISTS idx_security_findings_project ON soulbah.security_findings (project_id, status);
CREATE INDEX IF NOT EXISTS idx_security_findings_pattern ON soulbah.security_findings (pattern_id);
CREATE INDEX IF NOT EXISTS idx_security_findings_incident ON soulbah.security_findings (incident_id);
CREATE INDEX IF NOT EXISTS idx_security_findings_environment ON soulbah.security_findings (environment_name);
CREATE INDEX IF NOT EXISTS idx_security_findings_repository ON soulbah.security_findings (repository_id);
DROP TRIGGER IF EXISTS security_findings_set_updated_at ON soulbah.security_findings;
CREATE TRIGGER security_findings_set_updated_at BEFORE UPDATE ON soulbah.security_findings FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- Statistiques du motif tenues par les constats (occurrences, première et dernière observation).
CREATE OR REPLACE FUNCTION soulbah.security_findings_pattern_stats()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.pattern_id IS NOT NULL AND (TG_OP = 'INSERT' OR OLD.pattern_id IS DISTINCT FROM NEW.pattern_id) THEN
    UPDATE soulbah.security_patterns p
       SET occurrences = p.occurrences + 1,
           first_seen_at = LEAST(COALESCE(p.first_seen_at, NEW.detected_at), NEW.detected_at),
           last_seen_at = GREATEST(COALESCE(p.last_seen_at, NEW.detected_at), NEW.detected_at),
           projects_affected = CASE WHEN NEW.project_id IS NULL OR p.projects_affected ? NEW.project_id::text THEN p.projects_affected
                                    ELSE p.projects_affected || to_jsonb(NEW.project_id::text) END
     WHERE p.id = NEW.pattern_id;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS security_findings_pattern_stats ON soulbah.security_findings;
CREATE TRIGGER security_findings_pattern_stats AFTER INSERT OR UPDATE OF pattern_id ON soulbah.security_findings FOR EACH ROW EXECUTE FUNCTION soulbah.security_findings_pattern_stats();

-- 4. Vie d'un incident --------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.incident_events (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  incident_id  uuid NOT NULL REFERENCES soulbah.incidents(id) ON DELETE RESTRICT,
  kind         text NOT NULL CONSTRAINT incident_events_kind_check CHECK (kind IN (
                 'detected', 'triaged', 'escalated', 'contained', 'mitigated', 'resolved', 'reopened', 'closed', 'note', 'action', 'evidence', 'decision', 'status_change')),
  actor        text NOT NULL DEFAULT current_user CONSTRAINT incident_events_actor_length CHECK (length(actor) BETWEEN 1 AND 200),
  message      text NOT NULL DEFAULT '' CONSTRAINT incident_events_message_length CHECK (length(message) <= 4000),
  detail       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT incident_events_detail_object CHECK (soulbah.is_json_object(detail)),
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.incident_events IS 'Chronologie d''un incident (ajout seul).';
ALTER TABLE soulbah.incident_events ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_incident_events_incident ON soulbah.incident_events (incident_id, id);
DROP TRIGGER IF EXISTS incident_events_append_only ON soulbah.incident_events;
CREATE TRIGGER incident_events_append_only BEFORE UPDATE OR DELETE ON soulbah.incident_events FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS incident_events_no_truncate ON soulbah.incident_events;
CREATE TRIGGER incident_events_no_truncate BEFORE TRUNCATE ON soulbah.incident_events FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

-- Chaque changement de statut d'un incident est journalisé automatiquement.
CREATE OR REPLACE FUNCTION soulbah.incidents_log_status()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO soulbah.incident_events (incident_id, kind, actor, message, detail)
    VALUES (NEW.id, 'detected', NEW.detected_by, NEW.title, jsonb_build_object('severity', NEW.severity, 'kind', NEW.kind));
  ELSIF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO soulbah.incident_events (incident_id, kind, actor, message, detail)
    VALUES (NEW.id, 'status_change', COALESCE(soulbah.change_actor(), current_user), COALESCE(soulbah.change_reason(), ''),
            jsonb_build_object('from', OLD.status, 'to', NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS incidents_log_status ON soulbah.incidents;
CREATE TRIGGER incidents_log_status AFTER INSERT OR UPDATE OF status ON soulbah.incidents FOR EACH ROW EXECUTE FUNCTION soulbah.incidents_log_status();

CREATE TABLE IF NOT EXISTS soulbah.incident_actions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id        uuid NOT NULL REFERENCES soulbah.incidents(id) ON DELETE RESTRICT,
  kind               text NOT NULL CONSTRAINT incident_actions_kind_check CHECK (kind IN (
                       'investigate', 'isolate', 'block', 'rotate_secret', 'quarantine_agent', 'rollback', 'patch', 'restore', 'notify', 'monitor', 'other')),
  description        text NOT NULL CONSTRAINT incident_actions_description_length CHECK (length(description) BETWEEN 1 AND 4000),
  requires_approval  boolean NOT NULL DEFAULT true,
  status             text NOT NULL DEFAULT 'planned' CONSTRAINT incident_actions_status_check CHECK (status IN ('planned', 'approved', 'executing', 'executed', 'failed', 'cancelled')),
  approved_by        text,
  approved_at        timestamptz,
  executed_by        text,
  executed_at        timestamptz,
  task_id            uuid,
  result             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT incident_actions_result_object CHECK (soulbah.is_json_object(result)),
  created_by         text NOT NULL DEFAULT current_user,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  -- Une action qui exige une approbation ne s'exécute pas sans elle ; une action exécutée est signée.
  CONSTRAINT incident_actions_approval CHECK (status NOT IN ('executing', 'executed') OR NOT requires_approval OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
  CONSTRAINT incident_actions_executed_signed CHECK (status <> 'executed' OR (executed_by IS NOT NULL AND executed_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.incident_actions IS 'Actions de réponse (isoler, bloquer, faire tourner un secret, mettre un agent en quarantaine, revenir en arrière, corriger…) : approbation requise par défaut.';
ALTER TABLE soulbah.incident_actions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_incident_actions_incident ON soulbah.incident_actions (incident_id, status);
CREATE INDEX IF NOT EXISTS idx_incident_actions_task ON soulbah.incident_actions (task_id);
DROP TRIGGER IF EXISTS incident_actions_set_updated_at ON soulbah.incident_actions;
CREATE TRIGGER incident_actions_set_updated_at BEFORE UPDATE ON soulbah.incident_actions FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.incident_evidence (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  incident_id  uuid NOT NULL REFERENCES soulbah.incidents(id) ON DELETE RESTRICT,
  finding_id   uuid REFERENCES soulbah.security_findings(id) ON DELETE RESTRICT,
  kind         text NOT NULL CONSTRAINT incident_evidence_kind_check CHECK (kind IN ('log', 'screenshot', 'diff', 'query', 'report', 'metric', 'artifact', 'testimony', 'other')),
  artifact_id  uuid,
  sha256       text CONSTRAINT incident_evidence_sha256_format CHECK (sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$'),
  description  text NOT NULL CONSTRAINT incident_evidence_description_length CHECK (length(description) BETWEEN 1 AND 4000),
  detail       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT incident_evidence_detail_object CHECK (soulbah.is_json_object(detail)),
  created_by   text NOT NULL DEFAULT current_user,
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.incident_evidence IS 'Preuves d''un incident (ajout seul) : artefact par identifiant et empreinte, jamais le contenu.';
ALTER TABLE soulbah.incident_evidence ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_incident_evidence_incident ON soulbah.incident_evidence (incident_id, id);
CREATE INDEX IF NOT EXISTS idx_incident_evidence_finding ON soulbah.incident_evidence (finding_id);
CREATE INDEX IF NOT EXISTS idx_incident_evidence_artifact ON soulbah.incident_evidence (artifact_id);
DROP TRIGGER IF EXISTS incident_evidence_append_only ON soulbah.incident_evidence;
CREATE TRIGGER incident_evidence_append_only BEFORE UPDATE OR DELETE ON soulbah.incident_evidence FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS incident_evidence_no_truncate ON soulbah.incident_evidence;
CREATE TRIGGER incident_evidence_no_truncate BEFORE TRUNCATE ON soulbah.incident_evidence FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE TABLE IF NOT EXISTS soulbah.incident_decisions (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  incident_id     uuid NOT NULL REFERENCES soulbah.incidents(id) ON DELETE RESTRICT,
  decision        text NOT NULL CONSTRAINT incident_decisions_decision_length CHECK (length(decision) BETWEEN 1 AND 4000),
  rationale       text NOT NULL DEFAULT '' CONSTRAINT incident_decisions_rationale_length CHECK (length(rationale) <= 8000),
  decider_kind    text NOT NULL CONSTRAINT incident_decisions_decider_kind_check CHECK (decider_kind IN ('human', 'agent', 'system')),
  decided_by      text NOT NULL CONSTRAINT incident_decisions_decided_by_length CHECK (length(decided_by) BETWEEN 1 AND 200),
  autonomy_level  text CONSTRAINT incident_decisions_autonomy_check CHECK (autonomy_level IS NULL OR soulbah.is_autonomy_level(autonomy_level)),
  decided_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.incident_decisions IS 'Décisions prises pendant un incident (ajout seul) : qui a décidé (humain, agent, système) et sous quel niveau d''autonomie.';
ALTER TABLE soulbah.incident_decisions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_incident_decisions_incident ON soulbah.incident_decisions (incident_id, id);
DROP TRIGGER IF EXISTS incident_decisions_append_only ON soulbah.incident_decisions;
CREATE TRIGGER incident_decisions_append_only BEFORE UPDATE OR DELETE ON soulbah.incident_decisions FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS incident_decisions_no_truncate ON soulbah.incident_decisions;
CREATE TRIGGER incident_decisions_no_truncate BEFORE TRUNCATE ON soulbah.incident_decisions FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE TABLE IF NOT EXISTS soulbah.incident_recovery_steps (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id  uuid NOT NULL REFERENCES soulbah.incidents(id) ON DELETE RESTRICT,
  position     integer NOT NULL CONSTRAINT incident_recovery_steps_position_positive CHECK (position >= 1),
  description  text NOT NULL CONSTRAINT incident_recovery_steps_description_length CHECK (length(description) BETWEEN 1 AND 4000),
  status       text NOT NULL DEFAULT 'pending' CONSTRAINT incident_recovery_steps_status_check CHECK (status IN ('pending', 'in_progress', 'done', 'failed', 'skipped')),
  done_by      text,
  done_at      timestamptz,
  evidence     jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT incident_recovery_steps_evidence_array CHECK (soulbah.is_json_array(evidence)),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT incident_recovery_steps_unique UNIQUE (incident_id, position),
  CONSTRAINT incident_recovery_steps_done_signed CHECK (status <> 'done' OR (done_by IS NOT NULL AND done_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.incident_recovery_steps IS 'Plan de reprise ordonné d''un incident, chaque étape signée avec ses preuves.';
ALTER TABLE soulbah.incident_recovery_steps ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS incident_recovery_steps_set_updated_at ON soulbah.incident_recovery_steps;
CREATE TRIGGER incident_recovery_steps_set_updated_at BEFORE UPDATE ON soulbah.incident_recovery_steps FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- 5. Correctifs, tests de régression, règles de détection ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.security_fixes (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  finding_id        uuid NOT NULL REFERENCES soulbah.security_findings(id) ON DELETE RESTRICT,
  incident_id       uuid REFERENCES soulbah.incidents(id) ON DELETE SET NULL,
  environment_name  text REFERENCES soulbah.environments(name),
  change_kind       text NOT NULL CONSTRAINT security_fixes_change_kind_check CHECK (change_kind IN ('code', 'config', 'database', 'policy', 'dependency', 'infrastructure', 'documentation')),
  description       text NOT NULL CONSTRAINT security_fixes_description_length CHECK (length(description) BETWEEN 1 AND 8000),
  commit_id         uuid REFERENCES soulbah.project_commits(id) ON DELETE SET NULL,
  diff_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  status            text NOT NULL DEFAULT 'proposed' CONSTRAINT security_fixes_status_check CHECK (status IN ('proposed', 'approved', 'applied', 'verified', 'reverted', 'rejected')),
  proposed_by       text NOT NULL DEFAULT current_user,
  approved_by       text,
  approved_at       timestamptz,
  applied_by        text,
  applied_at        timestamptz,
  verified_by       text,
  verified_at       timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  -- Appliquer un correctif en PRODUCTION exige une approbation ; « vérifié » est signé.
  CONSTRAINT security_fixes_production_approved CHECK (status NOT IN ('applied', 'verified') OR environment_name IS DISTINCT FROM 'PRODUCTION' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
  CONSTRAINT security_fixes_applied_signed CHECK (status NOT IN ('applied', 'verified') OR (applied_by IS NOT NULL AND applied_at IS NOT NULL)),
  CONSTRAINT security_fixes_verified_signed CHECK (status <> 'verified' OR (verified_by IS NOT NULL AND verified_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.security_fixes IS 'Correctifs d''un constat : nature du changement, commit ou diff, cycle proposé → approuvé → appliqué → vérifié ; la production exige une approbation.';
ALTER TABLE soulbah.security_fixes ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_security_fixes_finding ON soulbah.security_fixes (finding_id, status);
CREATE INDEX IF NOT EXISTS idx_security_fixes_incident ON soulbah.security_fixes (incident_id);
CREATE INDEX IF NOT EXISTS idx_security_fixes_commit ON soulbah.security_fixes (commit_id);
CREATE INDEX IF NOT EXISTS idx_security_fixes_diff ON soulbah.security_fixes (diff_artifact_id);
CREATE INDEX IF NOT EXISTS idx_security_fixes_environment ON soulbah.security_fixes (environment_name);
CREATE INDEX IF NOT EXISTS idx_security_fixes_recent ON soulbah.security_fixes (applied_at DESC) WHERE applied_at IS NOT NULL;
DROP TRIGGER IF EXISTS security_fixes_set_updated_at ON soulbah.security_fixes;
CREATE TRIGGER security_fixes_set_updated_at BEFORE UPDATE ON soulbah.security_fixes FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.security_regression_tests (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id   uuid NOT NULL REFERENCES soulbah.projects(id) ON DELETE RESTRICT,
  finding_id   uuid REFERENCES soulbah.security_findings(id) ON DELETE SET NULL,
  pattern_id   uuid REFERENCES soulbah.security_patterns(id) ON DELETE SET NULL,
  fix_id       uuid REFERENCES soulbah.security_fixes(id) ON DELETE SET NULL,
  name         text NOT NULL CONSTRAINT security_regression_tests_name_length CHECK (length(name) BETWEEN 1 AND 300),
  kind         text NOT NULL DEFAULT 'integration' CONSTRAINT security_regression_tests_kind_check CHECK (kind IN ('unit', 'integration', 'e2e', 'sql', 'policy', 'static')),
  location     text NOT NULL DEFAULT '' CONSTRAINT security_regression_tests_location_length CHECK (length(location) <= 1000),
  status       text NOT NULL DEFAULT 'active' CONSTRAINT security_regression_tests_status_check CHECK (status IN ('active', 'retired')),
  last_result  text NOT NULL DEFAULT 'unknown' CONSTRAINT security_regression_tests_result_check CHECK (last_result IN ('unknown', 'passed', 'failed')),
  last_run_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT security_regression_tests_unique UNIQUE (project_id, name)
);
COMMENT ON TABLE soulbah.security_regression_tests IS 'Tests qui empêchent le retour d''un constat ou d''un motif (emplacement, dernier résultat).';
ALTER TABLE soulbah.security_regression_tests ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_security_regression_tests_finding ON soulbah.security_regression_tests (finding_id);
CREATE INDEX IF NOT EXISTS idx_security_regression_tests_pattern ON soulbah.security_regression_tests (pattern_id);
CREATE INDEX IF NOT EXISTS idx_security_regression_tests_fix ON soulbah.security_regression_tests (fix_id);
CREATE INDEX IF NOT EXISTS idx_security_regression_tests_failed ON soulbah.security_regression_tests (project_id) WHERE last_result = 'failed' AND status = 'active';
DROP TRIGGER IF EXISTS security_regression_tests_set_updated_at ON soulbah.security_regression_tests;
CREATE TRIGGER security_regression_tests_set_updated_at BEFORE UPDATE ON soulbah.security_regression_tests FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.security_detection_rules (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key                   text NOT NULL UNIQUE CONSTRAINT security_detection_rules_key_format CHECK (key ~ '^[a-z][a-z0-9_.-]{0,119}$'),
  pattern_id            uuid REFERENCES soulbah.security_patterns(id) ON DELETE SET NULL,
  kind                  text NOT NULL CONSTRAINT security_detection_rules_kind_check CHECK (kind IN ('static', 'runtime', 'database', 'log', 'network', 'agent_behaviour')),
  target                text NOT NULL DEFAULT '' CONSTRAINT security_detection_rules_target_length CHECK (length(target) <= 500),
  rule                  jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT security_detection_rules_rule_object CHECK (soulbah.is_json_object(rule)),
  severity              text NOT NULL DEFAULT 'MEDIUM' CONSTRAINT security_detection_rules_severity_check CHECK (soulbah.is_severity(severity)),
  enabled               boolean NOT NULL DEFAULT true,
  true_positive_count   integer NOT NULL DEFAULT 0 CONSTRAINT security_detection_rules_tp_positive CHECK (true_positive_count >= 0),
  false_positive_count  integer NOT NULL DEFAULT 0 CONSTRAINT security_detection_rules_fp_positive CHECK (false_positive_count >= 0),
  created_by            text NOT NULL DEFAULT current_user,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.security_detection_rules IS 'Règles de détection (statique, exécution, base, journaux, réseau, comportement d''agent) avec comptes de vrais et faux positifs.';
ALTER TABLE soulbah.security_detection_rules ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_security_detection_rules_pattern ON soulbah.security_detection_rules (pattern_id);
DROP TRIGGER IF EXISTS security_detection_rules_set_updated_at ON soulbah.security_detection_rules;
CREATE TRIGGER security_detection_rules_set_updated_at BEFORE UPDATE ON soulbah.security_detection_rules FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- 6. Liens avec les lots précédents --------------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'project_commits_incident_fkey') THEN
    ALTER TABLE soulbah.project_commits ADD CONSTRAINT project_commits_incident_fkey
      FOREIGN KEY (incident_id) REFERENCES soulbah.incidents(id) ON DELETE RESTRICT;
  END IF;
END $$;
ALTER TABLE soulbah.agent_quarantines ADD COLUMN IF NOT EXISTS incident_id uuid REFERENCES soulbah.incidents(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_agent_quarantines_incident ON soulbah.agent_quarantines (incident_id);

-- 7. Vues SOC (§57) — sur les tables réelles, jamais de chiffres calculés ailleurs -----------------------------------
CREATE OR REPLACE VIEW soulbah.v_soc_active_incidents AS
  SELECT i.id, i.kind, i.severity, i.title, i.status, i.project_id, p.slug AS project_slug, i.environment_name, i.detected_at, i.detected_by,
         (SELECT count(*) FROM soulbah.incident_actions a WHERE a.incident_id = i.id AND a.status IN ('planned', 'approved', 'executing')) AS pending_actions,
         (SELECT count(*) FROM soulbah.incident_evidence e WHERE e.incident_id = i.id) AS evidence_count,
         (SELECT max(ev.created_at) FROM soulbah.incident_events ev WHERE ev.incident_id = i.id) AS last_event_at
    FROM soulbah.incidents i LEFT JOIN soulbah.projects p ON p.id = i.project_id
   WHERE i.status NOT IN ('RESOLVED', 'POSTMORTEM', 'CLOSED');
COMMENT ON VIEW soulbah.v_soc_active_incidents IS 'SOC : incidents ouverts, contenus ou atténués, avec actions en attente et preuves.';

CREATE OR REPLACE VIEW soulbah.v_soc_open_findings AS
  SELECT f.id, f.kind, f.severity, f.confidence, f.title, f.status, f.project_id, p.slug AS project_slug, f.environment_name, f.pattern_id, f.incident_id, f.detected_at, f.detected_by
    FROM soulbah.security_findings f LEFT JOIN soulbah.projects p ON p.id = f.project_id
   WHERE f.status NOT IN ('FALSE_POSITIVE', 'VERIFIED', 'WONT_FIX');
COMMENT ON VIEW soulbah.v_soc_open_findings IS 'SOC : constats non clos (ni faux positif, ni vérifié, ni refusé).';

CREATE OR REPLACE VIEW soulbah.v_soc_critical_findings AS
  SELECT * FROM soulbah.v_soc_open_findings WHERE severity IN ('HIGH', 'CRITICAL');
COMMENT ON VIEW soulbah.v_soc_critical_findings IS 'SOC : constats ouverts de sévérité HIGH ou CRITICAL.';

CREATE OR REPLACE VIEW soulbah.v_soc_quarantined_agents AS
  SELECT q.id AS quarantine_id, d.id AS definition_id, d.name AS agent_name, d.display_name, q.reason, q.created_by, q.created_at, q.event_id, q.incident_id
    FROM soulbah.agent_quarantines q JOIN soulbah.agent_definitions d ON d.id = q.definition_id
   WHERE q.status = 'active';
COMMENT ON VIEW soulbah.v_soc_quarantined_agents IS 'SOC : agents actuellement en quarantaine et motif.';

CREATE OR REPLACE VIEW soulbah.v_soc_recent_fixes AS
  SELECT x.id, x.finding_id, f.title AS finding_title, f.severity, x.change_kind, x.status, x.environment_name, x.proposed_by, x.approved_by, x.applied_by, x.applied_at, x.verified_at, x.commit_id
    FROM soulbah.security_fixes x JOIN soulbah.security_findings f ON f.id = x.finding_id
   WHERE x.updated_at >= now() - interval '30 days';
COMMENT ON VIEW soulbah.v_soc_recent_fixes IS 'SOC : correctifs touchés dans les 30 derniers jours.';

CREATE OR REPLACE VIEW soulbah.v_soc_regressions AS
  SELECT t.id, t.project_id, p.slug AS project_slug, t.name, t.kind, t.location, t.finding_id, t.pattern_id, t.last_run_at
    FROM soulbah.security_regression_tests t LEFT JOIN soulbah.projects p ON p.id = t.project_id
   WHERE t.status = 'active' AND t.last_result = 'failed';
COMMENT ON VIEW soulbah.v_soc_regressions IS 'SOC : tests de régression actifs dont le dernier résultat est un échec (un constat revient).';

CREATE OR REPLACE VIEW soulbah.v_soc_coverage AS
  SELECT p.id AS project_id, p.slug AS project_slug,
         (SELECT count(*) FROM soulbah.security_findings f WHERE f.project_id = p.id) AS findings_total,
         (SELECT count(*) FROM soulbah.security_findings f WHERE f.project_id = p.id AND f.status NOT IN ('FALSE_POSITIVE', 'VERIFIED', 'WONT_FIX')) AS findings_open,
         (SELECT count(*) FROM soulbah.security_findings f WHERE f.project_id = p.id AND f.status = 'VERIFIED') AS findings_verified,
         (SELECT count(*) FROM soulbah.incidents i WHERE i.project_id = p.id AND i.status NOT IN ('RESOLVED', 'POSTMORTEM', 'CLOSED')) AS incidents_open,
         (SELECT count(*) FROM soulbah.security_regression_tests t WHERE t.project_id = p.id AND t.status = 'active') AS regression_tests_active,
         (SELECT count(*) FROM soulbah.security_patterns sp WHERE sp.status = 'active' AND sp.projects_affected ? p.id::text) AS patterns_seen,
         (SELECT max(f.detected_at) FROM soulbah.security_findings f WHERE f.project_id = p.id) AS last_finding_at
    FROM soulbah.projects p;
COMMENT ON VIEW soulbah.v_soc_coverage IS 'SOC : par projet, constats (total, ouverts, vérifiés), incidents ouverts, tests de régression actifs, motifs observés — des comptes, pas des scores.';

-- 8. audit_events : lecture structurée du journal d'audit existant (décision transversale : pas de seconde table) -------
CREATE OR REPLACE VIEW soulbah.audit_events AS
  SELECT a.seq, a.id, a.created_at, a.actor,
         split_part(a.actor, ':', 1) AS actor_kind,
         a.action, split_part(a.action, '.', 1) AS category,
         a.entity, a.entity_id, a.user_id, a.session_id, a.task_id,
         a.data ->> 'effect' AS effect, a.data ->> 'reason' AS reason, a.data ->> 'from' AS from_state, a.data ->> 'to' AS to_state,
         a.data, a.prev_hash, a.row_hash
    FROM soulbah.audit_logs a;
COMMENT ON VIEW soulbah.audit_events IS 'Événements d''audit : vue typée sur soulbah.audit_logs (chaîne de hachage conservée) — catégorie, acteur, effet, raison, transition.';

-- 9. Droits ------------------------------------------------------------------------------------------------------
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['security_patterns', 'incidents', 'security_incidents', 'security_findings', 'incident_events', 'incident_actions', 'incident_evidence',
                           'incident_decisions', 'incident_recovery_steps', 'security_fixes', 'security_regression_tests', 'security_detection_rules',
                           'v_soc_active_incidents', 'v_soc_open_findings', 'v_soc_critical_findings', 'v_soc_quarantined_agents', 'v_soc_recent_fixes',
                           'v_soc_regressions', 'v_soc_coverage', 'audit_events'] LOOP
    EXECUTE format('REVOKE ALL ON soulbah.%I FROM PUBLIC', t);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON soulbah.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.security_findings_pattern_stats(), soulbah.incidents_log_status() FROM %I', r);
    END IF;
  END LOOP;
END $$;


-- >>>>>>>>>> 20261002111300_db12_missions_checkpoints.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 12 — Missions, checkpoints, contexte, contrôle de l'ordinateur.
-- REUSE + EXTEND : soulbah.sessions (= missions), soulbah.tasks, soulbah.checkpoints ; NEW : session_checkpoints,
-- context_builds / context_sources / context_items / context_metrics, computer_sessions / computer_observations /
-- computer_permissions ; vue computer_actions sur soulbah.actions (outils bureau, écran, clavier, souris, téléphone).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002111300_db12_missions_checkpoints.down.sql (les colonnes ajoutées aux tables V2 sont retirées)
-- soulbah:transaction=single
-- Dépend de : db01, db02, db03, db09 (tools), db10 (model_versions).
-- =============================================================================

-- 1. Missions = sessions V2, étendues ----------------------------------------------------------------------------
SELECT soulbah.assert_table_shape('soulbah.sessions', '{"goal": "text", "status": "text", "plan": "jsonb", "simulated": "boolean"}');
ALTER TABLE soulbah.sessions
  ADD COLUMN IF NOT EXISTS project_id         uuid REFERENCES soulbah.projects(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS environment_name   text REFERENCES soulbah.environments(name),
  ADD COLUMN IF NOT EXISTS autonomy_level     text,
  ADD COLUMN IF NOT EXISTS mission_kind       text NOT NULL DEFAULT 'order',
  ADD COLUMN IF NOT EXISTS parent_session_id  uuid REFERENCES soulbah.sessions(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS result             text,
  ADD COLUMN IF NOT EXISTS result_summary     text NOT NULL DEFAULT '';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sessions_autonomy_level_check') THEN
    ALTER TABLE soulbah.sessions ADD CONSTRAINT sessions_autonomy_level_check CHECK (autonomy_level IS NULL OR soulbah.is_autonomy_level(autonomy_level));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sessions_mission_kind_check') THEN
    ALTER TABLE soulbah.sessions ADD CONSTRAINT sessions_mission_kind_check
      CHECK (mission_kind IN ('order', 'maintenance', 'research', 'security', 'migration', 'improvement', 'computer_control', 'other'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sessions_result_check') THEN
    ALTER TABLE soulbah.sessions ADD CONSTRAINT sessions_result_check CHECK (result IS NULL OR result IN ('success', 'partial', 'failure', 'cancelled'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sessions_result_summary_length') THEN
    ALTER TABLE soulbah.sessions ADD CONSTRAINT sessions_result_summary_length CHECK (length(result_summary) <= 8000);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sessions_not_own_parent') THEN
    ALTER TABLE soulbah.sessions ADD CONSTRAINT sessions_not_own_parent CHECK (parent_session_id IS NULL OR parent_session_id <> id);
  END IF;
  -- Une mission terminée porte un résultat ; une mission simulée n'est jamais un succès (§9.8).
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sessions_completed_has_result') THEN
    ALTER TABLE soulbah.sessions ADD CONSTRAINT sessions_completed_has_result CHECK (status NOT IN ('COMPLETED', 'FAILED', 'CANCELLED') OR result IS NOT NULL) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sessions_simulated_never_success') THEN
    ALTER TABLE soulbah.sessions ADD CONSTRAINT sessions_simulated_never_success CHECK (NOT (simulated AND result = 'success'));
  END IF;
END $$;
COMMENT ON COLUMN soulbah.sessions.result IS 'Résultat de la mission une fois terminée (success, partial, failure, cancelled) ; contrainte NOT VALID sur l''existant : les sessions terminées avant ce lot n''ont pas de résultat.';
CREATE INDEX IF NOT EXISTS idx_sessions_project ON soulbah.sessions (project_id, created_at DESC) WHERE project_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sessions_environment ON soulbah.sessions (environment_name) WHERE environment_name IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sessions_parent ON soulbah.sessions (parent_session_id) WHERE parent_session_id IS NOT NULL;
-- Résultat par défaut des sessions déjà terminées sans résultat : déduit du statut, jamais « success » (pas de preuve).
UPDATE soulbah.sessions SET result = CASE status WHEN 'FAILED' THEN 'failure' WHEN 'CANCELLED' THEN 'cancelled' ELSE 'partial' END,
                            result_summary = 'Résultat déduit du statut lors du DB LOT 12 (session terminée avant la tenue des résultats).'
 WHERE status IN ('COMPLETED', 'FAILED', 'CANCELLED') AND result IS NULL;
ALTER TABLE soulbah.sessions VALIDATE CONSTRAINT sessions_completed_has_result;

-- Les sessions COMPLETED / FAILED / CANCELLED héritent du résultat ; node-api posera result à l'avenir.
CREATE OR REPLACE FUNCTION soulbah.sessions_default_result()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF NEW.status IN ('COMPLETED', 'FAILED', 'CANCELLED') AND NEW.result IS NULL THEN
    NEW.result := CASE NEW.status WHEN 'FAILED' THEN 'failure' WHEN 'CANCELLED' THEN 'cancelled' WHEN 'COMPLETED' THEN CASE WHEN NEW.simulated THEN 'partial' ELSE 'success' END END;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS sessions_default_result ON soulbah.sessions;
CREATE TRIGGER sessions_default_result BEFORE INSERT OR UPDATE OF status ON soulbah.sessions FOR EACH ROW EXECUTE FUNCTION soulbah.sessions_default_result();

SELECT soulbah.assert_table_shape('soulbah.tasks', '{"session_id": "uuid", "status": "text", "spec": "jsonb"}');
ALTER TABLE soulbah.tasks ADD COLUMN IF NOT EXISTS project_id uuid REFERENCES soulbah.projects(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_project ON soulbah.tasks (project_id) WHERE project_id IS NOT NULL;

-- 2. Checkpoints (§61-62) --------------------------------------------------------------------------------------
SELECT soulbah.assert_table_shape('soulbah.checkpoints', '{"task_id": "uuid", "attempt": "integer", "seq": "integer", "step_cursor": "integer"}');
ALTER TABLE soulbah.checkpoints
  ADD COLUMN IF NOT EXISTS label              text,
  ADD COLUMN IF NOT EXISTS kind               text NOT NULL DEFAULT 'step',
  ADD COLUMN IF NOT EXISTS state_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS resumable          boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS created_by         text NOT NULL DEFAULT current_user;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'checkpoints_kind_check') THEN
    ALTER TABLE soulbah.checkpoints ADD CONSTRAINT checkpoints_kind_check CHECK (kind IN ('step', 'milestone', 'before_risky_action', 'after_risky_action', 'manual'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'checkpoints_label_length') THEN
    ALTER TABLE soulbah.checkpoints ADD CONSTRAINT checkpoints_label_length CHECK (label IS NULL OR length(label) <= 300);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_checkpoints_state_artifact ON soulbah.checkpoints (state_artifact_id);

CREATE TABLE IF NOT EXISTS soulbah.session_checkpoints (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id         uuid NOT NULL REFERENCES soulbah.sessions(id) ON DELETE CASCADE,
  seq                integer NOT NULL CONSTRAINT session_checkpoints_seq_positive CHECK (seq >= 0),
  label              text NOT NULL DEFAULT '' CONSTRAINT session_checkpoints_label_length CHECK (length(label) <= 300),
  kind               text NOT NULL DEFAULT 'milestone' CONSTRAINT session_checkpoints_kind_check CHECK (kind IN ('milestone', 'before_risky_action', 'after_risky_action', 'pause', 'manual')),
  plan_version       integer CONSTRAINT session_checkpoints_plan_version_positive CHECK (plan_version IS NULL OR plan_version >= 0),
  state              jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT session_checkpoints_state_object CHECK (soulbah.is_json_object(state)),
  state_artifact_id  uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  resumable          boolean NOT NULL DEFAULT true,
  created_by         text NOT NULL DEFAULT current_user,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT session_checkpoints_unique UNIQUE (session_id, seq)
);
COMMENT ON TABLE soulbah.session_checkpoints IS 'État d''une mission entre deux tâches (tâches faites, variables, version du plan) pour reprendre là où elle s''est arrêtée ; l''état volumineux va en artefact.';
ALTER TABLE soulbah.session_checkpoints ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_session_checkpoints_artifact ON soulbah.session_checkpoints (state_artifact_id);

-- 3. Contexte (§67-69 : ce qu'un agent a reçu, d'où, à quel coût) ----------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.context_builds (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id           uuid REFERENCES soulbah.sessions(id) ON DELETE CASCADE,
  task_id              uuid REFERENCES soulbah.tasks(id) ON DELETE CASCADE,
  agent_definition_id  uuid REFERENCES soulbah.agent_definitions(id) ON DELETE SET NULL,
  model_version_id     uuid REFERENCES soulbah.model_versions(id) ON DELETE SET NULL,
  purpose              text NOT NULL DEFAULT '' CONSTRAINT context_builds_purpose_length CHECK (length(purpose) <= 1000),
  strategy             text NOT NULL DEFAULT 'default' CONSTRAINT context_builds_strategy_length CHECK (length(strategy) BETWEEN 1 AND 60),
  token_budget         integer CONSTRAINT context_builds_budget_positive CHECK (token_budget IS NULL OR token_budget >= 0),
  tokens_used          integer CONSTRAINT context_builds_used_positive CHECK (tokens_used IS NULL OR tokens_used >= 0),
  status               text NOT NULL DEFAULT 'built' CONSTRAINT context_builds_status_check CHECK (status IN ('built', 'truncated', 'failed')),
  duration_ms          integer CONSTRAINT context_builds_duration_positive CHECK (duration_ms IS NULL OR duration_ms >= 0),
  built_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT context_builds_scope CHECK (session_id IS NOT NULL OR task_id IS NOT NULL)
);
COMMENT ON TABLE soulbah.context_builds IS 'Construction du contexte d''un appel de modèle : budget et jetons consommés, stratégie, troncature.';
ALTER TABLE soulbah.context_builds ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_context_builds_session ON soulbah.context_builds (session_id, built_at DESC);
CREATE INDEX IF NOT EXISTS idx_context_builds_task ON soulbah.context_builds (task_id);
CREATE INDEX IF NOT EXISTS idx_context_builds_agent ON soulbah.context_builds (agent_definition_id);
CREATE INDEX IF NOT EXISTS idx_context_builds_model ON soulbah.context_builds (model_version_id);

CREATE TABLE IF NOT EXISTS soulbah.context_sources (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  build_id    uuid NOT NULL REFERENCES soulbah.context_builds(id) ON DELETE CASCADE,
  kind        text NOT NULL CONSTRAINT context_sources_kind_check CHECK (kind IN (
                'memory_item', 'knowledge_chunk', 'code_file', 'code_symbol', 'project_brain_document', 'db_table', 'api_endpoint', 'user_flow',
                'incident', 'security_pattern', 'skill', 'tool', 'message', 'artifact', 'task_result', 'policy', 'other')),
  source_id   uuid,
  source_ref  text CONSTRAINT context_sources_ref_length CHECK (source_ref IS NULL OR length(source_ref) <= 500),
  score       real CONSTRAINT context_sources_score_range CHECK (score IS NULL OR (score >= 0 AND score <= 1)),
  tokens      integer CONSTRAINT context_sources_tokens_positive CHECK (tokens IS NULL OR tokens >= 0),
  included    boolean NOT NULL DEFAULT true,
  reason      text NOT NULL DEFAULT '' CONSTRAINT context_sources_reason_length CHECK (length(reason) <= 500),
  position    integer CONSTRAINT context_sources_position_positive CHECK (position IS NULL OR position >= 0),
  CONSTRAINT context_sources_target CHECK (source_id IS NOT NULL OR source_ref IS NOT NULL)
);
COMMENT ON TABLE soulbah.context_sources IS 'Sources candidates d''un contexte (mémoire, connaissance, code, cerveau projet, base, API…) : score, jetons, retenue ou non, raison.';
ALTER TABLE soulbah.context_sources ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_context_sources_build ON soulbah.context_sources (build_id, included);
CREATE INDEX IF NOT EXISTS idx_context_sources_source ON soulbah.context_sources (kind, source_id);

CREATE TABLE IF NOT EXISTS soulbah.context_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  build_id      uuid NOT NULL REFERENCES soulbah.context_builds(id) ON DELETE CASCADE,
  position      integer NOT NULL CONSTRAINT context_items_position_positive CHECK (position >= 0),
  role          text NOT NULL CONSTRAINT context_items_role_check CHECK (role IN ('system', 'user', 'assistant', 'tool')),
  kind          text NOT NULL DEFAULT 'text' CONSTRAINT context_items_kind_length CHECK (length(kind) BETWEEN 1 AND 40),
  tokens        integer CONSTRAINT context_items_tokens_positive CHECK (tokens IS NULL OR tokens >= 0),
  content_hash  text CONSTRAINT context_items_hash_format CHECK (content_hash IS NULL OR content_hash ~ '^[0-9a-f]{64}$'),
  source_id     uuid REFERENCES soulbah.context_sources(id) ON DELETE SET NULL,
  redacted      boolean NOT NULL DEFAULT false,
  CONSTRAINT context_items_unique UNIQUE (build_id, position)
);
COMMENT ON TABLE soulbah.context_items IS 'Éléments effectivement envoyés (rôle, jetons, empreinte du contenu, source) — le contenu lui-même n''est pas dupliqué ici.';
ALTER TABLE soulbah.context_items ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_context_items_source ON soulbah.context_items (source_id);

CREATE TABLE IF NOT EXISTS soulbah.context_metrics (
  build_id            uuid PRIMARY KEY REFERENCES soulbah.context_builds(id) ON DELETE CASCADE,
  candidates          integer NOT NULL DEFAULT 0 CONSTRAINT context_metrics_candidates_positive CHECK (candidates >= 0),
  included            integer NOT NULL DEFAULT 0 CONSTRAINT context_metrics_included_positive CHECK (included >= 0),
  duplicates_removed  integer NOT NULL DEFAULT 0 CONSTRAINT context_metrics_duplicates_positive CHECK (duplicates_removed >= 0),
  secrets_redacted    integer NOT NULL DEFAULT 0 CONSTRAINT context_metrics_secrets_positive CHECK (secrets_redacted >= 0),
  truncation_ratio    real CONSTRAINT context_metrics_truncation_range CHECK (truncation_ratio IS NULL OR (truncation_ratio >= 0 AND truncation_ratio <= 1)),
  relevance_estimate  real CONSTRAINT context_metrics_relevance_range CHECK (relevance_estimate IS NULL OR (relevance_estimate >= 0 AND relevance_estimate <= 1)),
  outcome             text NOT NULL DEFAULT 'unknown' CONSTRAINT context_metrics_outcome_check CHECK (outcome IN ('unknown', 'useful', 'insufficient', 'noisy')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT context_metrics_included_bounded CHECK (included <= candidates)
);
COMMENT ON TABLE soulbah.context_metrics IS 'Mesures d''une construction de contexte (candidats, retenus, doublons, secrets masqués, troncature) et utilité constatée a posteriori.';
ALTER TABLE soulbah.context_metrics ENABLE ROW LEVEL SECURITY;

-- 4. Contrôle de l'ordinateur et du téléphone (§63-66) ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS soulbah.computer_sessions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id        uuid REFERENCES soulbah.sessions(id) ON DELETE SET NULL,
  task_id           uuid REFERENCES soulbah.tasks(id) ON DELETE SET NULL,
  runtime_id        uuid REFERENCES soulbah.runtimes(id) ON DELETE SET NULL,
  kind              text NOT NULL CONSTRAINT computer_sessions_kind_check CHECK (kind IN ('desktop', 'phone', 'browser', 'terminal')),
  device_ref        text CONSTRAINT computer_sessions_device_length CHECK (device_ref IS NULL OR length(device_ref) <= 200),
  status            text NOT NULL DEFAULT 'active' CONSTRAINT computer_sessions_status_check CHECK (status IN ('active', 'paused', 'ended', 'aborted')),
  started_by        text NOT NULL DEFAULT current_user,
  started_at        timestamptz NOT NULL DEFAULT now(),
  ended_at          timestamptz,
  recording_id      uuid REFERENCES soulbah.recordings(id) ON DELETE SET NULL,
  actions_count     integer NOT NULL DEFAULT 0 CONSTRAINT computer_sessions_actions_positive CHECK (actions_count >= 0),
  summary           text NOT NULL DEFAULT '' CONSTRAINT computer_sessions_summary_length CHECK (length(summary) <= 4000),
  CONSTRAINT computer_sessions_ended_dated CHECK (status NOT IN ('ended', 'aborted') OR ended_at IS NOT NULL)
);
COMMENT ON TABLE soulbah.computer_sessions IS 'Sessions de contrôle d''un bureau, d''un téléphone, d''un navigateur ou d''un terminal : qui, quand, enregistrement vidéo lié.';
ALTER TABLE soulbah.computer_sessions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_computer_sessions_session ON soulbah.computer_sessions (session_id);
CREATE INDEX IF NOT EXISTS idx_computer_sessions_task ON soulbah.computer_sessions (task_id);
CREATE INDEX IF NOT EXISTS idx_computer_sessions_runtime ON soulbah.computer_sessions (runtime_id);
CREATE INDEX IF NOT EXISTS idx_computer_sessions_recording ON soulbah.computer_sessions (recording_id);
CREATE INDEX IF NOT EXISTS idx_computer_sessions_active ON soulbah.computer_sessions (started_at DESC) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS soulbah.computer_permissions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  computer_session_id  uuid NOT NULL REFERENCES soulbah.computer_sessions(id) ON DELETE CASCADE,
  scope                text NOT NULL CONSTRAINT computer_permissions_scope_check CHECK (scope IN (
                         'screen_read', 'input', 'clipboard', 'files', 'apps', 'network', 'phone_tap', 'phone_calls', 'sms', 'payments', 'credentials')),
  decision             text NOT NULL CONSTRAINT computer_permissions_decision_check CHECK (decision IN ('allow', 'deny')),
  granted_by           text,
  granted_at           timestamptz,
  expires_at           timestamptz,
  revoked_at           timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT computer_permissions_unique UNIQUE (computer_session_id, scope),
  CONSTRAINT computer_permissions_allow_signed CHECK (decision <> 'allow' OR (granted_by IS NOT NULL AND granted_at IS NOT NULL)),
  -- Appels, SMS, paiements et identifiants : jamais sans autorisation humaine explicite (§64-65).
  CONSTRAINT computer_permissions_sensitive_human CHECK (decision <> 'allow' OR scope NOT IN ('phone_calls', 'sms', 'payments', 'credentials') OR granted_by LIKE 'user:%')
);
COMMENT ON TABLE soulbah.computer_permissions IS 'Permissions d''une session de contrôle par périmètre ; les périmètres sensibles (appels, SMS, paiements, identifiants) exigent un humain.';
ALTER TABLE soulbah.computer_permissions ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS soulbah.computer_observations (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  computer_session_id  uuid NOT NULL REFERENCES soulbah.computer_sessions(id) ON DELETE CASCADE,
  action_id            uuid REFERENCES soulbah.actions(id) ON DELETE SET NULL,
  kind                 text NOT NULL CONSTRAINT computer_observations_kind_check CHECK (kind IN (
                         'screenshot', 'ocr', 'ui_snapshot', 'window_list', 'clipboard', 'file_list', 'log', 'audio', 'phone_screen', 'other')),
  artifact_id          uuid REFERENCES soulbah.artifacts(id) ON DELETE SET NULL,
  sensitivity          text NOT NULL DEFAULT 'none' CONSTRAINT computer_observations_sensitivity_check CHECK (sensitivity IN ('none', 'internal', 'pii', 'credentials', 'financial', 'health')),
  retention_class      text NOT NULL DEFAULT 'task' CONSTRAINT computer_observations_retention_check CHECK (retention_class IN ('ephemeral', 'task', 'session', 'permanent')),
  redacted             boolean NOT NULL DEFAULT false,
  summary              text NOT NULL DEFAULT '' CONSTRAINT computer_observations_summary_length CHECK (length(summary) <= 2000),
  metadata             jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT computer_observations_metadata_object CHECK (soulbah.is_json_object(metadata)),
  observed_at          timestamptz NOT NULL DEFAULT now(),
  -- Observations sensibles : rétention éphémère obligatoire (§65 : mots de passe, jetons, banque, données personnelles).
  CONSTRAINT computer_observations_sensitive_retention CHECK (sensitivity IN ('none', 'internal') OR retention_class = 'ephemeral')
);
COMMENT ON TABLE soulbah.computer_observations IS 'Ce que Soulbah a vu (captures, OCR, arbre d''interface, presse-papiers…) : artefact, sensibilité, rétention stricte si sensible.';
ALTER TABLE soulbah.computer_observations ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_computer_observations_session ON soulbah.computer_observations (computer_session_id, observed_at);
CREATE INDEX IF NOT EXISTS idx_computer_observations_action ON soulbah.computer_observations (action_id);
CREATE INDEX IF NOT EXISTS idx_computer_observations_artifact ON soulbah.computer_observations (artifact_id);
CREATE INDEX IF NOT EXISTS idx_computer_observations_sensitive ON soulbah.computer_observations (observed_at) WHERE sensitivity NOT IN ('none', 'internal');

-- Vue : actions de contrôle (outils des catégories bureau et téléphone du registre, synchronisé depuis shared/tools/catalog.json).
CREATE OR REPLACE VIEW soulbah.computer_actions AS
  SELECT a.id, a.task_id, a.user_id, a.attempt, a.step_index, a.tool, t.category AS tool_category, a.params, a.security_level, a.status,
         a.evidence, a.evidence_confidence, a.simulated, a.error, a.started_at, a.finished_at, a.created_at
    FROM soulbah.actions a JOIN soulbah.tools t ON t.name = a.tool
   WHERE t.category IN ('mouse', 'keyboard', 'screen', 'window', 'app_launch', 'phone', 'video', 'voice');
COMMENT ON VIEW soulbah.computer_actions IS 'Actions de contrôle de l''ordinateur ou du téléphone (vue sur soulbah.actions filtrée par la catégorie de l''outil).';

-- 5. Droits ------------------------------------------------------------------------------------------------------
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['session_checkpoints', 'context_builds', 'context_sources', 'context_items', 'context_metrics', 'computer_sessions',
                           'computer_permissions', 'computer_observations', 'computer_actions'] LOOP
    EXECUTE format('REVOKE ALL ON soulbah.%I FROM PUBLIC', t);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON soulbah.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.sessions_default_result() FROM %I', r);
    END IF;
  END LOOP;
END $$;


-- >>>>>>>>>> 20261002111400_db13_self_improvement.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 13 — Auto-amélioration contrôlée : candidats, expériences (mode ombre, benchmark, canari), mesures adossées
-- aux exécutions de benchmark, approbations (ajout seul, humaines pour déployer), déploiements avec version précédente
-- et retour arrière — liés aux versions système (db01) et bloqués tant que system_state.self_improvement = OFF.
-- soulbah:rollback=YES
-- soulbah:recovery=20261002111400_db13_self_improvement.down.sql
-- soulbah:transaction=single
-- Dépend de : db01 (system_versions, system_state), db10 (benchmark_runs).
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.improvement_candidates (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key               text NOT NULL UNIQUE CONSTRAINT improvement_candidates_key_format CHECK (key ~ '^[a-z][a-z0-9_.-]{0,119}$'),
  kind              text NOT NULL CONSTRAINT improvement_candidates_kind_check CHECK (kind IN ('prompt', 'skill', 'tool', 'routing', 'config', 'policy', 'model', 'planner', 'code', 'memory', 'other')),
  title             text NOT NULL CONSTRAINT improvement_candidates_title_length CHECK (length(title) BETWEEN 1 AND 300),
  description       text NOT NULL DEFAULT '' CONSTRAINT improvement_candidates_description_length CHECK (length(description) <= 8000),
  rationale         text NOT NULL DEFAULT '' CONSTRAINT improvement_candidates_rationale_length CHECK (length(rationale) <= 8000),
  source            text NOT NULL CONSTRAINT improvement_candidates_source_check CHECK (source IN ('failure_analysis', 'benchmark', 'watchdog', 'peer_review', 'research', 'human', 'shadow_run')),
  target_component  text NOT NULL CONSTRAINT improvement_candidates_component_format CHECK (target_component ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  target_ref        text CONSTRAINT improvement_candidates_target_ref_length CHECK (target_ref IS NULL OR length(target_ref) <= 500),
  evidence          jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT improvement_candidates_evidence_array CHECK (soulbah.is_json_array(evidence)),
  expected_gain     text NOT NULL DEFAULT '' CONSTRAINT improvement_candidates_gain_length CHECK (length(expected_gain) <= 2000),
  risk              text NOT NULL DEFAULT 'MEDIUM' CONSTRAINT improvement_candidates_risk_check CHECK (soulbah.is_severity(risk)),
  proposed_by       text NOT NULL DEFAULT current_user CONSTRAINT improvement_candidates_proposed_by_length CHECK (length(proposed_by) BETWEEN 1 AND 200),
  status            text NOT NULL DEFAULT 'proposed' CONSTRAINT improvement_candidates_status_check CHECK (status IN (
                      'proposed', 'experimenting', 'evaluated', 'approved', 'deployed', 'rolled_back', 'rejected')),
  decided_by        text,
  decided_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT improvement_candidates_decided CHECK (status NOT IN ('approved', 'rejected') OR (decided_by IS NOT NULL AND decided_at IS NOT NULL))
);
COMMENT ON TABLE soulbah.improvement_candidates IS 'Améliorations candidates (prompt, compétence, outil, routage, configuration, politique, modèle, planificateur…) : origine, preuves, gain attendu, risque, décision.';
ALTER TABLE soulbah.improvement_candidates ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.improvement_candidates', '{"key": "text", "kind": "text", "status": "text", "risk": "text"}');
CREATE INDEX IF NOT EXISTS idx_improvement_candidates_status ON soulbah.improvement_candidates (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_improvement_candidates_component ON soulbah.improvement_candidates (target_component);
DROP TRIGGER IF EXISTS improvement_candidates_set_updated_at ON soulbah.improvement_candidates;
CREATE TRIGGER improvement_candidates_set_updated_at BEFORE UPDATE ON soulbah.improvement_candidates FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.improvement_experiments (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id         uuid NOT NULL REFERENCES soulbah.improvement_candidates(id) ON DELETE CASCADE,
  name                 text NOT NULL CONSTRAINT improvement_experiments_name_length CHECK (length(name) BETWEEN 1 AND 200),
  hypothesis           text NOT NULL DEFAULT '' CONSTRAINT improvement_experiments_hypothesis_length CHECK (length(hypothesis) <= 4000),
  method               text NOT NULL CONSTRAINT improvement_experiments_method_check CHECK (method IN ('offline_eval', 'benchmark', 'shadow', 'ab_test', 'canary', 'replay')),
  environment_name     text NOT NULL DEFAULT 'LOCAL' REFERENCES soulbah.environments(name),
  baseline_version_id  uuid REFERENCES soulbah.system_versions(id) ON DELETE SET NULL,
  status               text NOT NULL DEFAULT 'planned' CONSTRAINT improvement_experiments_status_check CHECK (status IN ('planned', 'running', 'completed', 'failed', 'cancelled')),
  result               jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT improvement_experiments_result_object CHECK (soulbah.is_json_object(result)),
  conclusion           text NOT NULL DEFAULT '' CONSTRAINT improvement_experiments_conclusion_length CHECK (length(conclusion) <= 4000),
  created_by           text NOT NULL DEFAULT current_user,
  started_at           timestamptz,
  finished_at          timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT improvement_experiments_unique UNIQUE (candidate_id, name),
  -- Les expériences ne se mènent jamais en production (§ Self-improvement : laboratoire, ombre, benchmarks).
  CONSTRAINT improvement_experiments_not_production CHECK (environment_name <> 'PRODUCTION'),
  CONSTRAINT improvement_experiments_completed_dated CHECK (status <> 'completed' OR finished_at IS NOT NULL)
);
COMMENT ON TABLE soulbah.improvement_experiments IS 'Expériences d''un candidat (évaluation hors ligne, benchmark, ombre, A/B, canari, rejeu) — jamais en PRODUCTION.';
ALTER TABLE soulbah.improvement_experiments ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_improvement_experiments_baseline ON soulbah.improvement_experiments (baseline_version_id);
CREATE INDEX IF NOT EXISTS idx_improvement_experiments_environment ON soulbah.improvement_experiments (environment_name);

CREATE TABLE IF NOT EXISTS soulbah.improvement_benchmarks (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  experiment_id     uuid NOT NULL REFERENCES soulbah.improvement_experiments(id) ON DELETE CASCADE,
  benchmark_run_id  uuid NOT NULL REFERENCES soulbah.benchmark_runs(id) ON DELETE RESTRICT,
  role              text NOT NULL CONSTRAINT improvement_benchmarks_role_check CHECK (role IN ('baseline', 'candidate')),
  score             numeric(10, 4) NOT NULL CONSTRAINT improvement_benchmarks_score_positive CHECK (score >= 0),
  score_max         numeric(10, 4) NOT NULL CONSTRAINT improvement_benchmarks_score_max_positive CHECK (score_max > 0),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT improvement_benchmarks_unique UNIQUE (experiment_id, benchmark_run_id),
  CONSTRAINT improvement_benchmarks_bounded CHECK (score <= score_max)
);
COMMENT ON TABLE soulbah.improvement_benchmarks IS 'Mesures d''une expérience, toujours adossées à une exécution de benchmark (référence ou candidat).';
ALTER TABLE soulbah.improvement_benchmarks ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_improvement_benchmarks_run ON soulbah.improvement_benchmarks (benchmark_run_id);

CREATE TABLE IF NOT EXISTS soulbah.improvement_approvals (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  candidate_id   uuid NOT NULL REFERENCES soulbah.improvement_candidates(id) ON DELETE RESTRICT,
  experiment_id  uuid REFERENCES soulbah.improvement_experiments(id) ON DELETE RESTRICT,
  decision       text NOT NULL CONSTRAINT improvement_approvals_decision_check CHECK (decision IN ('approved', 'rejected', 'deferred', 'revoked')),
  decider_kind   text NOT NULL CONSTRAINT improvement_approvals_decider_kind_check CHECK (decider_kind IN ('human', 'agent', 'system')),
  decided_by     text NOT NULL CONSTRAINT improvement_approvals_decided_by_length CHECK (length(decided_by) BETWEEN 1 AND 200),
  rationale      text NOT NULL DEFAULT '' CONSTRAINT improvement_approvals_rationale_length CHECK (length(rationale) <= 4000),
  conditions     jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT improvement_approvals_conditions_object CHECK (soulbah.is_json_object(conditions)),
  decided_at     timestamptz NOT NULL DEFAULT now(),
  -- Seul un humain approuve ou révoque ; un agent peut rejeter ou différer.
  CONSTRAINT improvement_approvals_human CHECK (decision NOT IN ('approved', 'revoked') OR decider_kind = 'human')
);
COMMENT ON TABLE soulbah.improvement_approvals IS 'Décisions sur un candidat (ajout seul) ; approuver ou révoquer est réservé à un humain.';
ALTER TABLE soulbah.improvement_approvals ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_improvement_approvals_candidate ON soulbah.improvement_approvals (candidate_id, id);
CREATE INDEX IF NOT EXISTS idx_improvement_approvals_experiment ON soulbah.improvement_approvals (experiment_id);
DROP TRIGGER IF EXISTS improvement_approvals_append_only ON soulbah.improvement_approvals;
CREATE TRIGGER improvement_approvals_append_only BEFORE UPDATE OR DELETE ON soulbah.improvement_approvals FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS improvement_approvals_no_truncate ON soulbah.improvement_approvals;
CREATE TRIGGER improvement_approvals_no_truncate BEFORE TRUNCATE ON soulbah.improvement_approvals FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE TABLE IF NOT EXISTS soulbah.improvement_deployments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id      uuid NOT NULL REFERENCES soulbah.improvement_candidates(id) ON DELETE RESTRICT,
  approval_id       bigint NOT NULL REFERENCES soulbah.improvement_approvals(id) ON DELETE RESTRICT,
  environment_name  text NOT NULL REFERENCES soulbah.environments(name),
  component         text NOT NULL CONSTRAINT improvement_deployments_component_format CHECK (component ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  from_version_id   uuid REFERENCES soulbah.system_versions(id) ON DELETE SET NULL,
  to_version_id     uuid NOT NULL REFERENCES soulbah.system_versions(id) ON DELETE RESTRICT,
  status            text NOT NULL DEFAULT 'pending' CONSTRAINT improvement_deployments_status_check CHECK (status IN ('pending', 'deployed', 'verified', 'rolled_back', 'failed')),
  deployed_by       text,
  deployed_at       timestamptz,
  verified_by       text,
  verified_at       timestamptz,
  rolled_back_at    timestamptz,
  rollback_reason   text CONSTRAINT improvement_deployments_rollback_reason_length CHECK (rollback_reason IS NULL OR length(rollback_reason) <= 4000),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT improvement_deployments_versions_differ CHECK (from_version_id IS NULL OR from_version_id <> to_version_id),
  CONSTRAINT improvement_deployments_deployed_signed CHECK (status NOT IN ('deployed', 'verified') OR (deployed_by IS NOT NULL AND deployed_at IS NOT NULL)),
  CONSTRAINT improvement_deployments_verified_signed CHECK (status <> 'verified' OR (verified_by IS NOT NULL AND verified_at IS NOT NULL)),
  CONSTRAINT improvement_deployments_rollback_reasoned CHECK (status <> 'rolled_back' OR (rolled_back_at IS NOT NULL AND rollback_reason IS NOT NULL))
);
COMMENT ON TABLE soulbah.improvement_deployments IS 'Déploiement d''une amélioration approuvée : version précédente conservée (retour arrière), signatures, motif de retour.';
ALTER TABLE soulbah.improvement_deployments ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_improvement_deployments_candidate ON soulbah.improvement_deployments (candidate_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_improvement_deployments_approval ON soulbah.improvement_deployments (approval_id);
CREATE INDEX IF NOT EXISTS idx_improvement_deployments_environment ON soulbah.improvement_deployments (environment_name);
CREATE INDEX IF NOT EXISTS idx_improvement_deployments_from ON soulbah.improvement_deployments (from_version_id);
CREATE INDEX IF NOT EXISTS idx_improvement_deployments_to ON soulbah.improvement_deployments (to_version_id);
DROP TRIGGER IF EXISTS improvement_deployments_set_updated_at ON soulbah.improvement_deployments;
CREATE TRIGGER improvement_deployments_set_updated_at BEFORE UPDATE ON soulbah.improvement_deployments FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

-- Garde : déployer exige une approbation « approved » non révoquée du même candidat, un candidat approuvé ou déjà
-- déployé, l'auto-amélioration autorisée dans system_state, et jamais PRODUCTION sans production_changes activé.
CREATE OR REPLACE FUNCTION soulbah.improvement_deployments_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
DECLARE st soulbah.system_state%ROWTYPE; ap soulbah.improvement_approvals%ROWTYPE;
BEGIN
  SELECT * INTO ap FROM soulbah.improvement_approvals WHERE id = NEW.approval_id;
  IF ap.candidate_id IS DISTINCT FROM NEW.candidate_id OR ap.decision <> 'approved' THEN
    RAISE EXCEPTION 'soulbah.improvement_deployments : approbation absente, refusée ou d''un autre candidat' USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM soulbah.improvement_approvals r WHERE r.candidate_id = NEW.candidate_id AND r.decision = 'revoked' AND r.id > ap.id) THEN
    RAISE EXCEPTION 'soulbah.improvement_deployments : approbation révoquée' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.status IN ('deployed', 'verified') AND (TG_OP = 'INSERT' OR OLD.status NOT IN ('deployed', 'verified')) THEN
    IF NOT EXISTS (SELECT 1 FROM soulbah.improvement_candidates c WHERE c.id = NEW.candidate_id AND c.status IN ('approved', 'deployed')) THEN
      RAISE EXCEPTION 'soulbah.improvement_deployments : le candidat n''est pas approuvé' USING ERRCODE = 'check_violation';
    END IF;
    SELECT * INTO st FROM soulbah.system_state WHERE id = 1;
    IF st.self_improvement = 'OFF' OR st.safe_mode OR st.emergency_stop THEN
      RAISE EXCEPTION 'soulbah.improvement_deployments : auto-amélioration désactivée (system_state.self_improvement = %, safe_mode = %, emergency_stop = %)',
        st.self_improvement, st.safe_mode, st.emergency_stop USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.environment_name = 'PRODUCTION' AND st.production_changes = 'OFF' THEN
      RAISE EXCEPTION 'soulbah.improvement_deployments : changements de production désactivés (system_state.production_changes = OFF)' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS improvement_deployments_guard ON soulbah.improvement_deployments;
CREATE TRIGGER improvement_deployments_guard BEFORE INSERT OR UPDATE ON soulbah.improvement_deployments FOR EACH ROW EXECUTE FUNCTION soulbah.improvement_deployments_guard();

DO $$
DECLARE r text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['improvement_candidates', 'improvement_experiments', 'improvement_benchmarks', 'improvement_approvals', 'improvement_deployments'] LOOP
    EXECUTE format('REVOKE ALL ON soulbah.%I FROM PUBLIC', t);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON soulbah.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.improvement_deployments_guard() FROM %I', r);
    END IF;
  END LOOP;
END $$;


-- >>>>>>>>>> 20261002111500_db14_observability.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 14 — Observabilité : définitions de contrôles de santé, événements de santé (ajout seul, alimentent
-- system_health), métriques de ressources (ajout seul avec purge contrôlée), notifications au PDG (§51, §88).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002111500_db14_observability.down.sql (les séries de mesures seraient perdues)
-- soulbah:transaction=single
-- Dépend de : db01 (system_health).
-- =============================================================================

CREATE TABLE IF NOT EXISTS soulbah.health_checks (
  key               text PRIMARY KEY CONSTRAINT health_checks_key_format CHECK (key ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  component         text NOT NULL CONSTRAINT health_checks_component_format CHECK (component ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  kind              text NOT NULL CONSTRAINT health_checks_kind_check CHECK (kind IN ('http', 'tcp', 'sql', 'process', 'file', 'queue', 'model', 'custom')),
  target            text NOT NULL DEFAULT '' CONSTRAINT health_checks_target_length CHECK (length(target) <= 500),
  interval_s        integer NOT NULL DEFAULT 60 CONSTRAINT health_checks_interval_range CHECK (interval_s BETWEEN 5 AND 86400),
  timeout_s         integer NOT NULL DEFAULT 10 CONSTRAINT health_checks_timeout_range CHECK (timeout_s BETWEEN 1 AND 600),
  enabled           boolean NOT NULL DEFAULT true,
  severity_on_fail  text NOT NULL DEFAULT 'MEDIUM' CONSTRAINT health_checks_severity_check CHECK (soulbah.is_severity(severity_on_fail)),
  description       text NOT NULL DEFAULT '' CONSTRAINT health_checks_description_length CHECK (length(description) <= 1000),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT health_checks_timeout_lt_interval CHECK (timeout_s < interval_s)
);
COMMENT ON TABLE soulbah.health_checks IS 'Contrôles de santé déclarés (composant, genre, cible, cadence, sévérité en cas d''échec) ; enregistrés par node-api au démarrage.';
ALTER TABLE soulbah.health_checks ENABLE ROW LEVEL SECURITY;
SELECT soulbah.assert_table_shape('soulbah.health_checks', '{"key": "text", "component": "text", "interval_s": "integer", "enabled": "boolean"}');
CREATE INDEX IF NOT EXISTS idx_health_checks_component ON soulbah.health_checks (component);
DROP TRIGGER IF EXISTS health_checks_set_updated_at ON soulbah.health_checks;
CREATE TRIGGER health_checks_set_updated_at BEFORE UPDATE ON soulbah.health_checks FOR EACH ROW EXECUTE FUNCTION soulbah.set_updated_at();

CREATE TABLE IF NOT EXISTS soulbah.health_events (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  check_key        text REFERENCES soulbah.health_checks(key) ON DELETE RESTRICT,
  component        text NOT NULL CONSTRAINT health_events_component_format CHECK (component ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  status           text NOT NULL CONSTRAINT health_events_status_check CHECK (status IN ('healthy', 'degraded', 'down', 'unknown')),
  previous_status  text CONSTRAINT health_events_previous_check CHECK (previous_status IS NULL OR previous_status IN ('healthy', 'degraded', 'down', 'unknown')),
  latency_ms       integer CONSTRAINT health_events_latency_positive CHECK (latency_ms IS NULL OR latency_ms >= 0),
  detail           jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT health_events_detail_object CHECK (soulbah.is_json_object(detail)),
  observed_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.health_events IS 'Résultats des contrôles de santé (ajout seul) ; chaque événement met à jour soulbah.system_health pour son composant.';
ALTER TABLE soulbah.health_events ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_health_events_component ON soulbah.health_events (component, id DESC);
CREATE INDEX IF NOT EXISTS idx_health_events_check ON soulbah.health_events (check_key);
CREATE INDEX IF NOT EXISTS idx_health_events_transitions ON soulbah.health_events (observed_at DESC) WHERE previous_status IS DISTINCT FROM status;
DROP TRIGGER IF EXISTS health_events_append_only ON soulbah.health_events;
CREATE TRIGGER health_events_append_only BEFORE UPDATE OR DELETE ON soulbah.health_events FOR EACH ROW EXECUTE FUNCTION soulbah.append_only();
DROP TRIGGER IF EXISTS health_events_no_truncate ON soulbah.health_events;
CREATE TRIGGER health_events_no_truncate BEFORE TRUNCATE ON soulbah.health_events FOR EACH STATEMENT EXECUTE FUNCTION soulbah.append_only();

CREATE OR REPLACE FUNCTION soulbah.health_events_apply()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  INSERT INTO soulbah.system_health (component, status, detail, checked_at)
  VALUES (NEW.component, NEW.status, NEW.detail || jsonb_build_object('check_key', NEW.check_key, 'latency_ms', NEW.latency_ms), NEW.observed_at)
  ON CONFLICT (component) DO UPDATE
    SET status = EXCLUDED.status, detail = EXCLUDED.detail, checked_at = EXCLUDED.checked_at
    WHERE soulbah.system_health.checked_at IS NULL OR soulbah.system_health.checked_at <= EXCLUDED.checked_at;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS health_events_apply ON soulbah.health_events;
CREATE TRIGGER health_events_apply AFTER INSERT ON soulbah.health_events FOR EACH ROW EXECUTE FUNCTION soulbah.health_events_apply();

-- Métriques : ajout seul, mais purge possible par la seule fonction de rétention (jamais de DELETE direct).
CREATE TABLE IF NOT EXISTS soulbah.resource_metrics (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  host         text NOT NULL DEFAULT '' CONSTRAINT resource_metrics_host_length CHECK (length(host) <= 200),
  component    text NOT NULL CONSTRAINT resource_metrics_component_format CHECK (component ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  metric       text NOT NULL CONSTRAINT resource_metrics_metric_format CHECK (metric ~ '^[a-z][a-z0-9_.]{0,99}$'),
  value        numeric(18, 4) NOT NULL,
  unit         text NOT NULL DEFAULT '' CONSTRAINT resource_metrics_unit_length CHECK (length(unit) <= 40),
  labels       jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT resource_metrics_labels_object CHECK (soulbah.is_json_object(labels)),
  observed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE soulbah.resource_metrics IS 'Séries de mesures (CPU, RAM, GPU, VRAM, disque, base, modèles, agents, files) ; ajout seul, purge par soulbah.purge_resource_metrics() uniquement.';
ALTER TABLE soulbah.resource_metrics ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_resource_metrics_lookup ON soulbah.resource_metrics (metric, component, observed_at DESC);
CREATE INDEX IF NOT EXISTS idx_resource_metrics_time ON soulbah.resource_metrics (observed_at);

CREATE OR REPLACE FUNCTION soulbah.retention_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'soulbah.% est en ajout seul (UPDATE refusé)', TG_TABLE_NAME USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF coalesce(current_setting('soulbah.retention_purge', true), '') <> 'on' THEN
    RAISE EXCEPTION 'soulbah.% : suppression réservée à la purge de rétention (% refusé)', TG_TABLE_NAME, TG_OP USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN COALESCE(OLD, NEW);
END $$;
COMMENT ON FUNCTION soulbah.retention_guard() IS 'Trigger : refuse UPDATE ; refuse DELETE/TRUNCATE sauf sous soulbah.retention_purge = on (posé par la fonction de purge).';
DROP TRIGGER IF EXISTS resource_metrics_retention ON soulbah.resource_metrics;
CREATE TRIGGER resource_metrics_retention BEFORE UPDATE OR DELETE ON soulbah.resource_metrics FOR EACH ROW EXECUTE FUNCTION soulbah.retention_guard();
DROP TRIGGER IF EXISTS resource_metrics_no_truncate ON soulbah.resource_metrics;
CREATE TRIGGER resource_metrics_no_truncate BEFORE TRUNCATE ON soulbah.resource_metrics FOR EACH STATEMENT EXECUTE FUNCTION soulbah.retention_guard();

CREATE OR REPLACE FUNCTION soulbah.purge_resource_metrics(p_older_than interval DEFAULT interval '30 days')
RETURNS bigint LANGUAGE plpgsql SET search_path = soulbah, pg_temp AS $$
DECLARE n bigint;
BEGIN
  IF p_older_than < interval '1 day' THEN
    RAISE EXCEPTION 'soulbah.purge_resource_metrics : rétention minimale d''un jour' USING ERRCODE = 'check_violation';
  END IF;
  PERFORM set_config('soulbah.retention_purge', 'on', true);
  DELETE FROM soulbah.resource_metrics WHERE observed_at < now() - p_older_than;
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM set_config('soulbah.retention_purge', '', true);
  RETURN n;
END $$;
COMMENT ON FUNCTION soulbah.purge_resource_metrics(interval) IS 'Purge des mesures plus anciennes que l''intervalle (minimum un jour) ; seul chemin de suppression ; renvoie le nombre de lignes purgées.';

CREATE TABLE IF NOT EXISTS soulbah.notifications (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind          text NOT NULL CONSTRAINT notifications_kind_check CHECK (kind IN ('alert', 'approval_request', 'incident', 'report', 'info', 'watchdog', 'resource')),
  severity      text NOT NULL DEFAULT 'INFO' CONSTRAINT notifications_severity_check CHECK (soulbah.is_severity(severity)),
  title         text NOT NULL CONSTRAINT notifications_title_length CHECK (length(title) BETWEEN 1 AND 300),
  body          text NOT NULL DEFAULT '' CONSTRAINT notifications_body_length CHECK (length(body) <= 8000),
  recipient     text NOT NULL CONSTRAINT notifications_recipient_format CHECK (recipient ~ '^(user:[0-9a-f-]{36}|role:[a-z_]+|all)$'),
  channel       text NOT NULL DEFAULT 'ui' CONSTRAINT notifications_channel_check CHECK (channel IN ('ui', 'email', 'sms', 'push', 'log')),
  status        text NOT NULL DEFAULT 'pending' CONSTRAINT notifications_status_check CHECK (status IN ('pending', 'sent', 'delivered', 'read', 'failed', 'dismissed', 'expired')),
  related_kind  text CONSTRAINT notifications_related_kind_length CHECK (related_kind IS NULL OR length(related_kind) <= 60),
  related_id    uuid,
  dedupe_key    text UNIQUE CONSTRAINT notifications_dedupe_length CHECK (dedupe_key IS NULL OR length(dedupe_key) <= 300),
  action_url    text CONSTRAINT notifications_action_url_length CHECK (action_url IS NULL OR length(action_url) <= 1000),
  created_at    timestamptz NOT NULL DEFAULT now(),
  sent_at       timestamptz,
  read_at       timestamptz,
  expires_at    timestamptz,
  CONSTRAINT notifications_read_dated CHECK (status <> 'read' OR read_at IS NOT NULL),
  CONSTRAINT notifications_sent_dated CHECK (status NOT IN ('sent', 'delivered', 'read') OR sent_at IS NOT NULL)
);
COMMENT ON TABLE soulbah.notifications IS 'Notifications au PDG et aux rôles (alertes, demandes d''approbation, incidents, rapports) : destinataire, canal, dédoublonnage, cycle envoi/lecture.';
ALTER TABLE soulbah.notifications ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS idx_notifications_recipient ON soulbah.notifications (recipient, created_at DESC) WHERE status IN ('pending', 'sent', 'delivered');
CREATE INDEX IF NOT EXISTS idx_notifications_related ON soulbah.notifications (related_kind, related_id);

DO $$
DECLARE r text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['health_checks', 'health_events', 'resource_metrics', 'notifications'] LOOP
    EXECUTE format('REVOKE ALL ON soulbah.%I FROM PUBLIC', t);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON soulbah.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
  REVOKE ALL ON FUNCTION soulbah.purge_resource_metrics(interval) FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON FUNCTION soulbah.health_events_apply(), soulbah.retention_guard(), soulbah.purge_resource_metrics(interval) FROM %I', r);
    END IF;
  END LOOP;
END $$;


-- >>>>>>>>>> 20261002111600_db15_indexes_performance.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 15 — Index et performance : index couvrant de chaque clé étrangère encore sans index (relevé automatique
-- sur la base intégrée des lots 01 à 14, schémas public et soulbah : 23 clés), partiel sur les colonnes nullables.
-- Les index partiels des files (tâches READY, approbations pending, tâches RETRYING, baux) existent déjà en V2.
-- Tables de quelques lignes aujourd'hui : création dans la transaction, sans CONCURRENTLY (transaction=none à utiliser
-- le jour où une table est volumineuse).
-- soulbah:rollback=YES
-- soulbah:recovery=20261002111600_db15_indexes_performance.down.sql
-- soulbah:transaction=single
-- Dépend de : tous les lots précédents (les index portent sur leurs tables).
-- =============================================================================

-- agent_memory_source_task_fk → soulbah.tasks
CREATE INDEX IF NOT EXISTS idx_agent_memory_source_task_id ON public.agent_memory (source_task_id) WHERE source_task_id IS NOT NULL;
-- chat_messages_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_chat_messages_user_id ON public.chat_messages (user_id);
-- knowledge_versions_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_knowledge_versions_user_id ON public.knowledge_versions (user_id);
-- user_migrations_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_user_migrations_user_id ON public.user_migrations (user_id);
-- user_table_data_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_user_table_data_user_id ON public.user_table_data (user_id);
-- actions_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_actions_user_id ON soulbah.actions (user_id);
-- agent_assignments_environment_name_fkey → soulbah.environments
CREATE INDEX IF NOT EXISTS idx_agent_assignments_environment_name ON soulbah.agent_assignments (environment_name);
-- agent_permissions_environment_name_fkey → soulbah.environments
CREATE INDEX IF NOT EXISTS idx_agent_permissions_environment_name ON soulbah.agent_permissions (environment_name);
-- agents_current_task_fk → soulbah.tasks
CREATE INDEX IF NOT EXISTS idx_agents_current_task_id ON soulbah.agents (current_task_id) WHERE current_task_id IS NOT NULL;
-- agents_runtime_id_fkey → soulbah.runtimes
CREATE INDEX IF NOT EXISTS idx_agents_runtime_id ON soulbah.agents (runtime_id) WHERE runtime_id IS NOT NULL;
-- agents_version_id_fkey → soulbah.agent_definition_versions
CREATE INDEX IF NOT EXISTS idx_agents_version_id ON soulbah.agents (version_id) WHERE version_id IS NOT NULL;
-- artifacts_session_id_fkey → soulbah.sessions
CREATE INDEX IF NOT EXISTS idx_artifacts_session_id ON soulbah.artifacts (session_id) WHERE session_id IS NOT NULL;
-- autonomy_rules_environment_name_fkey → soulbah.environments
CREATE INDEX IF NOT EXISTS idx_autonomy_rules_environment_name ON soulbah.autonomy_rules (environment_name);
-- evaluations_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_evaluations_user_id ON soulbah.evaluations (user_id);
-- messages_from_agent_id_fkey → soulbah.agents
CREATE INDEX IF NOT EXISTS idx_messages_from_agent_id ON soulbah.messages (from_agent_id) WHERE from_agent_id IS NOT NULL;
-- messages_reply_to_fkey → soulbah.messages
CREATE INDEX IF NOT EXISTS idx_messages_reply_to ON soulbah.messages (reply_to) WHERE reply_to IS NOT NULL;
-- permissions_action_id_fkey → soulbah.actions
CREATE INDEX IF NOT EXISTS idx_permissions_action_id ON soulbah.permissions (action_id) WHERE action_id IS NOT NULL;
-- permissions_decided_by_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_permissions_decided_by ON soulbah.permissions (decided_by) WHERE decided_by IS NOT NULL;
-- policy_rules_environment_name_fkey → soulbah.environments
CREATE INDEX IF NOT EXISTS idx_policy_rules_environment_name ON soulbah.policy_rules (environment_name) WHERE environment_name IS NOT NULL;
-- projects_owner_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_projects_owner_user_id ON soulbah.projects (owner_user_id) WHERE owner_user_id IS NOT NULL;
-- recordings_artifact_id_fkey → soulbah.artifacts
CREATE INDEX IF NOT EXISTS idx_recordings_artifact_id ON soulbah.recordings (artifact_id) WHERE artifact_id IS NOT NULL;
-- recordings_user_id_fkey → auth.users
CREATE INDEX IF NOT EXISTS idx_recordings_user_id ON soulbah.recordings (user_id);
-- tool_calls_action_id_fkey → soulbah.actions
CREATE INDEX IF NOT EXISTS idx_tool_calls_action_id ON soulbah.tool_calls (action_id) WHERE action_id IS NOT NULL;

-- Index V2 en double (mêmes colonnes qu'un index UNIQUE existant, relevé par le test de ce lot) : retirés, l'index
-- unique sert aux mêmes requêtes. Recréés à l'identique par le retour arrière.
DROP INDEX IF EXISTS soulbah.idx_actions_task;               -- doublon de actions_idempotency (task_id, attempt, step_index)
DROP INDEX IF EXISTS soulbah.idx_knowledge_chunks_document;  -- doublon de knowledge_chunks_unique (document_id, chunk_index)

-- Vérification : plus aucune clé étrangère de public ni de soulbah sans index en tête
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(c.conrelid::regclass::text || '(' || a.attname || ')', ', ' ORDER BY c.conrelid::regclass::text) INTO bad
    FROM pg_constraint c
    JOIN pg_namespace ns ON ns.oid = c.connamespace
    JOIN LATERAL unnest(c.conkey) WITH ORDINALITY k(attnum, ord) ON k.ord = 1
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
   WHERE c.contype = 'f' AND ns.nspname IN ('public', 'soulbah')
     AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.conrelid AND i.indkey[0] = k.attnum);
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'DB LOT 15 : clés étrangères encore sans index : %', bad; END IF;
END $$;


-- >>>>>>>>>> 20261002111700_db16_hardening.sql <<<<<<<<<<

-- =============================================================================
-- DB LOT 16 — Hardening.
--  1. Schéma soulbah : EXECUTE retiré à PUBLIC, anon et authenticated sur toutes les fonctions présentes (PostgreSQL
--     l'accorde à PUBLIC par défaut à la création) ; node-api (propriétaire postgres ou rôle soulbah_api) garde ses
--     droits. Les fonctions futures relèvent de la convention « REVOKE … FROM PUBLIC » de chaque migration.
--  2. Schéma public : anon et authenticated perdent TRUNCATE, TRIGGER, REFERENCES, MAINTAIN (jamais exercés par
--     PostgREST, hors RLS) sur les tables présentes et futures du rôle courant.
--  3. Rôle soulbah_api (s'il existe) : droits sur les objets des lots et par défaut sur les objets futurs de soulbah.
--  4. Vérification finale (lève une exception, donc annule tout) : RLS sur chaque table de soulbah ; aucun droit
--     anon/authenticated/PUBLIC sur ses tables, vues, séquences et fonctions ; chaque journal « ajout seul » protégé par
--     trigger ; un commentaire sur chaque table et vue ; chaque clé étrangère de soulbah indexée ; règles « jamais ».
-- soulbah:rollback=PARTIAL
-- soulbah:recovery=20261002111700_db16_hardening.down.sql (rend les droits retirés, retire les privilèges par défaut ajoutés ; les vérifications n'ont rien créé)
-- soulbah:transaction=single
-- Dépend de : tous les lots précédents. Non fait (hors périmètre, à évaluer sur Supabase) : déplacer pgvector hors de
-- public ; retirer EXECUTE par défaut de anon/authenticated sur les fonctions futures de public (SEC-07/SEC-10).
-- =============================================================================

-- 0. Documentation des tables et vues V2 qui n'avaient pas de commentaire (rôle en une phrase) ------------------------
COMMENT ON TABLE soulbah.actions IS 'V2 — actions exécutées par les agents : outil du catalogue, paramètres (secrets masqués), niveau de sécurité, états planned → verified, preuves typées ; une action simulée n''est jamais « vérifiée ».';
COMMENT ON TABLE soulbah.agents IS 'V2 — instances d''agents d''une session (rôle et version, statut, runtime porteur), étendues par le DB LOT 3 (définition, version, issue, fin).';
COMMENT ON TABLE soulbah.artifacts IS 'V2 — artefacts produits (fichier, capture, vidéo, journal, rapport, diff) : empreinte, taille, emplacement de stockage, classe de rétention — jamais le contenu.';
COMMENT ON TABLE soulbah.audit_chain_head IS 'V2 — tête de la chaîne de hachage du journal d''audit (dernier numéro, dernier hachage) ; ligne unique mise à jour par trigger.';
COMMENT ON TABLE soulbah.audit_logs IS 'V2 — journal d''audit chaîné par hachage (ajout seul) : acteur, action, entité, données masquées ; la vue audit_events (DB LOT 11) le lit de façon typée.';
COMMENT ON TABLE soulbah.checkpoints IS 'V2 — points de reprise d''une tentative de tâche (curseur d''étape, variables), étendus par le DB LOT 12 (libellé, genre, artefact d''état, reprise possible).';
COMMENT ON TABLE soulbah.evaluations IS 'V2 — évaluation d''une tentative de tâche (critères, résultats, verdict, confiance, preuves, suite donnée) ; une seule par tentative.';
COMMENT ON TABLE soulbah.knowledge_chunks IS 'V2 — fragments indexés des documents de connaissance : texte, recherche plein texte, vecteur sans dimension fixe et modèle d''embedding (étendu par le DB LOT 6).';
COMMENT ON TABLE soulbah.messages IS 'V2 — messages entre agents et vers l''utilisateur dans une session (question, blocage, preuve, résultat, demande de revue), accusés de réception.';
COMMENT ON TABLE soulbah.permissions IS 'V2 — permissions de session (L1/L2) et demandes d''approbation par action (L2/L3) liées au contenu présenté ; jeton d''approbation stocké haché.';
COMMENT ON TABLE soulbah.recordings IS 'V2 — enregistrements d''écran d''une tâche (chemin, durée, images par seconde, sonde) liés à un artefact.';
COMMENT ON TABLE soulbah.resource_leases IS 'V2 — baux exclusifs ou partagés sur une ressource (ex. entrées du bureau d''un PC) : exclusivité garantie par index unique partiel.';
COMMENT ON TABLE soulbah.runtimes IS 'V2 — processus superviseurs des PC (clé agent, hôte, version, capacité en emplacements), vus par le plan de contrôle.';
COMMENT ON TABLE soulbah.sessions IS 'V2 — missions (sessions multi-agents) : objectif, statut, plan versionné, budget, simulation ; étendues par le DB LOT 12 (projet, environnement, autonomie, résultat).';
COMMENT ON TABLE soulbah.skills IS 'V2 — compétences : outils du catalogue et procédures apprises, versionnées (UNIQUE nom + version) ; étendues par le DB LOT 9 (versions, étapes, tests, candidats).';
COMMENT ON TABLE soulbah.task_dependencies IS 'V2 — dépendances entre tâches (arêtes du DAG, dures ou souples) avec trigger anti-cycle.';
COMMENT ON TABLE soulbah.tasks IS 'V2 — tâches d''une mission : nœud du plan, rôle, statut, bail, tentatives, spécification, critères d''acceptation, résultat ; étendues par les DB LOT 3 et 12.';
COMMENT ON TABLE soulbah.tool_calls IS 'V2 — métrage de chaque appel d''outil (code de sortie) ou de modèle (jetons, coût, fournisseur) par tâche et par utilisateur.';
COMMENT ON TABLE soulbah.user_settings IS 'V2 — réglages par utilisateur (parallélisme maximal, préférences de la page Paramètres).';
COMMENT ON VIEW soulbah.knowledge_documents IS 'V2 — vue sur public.knowledge_base : source, statut d''ingestion et statut documentaire des documents de connaissance.';
COMMENT ON VIEW soulbah.memories IS 'V2 — vue sur public.agent_memory : mémoire V1 (leçons, préférences) lue par le plan de contrôle ; les éléments validés sont copiés dans memory_items (DB LOT 5).';

-- 1. Fonctions du schéma soulbah ---------------------------------------------------------------------------------
DO $$
DECLARE r text;
BEGIN
  -- Fonctions présentes. Pas de ALTER DEFAULT PRIVILEGES par schéma : une entrée par schéma s'ajoute au défaut global
  -- (qui donne EXECUTE à PUBLIC) et ne peut rien lui retirer. Règle : chaque migration retire PUBLIC de ses
  -- fonctions (docs/db/DB_MIGRATION_CONVENTIONS.md) ; la vérification ci-dessous attrape tout oubli.
  REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA soulbah FROM PUBLIC;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA soulbah FROM %I', r);
      EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA soulbah FROM %I', r);
      EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA soulbah FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- 2. Schéma public : droits que PostgREST n'exerce jamais et que la RLS ne couvre pas ------------------------------------
DO $$
DECLARE r text; privs text;
BEGIN
  privs := 'TRUNCATE, TRIGGER, REFERENCES' || CASE WHEN current_setting('server_version_num')::int >= 170000 THEN ', MAINTAIN' ELSE '' END;
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE %s ON ALL TABLES IN SCHEMA public FROM %I', privs, r);
      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE %s ON TABLES FROM %I', privs, r);
    END IF;
  END LOOP;
END $$;

-- 3. Rôle de moindre privilège soulbah_api (node-api) ---------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'soulbah_api') THEN
    GRANT USAGE ON SCHEMA soulbah TO soulbah_api;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA soulbah TO soulbah_api;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA soulbah TO soulbah_api;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA soulbah TO soulbah_api;
    REVOKE UPDATE, DELETE, TRUNCATE ON soulbah.audit_logs FROM soulbah_api;
    ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO soulbah_api;
    ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah GRANT USAGE, SELECT ON SEQUENCES TO soulbah_api;
    ALTER DEFAULT PRIVILEGES IN SCHEMA soulbah GRANT EXECUTE ON FUNCTIONS TO soulbah_api;
    RAISE NOTICE 'Hardening : droits de soulbah_api accordés sur le schéma soulbah (objets présents et futurs)';
  ELSE
    RAISE NOTICE 'Hardening : rôle soulbah_api absent — node-api se connecte en postgres (SEC-06) ; créer le rôle puis rejouer scripts/sql/soulbah_api_grants.sql';
  END IF;
END $$;

-- 4. Vérifications : chaque manquement lève une exception et annule la migration -------------------------------------
DO $$
DECLARE
  bad text; n integer;
BEGIN
  -- RLS sur toute table du schéma soulbah
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'soulbah' AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : RLS absente sur soulbah.%', bad; END IF;

  -- Aucun droit de anon, authenticated ni PUBLIC sur les tables et vues de soulbah
  SELECT string_agg(DISTINCT g.table_name || ':' || g.grantee, ', ') INTO bad
    FROM information_schema.role_table_grants g
   WHERE g.table_schema = 'soulbah' AND g.grantee IN ('anon', 'authenticated', 'PUBLIC');
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : droits anon/authenticated/PUBLIC sur soulbah : %', bad; END IF;

  -- Séquences et fonctions de soulbah : rien pour anon ni authenticated (ni via PUBLIC)
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
      FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname = 'soulbah' AND c.relkind = 'S'
       AND (has_sequence_privilege('anon', c.oid, 'USAGE, SELECT, UPDATE') OR has_sequence_privilege('authenticated', c.oid, 'USAGE, SELECT, UPDATE'));
    IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : séquences de soulbah accessibles à anon/authenticated : %', bad; END IF;
    SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO bad
      FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'soulbah' AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));
    IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : fonctions de soulbah exécutables par anon/authenticated : %', bad; END IF;
  END IF;

  -- Journaux déclarés « ajout seul » (commentaire) : trigger d'ajout seul ou de rétention présent
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'soulbah' AND c.relkind = 'r'
     AND COALESCE(obj_description(c.oid, 'pg_class'), '') ILIKE '%ajout seul%'
     AND NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                      WHERE t.tgrelid = c.oid AND NOT t.tgisinternal
                        AND p.proname IN ('append_only', 'retention_guard', 'policy_versions_freeze', 'guardrails_track', 'audit_logs_immutable', 'schema_migration_runs_append_only'));
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : journaux sans trigger d''ajout seul : %', bad; END IF;

  -- Commentaire sur chaque table et vue de soulbah
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO bad
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'soulbah' AND c.relkind IN ('r', 'v', 'p') AND obj_description(c.oid, 'pg_class') IS NULL;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : tables ou vues sans commentaire : %', bad; END IF;

  -- Clés étrangères de soulbah : chaque colonne référençante est en tête d'un index
  SELECT string_agg(c.conrelid::regclass::text || '(' || a.attname || ')', ', ' ORDER BY c.conrelid::regclass::text) INTO bad
    FROM pg_constraint c
    JOIN pg_namespace ns ON ns.oid = c.connamespace
    JOIN LATERAL unnest(c.conkey) WITH ORDINALITY k(attnum, ord) ON k.ord = 1
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
   WHERE c.contype = 'f' AND ns.nspname = 'soulbah'
     AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.conrelid AND i.indkey[0] = k.attnum);
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : clés étrangères sans index : %', bad; END IF;

  -- Plus aucun droit TRUNCATE/TRIGGER/REFERENCES/MAINTAIN de anon/authenticated sur public
  SELECT string_agg(DISTINCT g.table_name || ':' || g.grantee || ':' || g.privilege_type, ', ') INTO bad
    FROM information_schema.role_table_grants g
   WHERE g.table_schema = 'public' AND g.grantee IN ('anon', 'authenticated') AND g.privilege_type IN ('TRUNCATE', 'TRIGGER', 'REFERENCES', 'MAINTAIN');
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Hardening : droits restants sur public : %', bad; END IF;

  -- Les règles « jamais » de l'audit tiennent toujours (§12 docs/SUPABASE_REPRISE.md)
  IF to_regclass('public.agent_tasks') IS NOT NULL AND (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'agent_tasks_status_check' AND conrelid = 'public.agent_tasks'::regclass)
     IS DISTINCT FROM 'CHECK ((status = ANY (ARRAY[''pending''::text, ''in_progress''::text, ''completed''::text, ''failed''::text, ''cancelled''::text])))' THEN
    RAISE EXCEPTION 'Jamais : le CHECK de statut de public.agent_tasks a changé';
  END IF;
  IF to_regclass('public.agent_events') IS NOT NULL AND EXISTS (
       SELECT 1 FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
        WHERE c.conrelid = 'public.agent_events'::regclass AND c.contype = 'f' AND a.attname = 'task_id') THEN
    RAISE EXCEPTION 'Jamais : FK sur public.agent_events.task_id';
  END IF;
  IF to_regclass('public.modules_status') IS NULL THEN RAISE EXCEPTION 'Jamais : public.modules_status a été supprimée'; END IF;

  SELECT count(*) INTO n FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace WHERE ns.nspname = 'soulbah' AND c.relkind = 'r';
  RAISE NOTICE 'Hardening : % tables du schéma soulbah vérifiées (RLS, droits, journaux, commentaires, index de clés étrangères)', n;
END $$;

-- 5. Trace : version de schéma dans system_versions (idempotente) ---------------------------------------------------
INSERT INTO soulbah.system_versions (component, version, status, reason, activated_by, activated_at, config)
VALUES ('database.schema', '2026-10-02.lots-01-16', 'active', 'DB LOT 16 : architecture cible appliquée et vérifiée', current_user, now(),
        jsonb_build_object('lots', 16, 'hardening', true))
ON CONFLICT (component, version) DO NOTHING;


COMMIT;
