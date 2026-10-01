// Authentification de la console : /api/analyze exige un JWT Supabase (T32).
// Deux moyens : connexion e-mail / mot de passe (API REST GoTrue de Supabase, sans
// dépendance) si VITE_SUPABASE_URL et VITE_SUPABASE_KEY sont définis, ou collage
// d'un jeton (JWT) obtenu ailleurs. Le jeton est gardé pour l'onglet (sessionStorage).

const STORAGE_KEY = "soulbah-console-token";

export const SUPABASE_URL = (import.meta.env.VITE_SUPABASE_URL ?? "").trim().replace(/\/+$/, "");
export const SUPABASE_KEY = (
  import.meta.env.VITE_SUPABASE_KEY ??
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY ??
  import.meta.env.VITE_SUPABASE_ANON_KEY ??
  ""
).trim();

export const passwordLoginAvailable = SUPABASE_URL !== "" && SUPABASE_KEY !== "";

export interface StoredSession {
  token: string;
  email: string | null;
  /** Expiration (secondes epoch) lue dans le JWT, si présente. */
  exp: number | null;
}

type Listener = (session: StoredSession | null) => void;
const listeners = new Set<Listener>();

/** Décode la charge utile d'un JWT (sans vérifier la signature : c'est le rôle du backend). */
export function decodeJwt(token: string): Record<string, unknown> | null {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
    const json = decodeURIComponent(
      atob(padded)
        .split("")
        .map((c) => `%${c.charCodeAt(0).toString(16).padStart(2, "0")}`)
        .join(""),
    );
    const payload: unknown = JSON.parse(json);
    return payload && typeof payload === "object" ? (payload as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function toSession(token: string): StoredSession | null {
  const payload = decodeJwt(token);
  if (!payload) return null;
  return {
    token,
    email: typeof payload.email === "string" ? payload.email : null,
    exp: typeof payload.exp === "number" ? payload.exp : null,
  };
}

function storage(): Storage | null {
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

let memoryToken: string | null = null;

/** Session courante (null si absente ou expirée). */
export function getSession(): StoredSession | null {
  const token = storage()?.getItem(STORAGE_KEY) ?? memoryToken;
  if (!token) return null;
  const session = toSession(token);
  if (!session || (session.exp !== null && session.exp * 1000 <= Date.now())) return null;
  return session;
}

function save(token: string | null) {
  memoryToken = token;
  const s = storage();
  if (s) {
    if (token) s.setItem(STORAGE_KEY, token);
    else s.removeItem(STORAGE_KEY);
  }
  const session = token ? toSession(token) : null;
  listeners.forEach((l) => l(session));
}

export function onSessionChange(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** Enregistre un JWT collé par l'utilisateur (vérification de forme et d'expiration). */
export function setManualToken(raw: string): StoredSession {
  const token = raw.trim().replace(/^Bearer\s+/i, "");
  const session = toSession(token);
  if (!session) throw new Error("Jeton invalide : collez un JWT Supabase (trois segments séparés par des points).");
  if (session.exp !== null && session.exp * 1000 <= Date.now()) throw new Error("Ce jeton a expiré.");
  save(token);
  return session;
}

/** Connexion e-mail / mot de passe via l'API d'authentification de Supabase. */
export async function signInWithPassword(email: string, password: string): Promise<StoredSession> {
  if (!passwordLoginAvailable) {
    throw new Error("Connexion indisponible : définissez VITE_SUPABASE_URL et VITE_SUPABASE_KEY.");
  }
  let res: Response;
  try {
    res = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: SUPABASE_KEY },
      body: JSON.stringify({ email, password }),
    });
  } catch {
    throw new Error("Supabase injoignable.");
  }
  const body = (await res.json().catch(() => ({}))) as {
    access_token?: string;
    error_description?: string;
    msg?: string;
    error?: string;
  };
  if (!res.ok || !body.access_token) {
    throw new Error(body.error_description || body.msg || body.error || `Connexion refusée (HTTP ${res.status}).`);
  }
  const session = toSession(body.access_token);
  if (!session) throw new Error("Jeton reçu illisible.");
  save(body.access_token);
  return session;
}

/** Déconnexion locale ; prévient le backend (invalidation du cache JWT), erreurs ignorées. */
export async function signOut(apiUrl: string): Promise<void> {
  const session = getSession();
  save(null);
  if (!session) return;
  try {
    await fetch(`${apiUrl}/api/auth/logout`, {
      method: "POST",
      headers: { Authorization: `Bearer ${session.token}` },
    });
  } catch {
    // best-effort
  }
}

/** En-tête Authorization si une session est active. */
export function authHeaders(): Record<string, string> {
  const session = getSession();
  return session ? { Authorization: `Bearer ${session.token}` } : {};
}
