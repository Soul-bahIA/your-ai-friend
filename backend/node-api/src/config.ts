// Configuration centralisée, lue depuis l'environnement (fournie par docker-compose / .env).
import { parseCorsOrigins } from "./lib/cors.js";

const num = (v: string | undefined, def: number): number => {
  const n = Number(v);
  return v !== undefined && v.trim() !== "" && Number.isFinite(n) ? n : def;
};

/** Liste séparée par des virgules → valeurs nettoyées, minuscules, sans doublon. */
export function parseList(raw: string | undefined | null): string[] {
  if (!raw) return [];
  return [...new Set(raw.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean))];
}

/**
 * TRUST_PROXY → option `trustProxy` de Fastify (adresse IP réelle derrière un proxy,
 * utilisée par la limitation de débit) :
 *  - vide / "false" / "0" → false (défaut : connexion directe, request.ip = pair TCP) ;
 *  - "true" → true (fait confiance à tout X-Forwarded-For : seulement derrière un proxy maîtrisé) ;
 *  - entier n ≥ 1 → nombre de sauts de proxy de confiance ;
 *  - sinon : liste d'adresses/CIDR de proxys de confiance (séparées par des virgules).
 */
export function parseTrustProxy(raw: string | undefined): boolean | number | string[] {
  const v = (raw ?? "").trim();
  if (!v || v.toLowerCase() === "false" || v === "0") return false;
  if (v.toLowerCase() === "true") return true;
  if (/^\d+$/.test(v)) return Number(v);
  return v.split(",").map((s) => s.trim()).filter(Boolean);
}

export const config = {
  // Environnement : dev | test | staging | production (défaut dev). Hors dev/test, des
  // garde-fous de démarrage s'appliquent (lib/envChecks.ts).
  soulbahEnv: (process.env.SOULBAH_ENV ?? "dev").trim().toLowerCase() || "dev",

  port: num(process.env.PORT, 3000),
  // Par défaut on n'écoute qu'en local ; docker-compose force HOST=0.0.0.0.
  host: process.env.HOST || "127.0.0.1",
  trustProxy: parseTrustProxy(process.env.TRUST_PROXY),

  // Origines autorisées (CORS), séparées par des virgules. "*" = toutes (déconseillé).
  corsOrigins: parseCorsOrigins(process.env.CORS_ORIGINS),

  // Base de données : Postgres de Supabase (chaîne de connexion directe / pooler).
  databaseUrl:
    process.env.DATABASE_URL ?? "postgres://soulbah:soulbah@postgres:5432/soulbah",
  databaseSsl: (process.env.DATABASE_SSL ?? "").toLowerCase() === "true",
  // Chemin d'un certificat CA (PEM) : active la vérification TLS stricte du serveur.
  pgSslCa: process.env.PG_SSL_CA ?? "",
  pgStatementTimeoutMs: num(process.env.PG_STATEMENT_TIMEOUT_MS, 30_000),

  // Auth Supabase : on vérifie les JWT via l'endpoint /auth/v1/user
  supabaseUrl: process.env.SUPABASE_URL ?? "",
  supabaseAnonKey: process.env.SUPABASE_ANON_KEY ?? "",

  // Authentification des routes JWT (LOT 3) : "supabase" (défaut : vérification via
  // /auth/v1/user) ou "dev-local" (jeton de dev partagé, SANS Supabase). dev-local n'est
  // accepté qu'en SOULBAH_ENV=dev|test, avec HOST en boucle locale, et seulement pour les
  // requêtes venant de la boucle locale (lib/envChecks.ts refuse le démarrage sinon).
  authMode: (process.env.AUTH_MODE ?? "supabase").trim().toLowerCase() || "supabase",
  devLocalUserId: (process.env.DEV_LOCAL_USER_ID ?? "").trim(),
  devLocalToken: (process.env.DEV_LOCAL_TOKEN ?? "").trim(),

  // Sécurité V2 (LOT 6). Secret HMAC des jetons d'approbation (≥ 32 caractères ; obligatoire
  // hors dev/test, sinon secret éphémère par processus). Valeurs à rédiger partout (journaux,
  // lignes, prompts), séparées par « ; » — p. ex. un canari de test.
  approvalSecret: (process.env.SOULBAH_APPROVAL_SECRET ?? "").trim(),
  redactValues: (process.env.SOULBAH_REDACT_VALUES ?? "").split(";").map((s) => s.trim()).filter((s) => s.length >= 4),

  // Service IA Python. IA_SERVICE_TOKEN (obligatoire hors dev/test) est envoyé en x-ia-token.
  iaServiceUrl: process.env.IA_SERVICE_URL ?? "http://python-ia:8000",
  iaServiceToken: process.env.IA_SERVICE_TOKEN ?? "",

  // Fournisseurs LLM qu'un client peut imposer (champ `provider`), séparés par des virgules.
  // Vide = aucune surcharge autorisée (tout `provider` fourni → 400).
  llmAllowedOverrides: parseList(process.env.LLM_ALLOWED_OVERRIDES),

  // Fichiers média produits par python-ia (vidéos/PDF), servis sous /media/.
  mediaDir: process.env.MEDIA_DIR ?? "",
  // Rétention des médias non référencés par une formation (jours ; 0 = jamais purgés).
  mediaRetentionDays: num(process.env.MEDIA_RETENTION_DAYS, 30),

  // Reprise des tâches agent : une tâche 'in_progress' sans heartbeat depuis
  // ce délai est considérée orpheline et remise en file par le reaper global.
  agentTaskStaleSeconds: num(process.env.AGENT_TASK_STALE_SECONDS, 180),
  // Période du reaper global (secondes).
  reaperIntervalSeconds: num(process.env.REAPER_INTERVAL_SECONDS, 60),

  // V2 (LOT 7) : plafond global de parallélisme (§9.6, min avec utilisateur / mission / runtime),
  // durée d'un bail de tâche (prolongé par keepalive), période du scheduler, période du flux SSE.
  maxParallelAgents: Math.max(1, Math.min(32, num(process.env.SOULBAH_MAX_PARALLEL_AGENTS, 6))),
  v2LeaseSeconds: Math.max(10, Math.min(3600, num(process.env.SOULBAH_LEASE_SECONDS, 90))),
  schedulerIntervalSeconds: Math.max(1, num(process.env.SOULBAH_SCHEDULER_INTERVAL_SECONDS, 5)),
  streamIntervalMs: Math.max(250, num(process.env.SOULBAH_STREAM_INTERVAL_MS, 2000)),

  // Générations (formations/applications) bloquées au-delà de ce délai → 'Erreur'.
  staleGenerationMinutes: num(process.env.STALE_GENERATION_MINUTES, 30),

  // Limitation de débit (requêtes / minute). Global, puis routes coûteuses (par utilisateur).
  rateLimitGlobal: num(process.env.RATE_LIMIT_GLOBAL, 300),
  rateLimitAgent: num(process.env.RATE_LIMIT_AGENT, 1200),
  rateLimitExpensive: num(process.env.RATE_LIMIT_EXPENSIVE, 20),
};
