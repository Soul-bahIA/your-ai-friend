// Agrégation honnête de l'état du système (tableau de bord).

export type ServiceState = "ok" | "down" | "unknown";
export type OverallStatus = "operational" | "degraded" | "offline" | "checking";

export interface DeepHealth {
  status?: string;
  checks?: Record<string, string>;
}

export interface StatusInputs {
  /** GET /health du backend Node. */
  backend: ServiceState;
  /** GET /health/deep (null si indisponible / non implémenté). */
  deep: DeepHealth | null;
  /** Supabase joignable (requête de comptage réussie). */
  supabase: ServiceState;
}

export const overallLabels: Record<OverallStatus, string> = {
  operational: "Opérationnel",
  degraded: "Dégradé",
  offline: "Hors ligne",
  checking: "Vérification…",
};

/** Calcule l'état global à partir des sondes. Pur, exporté pour les tests. */
export function computeOverallStatus({ backend, deep, supabase }: StatusInputs): OverallStatus {
  if (backend === "unknown" || supabase === "unknown") {
    // Encore en cours : si une sonde connue est déjà en échec, on le dit tout de suite.
    if (backend === "down" || supabase === "down") return "degraded";
    return "checking";
  }
  if (backend === "down" && supabase === "down") return "offline";
  if (backend === "down" || supabase === "down") return "degraded";
  const deepChecks = deep?.checks ? Object.values(deep.checks) : [];
  if (deep?.status && deep.status !== "ok") return "degraded";
  if (deepChecks.some((v) => v !== "ok")) return "degraded";
  return "operational";
}

/** État d'une dépendance remontée par /health/deep (postgres, python_ia...). */
export function deepCheck(deep: DeepHealth | null, name: string): ServiceState {
  const v = deep?.checks?.[name];
  if (v === undefined) return "unknown";
  return v === "ok" ? "ok" : "down";
}

export interface StatusView {
  label: string;
  /** Classe Tailwind de la pastille. */
  dotClass: string;
  pulse: boolean;
}

const STATUS_DOT: Record<OverallStatus, string> = {
  operational: "bg-success",
  degraded: "bg-warning",
  offline: "bg-destructive",
  checking: "bg-muted-foreground",
};

/** Pastille + libellé de la barre latérale, dérivés de l'état réel (T31). */
export function statusView(overall: OverallStatus): StatusView {
  const label = overall === "checking" ? "Vérification des services…" : `Système ${overallLabels[overall].toLowerCase()}`;
  return { label, dotClass: STATUS_DOT[overall], pulse: overall === "operational" || overall === "checking" };
}

export const SERVICE_STATE_LABELS: Record<ServiceState, string> = {
  ok: "OK",
  down: "hors ligne",
  unknown: "inconnu",
};
