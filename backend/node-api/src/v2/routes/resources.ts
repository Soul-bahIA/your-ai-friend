// GET /api/v2/resources — Resource Manager V3 (LOT 6) : agents logiques et file d'attente, PC
// (mémoire, workers permis), files d'inférence du modèle local (python-ia), plafond effectif.
import type { FastifyInstance } from "fastify";
import { pool } from "../../db.js";
import { requireUser } from "../../auth.js";
import { config } from "../../config.js";
import { resourcesStatus } from "../../clients/iaClient.js";
import { effectiveMaxParallel } from "../scheduler/parallelism.js";
import { agentsOverview, runtimesOverview } from "../resources/resourceManager.js";

export async function resourceRoutes(app: FastifyInstance): Promise<void> {
  app.get("/api/v2/resources", { preHandler: requireUser }, async (request) => {
    const userId = request.user!.id;
    const [agents, runtimes, model, us] = await Promise.all([
      agentsOverview(userId),
      runtimesOverview(userId),
      resourcesStatus(),
      pool.query("SELECT max_parallel_agents FROM soulbah.user_settings WHERE user_id = $1", [userId]),
    ]);
    const online = runtimes.filter((r) => r.status === "online");
    return {
      max_parallel_agents: effectiveMaxParallel({
        global: config.maxParallelAgents,
        user: us.rows[0]?.max_parallel_agents ?? null,
        runtime: online.length ? Math.max(...online.map((r) => r.max_slots)) : null,
      }),
      agents,
      runtimes,
      model,
    };
  });
}
