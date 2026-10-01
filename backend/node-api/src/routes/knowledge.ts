import type { FastifyInstance } from "fastify";
import { requireUser } from "../auth";
import { knowledgeService } from "../services/knowledge";
import type { KnowledgeInput } from "../services/knowledge";
import { logEvent } from "../services/logs";
import { pool } from "../db";
import { isUuid, optionalFiniteNumber, sanitizeLimit } from "../lib/sanitize";

/** Admin applicatif (fonction public.has_role de Supabase). Absente/erreur → non admin. */
async function isAdmin(userId: string): Promise<boolean> {
  try {
    const { rows } = await pool.query("SELECT public.has_role($1, 'admin') AS admin", [userId]);
    return rows[0]?.admin === true;
  } catch {
    return false;
  }
}

// API de la base de connaissances de SoulBah AI.
// CRUD + recherche + versions/restauration + domaines. Toutes scopées par JWT.
// La logique passe par knowledgeService (couche indépendante du fournisseur de stockage).

export async function knowledgeRoutes(app: FastifyInstance): Promise<void> {
  // --- Recherche / liste ---
  app.get("/api/knowledge", { preHandler: requireUser }, async (request) => {
    const userId = request.user!.id;
    const q = request.query as Record<string, string | undefined>;
    const entries = await knowledgeService.search(userId, {
      text: typeof q.q === "string" ? q.q.slice(0, 1000) : undefined,
      domain: typeof q.domain === "string" ? q.domain.slice(0, 80) : undefined,
      keywords: typeof q.keywords === "string"
        ? q.keywords.split(",").map((k) => k.trim().slice(0, 80)).filter(Boolean).slice(0, 20)
        : undefined,
      minConfidence: optionalFiniteNumber(q.minConfidence),
      maxAgeDays: optionalFiniteNumber(q.maxAgeDays),
      limit: sanitizeLimit(q.limit, 10, 100),
    });
    return { entries };
  });

  // --- Création (avec déduplication automatique) ---
  app.post("/api/knowledge", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const body = (request.body ?? {}) as Partial<KnowledgeInput> & { dedupe?: boolean };
    if (typeof body.title !== "string" || !body.title.trim() || typeof body.content !== "string" || !body.content.trim()) {
      return reply.status(400).send({ error: "title et content requis" });
    }
    if (body.title.length > 500 || body.content.length > 100_000) {
      return reply.status(400).send({ error: "title (500 car.) ou content (100000 car.) trop long" });
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
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const entry = await knowledgeService.get(userId, id);
    if (!entry) return reply.status(404).send({ error: "Connaissance introuvable" });
    return { entry };
  });

  // --- Mise à jour (versionnée) ---
  app.patch("/api/knowledge/:id", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const body = (request.body ?? {}) as Partial<KnowledgeInput> & { changeNote?: string };
    const entry = await knowledgeService.update(userId, id, body, body.changeNote);
    if (!entry) return reply.status(404).send({ error: "Connaissance introuvable" });
    return { success: true, entry };
  });

  // --- Suppression ---
  app.delete("/api/knowledge/:id", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const ok = await knowledgeService.remove(userId, id);
    if (!ok) return reply.status(404).send({ error: "Connaissance introuvable" });
    return { success: true };
  });

  // --- Historique de versions ---
  app.get("/api/knowledge/:id/versions", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const versions = await knowledgeService.listVersions(userId, id);
    return { versions };
  });

  // --- Restauration d'une version ---
  app.post("/api/knowledge/:id/restore", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
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

  // Référentiel GLOBAL (partagé par tous les comptes) : réservé aux administrateurs.
  app.post("/api/knowledge-domains", { preHandler: requireUser }, async (request, reply) => {
    if (!(await isAdmin(request.user!.id))) {
      return reply.status(403).send({ error: "Réservé aux administrateurs" });
    }
    const body = (request.body ?? {}) as { slug?: unknown; label?: unknown };
    if (typeof body.slug !== "string" || typeof body.label !== "string" || !body.slug.trim() || !body.label.trim()) {
      return reply.status(400).send({ error: "slug et label requis" });
    }
    if (body.slug.length > 60 || body.label.length > 120) {
      return reply.status(400).send({ error: "slug (60 car.) ou label (120 car.) trop long" });
    }
    const slug = body.slug.trim().toLowerCase().replace(/[^a-z0-9-]+/g, "-");
    const domain = await knowledgeService.addDomain(slug, body.label.trim());
    return { success: true, domain };
  });
}
