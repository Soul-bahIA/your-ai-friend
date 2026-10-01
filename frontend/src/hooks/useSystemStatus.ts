import { useQuery } from "@tanstack/react-query";
import { apiUrl } from "@/lib/api";
import { supabase } from "@/integrations/supabase/client";
import { computeOverallStatus, deepCheck, type DeepHealth, type OverallStatus, type ServiceState } from "@/lib/systemStatus";

const TIMEOUT_MS = 5000;
const REFRESH_MS = 30_000;

async function probe(path: string): Promise<Response> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    return await fetch(apiUrl(path), { signal: ctrl.signal, cache: "no-store" });
  } finally {
    clearTimeout(timer);
  }
}

async function fetchBackendHealth(): Promise<ServiceState> {
  try {
    const r = await probe("/health");
    if (!r.ok) return "down";
    const body = (await r.json().catch(() => null)) as { status?: string } | null;
    return body?.status === "ok" ? "ok" : "down";
  } catch {
    return "down";
  }
}

async function fetchDeepHealth(): Promise<DeepHealth | null> {
  try {
    const r = await probe("/health/deep");
    if (r.status === 404) return null; // non implémenté
    return ((await r.json().catch(() => null)) as DeepHealth | null) ?? { status: "down" };
  } catch {
    return null;
  }
}

/** Sondes de santé du backend (rafraîchies toutes les 30 s). */
export function useBackendHealth() {
  const backend = useQuery({
    queryKey: ["health", "backend"],
    queryFn: fetchBackendHealth,
    refetchInterval: REFRESH_MS,
    retry: false,
  });
  const deep = useQuery({
    queryKey: ["health", "deep"],
    queryFn: fetchDeepHealth,
    refetchInterval: REFRESH_MS,
    retry: false,
    enabled: backend.data === "ok",
  });
  return {
    backend: backend.data ?? ("unknown" as ServiceState),
    deep: backend.data === "ok" ? deep.data ?? null : null,
    deepPending: backend.data === "ok" && deep.isPending,
    refetch: () => {
      backend.refetch();
      if (backend.data === "ok") deep.refetch();
    },
  };
}

/** Supabase joignable : requête minimale (son propre profil, RLS), rafraîchie toutes les 60 s. */
async function fetchSupabaseHealth(): Promise<ServiceState> {
  try {
    const { error } = await supabase.from("profiles").select("id", { count: "exact", head: true });
    return error ? "down" : "ok";
  } catch {
    return "down";
  }
}

export interface SystemStatus {
  overall: OverallStatus;
  backend: ServiceState;
  supabase: ServiceState;
  postgres: ServiceState;
  pythonIa: ServiceState;
}

/** État réel du système (backend, dépendances profondes, Supabase) pour la barre latérale. */
export function useSystemStatus(): SystemStatus {
  const health = useBackendHealth();
  const supa = useQuery({
    queryKey: ["health", "supabase"],
    queryFn: fetchSupabaseHealth,
    refetchInterval: 60_000,
    retry: false,
  });
  const supabaseState: ServiceState = supa.data ?? "unknown";
  const down = health.backend === "down";
  return {
    overall: computeOverallStatus({ backend: health.backend, deep: health.deep, supabase: supabaseState }),
    backend: health.backend,
    supabase: supabaseState,
    postgres: down ? "down" : deepCheck(health.deep, "postgres"),
    pythonIa: down ? "down" : deepCheck(health.deep, "python_ia"),
  };
}
