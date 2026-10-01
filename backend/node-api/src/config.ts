// Configuration centralisée, lue depuis l'environnement (fournie par docker-compose / .env).
export const config = {
  port: Number(process.env.PORT ?? 3000),
  host: process.env.HOST ?? "0.0.0.0",

  // Base de données : pointe vers le Postgres de Supabase après migration
  // (chaîne de connexion directe / pooler). SSL requis côté Supabase.
  databaseUrl:
    process.env.DATABASE_URL ?? "postgres://soulbah:soulbah@postgres:5432/soulbah",
  databaseSsl: (process.env.DATABASE_SSL ?? "").toLowerCase() === "true",

  // Auth Supabase : on vérifie les JWT via l'endpoint /auth/v1/user
  supabaseUrl: process.env.SUPABASE_URL ?? "",
  supabaseAnonKey: process.env.SUPABASE_ANON_KEY ?? "",

  // Service IA Python (génération de formations/applications via Claude)
  iaServiceUrl: process.env.IA_SERVICE_URL ?? "http://python-ia:8000",

  // Reprise des tâches agent : une tâche 'in_progress' sans heartbeat depuis
  // ce délai est considérée orpheline et remise en file au prochain poll.
  agentTaskStaleSeconds: Number(process.env.AGENT_TASK_STALE_SECONDS ?? 180),

  // Chat streaming — OpenAI (ChatGPT). API compatible avec le parseur SSE du frontend.
  openaiApiKey: process.env.OPENAI_API_KEY ?? "",
  openaiUrl: process.env.OPENAI_URL ?? "https://api.openai.com/v1/chat/completions",
  chatModel: process.env.CHAT_MODEL ?? "gpt-4o",
};
