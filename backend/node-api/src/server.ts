import Fastify, { type FastifyError, type FastifyRequest } from "fastify";
import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
import fastifyStatic from "@fastify/static";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config } from "./config";
import { initDb, pool } from "./db";
import { bearerToken, cachedAgentForKey, cachedUserForToken } from "./auth";
import { isOriginAllowed } from "./lib/cors";
import { setLogger } from "./lib/logger";
import { runMaintenance } from "./services/maintenance";
import { healthRoutes } from "./routes/health";
import { analyzeRoutes } from "./routes/analyze";
import { databaseRoutes } from "./routes/database";
import { agentTaskRoutes } from "./routes/agentTasks";
import { agentKeyRoutes } from "./routes/agentKeys";
import { agentGoalRoutes } from "./routes/agentGoal";
import { agentMemoryRoutes } from "./routes/agentMemory";
import { generateRoutes } from "./routes/generate";
import { formationVideoRoutes } from "./routes/formationVideo";
import { chatRoutes } from "./routes/chat";
import { knowledgeRoutes } from "./routes/knowledge";
import { researchRoutes } from "./routes/research";
import { orchestratorRoutes } from "./routes/orchestrator";

// Corps limité à 2 Mo par défaut ; seules les routes de l'agent (captures d'écran)
// relèvent cette limite (bodyLimit par route, 15 Mo).
const app = Fastify({ logger: true, bodyLimit: 2 * 1024 * 1024 });
setLogger(app.log);

// --- Erreurs : 4xx → message explicite ; 5xx → message générique (détail journalisé) ---
app.setErrorHandler((err: FastifyError & { code?: string }, request, reply) => {
  // Erreurs PostgreSQL connues → 4xx.
  if (err.code === "22P02") return reply.status(400).send({ error: "Identifiant ou valeur invalide" });
  if (err.code === "23503") return reply.status(409).send({ error: "Référence introuvable (ressource supprimée ?)" });
  if (err.code === "23505") return reply.status(409).send({ error: "Doublon" });
  const dbDown =
    /timeout exceeded when trying to connect|Connection terminated|ECONNREFUSED|ENOTFOUND|EAI_AGAIN/i.test(err.message ?? "");
  const status = err.statusCode && err.statusCode >= 400 && err.statusCode < 600 ? err.statusCode : dbDown ? 503 : 500;
  if (status >= 500) {
    request.log.error({ err }, "erreur interne");
    return reply
      .status(status)
      .send({ error: status === 503 ? "Service temporairement indisponible" : "Erreur interne du serveur" });
  }
  return reply.status(status).send({ error: err.message });
});

// --- CORS : liste blanche (CORS_ORIGINS) ---
await app.register(cors, {
  origin: (origin, cb) => cb(null, isOriginAllowed(origin, config.corsOrigins)),
});

// --- Limitation de débit ---
// Clé : id utilisateur quand le jeton a DÉJÀ été vérifié (cache d'auth), propriétaire
// de la clé agent si déjà résolue, sinon IP. Les routes coûteuses fixent leur propre
// limite (config.rateLimit) plus stricte.
function rateLimitKey(request: FastifyRequest): string {
  const user = cachedUserForToken(bearerToken(request));
  if (user) return `u:${user.id}`;
  const agentKey = request.headers["x-agent-key"];
  const agent = typeof agentKey === "string" ? cachedAgentForKey(agentKey) : undefined;
  if (agent) return `a:${agent.keyId}`;
  return `ip:${request.ip}`;
}
await app.register(rateLimit, {
  global: true,
  max: config.rateLimitGlobal,
  timeWindow: "1 minute",
  keyGenerator: rateLimitKey,
  errorResponseBuilder: (_req, ctx) => {
    const err = new Error(`Trop de requêtes. Réessayez dans ${ctx.after}.`) as Error & { statusCode: number };
    err.statusCode = ctx.statusCode;
    return err;
  },
});

// --- Fichiers média produits (vidéos MP4 / PDF des formations) servis sous /media/ ---
// @fastify/static (send) refuse toute sortie de `root` (../, encodages, liens absolus).
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const mediaDir = path.resolve(config.mediaDir || path.join(__dirname, "..", "..", "media"));
try {
  fs.mkdirSync(mediaDir, { recursive: true });
} catch (err) {
  app.log.warn({ err: (err as Error).message, mediaDir }, "dossier média inaccessible");
}
await app.register(fastifyStatic, { root: mediaDir, prefix: "/media/", dotfiles: "deny", index: false });

// Santé + démo (Node → Python → Rust)
await app.register(healthRoutes);
await app.register(analyzeRoutes);

// Fonctionnalités migrées depuis les edge functions Supabase
await app.register(databaseRoutes); // ← manage-database
await app.register(agentTaskRoutes); // ← agent-tasks
await app.register(agentKeyRoutes); // ← clés de l'agent local
await app.register(agentGoalRoutes); // ← moteur de raisonnement (objectif → plan → correction)
await app.register(agentMemoryRoutes); // ← mémoire d'exécution + auto-amélioration
await app.register(generateRoutes); // ← generate-formation / generate-application
await app.register(formationVideoRoutes); // ← production vidéo MP4 des formations
await app.register(chatRoutes); // ← chat
await app.register(knowledgeRoutes); // ← base de connaissances (KB propriétaire évolutive)
await app.register(researchRoutes); // ← moteur de recherche KB-first (KB → web → synthèse → cache)
await app.register(orchestratorRoutes); // ← cerveau central (Chief Agent → agents spécialisés)

// --- Base de données : non bloquante au démarrage ---
// Si Postgres est injoignable, l'API démarre quand même (santé, routes sans DB) et
// réessaie périodiquement ; dès que la DB répond, on lance la maintenance de reprise.
const DB_RETRY_MS = 30_000;
const MAINTENANCE_MS = 60 * 60 * 1000;
let dbRetryTimer: NodeJS.Timeout | undefined;
let maintenanceTimer: NodeJS.Timeout | undefined;

async function connectDb(): Promise<void> {
  try {
    await initDb();
    app.log.info("PostgreSQL joignable");
    await runMaintenance(); // générations bloquées → 'Erreur', purge des évènements
    maintenanceTimer = setInterval(() => void runMaintenance(), MAINTENANCE_MS);
    maintenanceTimer.unref();
  } catch (err) {
    app.log.warn(
      { err: (err as Error).message },
      `PostgreSQL injoignable — l'API démarre en mode dégradé, nouvel essai dans ${DB_RETRY_MS / 1000} s`,
    );
    dbRetryTimer = setTimeout(() => void connectDb(), DB_RETRY_MS);
    dbRetryTimer.unref();
  }
}

// --- Arrêt propre ---
let shuttingDown = false;
async function shutdown(signal: string): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  app.log.info(`${signal} reçu — arrêt propre`);
  clearTimeout(dbRetryTimer);
  clearInterval(maintenanceTimer);
  const force = setTimeout(() => process.exit(1), 10_000);
  force.unref();
  try {
    await app.close();
    await pool.end();
  } catch (err) {
    app.log.error(err);
  }
  process.exit(0);
}
process.on("SIGINT", () => void shutdown("SIGINT"));
process.on("SIGTERM", () => void shutdown("SIGTERM"));

try {
  await app.listen({ port: config.port, host: config.host });
  app.log.info({ corsOrigins: config.corsOrigins }, `node-api en écoute sur http://${config.host}:${config.port}`);
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
void connectDb();
