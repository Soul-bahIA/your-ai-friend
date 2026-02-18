
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
