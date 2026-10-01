// Client HTTP typé vers l'API Node (node-api).
export const API_URL = import.meta.env.VITE_API_URL ?? "http://localhost:3000";

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

export interface HealthResponse {
  status: string;
  checks?: Record<string, string>;
}

/** Flux complet : Node → Python IA → Rust → Postgres. */
export async function analyze(text: string): Promise<AnalyzeResponse> {
  const res = await fetch(`${API_URL}/api/analyze`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text }),
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as { error?: string };
    throw new Error(body.error ?? `Erreur ${res.status}`);
  }
  return (await res.json()) as AnalyzeResponse;
}

/** État de santé de l'API et de ses dépendances (Postgres, service IA). */
export async function deepHealth(): Promise<HealthResponse> {
  const res = await fetch(`${API_URL}/health/deep`);
  if (!res.ok) throw new Error(`Erreur ${res.status}`);
  return (await res.json()) as HealthResponse;
}
