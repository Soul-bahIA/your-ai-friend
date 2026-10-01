import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { fetchBackendHealth, fetchDeepHealth } from "@/lib/healthProbe";
import { computeOverallStatus, deepCheck, type OverallStatus, type ServiceState } from "@/lib/systemStatus";
import { devLocalAuth } from "@/lib/localAuth";

const REFRESH_MS = 30_000;

/** Sondes de santé du backend (rafraîchies toutes les 30 s). /health/deep part avec le JWT (T31). */
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
  if (devLocalAuth()) return "unknown"; // connexion locale : Supabase n'est pas utilisé
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
    overall: computeOverallStatus({
      backend: health.backend,
      deep: health.deep,
      supabase: supabaseState,
      deepPending: health.deepPending,
    }),
    backend: health.backend,
    supabase: supabaseState,
    postgres: down ? "down" : deepCheck(health.deep, "postgres"),
    pythonIa: down ? "down" : deepCheck(health.deep, "python_ia"),
  };
}
