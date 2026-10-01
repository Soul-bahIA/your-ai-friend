// Client HTTP typé vers l'API Node (node-api).
import { authHeaders } from "./auth";
import { probeFromResponse, type HealthProbe } from "./health";

export type { HealthProbe, HealthResponse } from "./health";

export const API_URL = (import.meta.env.VITE_API_URL ?? "http://localhost:3000").replace(/\/+$/, "");

export interface ComputeResult {
  count: number;
  sum: number;
  mean: number;
  std_dev: number;
  norm: number;
  primes_under_limit: number;
}

export interface AnalyzeResponse {
  requestId: string;
  label: string;
  score: number;
  compute: ComputeResult;
}

/** Erreur HTTP de l'API (le statut permet de distinguer un 401). */
export class ApiError extends Error {
  readonly status: number;
  constructor(message: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

/** Flux complet : Node → Python IA → Rust → Postgres. Exige une session (JWT). */
export async function analyze(text: string): Promise<AnalyzeResponse> {
  const headers: Record<string, string> = { "Content-Type": "application/json", ...authHeaders() };
  if (!headers.Authorization) {
    throw new ApiError("Connectez-vous (ou collez un jeton) pour lancer une analyse.", 401);
  }
  const res = await fetch(`${API_URL}/api/analyze`, {
    method: "POST",
    headers,
    body: JSON.stringify({ text }),
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as { error?: string };
    if (res.status === 401) throw new ApiError("Session refusée ou expirée : reconnectez-vous.", 401);
    throw new ApiError(body.error ?? `Erreur ${res.status}`, res.status);
  }
  return (await res.json()) as AnalyzeResponse;
}

/**
 * État de santé de l'API et de ses dépendances (Postgres, service IA). Ne lève jamais :
 * distingue « pas de réponse » (backend arrêté / CORS), un refus HTTP (401 hors dev) et un état lu.
 */
export async function deepHealth(): Promise<HealthProbe> {
  let res: Response;
  try {
    res = await fetch(`${API_URL}/health/deep`, { headers: authHeaders() });
  } catch {
    return { kind: "network" };
  }
  const body: unknown = await res.json().catch(() => null);
  return probeFromResponse(res.status, body);
}
