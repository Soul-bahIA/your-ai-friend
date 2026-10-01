import type { FastifyInstance } from "fastify";
import { pool } from "../db";
import { requireUser } from "../auth";
import { planGoal, evaluateGoal, ServiceError, type AgentStep } from "../clients/iaClient";
import { logEvent } from "../services/logs";
import { getMemoryContext, writeMemory } from "./agentMemory";
import { getUserAllowedDirs } from "../services/agentKeys";
import { clampAndValidatePlanSteps, validateGoalBody } from "../lib/agentSteps";
import { stripImageB64 } from "../lib/sanitize";
import { config } from "../config";

// Moteur de raisonnement — côté orchestration :
//   POST /api/agent/goal : objectif en langage naturel → plan (Claude) → agent_task
//   maybeEvaluateGoalTask : appelé quand l'agent termine une tâche issue d'un objectif ;
//   Claude évalue le rapport et, si besoin, une tâche corrective est créée (borné).

const MAX_ATTEMPTS = 3;

interface GoalMeta {
  goal: string;
  attempt: number;
  max_attempts: number;
  understanding?: string;
}

/** Nettoie une étape : ne garde que les champs pertinents pour son type. */
function compactStep(s: AgentStep): Record<string, unknown> {
  const out: Record<string, unknown> = { type: s.type };
  if (s.note) out.note = s.note;
  switch (s.type) {
    case "open_app": out.app = s.app; break;
    case "type_text": out.text = s.text; break;
    case "hotkey": out.keys = s.keys ?? []; break;
    case "wait": out.seconds = s.seconds ?? 1; break;
    case "screenshot": if (s.path) out.path = s.path; break;
    case "click":
    case "double_click":
    case "right_click":
    case "move_mouse":
    case "drag":
      if (s.x !== undefined) out.x = s.x;
      if (s.y !== undefined) out.y = s.y;
      break;
    case "scroll": out.dy = s.dy ?? 0; break;
    case "window": out.action = s.action ?? "focus"; out.window_title = s.window_title; break;
    case "move_file": out.src = s.src; out.dest = s.dest; break;
    case "write_file": out.path = s.path; out.content = s.content ?? ""; break;
    case "read_file":
    case "list_dir":
    case "make_dir": out.path = s.path; break;
    case "run_command":
      out.program = s.program;
      out.args = s.args ?? [];
      if (s.cwd) out.cwd = s.cwd;
      break;
    case "record_screen":
      out.path = s.path;
      if (s.duration !== undefined) out.duration = s.duration;
      if (s.fps !== undefined) out.fps = s.fps;
      break;
    case "edit_video":
      out.clips = s.clips ?? [];
      out.output = s.output;
      if (s.title) out.title = s.title;
      break;
    case "resolve_montage":
      out.clips = s.clips ?? [];
      out.output = s.output;
      if (s.audio) out.audio = s.audio;
      if (s.project) out.project = s.project;
      break;
    case "phone_list_devices":
      break;
    case "phone_tap":
      out.x = s.x; out.y = s.y;
      break;
    case "phone_swipe":
      out.x1 = s.x1; out.y1 = s.y1; out.x2 = s.x2; out.y2 = s.y2;
      if (s.duration_ms !== undefined) out.duration_ms = s.duration_ms;
      break;
    case "phone_type":
      out.text = s.text;
      break;
    case "phone_key":
      out.keycode = s.keycode;
      break;
    case "phone_open_app":
      out.package = s.package;
      break;
    case "phone_screenshot":
      out.path = s.path;
      break;
  }
  if (s.device_id && s.type.startsWith("phone_")) out.device_id = s.device_id;
  return out;
}

// Champs obligatoires par type d'étape : un plan qui en omet un échouerait
// forcément côté agent — on le rejette AVANT de le mettre en file.
const REQUIRED_FIELDS: Record<string, string[]> = {
  open_app: ["app"],
  type_text: ["text"],
  hotkey: ["keys"],
  window: ["window_title"],
  move_file: ["src", "dest"],
  write_file: ["path"],
  read_file: ["path"],
  list_dir: ["path"],
  make_dir: ["path"],
  run_command: ["program"],
  record_screen: ["path"],
  edit_video: ["clips", "output"],
  resolve_montage: ["clips", "output"],
  phone_tap: ["x", "y"],
  phone_swipe: ["x1", "y1", "x2", "y2"],
  phone_type: ["text"],
  phone_key: ["keycode"],
  phone_open_app: ["package"],
  phone_screenshot: ["path"],
};

