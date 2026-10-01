import type { FastifyInstance } from "fastify";
import { pool } from "../db.js";
import { requireUser } from "../auth.js";
import { generateFormationVideo, generateFormationPdf, ServiceError } from "../clients/iaClient.js";
import { logEvent } from "../services/logs.js";
import { isUuid } from "../lib/sanitize.js";
import { config } from "../config.js";

// Production vidéo/PDF et mise en file de démos : coûteux → limite stricte par utilisateur.
const formationRateLimit = { rateLimit: { max: Math.max(1, Math.floor(config.rateLimitExpensive / 4)), timeWindow: "1 minute" } };

// Production de la vraie vidéo MP4 d'une formation (narration TTS + diapos + montage).
// Node vérifie l'auth, récupère le contenu, délègue la production à Python, puis
// enregistre l'URL du fichier (servi statiquement sous /media).

import { demoToSession } from "../v2/planner/bridge.js";

export async function formationVideoRoutes(app: FastifyInstance): Promise<void> {
  app.post("/api/formations/:id/video", { preHandler: requireUser, config: formationRateLimit }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });

    const { rows } = await pool.query(
      `SELECT title, content FROM formations WHERE id = $1 AND user_id = $2`,
      [id, userId],
    );
    if (rows.length === 0) return reply.status(404).send({ error: "Formation introuvable" });

    const { title, content } = rows[0] as { title: string; content: unknown };
    const lessons = Array.isArray(content) ? content : [];
    if (lessons.length === 0) {
      return reply.status(400).send({ error: "Cette formation n'a pas de leçons à mettre en vidéo" });
    }

    try {
      const result = await generateFormationVideo({ formationId: id, title, lessons });
      const videoUrl = `/media/${result.filename}`;

      await pool.query(`UPDATE formations SET video_url = $1 WHERE id = $2 AND user_id = $3`, [
        videoUrl,
        id,
        userId,
      ]);
      await logEvent(
        userId,
        "Formations",
        `Vidéo MP4 produite pour « ${title} » (${result.slides} diapos, ${result.duration_s}s)`,
        "success",
      );

      return { success: true, video_url: videoUrl, slides: result.slides, duration_s: result.duration_s };
    } catch (e) {
      if (e instanceof ServiceError) return reply.status(e.status).send({ error: e.message });
      throw e; // → gestionnaire d'erreurs global (message générique, détail journalisé)
    }
  });

  // --- Démonstrations de la formation (LOT 11) : gabarit demo_video ---
  // { demo: "description de la démonstration", title?, output_dir?, agent_key_id? } → mission V2
  // (observer → filmer pendant les actions → monter ; vidéo vérifiée par probe) en attente
  // d'approbation. Plus jamais de tâche sans étapes (T5) : le plan passe par validateDag.
  app.post("/api/formations/:id/demos", { preHandler: requireUser, config: formationRateLimit }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const body = (request.body ?? {}) as { demo?: unknown; title?: unknown; output_dir?: unknown; agent_key_id?: unknown };
    const demo = typeof body.demo === "string" ? body.demo.trim() : "";
    if (!demo || demo.length > 2000) return reply.status(400).send({ error: "demo (description, ≤ 2000 car.) requis" });
    const f = await pool.query("SELECT id, title FROM formations WHERE id = $1 AND user_id = $2", [id, userId]);
    if (f.rows.length === 0) return reply.status(404).send({ error: "Formation introuvable" });
    const agentKeyId = typeof body.agent_key_id === "string" && isUuid(body.agent_key_id) ? body.agent_key_id : undefined;
    const out = await demoToSession(userId, {
      formationId: id,
      title: typeof body.title === "string" && body.title.trim() ? body.title.trim().slice(0, 200) : String(f.rows[0].title ?? "Démonstration"),
      description: demo,
      outputDir: typeof body.output_dir === "string" && body.output_dir.trim() ? body.output_dir.trim() : undefined,
      agentKeyId,
    });
    if (!out.ok) return reply.status(out.status).send({ error: out.error, errors: out.errors, reason: out.reason, agents: out.agents });
    return reply.status(201).send({
      success: true,
      session_id: out.session.id,
      status: out.session.status,
      understanding: out.understanding,
      tasks: out.tasks.map((t) => ({ id: t.id, node_key: t.node_key, role: t.role })),
    });
  });

  // --- Support PDF de la formation (curriculum complet) ---
  app.post("/api/formations/:id/pdf", { preHandler: requireUser, config: formationRateLimit }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });

    const { rows } = await pool.query(
      `SELECT title, description, duration, curriculum, content FROM formations WHERE id = $1 AND user_id = $2`,
      [id, userId],
    );
    if (rows.length === 0) return reply.status(404).send({ error: "Formation introuvable" });

    const row = rows[0] as {
      title: string;
      description: string | null;
      duration: string | null;
      curriculum: Record<string, unknown> | null;
      content: unknown;
    };

    // Curriculum riche si disponible, sinon reconstruit un minimal depuis les leçons.
    const curriculum =
      row.curriculum ??
      {
        title: row.title,
        description: row.description ?? "",
        duration: row.duration ?? "",
        level: "",
        audience: "",
        objectives: [],
        modules: (Array.isArray(row.content) ? row.content : []).map((l: Record<string, unknown>) => ({
          title: l.title,
          summary: "",
          objectives: l.objectives ?? [],
          chapters: [{ title: l.title, content: l.content ?? "", key_points: [], examples: l.examples ?? [] }],
          exercises: Array.isArray(l.exercises)
            ? (l.exercises as string[]).map((q) => ({ question: q, solution: "" }))
            : [],
          quiz: [],
          case_study: "",
          project: "",
        })),
        glossary: [],
        faq: [],
      };

    try {
      const result = await generateFormationPdf({ formationId: id, curriculum });
      const pdfUrl = `/media/${result.filename}`;
      await pool.query(`UPDATE formations SET pdf_url = $1 WHERE id = $2 AND user_id = $3`, [pdfUrl, id, userId]);
      await logEvent(userId, "Formations", `Support PDF produit pour « ${row.title} » (${result.pages} pages)`, "success");
      return { success: true, pdf_url: pdfUrl, pages: result.pages };
    } catch (e) {
      if (e instanceof ServiceError) return reply.status(e.status).send({ error: e.message });
      throw e; // → gestionnaire d'erreurs global (message générique, détail journalisé)
    }
  });
}
