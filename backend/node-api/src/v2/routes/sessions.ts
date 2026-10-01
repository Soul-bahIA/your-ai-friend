// Routes V2 — sessions (missions) et tâches côté utilisateur (JWT) — LOT 7.
//
//   POST  /api/v2/sessions                 créer (DRAFT ; avec `plan` → AWAITING_APPROVAL)
//   GET   /api/v2/sessions                 lister
//   GET   /api/v2/sessions/:id             session + tâches + agents
//   POST  /api/v2/sessions/:id/plan        poser / remplacer le plan (DAG validé)
//   POST  /api/v2/sessions/:id/approve     AWAITING_APPROVAL → RUNNING (+ grant L1 de session)
//   POST  /api/v2/sessions/:id/pause|resume|cancel
//   PATCH /api/v2/sessions/:id             { max_parallel_agents }
//   GET   /api/v2/sessions/:id/messages    bus de la session
//   GET   /api/v2/tasks/:id                tâche + messages
//   POST  /api/v2/tasks/:id/answer         réponse à une QUESTION (WAITING → RUNNING)
//   POST  /api/v2/tasks/:id/retry          FAILED → READY (relance manuelle, auditée)
//   POST  /api/v2/tasks/:id/cancel
import type { FastifyInstance, FastifyReply } from "fastify";
import { pool, withTransaction } from "../../db.js";
import { requireUser } from "../../auth.js";
import { isPlainObject, isUuid, sanitizeLimit, unknownKeys } from "../../lib/sanitize.js";
import { userActor } from "../audit.js";
import { answerQuestion } from "../bus/messages.js";
import { tick } from "../scheduler/scheduler.js";
import { isSecurityLevel } from "../security/policy.js";
import { allowedDirsFor, applyPlan, draftPlan } from "../planner/planner.js";
import {
  approveSession,
  cancelSession,
  createSession,
  getSession,
  listSessions,
  transitionSession,
  updateSessionSettings,
  TERMINAL_SESSION_STATUSES,
} from "../sessions/repo.js";
import { getTask, listSessionTasks, transitionTask } from "../tasks/repo.js";
import { isTerminal } from "../tasks/stateMachine.js";
import { logger } from "../../lib/logger.js";

function bad(reply: FastifyReply, error: string) {
  return reply.status(400).send({ error });
}

/** Tick du scheduler déclenché par une action utilisateur (sans attendre l'intervalle). */
function kickScheduler(): void {
  void tick().catch((e) => logger.warn({ err: (e as Error).message }, "scheduler : tick après action utilisateur en échec"));
}

async function sessionMessages(sessionId: string, limit: number) {
  const { rows } = await pool.query(
    `SELECT id, task_id, from_agent_id, to_agent_id, to_role, type, correlation_id, reply_to, payload, requires_ack, acked_at, created_at
       FROM soulbah.messages WHERE session_id = $1 ORDER BY created_at DESC LIMIT ${limit}`,
    [sessionId],
  );
  return rows;
}

