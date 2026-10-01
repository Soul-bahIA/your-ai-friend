import type { FastifyInstance } from "fastify";
import { pool } from "../db";
import { requireUser } from "../auth";
import { generateFormationVideo, generateFormationPdf, ServiceError } from "../clients/iaClient";
import { buildDemoTasks } from "../services/formation/demoTasks";
import { logEvent } from "../services/logs";
import { isUuid } from "../lib/sanitize";
import { config } from "../config";

// Production vidéo/PDF et mise en file de démos : coûteux → limite stricte par utilisateur.
const formationRateLimit = { rateLimit: { max: Math.max(1, Math.floor(config.rateLimitExpensive / 4)), timeWindow: "1 minute" } };

// Production de la vraie vidéo MP4 d'une formation (narration TTS + diapos + montage).
// Node vérifie l'auth, récupère le contenu, délègue la production à Python, puis
// enregistre l'URL du fichier (servi statiquement sous /media).

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

  // --- Mettre en file les démonstrations de la formation pour l'agent local ---
  app.post("/api/formations/:id/demos", { preHandler: requireUser, config: formationRateLimit }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });

    const { rows } = await pool.query(
      `SELECT title, curriculum FROM formations WHERE id = $1 AND user_id = $2`,
      [id, userId],
    );
    if (rows.length === 0) return reply.status(404).send({ error: "Formation introuvable" });
    const curriculum = rows[0].curriculum as { title?: string; modules?: Record<string, unknown>[] } | null;
    if (!curriculum) return reply.status(400).send({ error: "Cette formation n'a pas de curriculum (démos indisponibles)" });

    const tasks = buildDemoTasks(curriculum);
    if (tasks.length === 0) return reply.status(422).send({ error: "Aucune démonstration à exécuter dans ce curriculum" });

    let queued = 0;
    for (const t of tasks) {
      await pool.query(
        `INSERT INTO agent_tasks (user_id, task_type, status, priority, payload)
         VALUES ($1, $2, 'pending', $3, $4::jsonb)`,
        [userId, t.task_type, t.priority, JSON.stringify(t.payload)],
      );
      queued++;
    }
    await logEvent(userId, "Formations", `${queued} démonstration(s) mise(s) en file pour l'agent (« ${rows[0].title} »)`, "info");
    return { success: true, queued };
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
