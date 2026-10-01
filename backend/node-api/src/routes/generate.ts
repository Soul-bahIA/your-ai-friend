import type { FastifyInstance } from "fastify";
import { pool } from "../db";
import { requireUser } from "../auth";
import { logEvent } from "../services/logs";
import { generateApplication, ServiceError } from "../clients/iaClient";
import { formationEngine, curriculumToLessons } from "../services/formation";

// Port de `generate-formation` et `generate-application`.
// Node vérifie l'auth et persiste ; la génération LLM est déléguée à Python.

export async function generateRoutes(app: FastifyInstance): Promise<void> {
  // --- Formation ---
  app.post("/api/generate/formation", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { topic, details, formationId, provider } = (request.body ?? {}) as {
      topic?: string;
      details?: string;
      formationId?: string;
      provider?: string;
    };
    if (!topic || !formationId) {
      return reply.status(400).send({ error: "topic et formationId requis" });
    }

    // Émission d'un évènement de progression (canal temps réel, task_id = formationId).
    const emit = (type: string, message: string, data: Record<string, unknown> = {}) =>
      pool
        .query(
          `INSERT INTO agent_events (task_id, user_id, type, message, data)
           VALUES ($1, $2, $3, $4, $5::jsonb)`,
          [formationId, userId, type, message, JSON.stringify(data)],
        )
        .catch(() => {});

    // La génération est LONGUE (analyse → recherche → programme → modules) : on la lance
    // en arrière-plan et on rend la main immédiatement. La progression est diffusée en
    // temps réel ; la formation passe à « Terminé » une fois prête.
    await pool.query("UPDATE formations SET status = 'Génération...' WHERE id = $1 AND user_id = $2", [
      formationId,
      userId,
    ]);

    void (async () => {
      emit("task_started", `Génération de la formation « ${topic} »…`, { topic });
      try {
        const curriculum = await formationEngine.build(userId, topic, details ?? null, {
          provider,
          onProgress: (step, detail) => emit("step_started", detail ? `${step} — ${detail}` : step, { step }),
        });
        const lessons = curriculumToLessons(curriculum);

        const { rowCount } = await pool.query(
          `UPDATE formations
           SET title = $1, description = $2, duration = $3, lessons_count = $4,
               content = $5::jsonb, curriculum = $6::jsonb, status = 'Terminé'
           WHERE id = $7 AND user_id = $8`,
          [
            curriculum.title ?? topic,
            curriculum.description ?? null,
            curriculum.duration ?? null,
            lessons.length,
            JSON.stringify(lessons),
            JSON.stringify(curriculum),
            formationId,
            userId,
          ],
        );
        if (rowCount === 0) {
          emit("task_failed", "Formation introuvable (supprimée ?)", {});
          return;
        }
        emit("task_completed", `Formation prête : ${curriculum.modules.length} modules, ${lessons.length} leçons`, {
          modules: curriculum.modules.length,
        });
        await logEvent(
          userId,
          "Formations",
          `Formation « ${curriculum.title} » générée (${curriculum.modules.length} modules, ${lessons.length} leçons, niveau ${curriculum.level})`,
          "success",
        );
      } catch (e) {
        const msg = e instanceof ServiceError ? e.message : e instanceof Error ? e.message : "Erreur inconnue";
        await pool
          .query("UPDATE formations SET status = 'Erreur' WHERE id = $1 AND user_id = $2", [formationId, userId])
          .catch(() => {});
        emit("task_failed", `Échec de la génération : ${msg}`, {});
        request.log.error(e);
      }
    })();

    // Réponse immédiate : le frontend suit la progression et se met à jour à la fin.
    return { success: true, async: true, formationId };
  });

  // --- Application (création ou amélioration) ---
  app.post("/api/generate/application", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { appName, appDesc, applicationId, conversationHistory, existingArchitecture } =
      (request.body ?? {}) as {
        appName?: string;
        appDesc?: string;
        applicationId?: string;
        conversationHistory?: unknown[];
        existingArchitecture?: unknown;
      };
    if (!appName || !applicationId) {
      return reply.status(400).send({ error: "appName et applicationId requis" });
    }

    const isImprovement = !!conversationHistory?.length && !!existingArchitecture;

    try {
      const application = await generateApplication({
        appName,
        appDesc,
        conversationHistory,
        existingArchitecture,
      });

      const { rowCount } = await pool.query(
        `UPDATE applications
         SET title = $1, description = $2, app_type = $3, tech_stack = $4,
             source_code = $5::jsonb, status = 'Généré'
         WHERE id = $6 AND user_id = $7`,
        [
          application.title,
          application.description,
          application.app_type,
          application.tech_stack,
          JSON.stringify(application.architecture ?? {}),
          applicationId,
          userId,
        ],
      );
      if (rowCount === 0) return reply.status(404).send({ error: "Application introuvable" });

      const label = isImprovement ? "améliorée" : "générée";
      await logEvent(userId, "Applications", `Application « ${application.title} » ${label} par IA`, "success");

      return { success: true, application };
    } catch (e) {
      if (e instanceof ServiceError) return reply.status(e.status).send({ error: e.message });
      request.log.error(e);
      return reply.status(500).send({ error: e instanceof Error ? e.message : "Erreur inconnue" });
    }
  });
}
