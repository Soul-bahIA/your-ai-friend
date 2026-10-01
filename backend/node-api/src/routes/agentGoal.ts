import { randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { pool } from "../db.js";
import { requireUser } from "../auth.js";
import { planGoal, evaluateGoal, ServiceError } from "../clients/iaClient.js";
import { logEvent } from "../services/logs.js";
import { getMemoryContext, writeMemory } from "./agentMemory.js";
import { getAgentKey, getUserAllowedDirs, resolveTargetKey } from "../services/agentKeys.js";
import {
  clampAndValidatePlanSteps,
  compactStep,
  findInvalidStep,
  findPathOutsideAllowed,
  parseAgentKeyId,
  requiresConfirmation,
  validateGoalBody,
} from "../lib/agentSteps.js";
import { isPlainObject, stripImageB64 } from "../lib/sanitize.js";
import { maskTypedText } from "../lib/redact.js";
import { getScreenshot } from "../services/screenshots.js";
import { config } from "../config.js";

// Moteur de raisonnement — côté orchestration :
//   POST /api/agent/goal : objectif en langage naturel → plan (LLM) → agent_task ciblée
//   maybeEvaluateGoalTask : appelé (tâche de fond suivie) quand l'agent termine une tâche
//   issue d'un objectif ; le LLM évalue le rapport et, si besoin, une tâche corrective est
//   PROPOSÉE (awaiting_approval) — elle ne part qu'après POST /api/agent-tasks/:id/approve.

const MAX_ATTEMPTS = 3;

export interface GoalMeta {
  goal: string;
  attempt: number;
  max_attempts: number;
  understanding?: string;
  /** Première tâche de l'objectif (elle-même pour la tâche initiale). */
  root_task_id?: string;
  /** Tâche évaluée qui a donné lieu à cette correction. */
  parent_task_id?: string;
  /** Correction proposée par l'évaluateur : non servie à l'agent avant approbation. */
  awaiting_approval?: boolean;
  correction_reason?: string;
}

async function createGoalTask(
  userId: string,
  steps: Record<string, unknown>[],
  meta: GoalMeta,
  targetKeyId: string | null,
): Promise<string> {
  const id = randomUUID();
  const goalMeta: GoalMeta = { ...meta, root_task_id: meta.root_task_id ?? id, awaiting_approval: meta.awaiting_approval ?? false };
  const payload = { steps, goal_meta: goalMeta, requires_confirmation: requiresConfirmation(steps) };
  const { rows } = await pool.query(
    `INSERT INTO agent_tasks (id, user_id, task_type, status, priority, payload, target_agent_key_id)
     VALUES ($1, $2, 'goal', 'pending', 3, $3::jsonb, $4) RETURNING id`,
    [id, userId, JSON.stringify(payload), targetKeyId],
  );
  return rows[0].id as string;
}

/**
 * Planifie un objectif en langage naturel et met la tâche en file pour le PC ciblé.
 * Réutilisable par la route /api/agent/goal ET par le dispatch du Chief Agent.
 * Retourne un résultat discriminé (pas de reply ici).
 */
export type GoalOutcome =
  | {
      ok: true;
      task_id: string;
      understanding: string;
      steps: Record<string, unknown>[];
      target_agent_key_id: string | null;
    }
  | {
      ok: false;
      status: number;
      error: string;
      understanding?: string;
      reason?: string;
      agents?: { id: string; name: string }[];
    };

export async function planAndQueueGoal(
  userId: string,
  goal: string,
  opts: { agentKeyId?: string } = {},
): Promise<GoalOutcome> {
  const trimmed = goal.trim();
  if (!trimmed) return { ok: false, status: 400, error: "goal requis" };

  // PC ciblé : le planner ne voit que les dossiers autorisés de CETTE clé (T16).
  const target = await resolveTargetKey(userId, opts.agentKeyId);
  if (!target.ok) return { ok: false, status: target.status, error: target.error, agents: target.agents };
  const allowedDirs = target.key?.allowed_dirs ?? [];

  const memoryContext = await getMemoryContext(userId, trimmed);
  const dirsContext =
    allowedDirs.length > 0
      ? `DOSSIERS AUTORISÉS (whitelist de l'agent ciblé) — tout chemin de fichier/dossier/cwd DOIT être absolu et strictement à l'intérieur de l'un d'eux :\n${allowedDirs.map((d) => `- ${d}`).join("\n")}`
      : "ATTENTION : aucun dossier autorisé connu pour l'agent ciblé. Toute étape fichier/commande/vidéo sera refusée — si l'objectif en nécessite, réponds feasible=false en l'expliquant.";
  const context = [dirsContext, memoryContext].filter(Boolean).join("\n\n");

  let plan;
  try {
    plan = await planGoal(trimmed, context);
  } catch (e) {
    if (e instanceof ServiceError) return { ok: false, status: e.status, error: e.message };
    throw e;
  }

  const rawSteps = Array.isArray(plan.steps) ? plan.steps : [];
  if (!plan.feasible || rawSteps.length === 0) {
    await logEvent(userId, "Agent", `Objectif refusé par le planificateur : ${plan.reason}`, "warning");
    return {
      ok: false,
      status: 422,
      error: "Objectif non réalisable avec les capacités actuelles de l'agent",
      understanding: plan.understanding,
      reason: plan.reason,
    };
  }

  const checked = clampAndValidatePlanSteps(rawSteps.map((s) => compactStep(s as unknown as Record<string, unknown>)));
  if (!checked.ok) {
    await logEvent(userId, "Agent", `Plan rejeté (invalide) : ${checked.error}`, "warning");
    return {
      ok: false,
      status: 422,
      error: "Le plan généré contient des actions non supportées, réessayez en reformulant",
      understanding: plan.understanding,
      reason: checked.error,
    };
  }
  const steps = checked.value;
  const invalid = findInvalidStep(steps) ?? findPathOutsideAllowed(steps, allowedDirs);
  if (invalid) {
    await logEvent(userId, "Agent", `Plan rejeté (incomplet ou hors whitelist) : ${invalid}`, "warning");
    return {
      ok: false,
      status: 422,
      error: "Le plan généré est incomplet ou sort des dossiers autorisés, réessayez en précisant l'objectif",
      understanding: plan.understanding,
      reason: invalid,
    };
  }

  const targetId = target.key?.id ?? null;
  const taskId = await createGoalTask(
    userId,
    steps,
    { goal: trimmed, attempt: 1, max_attempts: MAX_ATTEMPTS, understanding: plan.understanding, awaiting_approval: false },
    targetId,
  );
  await logEvent(userId, "Agent", `Objectif planifié (${steps.length} étapes) : ${plan.understanding}`, "info");
  return { ok: true, task_id: taskId, understanding: plan.understanding, steps, target_agent_key_id: targetId };
}

export async function agentGoalRoutes(app: FastifyInstance): Promise<void> {
  app.post(
    "/api/agent/goal",
    { preHandler: requireUser, config: { rateLimit: { max: config.rateLimitExpensive, timeWindow: "1 minute" } } },
    async (request, reply) => {
      const userId = request.user!.id;
      const parsed = validateGoalBody(request.body);
      if (!parsed.ok) return reply.status(400).send({ error: parsed.error });
      const agentKeyId = parseAgentKeyId((request.body as Record<string, unknown>).agent_key_id) ?? undefined;
      const outcome = await planAndQueueGoal(userId, parsed.value, { agentKeyId });
      if (!outcome.ok) {
        return reply.status(outcome.status).send({
          error: outcome.error,
          understanding: outcome.understanding,
          reason: outcome.reason,
          agents: outcome.agents,
        });
      }
      return {
        success: true,
        task_id: outcome.task_id,
        understanding: outcome.understanding,
        steps: outcome.steps,
        target_agent_key_id: outcome.target_agent_key_id,
      };
    },
  );
}

// ---------------------------------------------------------------------------------------
// Évaluation (boucle Observer → Corriger)
// ---------------------------------------------------------------------------------------

export interface EvaluableTask {
  status: string;
  control?: string | null;
  payload: { steps?: unknown[]; goal_meta?: GoalMeta } | null;
  result: unknown;
}

/**
 * Raison de NE PAS évaluer une tâche (null = à évaluer). Jamais d'évaluation (donc ni
 * correction ni mémoire) pour un run annulé, stoppé, simulé (dry-run) ou à plan vide
 * (contrat LOT 1 §2 et §4).
 */
export function evaluationSkipReason(task: EvaluableTask): string | null {
  if (!task.payload?.goal_meta) return "not_goal";
  if (task.status === "cancelled") return "cancelled";
  if (task.status !== "completed" && task.status !== "failed") return "not_terminal";
  if (task.control === "stop") return "stopped_by_user";
  const r = isPlainObject(task.result) ? task.result : {};
  if (r.cancelled === true || r.status === "cancelled") return "cancelled";
  if (r.simulated === true) return "simulated";
  if (r.empty_plan === true) return "empty_plan";
  if (Array.isArray(task.payload.steps) && task.payload.steps.length === 0) return "empty_plan";
  // Mêmes règles que python-ia (not_evaluable) : rapport sans étape exécutée, ou agent
  // antérieur au contrat (dry-run sans `simulated`) dont une étape porte « [dry-run] ».
  if (Array.isArray(r.steps)) {
    if (r.steps.length === 0) return "no_step_executed";
    if (r.steps.some((s) => isPlainObject(s) && typeof s.detail === "string" && s.detail.trimStart().startsWith("[dry-run]"))) {
      return "simulated";
    }
  }
  if ("evaluation" in r || "evaluation_status" in r) return "already_evaluated";
  return null;
}

export type EvaluationAction =
  | "none"
  | "memory_proposed"
  | "correction_awaiting_approval"
  | "correction_invalid"
  | "max_attempts_reached"
  | "abandoned"
  | "evaluation_failed";

export interface EvaluationOutcome {
  skipped?: string;
  verdict?: "success" | "retry" | "abort" | "not_evaluable";
  action_taken?: EvaluationAction;
  corrective_task_id?: string;
}

async function allowedDirsForTarget(userId: string, targetKeyId: string | null | undefined): Promise<string[]> {
  if (targetKeyId) return (await getAgentKey(userId, targetKeyId))?.allowed_dirs ?? [];
  return getUserAllowedDirs(userId); // tâche héritée (antérieure au ciblage)
}

async function recordEvaluation(taskId: string, userId: string, evaluation: Record<string, unknown>, status: string) {
  await pool.query(
    `UPDATE agent_tasks
        SET result = COALESCE(result, '{}'::jsonb) || jsonb_build_object('evaluation', $1::jsonb, 'evaluation_status', $2::text)
      WHERE id = $3 AND user_id = $4`,
    [JSON.stringify(evaluation), status, taskId, userId],
  );
  // Évènement de timeline : l'UI n'affiche « Correction proposée » que si corrective_task_id est présent.
  await pool
    .query(
      "INSERT INTO agent_events (task_id, user_id, type, message, data) VALUES ($1, $2, 'evaluation', $3, $4::jsonb)",
      [
        taskId,
        userId,
        `Évaluation : ${String(evaluation.verdict ?? status)}`,
        JSON.stringify({
          source: "agent",
          verdict: evaluation.verdict ?? null,
          action_taken: evaluation.action_taken ?? null,
          corrective_task_id: evaluation.corrective_task_id ?? null,
        }),
      ],
    )
    .catch(() => {});
}

/**
 * Boucle Observer → Corriger, exécutée dans une tâche de fond SUIVIE après qu'une tâche
 * 'goal' passe en completed/failed. Évalue (au plus une fois : réservation atomique) puis :
 *  - success → mémoire « solution » PROPOSÉE (jamais validée automatiquement) ;
 *  - retry   → tâche corrective liée (parent/root) EN ATTENTE D'APPROBATION ;
 *  - sinon   → mémoire « error » proposée.
 * Le texte saisi (text/content) est masqué avant tout envoi au LLM (contrat §12).
 */
export async function maybeEvaluateGoalTask(
  taskId: string,
  userId: string,
  opts: { screenshots?: string[] } = {},
): Promise<EvaluationOutcome> {
  const { rows } = await pool.query(
    `SELECT payload, result, status, control, target_agent_key_id FROM agent_tasks WHERE id = $1 AND user_id = $2`,
    [taskId, userId],
  );
  if (rows.length === 0) return { skipped: "gone" };
  const task = rows[0] as EvaluableTask & { target_agent_key_id?: string | null };
  const skip = evaluationSkipReason(task);
  if (skip) return { skipped: skip };
  const meta = task.payload!.goal_meta!;
  const plannedSteps = Array.isArray(task.payload!.steps) ? task.payload!.steps : [];

  // Réservation atomique : une seule évaluation par tâche, même si /update est rejoué.
  const claim = await pool.query(
    `UPDATE agent_tasks
        SET result = COALESCE(result, '{}'::jsonb) || jsonb_build_object('evaluation_status', 'running')
      WHERE id = $1 AND user_id = $2 AND status IN ('completed', 'failed')
        AND NOT (COALESCE(result, '{}'::jsonb) ? 'evaluation')
        AND NOT (COALESCE(result, '{}'::jsonb) ? 'evaluation_status')
      RETURNING id`,
    [taskId, userId],
  );
  if (claim.rowCount !== 1) return { skipped: "already_evaluated" };

  // Captures : uniquement par le champ vision (3 dernières) ; rapport texte sans base64 et masqué.
  const fallbackShot = getScreenshot(taskId, userId);
  const screenshots = opts.screenshots?.length ? opts.screenshots.slice(-3) : fallbackShot ? [fallbackShot.image_b64] : [];
  const textResult = maskTypedText(stripImageB64(task.result ?? { status: task.status }));
  const maskedSteps = maskTypedText(plannedSteps);

  let evaluation;
  try {
    evaluation = await evaluateGoal(meta.goal, maskedSteps, textResult, screenshots);
  } catch (e) {
    const msg = e instanceof ServiceError ? e.message : "erreur interne";
    await recordEvaluation(taskId, userId, { verdict: null, action_taken: "evaluation_failed", reason: msg, at: new Date().toISOString() }, "error");
    await logEvent(userId, "Agent", `Évaluation impossible (${msg})`, "error");
    if (!(e instanceof ServiceError)) throw e; // journalisé par la tâche de fond
    return { action_taken: "evaluation_failed" };
  }

  const llmVerdict = evaluation.verdict;
  const base = { llm_verdict: llmVerdict, reason: evaluation.reason, at: new Date().toISOString() };

  // Non évaluable (python-ia : simulé, plan vide, annulé, rien d'exécuté) : jamais un
  // succès, ni correction ni mémoire.
  if (llmVerdict === "not_evaluable" || evaluation.evaluable === false) {
    await recordEvaluation(taskId, userId, { ...base, verdict: "not_evaluable", action_taken: "none" }, "skipped");
    return { verdict: "not_evaluable", action_taken: "none" };
  }

  if (llmVerdict === "success") {
    await writeMemory(userId, "solution", meta.goal, `Plan réussi : ${JSON.stringify(maskedSteps)}`, {
      taskId,
      source: "evaluator",
    });
    await recordEvaluation(taskId, userId, { ...base, verdict: "success", action_taken: "memory_proposed" }, "done");
    await logEvent(userId, "Agent", `Objectif atteint (selon l'évaluateur) : ${meta.goal}`, "success");
    return { verdict: "success", action_taken: "memory_proposed" };
  }

  const correctives = Array.isArray(evaluation.corrective_steps) ? evaluation.corrective_steps : [];
  if (llmVerdict === "retry" && meta.attempt < meta.max_attempts && correctives.length > 0) {
    const checked = clampAndValidatePlanSteps(correctives.map((s) => compactStep(s as unknown as Record<string, unknown>)));
    const steps = checked.ok ? checked.value : [];
    const dirs = checked.ok ? await allowedDirsForTarget(userId, task.target_agent_key_id) : [];
    const invalid = checked.ok ? (findInvalidStep(steps) ?? findPathOutsideAllowed(steps, dirs)) : checked.error;
    if (invalid) {
      await writeMemory(userId, "error", meta.goal, `Plan correctif refusé : ${invalid}`, { taskId, source: "evaluator" });
      await recordEvaluation(
        taskId,
        userId,
        { ...base, verdict: "abort", action_taken: "correction_invalid", correction_error: invalid },
        "done",
      );
      await logEvent(userId, "Agent", `Correction abandonnée (plan invalide) : ${invalid}`, "error");
      return { verdict: "abort", action_taken: "correction_invalid" };
    }
    const correctiveId = await createGoalTask(
      userId,
      steps,
      {
        ...meta,
        attempt: meta.attempt + 1,
        parent_task_id: taskId,
        root_task_id: meta.root_task_id ?? taskId,
        awaiting_approval: true,
        correction_reason: evaluation.reason,
      },
      task.target_agent_key_id ?? null,
    );
    await recordEvaluation(
      taskId,
      userId,
      { ...base, verdict: "retry", action_taken: "correction_awaiting_approval", corrective_task_id: correctiveId },
      "done",
    );
    await logEvent(
      userId,
      "Agent",
      `Correction proposée (tentative ${meta.attempt + 1}/${meta.max_attempts}), en attente d'approbation : ${evaluation.reason}`,
      "warning",
    );
    return { verdict: "retry", action_taken: "correction_awaiting_approval", corrective_task_id: correctiveId };
  }

  // Abandon : verdict « abort », ou « retry » impossible (tentatives épuisées / aucune étape).
  const action: EvaluationAction = llmVerdict === "retry" ? "max_attempts_reached" : "abandoned";
  await writeMemory(userId, "error", meta.goal, evaluation.reason, { taskId, attempts: meta.attempt, source: "evaluator" });
  await recordEvaluation(taskId, userId, { ...base, verdict: "abort", action_taken: action }, "done");
  await logEvent(userId, "Agent", `Objectif abandonné après ${meta.attempt} tentative(s) : ${evaluation.reason}`, "error");
  return { verdict: "abort", action_taken: action };
}
