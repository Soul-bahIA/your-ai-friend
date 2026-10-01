import type { FastifyInstance } from "fastify";
import { requireUser, forgetAgentKey } from "../auth.js";
import { isUuid } from "../lib/sanitize.js";
import { createAgentKey, listAgentKeys, revokeAgentKey } from "../services/agentKeys.js";

// Gestion des clés de l'agent local par l'utilisateur (JWT requis).

export async function agentKeyRoutes(app: FastifyInstance): Promise<void> {
  // Générer une nouvelle clé — la clé en clair n'est renvoyée qu'ICI, une seule fois.
  app.post("/api/agent-keys", { preHandler: requireUser }, async (request) => {
    const userId = request.user!.id;
    const { label } = (request.body ?? {}) as { label?: string };
    const { id, key } = await createAgentKey(userId, typeof label === "string" ? label.slice(0, 100) : undefined);
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
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const ok = await revokeAgentKey(request.user!.id, id);
    if (!ok) return reply.status(404).send({ error: "Clé introuvable" });
    forgetAgentKey(id);
    return { success: true };
  });
}
