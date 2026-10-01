import type { FastifyInstance } from "fastify";
import { bearerToken, forgetToken } from "../auth.js";

// Déconnexion côté API (S26) : le front l'appelle juste avant supabase.auth.signOut().
// Le jeton est retiré du cache de vérification : il n'est plus accepté par cette instance
// sans nouvelle vérification auprès de Supabase (qui le refusera une fois la session close).
export async function authRoutes(app: FastifyInstance): Promise<void> {
  app.post("/api/auth/logout", async (request, reply) => {
    const token = bearerToken(request);
    if (!token) return reply.status(401).send({ error: "Non authentifié" });
    forgetToken(token);
    return { success: true };
  });
}