/** Retourne null si toutes les étapes sont complètes, sinon un message d'erreur lisible. */
function findInvalidStep(steps: Record<string, unknown>[]): string | null {
  for (const [i, step] of steps.entries()) {
    for (const field of REQUIRED_FIELDS[step.type as string] ?? []) {
      const v = step[field];
      const missing = v === undefined || v === null || v === "" || (Array.isArray(v) && v.length === 0);
      if (missing) return `étape ${i + 1} (${step.type}) : champ obligatoire manquant « ${field} »`;
    }
  }
  return null;
}

/** Extrait les captures d'écran (base64) prises pendant l'exécution — bornées à 3
 * pour limiter le coût vision — utilisées par l'évaluation pour « voir » l'écran. */
function extractScreenshots(result: unknown): string[] {
  const steps = (result as { steps?: unknown[] } | null)?.steps;
  if (!Array.isArray(steps)) return [];
  const shots: string[] = [];
  for (const s of steps) {
    const step = s as { type?: string; data?: { image_b64?: string } };
    if (step?.type === "screenshot" && step.data?.image_b64) {
      shots.push(step.data.image_b64);
      if (shots.length >= 3) break;
    }
  }
  return shots;
}

async function createGoalTask(
  userId: string,
  steps: Record<string, unknown>[],
  meta: GoalMeta,
): Promise<string> {
  const { rows } = await pool.query(
    `INSERT INTO agent_tasks (user_id, task_type, status, priority, payload)
     VALUES ($1, 'goal', 'pending', 3, $2::jsonb) RETURNING id`,
    [userId, JSON.stringify({ steps, goal_meta: meta })],
  );
  return rows[0].id as string;
}

/**
 * Planifie un objectif en langage naturel (Claude) et met la tâche en file pour
 * l'agent local. Réutilisable par la route /api/agent/goal ET par le dispatch du
 * Chief Agent (Desktop Agent). Retourne un résultat discriminé (pas de reply ici).
 */
export type GoalOutcome =
  | { ok: true; task_id: string; understanding: string; steps: Record<string, unknown>[] }
  | { ok: false; status: number; error: string; understanding?: string; reason?: string };

export async function planAndQueueGoal(userId: string, goal: string): Promise<GoalOutcome> {
  const trimmed = goal.trim();
  if (!trimmed) return { ok: false, status: 400, error: "goal requis" };

  const memoryContext = await getMemoryContext(userId, trimmed);
  const allowedDirs = await getUserAllowedDirs(userId);
  const dirsContext =
    allowedDirs.length > 0
      ? `DOSSIERS AUTORISÉS (whitelist de l'agent) — tout chemin de fichier/dossier/cwd DOIT être strictement à l'intérieur de l'un d'eux :\n${allowedDirs.map((d) => `- ${d}`).join("\n")}`
      : "ATTENTION : aucun dossier autorisé connu pour cet agent. Toute étape fichier/commande/vidéo sera refusée — si l'objectif en nécessite, réponds feasible=false en l'expliquant.";
  const context = [dirsContext, memoryContext].filter(Boolean).join("\n\n");

  let plan;
  try {
    plan = await planGoal(trimmed, context);
  } catch (e) {
    if (e instanceof ServiceError) return { ok: false, status: e.status, error: e.message };
    throw e;
  }

  if (!plan.feasible || plan.steps.length === 0) {
    await logEvent(userId, "Agent", `Objectif refusé par le planificateur : ${plan.reason}`, "warning");
    return {
      ok: false,
      status: 422,
      error: "Objectif non réalisable avec les capacités actuelles de l'agent",
      understanding: plan.understanding,
      reason: plan.reason,
    };
  }

  const checked = clampAndValidatePlanSteps(plan.steps.map(compactStep));
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
  const invalid = findInvalidStep(steps);
  if (invalid) {
    await logEvent(userId, "Agent", `Plan rejeté (incomplet) : ${invalid}`, "warning");
    return {
      ok: false,
      status: 422,
      error: "Le plan généré est incomplet, réessayez en précisant l'objectif",
      understanding: plan.understanding,
      reason: invalid,
    };
  }

  const taskId = await createGoalTask(userId, steps, {
    goal: trimmed,
    attempt: 1,
    max_attempts: MAX_ATTEMPTS,
    understanding: plan.understanding,
  });
  await logEvent(userId, "Agent", `Objectif planifié (${steps.length} étapes) : ${plan.understanding}`, "info");
  return { ok: true, task_id: taskId, understanding: plan.understanding, steps };
}

