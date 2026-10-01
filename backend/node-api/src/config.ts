// Configuration centralisée, lue depuis l'environnement (fournie par docker-compose / .env).
import { parseCorsOrigins } from "./lib/cors";

const num = (v: string | undefined, def: number): number => {
  const n = Number(v);
  return v !== undefined && v.trim() !== "" && Number.isFinite(n) ? n : def;
};

export const config = {
  port: num(process.env.PORT, 3000),
  // Par défaut on n'écoute qu'en local ; docker-compose force HOST=0.0.0.0.
  host: process.env.HOST || "127.0.0.1",

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

  // Service IA Python. IA_SERVICE_TOKEN (si défini) est envoyé en en-tête x-ia-token.
  iaServiceUrl: process.env.IA_SERVICE_URL ?? "http://python-ia:8000",
  iaServiceToken: process.env.IA_SERVICE_TOKEN ?? "",

  // Fichiers média produits par python-ia (vidéos/PDF), servis sous /media/.
  mediaDir: process.env.MEDIA_DIR ?? "",

  // Reprise des tâches agent : une tâche 'in_progress' sans heartbeat depuis
  // ce délai est considérée orpheline et remise en file au prochain poll.
  agentTaskStaleSeconds: num(process.env.AGENT_TASK_STALE_SECONDS, 180),

  // Générations (formations/applications) bloquées au-delà de ce délai → 'Erreur'.
  staleGenerationMinutes: num(process.env.STALE_GENERATION_MINUTES, 30),

  // Limitation de débit (requêtes / minute). Global, puis routes coûteuses (par utilisateur).
  rateLimitGlobal: num(process.env.RATE_LIMIT_GLOBAL, 300),
  rateLimitAgent: num(process.env.RATE_LIMIT_AGENT, 1200),
  rateLimitExpensive: num(process.env.RATE_LIMIT_EXPENSIVE, 20),
};
