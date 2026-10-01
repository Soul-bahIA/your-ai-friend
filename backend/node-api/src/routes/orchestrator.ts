import type { FastifyInstance } from "fastify";
import { requireUser } from "../auth.js";
import { routeRequest, ServiceError } from "../clients/iaClient.js";
import { researchService } from "../services/research/index.js";
import { planAndQueueGoal } from "./agentGoal.js";
import { logEvent } from "../services/logs.js";
import { parseAgentKeyId } from "../lib/agentSteps.js";
import { checkProviderOverride } from "../lib/providerOverride.js";
import { config } from "../config.js";

// Cerveau central (Chief Agent) : point d'entrée unique. Comprend la demande, désigne
// l'agent spécialisé, et — si execute=true — DISPATCHE réellement vers la capacité
// cible quand elle est auto-suffisante (recherche, objectif desktop). Les capacités
// nécessitant un contexte UI (formation/app : ligne à créer, chat interactif) sont
// renvoyées avec une instruction de navigation.

/** Statut HTTP d'un échec de planification dispatchée (T44) : 4xx relayé, sinon 502. */
export function dispatchFailureStatus(status: number): number {
  return status >= 400 && status < 500 ? status : 502;
}

export async function orchestratorRoutes(app: FastifyInstance): Promise<void> {
  app.post(
    "/api/orchestrator/route",
    { preHandler: requireUser, config: { rateLimit: { max: config.rateLimitExpensive, timeWindow: "1 minute" } } },
    async (request, reply) => {
      const userId = request.user!.id;
      const body = (request.body ?? {}) as { request?: string; provider?: unknown; execute?: boolean; agent_key_id?: unknown };
      if (typeof body.request !== "string" || !body.request.trim()) return reply.status(400).send({ error: "request requis" });
      if (body.request.length > 2000) return reply.status(400).send({ error: "request trop longue (2000 car. max)" });
      const provider = checkProviderOverride(body.provider, config.llmAllowedOverrides);
      if (!provider.ok) return reply.status(400).send({ error: provider.error });
      const agentKeyId = parseAgentKeyId(body.agent_key_id);
      if (agentKeyId === null) return reply.status(400).send({ error: "agent_key_id doit être un uuid" });
      const text = body.request.trim();

      try {
        const decision = await routeRequest({ request: text, provider: provider.value });
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
          const result = await researchService.research(userId, text, { provider: provider.value });
          return { success: true, decision, executed: "research", result };
        }

        // Desktop / DevOps / Vision Agent : planifie l'objectif et le met en file pour l'agent local.
        if (decision.capability === "agent_goal") {
          const outcome = await planAndQueueGoal(userId, text, { agentKeyId });
          if (!outcome.ok) {
            // Échec de planification : jamais un 200 success:true (T44).
            return reply.status(dispatchFailureStatus(outcome.status)).send({
              success: false,
              decision,
              executed: "agent_goal",
              error: outcome.error,
              reason: outcome.reason,
              agents: outcome.agents,
            });
          }
          return {
            success: true,
            decision,
            executed: "agent_goal",
            task_id: outcome.task_id,
            understanding: outcome.understanding,
            steps: outcome.steps,
            target_agent_key_id: outcome.target_agent_key_id,
          };
        }

        // Autres capacités : navigation UI (contexte nécessaire côté page).
        return { success: true, decision, executed: null, navigate: decision.capability };
      } catch (e) {
        if (e instanceof ServiceError) return reply.status(e.status).send({ success: false, error: e.message });
        throw e; // → gestionnaire d'erreurs global (message générique, détail journalisé)
      }
    },
  );
}
