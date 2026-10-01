// Client HTTP unique vers le backend Node (remplace les appels aux edge functions Supabase).
// - URL de base : VITE_API_URL (repli sur http://localhost:3000)
// - Jeton Supabase attaché automatiquement
// - Erreurs normalisées (messages en français)
import { supabase } from "@/integrations/supabase/client";
import { sanitizeMediaUrl } from "@/lib/url";

const DEFAULT_API_URL = "http://localhost:3000";

/** Résout l'URL de base du backend. Exporté pour les tests. */
export function resolveApiUrl(
  env: { VITE_API_URL?: string; PROD?: boolean },
  log: (msg: string) => void = (m) => console.error(m),
): string {
  const raw = env.VITE_API_URL?.trim();
  if (!raw) {
    if (env.PROD) {
      log(
        `[API] VITE_API_URL n'est pas défini pour ce build de production — repli sur ${DEFAULT_API_URL}. ` +
          "Définissez VITE_API_URL au moment du build.",
      );
    }
    return DEFAULT_API_URL;
  }
  return raw.replace(/\/+$/, "");
}

export const API_URL = resolveApiUrl({
  VITE_API_URL: import.meta.env.VITE_API_URL,
  PROD: import.meta.env.PROD,
});

export const apiUrl = (path: string) => `${API_URL}${path.startsWith("/") ? path : `/${path}`}`;

/** Erreur HTTP normalisée renvoyée par apiFetch / apiFetchRaw. */
export class ApiError extends Error {
  readonly status: number;
  constructor(message: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

export const SESSION_EXPIRED_MESSAGE = "Session expirée. Veuillez vous reconnecter.";
export const TOO_MANY_REQUESTS_MESSAGE = "Trop de requêtes. Patientez quelques instants avant de réessayer.";
export const AI_UNAVAILABLE_MESSAGE = "Service IA indisponible pour le moment. Réessayez plus tard.";
export const NETWORK_ERROR_MESSAGE = "Backend injoignable. Vérifiez votre connexion ou que le serveur est démarré.";

/** Extrait le message d'erreur d'un corps JSON ({ error } / { message } / { reason }). */
function extractServerMessage(body: unknown): string | undefined {
  if (!body || typeof body !== "object") return undefined;
  const b = body as Record<string, unknown>;
  for (const key of ["error", "message", "reason"]) {
    const v = b[key];
    if (typeof v === "string" && v.trim()) return v;
    if (v && typeof v === "object" && typeof (v as { message?: unknown }).message === "string") {
      return (v as { message: string }).message;
    }
  }
  return undefined;
}

/** Message utilisateur pour un statut HTTP non-2xx. Pur, exporté pour les tests. */
export function errorMessageForStatus(status: number, body?: unknown): string {
  if (status === 401) return SESSION_EXPIRED_MESSAGE;
  if (status === 429) return TOO_MANY_REQUESTS_MESSAGE;
  if (status === 502 || status === 503) return AI_UNAVAILABLE_MESSAGE;
  return extractServerMessage(body) ?? `Erreur serveur (HTTP ${status}).`;
}

/** Construit une ApiError à partir d'une réponse non-2xx (lit le corps une seule fois). */
export async function toApiError(resp: Response): Promise<ApiError> {
  let body: unknown;
  try {
    const text = await resp.text();
    try {
      body = text ? JSON.parse(text) : undefined;
    } catch {
      body = { error: text.slice(0, 300) };
    }
  } catch {
    body = undefined;
  }
  return new ApiError(errorMessageForStatus(resp.status, body), resp.status);
}

/** Jeton d'accès Supabase courant ; lève ApiError(401) s'il n'y a pas de session. */
export async function getAccessToken(): Promise<string> {
  const { data } = await supabase.auth.getSession();
  const token = data.session?.access_token;
  if (!token) throw new ApiError(SESSION_EXPIRED_MESSAGE, 401);
  return token;
}

export type ApiInit = Omit<RequestInit, "body"> & {
  /** Objet sérialisé en JSON, ou corps brut (string/FormData...). */
  json?: unknown;
  body?: BodyInit | null;
  /** Désactive l'ajout automatique du jeton (endpoints publics comme /health). */
  auth?: boolean;
};

/**
 * Requête brute vers le backend : renvoie la Response telle quelle si 2xx
 * (utile pour le streaming SSE), lève une ApiError sinon.
 */
export async function apiFetchRaw(path: string, init: ApiInit = {}): Promise<Response> {
  const { json, auth = true, headers: initHeaders, ...rest } = init;
  const headers = new Headers(initHeaders);
  if (auth) headers.set("Authorization", `Bearer ${await getAccessToken()}`);
  let body = rest.body;
  if (json !== undefined) {
    body = JSON.stringify(json);
    if (!headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  }

  let resp: Response;
  try {
    resp = await fetch(apiUrl(path), { ...rest, headers, body });
  } catch (err) {
    if (err instanceof DOMException && err.name === "AbortError") throw err;
    throw new ApiError(NETWORK_ERROR_MESSAGE, 0);
  }
  if (!resp.ok) throw await toApiError(resp);
  return resp;
}

/** Requête JSON vers le backend : renvoie le corps décodé, lève une ApiError si non-2xx. */
export async function apiFetch<T = unknown>(path: string, init: ApiInit = {}): Promise<T> {
  const resp = await apiFetchRaw(path, init);
  if (resp.status === 204) return undefined as T;
  const text = await resp.text();
  if (!text) return undefined as T;
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new ApiError("Réponse invalide du serveur.", resp.status);
  }
}

/** Message lisible pour n'importe quelle erreur attrapée. */
export function errorMessage(err: unknown, fallback = "Une erreur est survenue."): string {
  if (err instanceof Error && err.message) return err.message;
  if (typeof err === "string" && err) return err;
  return fallback;
}

export const isAbortError = (err: unknown) =>
  err instanceof DOMException && err.name === "AbortError";

/** URL de média sûre (préfixée par l'API pour /media/...), ou null si refusée. */
export const safeMediaUrl = (url: unknown): string | null => sanitizeMediaUrl(url, API_URL);
