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
  /** GET /health/deep décodé par parseDeepHealth (null : non vérifié — 401, 404, réponse invalide…). */
  deep: DeepHealth | null;
  /** Supabase joignable (requête de comptage réussie). */
  supabase: ServiceState;
  /** Première sonde /health/deep encore en cours. */
  deepPending?: boolean;
}

export const overallLabels: Record<OverallStatus, string> = {
  operational: "Opérationnel",
  degraded: "Dégradé",
  offline: "Hors ligne",
  checking: "Vérification…",
};

const isPlainRecord = (v: unknown): v is Record<string, unknown> =>
  !!v && typeof v === "object" && !Array.isArray(v);

/**
 * Décode la réponse de GET /health/deep. Hors SOULBAH_ENV=dev la route exige un JWT : un
 * 401/403 (`{error:"Non authentifié"}`), un 404, un 5xx ou un corps sans `checks` ne disent
 * RIEN de Postgres ni du service IA → null (« non vérifié »), jamais un faux « ok » (T31).
 * Une valeur de check non textuelle est lue comme une panne. Pur, exporté pour les tests.
 */
export function parseDeepHealth(httpStatus: number, body: unknown): DeepHealth | null {
  if (httpStatus < 200 || httpStatus >= 300 || !isPlainRecord(body) || !isPlainRecord(body.checks)) return null;
  const checks: Record<string, string> = {};
  for (const [name, value] of Object.entries(body.checks)) checks[name] = typeof value === "string" ? value : "down";
  if (Object.keys(checks).length === 0) return null;
  return typeof body.status === "string" ? { status: body.status, checks } : { checks };
}

/** Calcule l'état global à partir des sondes. Pur, exporté pour les tests. */
export function computeOverallStatus({ backend, deep, supabase, deepPending = false }: StatusInputs): OverallStatus {
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
  // « Opérationnel » exige des dépendances profondes VÉRIFIÉES et toutes « ok » (T31).
  if (deepChecks.length > 0) return "operational";
  // Postgres / service IA non vérifiés (401 hors dev, 404, réponse invalide) : jamais « opérationnel ».
  return deepPending ? "checking" : "degraded";
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