export async function agentGoalRoutes(app: FastifyInstance): Promise<void> {
  app.post(
    "/api/agent/goal",
    { preHandler: requireUser, config: { rateLimit: { max: config.rateLimitExpensive, timeWindow: "1 minute" } } },
    async (request, reply) => {
    const userId = request.user!.id;
    const parsed = validateGoalBody(request.body);
    if (!parsed.ok) return reply.status(400).send({ error: parsed.error });
    const outcome = await planAndQueueGoal(userId, parsed.value);
    if (!outcome.ok) {
      return reply.status(outcome.status).send({
        error: outcome.error,
        understanding: outcome.understanding,
        reason: outcome.reason,
      });
    }
    return {
      success: true,
      task_id: outcome.task_id,
      understanding: outcome.understanding,
      steps: outcome.steps,
    };
    },
  );
}

/**
 * Boucle Observer → Corriger. Appelée (fire-and-forget) après qu'une tâche 'goal'
 * passe en completed/failed. Évalue le rapport via Claude ; en cas d'échec corrigeable,
 * crée une tâche corrective (attempt+1, borné à max_attempts).
 */
export async function maybeEvaluateGoalTask(taskId: string, userId: string): Promise<void> {
  const { rows } = await pool.query(
    `SELECT payload, result, status FROM agent_tasks WHERE id = $1 AND user_id = $2`,
    [taskId, userId],
  );
  if (rows.length === 0) return;
  const { payload, result, status } = rows[0] as {
    payload: { steps?: unknown[]; goal_meta?: GoalMeta };
    result: unknown;
    status: string;
  };
  const meta = payload?.goal_meta;
  if (!meta || !["completed", "failed"].includes(status)) return;

  // Les captures ne passent QUE par le champ vision dédié (screenshots, max 3) ;
  // le rapport texte est débarrassé de tout image_b64 (sinon des Mo de base64 en prompt).
  const screenshots = extractScreenshots(result);
  const textResult = stripImageB64(result ?? { status });

  let evaluation;
  try {
    evaluation = await evaluateGoal(meta.goal, payload.steps ?? [], textResult, screenshots);
  } catch (e) {
    await logEvent(userId, "Agent", `Évaluation impossible (${(e as Error).message})`, "error");
    return;
  }

  // Trace le verdict sur la tâche évaluée
  await pool.query(
    `UPDATE agent_tasks
     SET result = COALESCE(result, '{}'::jsonb) || jsonb_build_object('evaluation', $1::jsonb)
     WHERE id = $2 AND user_id = $3`,
    [JSON.stringify({ verdict: evaluation.verdict, reason: evaluation.reason }), taskId, userId],
  );

  if (evaluation.verdict === "success") {
    await writeMemory(
      userId,
      "solution",
      meta.goal,
      `Plan réussi : ${JSON.stringify(payload.steps ?? [])}`,
      { taskId },
    );
    await logEvent(userId, "Agent", `Objectif atteint : ${meta.goal}`, "success");
    return;
  }

  if (evaluation.verdict === "retry" && meta.attempt < meta.max_attempts && evaluation.corrective_steps.length > 0) {
    const checked = clampAndValidatePlanSteps(evaluation.corrective_steps.map(compactStep));
    const steps = checked.ok ? checked.value : [];
    const invalid = checked.ok ? findInvalidStep(steps) : checked.error;
    if (invalid) {
      await writeMemory(userId, "error", meta.goal, `Plan correctif incomplet : ${invalid}`, { taskId });
      await logEvent(userId, "Agent", `Correction abandonnée (plan incomplet) : ${invalid}`, "error");
      return;
    }
    const newId = await createGoalTask(userId, steps, { ...meta, attempt: meta.attempt + 1 });
    await logEvent(
      userId,
      "Agent",
      `Correction planifiée (tentative ${meta.attempt + 1}/${meta.max_attempts}) : ${evaluation.reason}`,
      "warning",
    );
    void newId;
    return;
  }

  await writeMemory(userId, "error", meta.goal, evaluation.reason, {
    taskId,
    attempts: meta.attempt,
  });
  await logEvent(
    userId,
    "Agent",
    `Objectif abandonné après ${meta.attempt} tentative(s) : ${evaluation.reason}`,
    "error",
  );
}
