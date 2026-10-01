import type { FastifyInstance } from "fastify";
import { requireUser } from "../auth";
import { knowledgeService } from "../services/knowledge";
import type { KnowledgeInput } from "../services/knowledge";
import { logEvent } from "../services/logs";

// API de la base de connaissances de SoulBah AI.
// CRUD + recherche + versions/restauration + domaines. Toutes scopées par JWT.
// La logique passe par knowledgeService (couche indépendante du fournisseur de stockage).

export async function knowledgeRoutes(app: FastifyInstance): Promise<void> {
  // --- Recherche / liste ---
  app.get("/api/knowledge", { preHandler: requireUser }, async (request) => {
    const userId = request.user!.id;
    const q = request.query as Record<string, string | undefined>;
    const entries = await knowledgeService.search(userId, {
      text: q.q,
      domain: q.domain,
      keywords: q.keywords ? q.keywords.split(",").map((k) => k.trim()).filter(Boolean) : undefined,
      minConfidence: q.minConfidence ? Number(q.minConfidence) : undefined,
      maxAgeDays: q.maxAgeDays ? Number(q.maxAgeDays) : undefined,
      limit: q.limit ? Number(q.limit) : undefined,
    });
    return { entries };
  });

  // --- Création (avec déduplication automatique) ---
  app.post("/api/knowledge", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const body = (request.body ?? {}) as Partial<KnowledgeInput> & { dedupe?: boolean };
    if (!body.title || !body.content) {
      return reply.status(400).send({ error: "title et content requis" });
    }
    const input: KnowledgeInput = {
      title: body.title,
      content: body.content,
      description: body.description ?? null,
      summary: body.summary ?? null,
      domain: body.domain ?? "general",
      category: body.category ?? "general",
      keywords: body.keywords ?? [],
      tags: body.tags ?? [],
      sources: body.sources ?? [],
      source: body.source ?? null,
      confidence: body.confidence,
      links: body.links ?? [],
    };
    // Par défaut on déduplique (comportement voulu pour l'IA) ; dedupe:false force la création.
    if (body.dedupe === false) {
      const entry = await knowledgeService.create(userId, input);
      return { success: true, entry, deduped: false };
    }
    const { entry, deduped } = await knowledgeService.remember(userId, input);
    await logEvent(
      userId,
      "Connaissances",
      `${deduped ? "Reconfirmée" : "Nouvelle connaissance"} : « ${entry.title} » [${entry.domain}]`,
      "info",
    );
    return { success: true, entry, deduped };
  });

  // --- Lecture d'une entrée ---
  app.get("/api/knowledge/:id", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    const entry = await knowledgeService.get(userId, id);
    if (!entry) return reply.status(404).send({ error: "Connaissance introuvable" });
    return { entry };
  });

  // --- Mise à jour (versionnée) ---
  app.patch("/api/knowledge/:id", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    const body = (request.body ?? {}) as Partial<KnowledgeInput> & { changeNote?: string };
    const entry = await knowledgeService.update(userId, id, body, body.changeNote);
    if (!entry) return reply.status(404).send({ error: "Connaissance introuvable" });
    return { success: true, entry };
  });

  // --- Suppression ---
  app.delete("/api/knowledge/:id", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    const ok = await knowledgeService.remove(userId, id);
    if (!ok) return reply.status(404).send({ error: "Connaissance introuvable" });
    return { success: true };
  });

  // --- Historique de versions ---
  app.get("/api/knowledge/:id/versions", { preHandler: requireUser }, async (request) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    const versions = await knowledgeService.listVersions(userId, id);
    return { versions };
  });

  // --- Restauration d'une version ---
  app.post("/api/knowledge/:id/restore", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    const { version } = (request.body ?? {}) as { version?: number };
    if (typeof version !== "number") return reply.status(400).send({ error: "version (nombre) requise" });
    const entry = await knowledgeService.restoreVersion(userId, id, version);
    if (!entry) return reply.status(404).send({ error: "Version introuvable" });
    return { success: true, entry };
  });

  // --- Domaines (référentiel extensible) ---
  app.get("/api/knowledge-domains", { preHandler: requireUser }, async () => {
    const domains = await knowledgeService.listDomains();
    return { domains };
  });

  app.post("/api/knowledge-domains", { preHandler: requireUser }, async (request, reply) => {
    const body = (request.body ?? {}) as { slug?: string; label?: string };
    if (!body.slug || !body.label) return reply.status(400).send({ error: "slug et label requis" });
    const slug = body.slug.trim().toLowerCase().replace(/[^a-z0-9-]+/g, "-");
    const domain = await knowledgeService.addDomain(slug, body.label.trim());
    return { success: true, domain };
  });
}
