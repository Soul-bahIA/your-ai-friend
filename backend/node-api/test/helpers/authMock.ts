// Remplace requireUser / requireAgentKey (pas d'appel Supabase ni de DB) :
//  - JWT simulé : en-tête x-test-user = id utilisateur ;
//  - clé agent simulée : x-test-agent-user + x-test-agent-key.
import type { FastifyReply, FastifyRequest } from "fastify";

export function mockAuth<T extends object>(orig: T): T {
  return {
    ...orig,
    requireUser: async (request: FastifyRequest, reply: FastifyReply) => {
      const u = request.headers["x-test-user"];
      if (typeof u !== "string" || !u) {
        await reply.status(401).send({ error: "Non authentifié" });
        return;
      }
      request.user = { id: u };
    },
    requireAgentKey: async (request: FastifyRequest, reply: FastifyReply) => {
      const u = request.headers["x-test-agent-user"];
      const k = request.headers["x-test-agent-key"];
      if (typeof u !== "string" || typeof k !== "string") {
        await reply.status(401).send({ error: "x-agent-key requis" });
        return;
      }
      request.agentUserId = u;
      request.agentKeyId = k;
    },
  };
}