export async function sessionRoutes(app: FastifyInstance): Promise<void> {
  app.post("/api/v2/sessions", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const body = request.body;
    if (!isPlainObject(body)) return bad(reply, "corps JSON objet attendu");
    const extra = unknownKeys(body, ["goal", "max_security_level", "max_parallel_agents", "budget_usd", "environment", "simulated", "plan"]);
    if (extra.length) return bad(reply, `champ(s) inconnu(s) : ${extra.join(", ").slice(0, 200)}`);
    const goal = typeof body.goal === "string" ? body.goal.trim() : "";
    if (!goal || goal.length > 4000) return bad(reply, "goal requis (1–4000 caractères)");
    const level = body.max_security_level ?? "L2";
    if (!isSecurityLevel(level)) return bad(reply, "max_security_level : L0 | L1 | L2 | L3 attendu");
    let maxParallel: number | null = null;
    if (body.max_parallel_agents !== undefined && body.max_parallel_agents !== null) {
      const v = body.max_parallel_agents;
      if (typeof v !== "number" || !Number.isInteger(v) || v < 1 || v > 32) return bad(reply, "max_parallel_agents : entier 1–32 attendu");
      maxParallel = v;
    }
    let budget: number | null = null;
    if (body.budget_usd !== undefined && body.budget_usd !== null) {
      if (typeof body.budget_usd !== "number" || !Number.isFinite(body.budget_usd) || body.budget_usd < 0) return bad(reply, "budget_usd : nombre ≥ 0 attendu");
      budget = body.budget_usd;
    }
    if (body.environment !== undefined && !isPlainObject(body.environment)) return bad(reply, "environment : objet attendu");
    const dirs = body.plan === undefined ? [] : await allowedDirsFor(userId);
    try {
      const out = await withTransaction(async (client) => {
        const session = await createSession(client, userId, { goal, maxSecurityLevel: level, maxParallelAgents: maxParallel, budgetUsd: budget, environment: body.environment as Record<string, unknown> | undefined, simulated: body.simulated === true });
        if (body.plan === undefined) return { session, tasks: [] };
        // LOT 11 : tout plan posé passe par validateDag (rôles, outils, niveaux, chemins, critères).
        const applied = await applyPlan(client, session, body.plan, userId, dirs);
        if (!applied.ok) throw Object.assign(new Error(applied.error), { statusCode: applied.status, planErrors: applied.errors });
        return { session: applied.session, tasks: applied.tasks };
      });
      return reply.status(201).send(out);
    } catch (e) {
      const err = e as Error & { statusCode?: number; planErrors?: string[] };
      if (err.planErrors) return reply.status(err.statusCode ?? 422).send({ error: err.message, errors: err.planErrors });
      throw e;
    }
  });

  app.get("/api/v2/sessions", { preHandler: requireUser }, async (request) => {
    const q = request.query as { limit?: string };
    return { sessions: await listSessions(pool, request.user!.id, sanitizeLimit(q.limit, 50, 200)) };
  });

  app.get("/api/v2/sessions/:id", { preHandler: requireUser }, async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const session = await getSession(pool, request.user!.id, id);
    if (!session) return reply.status(404).send({ error: "Session introuvable" });
    const tasks = await listSessionTasks(pool, id);
    const agents = await pool.query("SELECT id, role, role_version, name, status, runtime_id, current_task_id, created_at, updated_at FROM soulbah.agents WHERE session_id = $1 ORDER BY created_at", [id]);
    const busy = agents.rows.filter((a) => a.status === "BUSY").length;
    return { session, tasks, agents: agents.rows, busy_agents: busy };
  });

  app.post("/api/v2/sessions/:id/plan", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const body = (request.body ?? {}) as { plan?: unknown };
    const dirs = await allowedDirsFor(userId);
    try {
      const out = await withTransaction(async (client) => {
        const session = await getSession(client, userId, id, true);
        if (!session) return null;
        if (!["DRAFT", "PLANNING", "AWAITING_APPROVAL"].includes(session.status)) {
          throw Object.assign(new Error(`plan non modifiable dans l'état ${session.status}`), { statusCode: 409 });
        }
        const applied = await applyPlan(client, session, body.plan, userId, dirs);
        if (!applied.ok) throw Object.assign(new Error(applied.error), { statusCode: applied.status, planErrors: applied.errors });
        return { session: applied.session, tasks: applied.tasks };
      });
      if (!out) return reply.status(404).send({ error: "Session introuvable" });
      return out;
    } catch (e) {
      const err = e as Error & { statusCode?: number; planErrors?: string[] };
      if (err.planErrors) return reply.status(err.statusCode ?? 422).send({ error: err.message, errors: err.planErrors });
      if (err.statusCode === 409 || err.statusCode === 400) return reply.status(err.statusCode).send({ error: err.message });
      throw e;
    }
  });

  // --- LOT 11 : planification par gabarit ou par le modèle, puis validateDag -------------------
  //   POST /api/v2/sessions/:id/propose { template, params } | { goal?, context? }
  //   → 200 { session (AWAITING_APPROVAL), tasks, source } ; 422 { errors } si validateDag refuse.
  app.post("/api/v2/sessions/:id/propose", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const body = request.body;
    if (!isPlainObject(body)) return bad(reply, "corps JSON objet attendu");
    const extra = unknownKeys(body, ["template", "params", "goal", "context"]);
    if (extra.length) return bad(reply, `champ(s) inconnu(s) : ${extra.join(", ")}`);
    if (body.template !== undefined && typeof body.template !== "string") return bad(reply, "template : texte attendu");
    if (body.params !== undefined && !isPlainObject(body.params)) return bad(reply, "params : objet attendu");
    if (body.goal !== undefined && (typeof body.goal !== "string" || body.goal.length > 4000)) return bad(reply, "goal : texte (≤ 4000 car.) attendu");
    if (body.context !== undefined && (typeof body.context !== "string" || body.context.length > 20000)) return bad(reply, "context : texte attendu");
    const session = await getSession(pool, userId, id);
    if (!session) return reply.status(404).send({ error: "Session introuvable" });
    if (!["DRAFT", "PLANNING", "AWAITING_APPROVAL"].includes(session.status)) {
      return reply.status(409).send({ error: `plan non modifiable dans l'état ${session.status}`, status: session.status });
    }
    const dirs = await allowedDirsFor(userId);
    const draft = await draftPlan(session, { template: body.template as string | undefined, params: body.params as Record<string, unknown> | undefined, goal: body.goal as string | undefined, context: body.context as string | undefined }, dirs);
    if (!draft.ok) return reply.status(draft.status).send({ error: draft.error, reason: draft.reason });
    try {
      const out = await withTransaction(async (client) => {
        const locked = await getSession(client, userId, id, true);
        if (!locked) return null;
        const applied = await applyPlan(client, locked, draft.plan, userId, dirs);
        if (!applied.ok) throw Object.assign(new Error(applied.error), { statusCode: applied.status, planErrors: applied.errors });
        return applied;
      });
      if (!out) return reply.status(404).send({ error: "Session introuvable" });
      return { session: out.session, tasks: out.tasks, source: draft.source, understanding: draft.understanding };
    } catch (e) {
      const err = e as Error & { statusCode?: number; planErrors?: string[] };
      if (err.planErrors) return reply.status(422).send({ error: err.message, errors: err.planErrors, plan: draft.plan, source: draft.source });
      throw e;
    }
  });

  app.post("/api/v2/sessions/:id/approve", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const out = await withTransaction(async (client) => {
      const session = await getSession(client, userId, id, true);
      if (!session) return { status: 404 as const };
      if (session.status !== "AWAITING_APPROVAL") return { status: 409 as const, current: session.status };
      return { status: 200 as const, session: await approveSession(client, session, userId) };
    });
    if (out.status === 404) return reply.status(404).send({ error: "Session introuvable" });
    if (out.status === 409) return reply.status(409).send({ error: `Session « ${out.current} » : approbation impossible`, status: out.current });
    kickScheduler();
    return { session: out.session };
  });

  for (const [action, from, to] of [
    ["pause", "RUNNING", "PAUSED"],
    ["resume", "PAUSED", "RUNNING"],
  ] as const) {
    app.post(`/api/v2/sessions/:id/${action}`, { preHandler: requireUser }, async (request, reply) => {
      const userId = request.user!.id;
      const { id } = request.params as { id: string };
      if (!isUuid(id)) return bad(reply, "id invalide");
      const out = await withTransaction(async (client) => {
        const session = await getSession(client, userId, id, true);
        if (!session) return { status: 404 as const };
        if (session.status !== from) return { status: 409 as const, current: session.status };
        return { status: 200 as const, session: await transitionSession(client, session, to, userActor(userId)) };
      });
      if (out.status === 404) return reply.status(404).send({ error: "Session introuvable" });
      if (out.status === 409) return reply.status(409).send({ error: `Session « ${out.current} » : ${action} impossible`, status: out.current });
      if (to === "RUNNING") kickScheduler();
      return { session: out.session };
    });
  }

  app.post("/api/v2/sessions/:id/cancel", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const body = (request.body ?? {}) as { reason?: unknown };
    const reason = typeof body.reason === "string" ? body.reason.slice(0, 500) : "annulée par l'utilisateur";
    const out = await withTransaction(async (client) => {
      const session = await getSession(client, userId, id, true);
      if (!session) return { status: 404 as const };
      if (TERMINAL_SESSION_STATUSES.includes(session.status)) return { status: 409 as const, current: session.status };
      return { status: 200 as const, session: await cancelSession(client, session, userActor(userId), reason) };
    });
    if (out.status === 404) return reply.status(404).send({ error: "Session introuvable" });
    if (out.status === 409) return reply.status(409).send({ error: `Session déjà terminée (« ${out.current} »)`, status: out.current });
    return { session: out.session };
  });

  app.patch("/api/v2/sessions/:id", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const body = request.body;
    if (!isPlainObject(body)) return bad(reply, "corps JSON objet attendu");
    const extra = unknownKeys(body, ["max_parallel_agents"]);
    if (extra.length) return bad(reply, `champ(s) inconnu(s) : ${extra.join(", ")}`);
    let maxParallel: number | null = null;
    if (body.max_parallel_agents !== undefined && body.max_parallel_agents !== null) {
      const v = body.max_parallel_agents;
      if (typeof v !== "number" || !Number.isInteger(v) || v < 1 || v > 32) return bad(reply, "max_parallel_agents : entier 1–32 attendu (null = réglage utilisateur)");
      maxParallel = v;
    }
    const out = await withTransaction(async (client) => {
      const session = await getSession(client, userId, id, true);
      if (!session) return null;
      return updateSessionSettings(client, session, userId, { maxParallelAgents: maxParallel });
    });
    if (!out) return reply.status(404).send({ error: "Session introuvable" });
    return { session: out };
  });

  app.get("/api/v2/sessions/:id/messages", { preHandler: requireUser }, async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const session = await getSession(pool, request.user!.id, id);
    if (!session) return reply.status(404).send({ error: "Session introuvable" });
    const q = request.query as { limit?: string };
    return { messages: await sessionMessages(id, sanitizeLimit(q.limit, 100, 500)) };
  });

  // --- Tâches ---------------------------------------------------------------------------
  app.get("/api/v2/tasks/:id", { preHandler: requireUser }, async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const task = await getTask(pool, id, request.user!.id);
    if (!task) return reply.status(404).send({ error: "Tâche introuvable" });
    const { rows } = await pool.query("SELECT id, type, payload, to_role, created_at, acked_at FROM soulbah.messages WHERE task_id = $1 ORDER BY created_at DESC LIMIT 100", [id]);
    const evaluations = await pool.query(
      "SELECT id, attempt, verdict, confidence, criteria, results, action_taken, evaluator, created_at FROM soulbah.evaluations WHERE task_id = $1 ORDER BY attempt DESC",
      [id],
    );
    return { task, messages: rows, evaluations: evaluations.rows };
  });

  app.post("/api/v2/tasks/:id/answer", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const body = (request.body ?? {}) as { answer?: unknown };
    if (typeof body.answer !== "string" || !body.answer.trim()) return bad(reply, "answer (texte) requis");
    const out = await withTransaction(async (client) => {
      const task = await getTask(client, id, userId);
      if (!task) return { status: 404 as const };
      if (task.status !== "WAITING") return { status: 409 as const, current: task.status };
      const t = await answerQuestion(client, task, body.answer as string, userId);
      return t ? { status: 200 as const, task: t } : { status: 409 as const, current: task.status };
    });
    if (out.status === 404) return reply.status(404).send({ error: "Tâche introuvable" });
    if (out.status === 409) return reply.status(409).send({ error: `Tâche « ${out.current} » : aucune question en attente`, status: out.current });
    return { task: out.task };
  });

  app.post("/api/v2/tasks/:id/retry", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const out = await withTransaction(async (client) => {
      const task = await getTask(client, id, userId);
      if (!task) return { status: 404 as const };
      if (task.status !== "FAILED") return { status: 409 as const, current: task.status };
      const t = await transitionTask(client, { task, to: "READY", set: { error: null, retry_count: 0, next_attempt_at: null, lease_owner: null }, actor: userActor(userId), data: { reason: "manual_retry" } });
      return t ? { status: 200 as const, task: t } : { status: 409 as const, current: task.status };
    });
    if (out.status === 404) return reply.status(404).send({ error: "Tâche introuvable" });
    if (out.status === 409) return reply.status(409).send({ error: `Tâche « ${out.current} » : seule une tâche FAILED se relance`, status: out.current });
    kickScheduler();
    return { task: out.task };
  });

  app.post("/api/v2/tasks/:id/cancel", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const out = await withTransaction(async (client) => {
      const task = await getTask(client, id, userId);
      if (!task) return { status: 404 as const };
      if (isTerminal(task.status)) return { status: 409 as const, current: task.status };
      const t = await transitionTask(client, { task, to: "CANCELLED", set: { error: "annulée par l'utilisateur" }, actor: userActor(userId), data: { reason: "user_cancel" } });
      return t ? { status: 200 as const, task: t } : { status: 409 as const, current: task.status };
    });
    if (out.status === 404) return reply.status(404).send({ error: "Tâche introuvable" });
    if (out.status === 409) return reply.status(409).send({ error: `Tâche déjà terminée (« ${out.current} »)`, status: out.current });
    return { task: out.task };
  });
}
