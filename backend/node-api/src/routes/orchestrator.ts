import type { FastifyInstance } from "fastify";
import { requireUser } from "../auth";
import { routeRequest, ServiceError } from "../clients/iaClient";
import { researchService } from "../services/research";
import { planAndQueueGoal } from "./agentGoal";
import { logEvent } from "../services/logs";

// Cerveau central (Chief Agent) : point d'entrée unique. Comprend la demande, désigne
// l'agent spécialisé, et — si execute=true — DISPATCHE réellement vers la capacité
// cible quand elle est auto-suffisante (recherche, objectif desktop). Les capacités
// nécessitant un contexte UI (formation/app : ligne à créer, chat interactif) sont
// renvoyées avec une instruction de navigation.

export async function orchestratorRoutes(app: FastifyInstance): Promise<void> {
  app.post("/api/orchestrator/route", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const body = (request.body ?? {}) as { request?: string; provider?: string; execute?: boolean };
    if (!body.request?.trim()) return reply.status(400).send({ error: "request requis" });
    const text = body.request.trim();

    try {
      const decision = await routeRequest({ request: text, provider: body.provider });
      await logEvent(
        userId,
        "Orchestrateur",
        `Demande routée → ${decision.agent_label} (${decision.task_type}, ${decision.complexity})`,
        "info",
      );

      // Sans exécution : on renvoie juste la décision (l'UI navigue/pré-remplit).
      if (!body.execute) return { success: true, decision };

      // --- Dispatch réel vers l'agent spécialisé ---
      // Research / Knowledge Agent : lance la recherche KB-first et renvoie la synthèse.
      if (decision.capability === "research" || decision.capability === "knowledge") {
        const result = await researchService.research(userId, text);
        return { success: true, decision, executed: "research", result };
      }

      // Desktop / DevOps / Vision Agent : planifie l'objectif et le met en file pour l'agent local.
      if (decision.capability === "agent_goal") {
        const outcome = await planAndQueueGoal(userId, text);
        if (!outcome.ok) {
          return { success: true, decision, executed: "agent_goal", error: outcome.error, reason: outcome.reason };
        }
        return {
          success: true,
          decision,
          executed: "agent_goal",
          task_id: outcome.task_id,
          understanding: outcome.understanding,
          steps: outcome.steps,
        };
      }

      // Autres capacités : navigation UI (contexte nécessaire côté page).
      return { success: true, decision, executed: null, navigate: decision.capability };
    } catch (e) {
      if (e instanceof ServiceError) return reply.status(e.status).send({ error: e.message });
      request.log.error(e);
      return reply.status(500).send({ error: e instanceof Error ? e.message : "Erreur d'orchestration" });
    }
  });
}
