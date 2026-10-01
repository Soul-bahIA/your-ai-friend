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
  seq          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
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


COMMIT;
