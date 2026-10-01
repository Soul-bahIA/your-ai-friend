// Barre de santé de la console : décodage de GET /health/deep et message affiché.
// Module pur, sans dépendance (testé sous Node : `npm test`).
//
// Hors SOULBAH_ENV=dev, /health/deep exige un JWT (S18) : un 401/403 veut dire « connexion
// requise », pas « API injoignable » (T32). Une requête qui n'obtient AUCUNE réponse lisible
// vient d'un backend arrêté ou d'un blocage CORS (l'origine de la console, http://localhost:5173
// par défaut, doit figurer dans CORS_ORIGINS du backend).

export interface HealthResponse {
  status: string;
  checks?: Record<string, string>;
}

/** Résultat d'une sonde GET /health/deep. */
export type HealthProbe =
  | { kind: "ok"; health: HealthResponse }
  /** Réponse HTTP non-2xx. */
  | { kind: "http"; status: number }
  /** Réponse 2xx inexploitable. */
  | { kind: "invalid" }
  /** Aucune réponse lisible : backend arrêté, ou requête bloquée par CORS. */
  | { kind: "network" };

export type HealthTone = "ok" | "warn" | "down";

export interface HealthView {
  tone: HealthTone;
  message: string;
  /** Dépendances (postgres, python_ia…) et leur pastille. */
  checks: Array<[string, HealthTone]>;
}

const isRecord = (v: unknown): v is Record<string, unknown> =>
  !!v && typeof v === "object" && !Array.isArray(v);

/** Décode une réponse de GET /health/deep (statut HTTP + corps JSON déjà lu, ou null). */
export function probeFromResponse(httpStatus: number, body: unknown): HealthProbe {
  if (httpStatus < 200 || httpStatus >= 300) return { kind: "http", status: httpStatus };
  if (!isRecord(body) || typeof body.status !== "string") return { kind: "invalid" };
  const checks: Record<string, string> = {};
  if (isRecord(body.checks)) {
    for (const [name, value] of Object.entries(body.checks)) checks[name] = typeof value === "string" ? value : "down";
  }
  return { kind: "ok", health: { status: body.status, checks } };
}

/** Message et pastilles de la barre de santé ; `origin` = origine de la console (indice CORS). */
export function healthView(probe: HealthProbe | null, origin = "http://localhost:5173"): HealthView {
  if (!probe) return { tone: "warn", message: "Vérification des services…", checks: [] };
  switch (probe.kind) {
    case "network":
      return {
        tone: "down",
        message:
          `API injoignable — le backend est-il démarré, et l'origine ${origin} figure-t-elle dans ` +
          "CORS_ORIGINS du backend ?",
        checks: [],
      };
    case "http":
      if (probe.status === 401 || probe.status === 403) {
        return {
          tone: "warn",
          message: "Connexion requise : l'état détaillé (GET /health/deep) exige une session hors SOULBAH_ENV=dev.",
          checks: [],
        };
      }
      return { tone: "down", message: `API en erreur (HTTP ${probe.status})`, checks: [] };
    case "invalid":
      return { tone: "down", message: "Réponse inattendue de l'API (GET /health/deep)", checks: [] };
    case "ok": {
      const checks = Object.entries(probe.health.checks ?? {}).map(
        ([name, state]): [string, HealthTone] => [name, state === "ok" ? "ok" : "down"],
      );
      return { tone: probe.health.status === "ok" ? "ok" : "warn", message: `API ${probe.health.status}`, checks };
    }
  }
}
