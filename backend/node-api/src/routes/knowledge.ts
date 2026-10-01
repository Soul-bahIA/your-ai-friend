import type { FastifyInstance } from "fastify";
import { requireUser } from "../auth.js";
import { knowledgeService } from "../services/knowledge/index.js";
import type { KnowledgeInput } from "../services/knowledge/index.js";
import { logEvent } from "../services/logs.js";
import { pool } from "../db.js";
import { isUuid, optionalFiniteNumber, sanitizeLimit } from "../lib/sanitize.js";
import { validateKnowledgeInput } from "../lib/knowledgeValidation.js";

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
    const body = (request.body ?? {}) as { dedupe?: unknown };
    const checked = validateKnowledgeInput(request.body, false);
    if (!checked.ok) return reply.status(400).send({ error: checked.error });
    const v = checked.value;
    const input: KnowledgeInput = {
      title: v.title!,
      content: v.content!,
      description: v.description ?? null,
      summary: v.summary ?? null,
      domain: v.domain ?? "general",
      category: v.category ?? "general",
      keywords: v.keywords ?? [],
      tags: v.tags ?? [],
      sources: v.sources ?? [],
      source: v.source ?? null,
      confidence: v.confidence,
      links: v.links ?? [],
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
    const body = (request.body ?? {}) as { changeNote?: unknown };
    if (body.changeNote !== undefined && (typeof body.changeNote !== "string" || body.changeNote.length > 500)) {
      return reply.status(400).send({ error: "changeNote doit être un texte (500 car. max)" });
    }
    const checked = validateKnowledgeInput(request.body, true);
    if (!checked.ok) return reply.status(400).send({ error: checked.error });
    // Hash, version et embedding sont recalculés par le service (contrat LOT 1 §11).
    const entry = await knowledgeService.update(userId, id, checked.value, body.changeNote as string | undefined);
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
    const { version } = (request.body ?? {}) as { version?: unknown };
    if (typeof version !== "number" || !Number.isInteger(version) || version < 1) {
      return reply.status(400).send({ error: "version (entier ≥ 1) requise" });
    }
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
