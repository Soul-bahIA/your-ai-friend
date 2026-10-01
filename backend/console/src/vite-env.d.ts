/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_API_URL?: string;
  /** URL du projet Supabase (connexion e-mail / mot de passe de la console). */
  readonly VITE_SUPABASE_URL?: string;
  /** Clé publique (anon / publishable) Supabase. */
  readonly VITE_SUPABASE_KEY?: string;
  readonly VITE_SUPABASE_PUBLISHABLE_KEY?: string;
  readonly VITE_SUPABASE_ANON_KEY?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
