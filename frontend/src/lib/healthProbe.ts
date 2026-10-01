// Sondes HTTP de santé du backend Node (barre latérale, tableau de bord).
//  - GET /health : liveness publique ;
//  - GET /health/deep : JWT exigé hors SOULBAH_ENV=dev (S18) → jeton de session joint quand il
//    existe ; une réponse sans `checks` (401/403, 404, 5xx, corps invalide) donne null, c.-à-d.
//    « non vérifié », que computeOverallStatus ne transforme jamais en « opérationnel » (T31).
import { apiUrl } from "@/lib/api";
import { supabase } from "@/integrations/supabase/client";
import { parseDeepHealth, type DeepHealth, type ServiceState } from "@/lib/systemStatus";
import { devLocalAuth } from "@/lib/localAuth";

export const PROBE_TIMEOUT_MS = 5000;

async function probe(path: string, headers?: Record<string, string>): Promise<Response> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), PROBE_TIMEOUT_MS);
  try {
    return await fetch(apiUrl(path), { signal: ctrl.signal, cache: "no-store", headers });
  } finally {
    clearTimeout(timer);
  }
}

/** GET /health : "ok" si le backend répond `{status:"ok"}`, "down" sinon. */
export async function fetchBackendHealth(): Promise<ServiceState> {
  try {
    const r = await probe("/health");
    if (!r.ok) return "down";
    const body = (await r.json().catch(() => null)) as { status?: string } | null;
    return body?.status === "ok" ? "ok" : "down";
  } catch {
    return "down";
  }
}

/** Jeton d'accès de la session courante, ou null (pas de session / client indisponible). */
async function sessionToken(): Promise<string | null> {
  const local = devLocalAuth();
  if (local) return local.token;
  try {
    const { data } = await supabase.auth.getSession();
    return data.session?.access_token ?? null;
  } catch {
    return null;
  }
}

/** GET /health/deep avec le JWT de la session ; null si l'état des dépendances n'est pas vérifiable. */
export async function fetchDeepHealth(): Promise<DeepHealth | null> {
  try {
    const token = await sessionToken();
    const r = await probe("/health/deep", token ? { Authorization: `Bearer ${token}` } : undefined);
    const body: unknown = await r.json().catch(() => null);
    return parseDeepHealth(r.status, body);
  } catch {
    return null;
  }
}
