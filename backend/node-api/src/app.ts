// Construction de l'application Fastify (sans écoute réseau ni connexion DB) :
// réutilisée par server.ts et par les tests (fastify.inject).
import Fastify, {
  type FastifyError,
  type FastifyInstance,
  type FastifyReply,
  type FastifyRequest,
  type FastifyServerOptions,
} from "fastify";
import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
import fastifyStatic from "@fastify/static";
import fs from "node:fs";
import { config } from "./config.js";
import { bearerToken, cachedAgentForKey, cachedUserForToken } from "./auth.js";
import { requestStore } from "./lib/requestStore.js";
import { isOriginAllowed } from "./lib/cors.js";
import { resolveMediaDir } from "./lib/mediaDir.js";
import { healthRoutes } from "./routes/health.js";
import { authRoutes } from "./routes/auth.js";
import { analyzeRoutes } from "./routes/analyze.js";
import { databaseRoutes } from "./routes/database.js";
import { agentTaskRoutes } from "./routes/agentTasks.js";
import { agentKeyRoutes } from "./routes/agentKeys.js";
import { agentGoalRoutes } from "./routes/agentGoal.js";
import { agentMemoryRoutes } from "./routes/agentMemory.js";
import { generateRoutes } from "./routes/generate.js";
import { formationVideoRoutes } from "./routes/formationVideo.js";
import { chatRoutes } from "./routes/chat.js";
import { knowledgeRoutes } from "./routes/knowledge.js";
import { researchRoutes } from "./routes/research.js";
import { orchestratorRoutes } from "./routes/orchestrator.js";

/** Erreurs : 4xx → message explicite ; 5xx → message générique (détail journalisé uniquement). */
export function errorHandler(err: FastifyError & { code?: string }, request: FastifyRequest, reply: FastifyReply) {
  // Erreurs PostgreSQL connues → 4xx (jamais une 500 pour une valeur hors bornes).
  if (err.code === "22P02") return reply.status(400).send({ error: "Identifiant ou valeur invalide" });
  if (err.code === "22003" || err.code === "23514") return reply.status(400).send({ error: "Valeur hors bornes" });
  if (err.code === "23502") return reply.status(400).send({ error: "Champ obligatoire manquant" });
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
}

/**
 * Clé de limitation de débit : id utilisateur quand le jeton a DÉJÀ été vérifié (cache
 * d'auth), propriétaire de la clé agent si déjà résolue, sinon IP — `request.ip` tient
 * compte de TRUST_PROXY (IP réelle derrière un proxy de confiance, sinon pair TCP).
 */
export function rateLimitKey(request: FastifyRequest): string {
  const user = cachedUserForToken(bearerToken(request));
  if (user) return `u:${user.id}`;
  const agentKey = request.headers["x-agent-key"];
  const agent = typeof agentKey === "string" ? cachedAgentForKey(agentKey) : undefined;
  if (agent) return `a:${agent.keyId}`;
  return `ip:${request.ip}`;
}

/** Nombre de sauts de proxy → fonction de confiance (équivalent runtime de Fastify, typé). */
export function toFastifyTrustProxy(
  v: boolean | number | string[],
): boolean | string[] | ((address: string, hop: number) => boolean) {
  return typeof v === "number" ? (_address: string, hop: number) => hop < v : v;
}

export interface BuildAppOptions {
  logger?: FastifyServerOptions["logger"];
  mediaDir?: string;
}

export async function buildApp(opts: BuildAppOptions = {}): Promise<FastifyInstance> {
  // Corps limité à 2 Mo par défaut ; seules les routes de l'agent relèvent cette limite.
  const app = Fastify({
    logger: opts.logger ?? false,
    bodyLimit: 2 * 1024 * 1024,
    trustProxy: toFastifyTrustProxy(config.trustProxy),
  });

  app.setErrorHandler(errorHandler);

  // Contexte de requête (AsyncLocalStorage) : les services profonds (client python-ia,
  // métrage dans soulbah.tool_calls) retrouvent l'utilisateur authentifié sans paramètre.
  app.addHook("onRequest", (request, _reply, done) => {
    requestStore.run(request, done);
  });

  // --- CORS : liste blanche (CORS_ORIGINS) ---
  await app.register(cors, {
    origin: (origin, cb) => cb(null, isOriginAllowed(origin, config.corsOrigins)),
  });

  // --- Limitation de débit (les routes coûteuses fixent leur propre limite, plus stricte) ---
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

  // --- Fichiers média produits (MP4 / PDF des formations) servis sous /media/ ---
  // Noms non devinables (UUID) ; pas de listing, pas de fichiers cachés, cache PRIVÉ
  // (jamais mis en cache par un proxy partagé). @fastify/static refuse toute sortie de root.
  const mediaDir = opts.mediaDir ?? resolveMediaDir();
  try {
    fs.mkdirSync(mediaDir, { recursive: true });
  } catch (err) {
    app.log.warn({ err: (err as Error).message, mediaDir }, "dossier média inaccessible");
  }
  await app.register(fastifyStatic, {
    root: mediaDir,
    prefix: "/media/",
    dotfiles: "deny",
    index: false,
    list: false,
    redirect: false,
    cacheControl: false,
    setHeaders: (reply) => {
      reply.header("Cache-Control", "private, max-age=3600");
      reply.header("X-Content-Type-Options", "nosniff");
    },
  });

  // Santé + démo (Node → Python → Rust)
  await app.register(healthRoutes);
  await app.register(authRoutes);
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

  return app;
}
