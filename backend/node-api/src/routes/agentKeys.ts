import type { FastifyInstance } from "fastify";
import { requireUser } from "../auth";
import { createAgentKey, listAgentKeys, revokeAgentKey } from "../services/agentKeys";

// Gestion des clés de l'agent local par l'utilisateur (JWT requis).

export async function agentKeyRoutes(app: FastifyInstance): Promise<void> {
  // Générer une nouvelle clé — la clé en clair n'est renvoyée qu'ICI, une seule fois.
  app.post("/api/agent-keys", { preHandler: requireUser }, async (request) => {
    const userId = request.user!.id;
    const { label } = (request.body ?? {}) as { label?: string };
    const { id, key } = await createAgentKey(userId, label);
    return { id, key };
  });

  // Lister ses clés (métadonnées uniquement, jamais la clé/hash).
  app.get("/api/agent-keys", { preHandler: requireUser }, async (request) => {
    const keys = await listAgentKeys(request.user!.id);
    return { keys };
  });

  // Révoquer une clé.
  app.delete("/api/agent-keys/:id", { preHandler: requireUser }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const ok = await revokeAgentKey(request.user!.id, id);
    if (!ok) return reply.status(404).send({ error: "Clé introuvable" });
    return { success: true };
  });
}
