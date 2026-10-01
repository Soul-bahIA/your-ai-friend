// Connexion LOCALE (V3) : l'interface fonctionne sans Supabase, avec le jeton de développement
// que node-api accepte en AUTH_MODE=dev-local (boucle locale et SOULBAH_ENV dev/test uniquement).
//
// Garde-fous :
//   - serveur de développement Vite seulement (import.meta.env.DEV) : une version de production
//     ignore ces variables, même si elles ont été définies au build ;
//   - VITE_AUTH_MODE=dev-local + VITE_DEV_LOCAL_TOKEN (≥ 32 caractères) + VITE_DEV_LOCAL_USER_ID
//     (uuid de l'utilisateur créé par scripts/dev_db/dev_db.sh seed) ; sinon : Supabase, comme avant.
import type { Session, User } from "@supabase/supabase-js";

export interface DevLocalAuth {
  token: string;
  userId: string;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function devLocalAuthFrom(env: Record<string, unknown>): DevLocalAuth | null {
  if (!env.DEV) return null;
  if (String(env.VITE_AUTH_MODE ?? "").trim().toLowerCase() !== "dev-local") return null;
  const token = String(env.VITE_DEV_LOCAL_TOKEN ?? "").trim();
  const userId = String(env.VITE_DEV_LOCAL_USER_ID ?? "").trim();
  if (token.length < 32 || !UUID_RE.test(userId)) return null;
  return { token, userId };
}

/** Configuration de la connexion locale, ou null (connexion Supabase habituelle). */
export function devLocalAuth(): DevLocalAuth | null {
  return devLocalAuthFrom(import.meta.env as unknown as Record<string, unknown>);
}

/** Session au format Supabase pour l'utilisateur de développement local. */
export function devLocalSession(auth: DevLocalAuth): Session {
  const user = {
    id: auth.userId,
    email: "dev@soulbah.local",
    aud: "authenticated",
    role: "authenticated",
    app_metadata: { provider: "dev-local" },
    user_metadata: { full_name: "Développeur local" },
    created_at: new Date(0).toISOString(),
  } as unknown as User;
  return {
    access_token: auth.token,
    refresh_token: "",
    token_type: "bearer",
    expires_in: 24 * 3600,
    expires_at: Math.floor(Date.now() / 1000) + 24 * 3600,
    user,
  } as Session;
}
