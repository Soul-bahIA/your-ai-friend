// Analyse de la liste d'origines CORS autorisées (env CORS_ORIGINS, séparées par des virgules).

export const DEFAULT_CORS_ORIGINS = ["http://localhost:8080", "http://127.0.0.1:8080"];

/** "*" → ["*"] (toutes origines) ; vide/absent → défaut ; sinon liste nettoyée (sans / final). */
export function parseCorsOrigins(raw: string | undefined | null): string[] {
  if (raw === undefined || raw === null || raw.trim() === "") return [...DEFAULT_CORS_ORIGINS];
  const list = raw
    .split(",")
    .map((s) => s.trim().replace(/\/+$/, ""))
    .filter(Boolean);
  if (list.includes("*")) return ["*"];
  return [...new Set(list)];
}

/** Requêtes sans en-tête Origin (curl, agent local, serveur-à-serveur) : autorisées. */
export function isOriginAllowed(origin: string | undefined, allowed: string[]): boolean {
  if (!origin) return true;
  if (allowed.includes("*")) return true;
  return allowed.includes(origin.replace(/\/+$/, ""));
}
