import type { FastifyInstance } from "fastify";
import { requireUser } from "../auth";
import { researchService } from "../services/research";
import { getWebSearchProvider } from "../services/research/webSearch";
import { ServiceError } from "../clients/iaClient";
import { logEvent } from "../services/logs";

// Moteur de recherche KB-first : interroge d'abord la base de connaissances,
// n'effectue une recherche web que si nécessaire, synthétise, puis met en cache.

export async function researchRoutes(app: FastifyInstance): Promise<void> {
  app.post("/api/research", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const body = (request.body ?? {}) as {
      query?: string;
      domain?: string;
      forceRefresh?: boolean;
      maxAgeDays?: number;
      minConfidence?: number;
      provider?: string;
    };
    if (!body.query?.trim()) return reply.status(400).send({ error: "query requis" });

    try {
      const result = await researchService.research(userId, body.query.trim(), {
        domain: body.domain,
        forceRefresh: body.forceRefresh,
        maxAgeDays: body.maxAgeDays,
        minConfidence: body.minConfidence,
        provider: body.provider,
      });
      await logEvent(
        userId,
        "Recherche",
        `« ${result.query} » → ${result.source}` +
          (result.fromCache ? " (base de connaissances)" : result.webUsed ? ` (web:${result.webProvider})` : " (synthèse modèle)"),
        "info",
      );
      return { success: true, ...result };
    } catch (e) {
      if (e instanceof ServiceError) return reply.status(e.status).send({ error: e.message });
      request.log.error(e);
      return reply.status(500).send({ error: e instanceof Error ? e.message : "Erreur de recherche" });
    }
  });

  // État du fournisseur de recherche web (pour l'UI / le diagnostic).
  app.get("/api/research/status", { preHandler: requireUser }, async () => {
    const web = getWebSearchProvider();
    return { web_provider: web.id, web_available: web.available };
  });
}
