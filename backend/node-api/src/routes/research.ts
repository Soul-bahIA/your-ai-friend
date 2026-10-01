import type { FastifyInstance } from "fastify";
import { requireUser } from "../auth";
import { researchService } from "../services/research";
import { getWebSearchProvider } from "../services/research/webSearch";
import { ServiceError } from "../clients/iaClient";
import { logEvent } from "../services/logs";
import { optionalFiniteNumber } from "../lib/sanitize";
import { config } from "../config";

// Moteur de recherche KB-first : interroge d'abord la base de connaissances,
// n'effectue une recherche web que si nécessaire, synthétise, puis met en cache.

export async function researchRoutes(app: FastifyInstance): Promise<void> {
  app.post(
    "/api/research",
    { preHandler: requireUser, config: { rateLimit: { max: config.rateLimitExpensive, timeWindow: "1 minute" } } },
    async (request, reply) => {
    const userId = request.user!.id;
    const body = (request.body ?? {}) as {
      query?: string;
      domain?: string;
      forceRefresh?: boolean;
      maxAgeDays?: number;
      minConfidence?: number;
      provider?: string;
    };
    if (typeof body.query !== "string" || !body.query.trim()) return reply.status(400).send({ error: "query requis" });
    if (body.query.length > 1000) return reply.status(400).send({ error: "query trop longue (1000 car. max)" });

    try {
      const result = await researchService.research(userId, body.query.trim(), {
        forceRefresh: body.forceRefresh,
        maxAgeDays: optionalFiniteNumber(body.maxAgeDays),
        minConfidence: optionalFiniteNumber(body.minConfidence),
        provider: typeof body.provider === "string" ? body.provider.slice(0, 40) : undefined,
        domain: typeof body.domain === "string" ? body.domain.slice(0, 80) : undefined,
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
      throw e; // → gestionnaire d'erreurs global (message générique, détail journalisé)
    }
    },
  );

  // État du fournisseur de recherche web (pour l'UI / le diagnostic).
  app.get("/api/research/status", { preHandler: requireUser }, async () => {
    const web = getWebSearchProvider();
    return { web_provider: web.id, web_available: web.available };
  });
}
