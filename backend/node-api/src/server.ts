import Fastify from "fastify";
import cors from "@fastify/cors";
import fastifyStatic from "@fastify/static";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { setGlobalDispatcher, Agent } from "undici";
import { config } from "./config";
import { initDb } from "./db";
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

// La production vidéo (Python) peut durer plusieurs minutes : on relève le timeout
// par défaut d'undici (300s) pour les appels sortants du backend vers le service IA.
setGlobalDispatcher(new Agent({ headersTimeout: 900_000, bodyTimeout: 900_000 }));

const app = Fastify({ logger: true, bodyLimit: 10 * 1024 * 1024 });

await app.register(cors, { origin: true });

// Fichiers média produits (vidéos MP4 des formations) servis sous /media/
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const mediaDir = process.env.MEDIA_DIR ?? path.join(__dirname, "..", "..", "media");
await app.register(fastifyStatic, { root: path.resolve(mediaDir), prefix: "/media/" });

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

try {
  await initDb();
  await app.listen({ port: config.port, host: config.host });
  app.log.info(`node-api en écoute sur http://${config.host}:${config.port}`);
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
