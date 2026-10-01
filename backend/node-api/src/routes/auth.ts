import type { FastifyInstance } from "fastify";
import { bearerToken, forgetToken } from "../auth.js";

// Déconnexion côté API (S26) : le front l'appelle juste avant supabase.auth.signOut().
// Le jeton est retiré du cache de vérification ET marqué révoqué : cette instance le refuse
// immédiatement (401), sans le re-vérifier auprès de Supabase ni le remettre en cache — même
// pour une requête arrivée entre ce logout et le signOut. (Autre instance : au plus 15 s.)
export async function authRoutes(app: FastifyInstance): Promise<void> {
  app.post("/api/auth/logout", async (request, reply) => {
    const token = bearerToken(request);
    if (!token) return reply.status(401).send({ error: "Non authentifié" });
    forgetToken(token);
    return { success: true };
  });
}
