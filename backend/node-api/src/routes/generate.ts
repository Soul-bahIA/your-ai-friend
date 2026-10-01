import type { FastifyInstance } from "fastify";
import { pool } from "../db";
import { requireUser } from "../auth";
import { logEvent } from "../services/logs";
import { generateApplication, ServiceError } from "../clients/iaClient";
import { formationEngine, curriculumToLessons } from "../services/formation";
import { activeGenerations } from "../services/activeJobs";
import { isUuid } from "../lib/sanitize";
import { config } from "../config";

const generateRateLimit = { rateLimit: { max: Math.max(1, Math.floor(config.rateLimitExpensive / 2)), timeWindow: "1 minute" } };

// Port de `generate-formation` et `generate-application`.
// Node vérifie l'auth et persiste ; la génération LLM est déléguée à Python.

export async function generateRoutes(app: FastifyInstance): Promise<void> {
  // --- Formation ---
  app.post("/api/generate/formation", { preHandler: requireUser, config: generateRateLimit }, async (request, reply) => {
    const userId = request.user!.id;
    const { topic, details, formationId, provider } = (request.body ?? {}) as {
      topic?: string;
      details?: string;
      formationId?: string;
      provider?: string;
    };
    if (typeof topic !== "string" || !topic.trim() || !isUuid(formationId)) {
      return reply.status(400).send({ error: "topic et formationId (uuid) requis" });
    }
    if (topic.length > 500 || (details !== undefined && (typeof details !== "string" || details.length > 5000))) {
      return reply.status(400).send({ error: "topic (500 car.) ou details (5000 car.) trop long" });
    }
    if (provider !== undefined && (typeof provider !== "string" || provider.length > 40)) {
      return reply.status(400).send({ error: "provider invalide" });
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
    if (activeGenerations.has(formationId)) {
      return reply.status(409).send({ error: "Génération déjà en cours pour cette formation" });
    }
    const start = await pool.query(
      "UPDATE formations SET status = 'Génération...' WHERE id = $1 AND user_id = $2",
      [formationId, userId],
    );
    if (start.rowCount !== 1) return reply.status(404).send({ error: "Formation introuvable" });
    activeGenerations.add(formationId);

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
        // Message public : jamais le détail interne d'une exception (journalisé ci-dessous).
        const msg = e instanceof ServiceError ? e.message : "erreur interne";
        await pool
          .query("UPDATE formations SET status = 'Erreur' WHERE id = $1 AND user_id = $2", [formationId, userId])
          .catch(() => {});
        emit("task_failed", `Échec de la génération : ${msg}`, {});
        request.log.error(e);
      } finally {
        activeGenerations.delete(formationId);
      }
    })();

    // Réponse immédiate : le frontend suit la progression et se met à jour à la fin.
    return { success: true, async: true, formationId };
  });

  // --- Application (création ou amélioration) ---
  app.post("/api/generate/application", { preHandler: requireUser, config: generateRateLimit }, async (request, reply) => {
    const userId = request.user!.id;
    const { appName, appDesc, applicationId, conversationHistory, existingArchitecture } =
      (request.body ?? {}) as {
        appName?: string;
        appDesc?: string;
        applicationId?: string;
        conversationHistory?: unknown[];
        existingArchitecture?: unknown;
      };
    if (typeof appName !== "string" || !appName.trim() || !isUuid(applicationId)) {
      return reply.status(400).send({ error: "appName et applicationId (uuid) requis" });
    }
    if (conversationHistory !== undefined && (!Array.isArray(conversationHistory) || conversationHistory.length > 100)) {
      return reply.status(400).send({ error: "conversationHistory invalide (liste, 100 max)" });
    }

    const isImprovement = !!conversationHistory?.length && !!existingArchitecture;

    // Propriété vérifiée AVANT l'appel (coûteux) au modèle.
    const owned = await pool.query("SELECT 1 FROM applications WHERE id = $1 AND user_id = $2", [applicationId, userId]);
    if (owned.rowCount !== 1) return reply.status(404).send({ error: "Application introuvable" });

    activeGenerations.add(applicationId);
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
      throw e; // → gestionnaire d'erreurs global (message générique, détail journalisé)
    } finally {
      activeGenerations.delete(applicationId);
    }
  });
}
