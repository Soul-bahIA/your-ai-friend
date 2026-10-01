// Sessions (missions) V2 — LOT 7, audit §9.3 : cycle DRAFT → PLANNING → AWAITING_APPROVAL →
// RUNNING / PAUSED → COMPLETED | FAILED | CANCELLED, plan (DAG) versionné, approbation = grant
// L1 de session (audit §9.10), parallélisme par mission. Toute décision est auditée dans la
// transaction. node-api est le seul écrivain (rôle soulbah_api).
import type { Queryable } from "../../db.js";
import type { SecurityLevel } from "../../lib/toolCatalog.js";
import { audit, userActor } from "../audit.js";
import { isSecurityLevel } from "../security/policy.js";
import { cancelSessionTasks, listSessionTasks, type TaskRow } from "../tasks/repo.js";
import { isTerminal } from "../tasks/stateMachine.js";
import { topologicalOrder, type Plan } from "./dag.js";

export const SESSION_STATUSES = ["DRAFT", "PLANNING", "AWAITING_APPROVAL", "RUNNING", "PAUSED", "COMPLETED", "FAILED", "CANCELLED"] as const;
export type SessionStatus = (typeof SESSION_STATUSES)[number];
export const TERMINAL_SESSION_STATUSES: readonly SessionStatus[] = ["COMPLETED", "FAILED", "CANCELLED"];

export const SESSION_TRANSITIONS: Readonly<Record<SessionStatus, readonly SessionStatus[]>> = {
  DRAFT: ["PLANNING", "AWAITING_APPROVAL"],
  PLANNING: ["AWAITING_APPROVAL", "FAILED", "DRAFT"],
  AWAITING_APPROVAL: ["RUNNING", "PLANNING", "DRAFT"],
  RUNNING: ["PAUSED", "COMPLETED", "FAILED"],
  PAUSED: ["RUNNING"],
  COMPLETED: [],
  FAILED: [],
  CANCELLED: [],
};

export function canSessionTransition(from: SessionStatus, to: SessionStatus): boolean {
  if (from === to) return false;
  if (to === "CANCELLED") return !TERMINAL_SESSION_STATUSES.includes(from);
  return SESSION_TRANSITIONS[from].includes(to);
}

export const SESSION_COLS = `id, user_id, goal, status, environment, max_security_level, max_parallel_agents, budget_usd,
  spent_usd, plan, plan_version, simulated, error, created_at, updated_at, started_at, finished_at`;

export interface SessionRow {
  id: string;
  user_id: string;
  goal: string;
  status: SessionStatus;
  environment: Record<string, unknown>;
  max_security_level: SecurityLevel;
  max_parallel_agents: number | null;
  budget_usd: string | number | null;
  spent_usd: string | number;
  plan: Plan | null;
  plan_version: number;
  simulated: boolean;
  error: string | null;
  created_at: string | Date;
  updated_at: string | Date;
  started_at: string | Date | null;
  finished_at: string | Date | null;
}

export interface CreateSessionInput {
  goal: string;
  maxSecurityLevel?: SecurityLevel;
  maxParallelAgents?: number | null;
  budgetUsd?: number | null;
  environment?: Record<string, unknown>;
  simulated?: boolean;
}

export async function createSession(q: Queryable, userId: string, input: CreateSessionInput): Promise<SessionRow> {
  const level = input.maxSecurityLevel ?? "L2";
  if (!isSecurityLevel(level)) throw new Error("niveau de sécurité invalide");
  const { rows } = await q.query(
    `INSERT INTO soulbah.sessions (user_id, goal, max_security_level, max_parallel_agents, budget_usd, environment, simulated)
     VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7) RETURNING ${SESSION_COLS}`,
    [userId, input.goal, level, input.maxParallelAgents ?? null, input.budgetUsd ?? null, JSON.stringify(input.environment ?? {}), input.simulated === true],
  );
  const s = rows[0] as SessionRow;
  await audit({ userId, sessionId: s.id, actor: userActor(userId), action: "session.created", entity: "session", entityId: s.id, data: { goal: input.goal.slice(0, 200), level, simulated: s.simulated } }, q);
  return s;
}

export async function getSession(q: Queryable, userId: string, id: string, forUpdate = false): Promise<SessionRow | null> {
  const { rows } = await q.query(`SELECT ${SESSION_COLS} FROM soulbah.sessions WHERE id = $1 AND user_id = $2${forUpdate ? " FOR UPDATE" : ""}`, [id, userId]);
  return (rows[0] as SessionRow | undefined) ?? null;
}

export async function listSessions(q: Queryable, userId: string, limit = 50): Promise<SessionRow[]> {
  const { rows } = await q.query(`SELECT ${SESSION_COLS} FROM soulbah.sessions WHERE user_id = $1 ORDER BY created_at DESC LIMIT ${Math.max(1, Math.min(200, limit))}`, [userId]);
  return rows as SessionRow[];
}

/** Transition de session CAS + audit ; null si l'état de départ a changé. */
export async function transitionSession(
  q: Queryable,
  session: Pick<SessionRow, "id" | "user_id" | "status">,
  to: SessionStatus,
  actor: string,
  opts: { set?: Record<string, unknown>; data?: Record<string, unknown> } = {},
): Promise<SessionRow | null> {
  if (!canSessionTransition(session.status, to)) throw new Error(`session : transition ${session.status} → ${to} interdite`);
  const sets = ["status = $1", "updated_at = now()"];
  const values: unknown[] = [to];
  for (const [k, v] of Object.entries(opts.set ?? {})) {
    if (!["error", "started_at", "finished_at", "plan", "plan_version"].includes(k)) throw new Error(`transitionSession : colonne non modifiable « ${k} »`);
    values.push(k === "plan" ? JSON.stringify(v) : v);
    sets.push(`${k} = $${values.length}${k === "plan" ? "::jsonb" : ""}`);
  }
  if (to === "RUNNING" && !("started_at" in (opts.set ?? {}))) sets.push("started_at = coalesce(started_at, now())");
  if (TERMINAL_SESSION_STATUSES.includes(to) && !("finished_at" in (opts.set ?? {}))) sets.push("finished_at = now()");
  values.push(session.id, session.status);
  const { rows } = await q.query(
    `UPDATE soulbah.sessions SET ${sets.join(", ")} WHERE id = $${values.length - 1} AND status = $${values.length} RETURNING ${SESSION_COLS}`,
    values,
  );
  if (rows.length !== 1) return null;
  await audit(
    { userId: session.user_id, sessionId: session.id, actor, action: "session.transition", entity: "session", entityId: session.id, data: { from: session.status, to, ...(opts.data ?? {}) } },
    q,
  );
  return rows[0] as SessionRow;
}

/**
 * Pose (ou remplace) le plan d'une session en DRAFT / PLANNING / AWAITING_APPROVAL : les tâches
 * non terminales de la version précédente sont annulées, les nœuds deviennent des tâches PENDING
 * (plan_version + 1) et les arêtes des dépendances (le trigger anti-cycle de la base tranche en
 * dernier ressort). La session passe en AWAITING_APPROVAL.
 */
export async function setPlan(q: Queryable, session: SessionRow, plan: Plan, actor: string): Promise<{ session: SessionRow; tasks: TaskRow[] }> {
  if (!["DRAFT", "PLANNING", "AWAITING_APPROVAL"].includes(session.status)) {
    throw new Error(`session : plan non modifiable dans l'état ${session.status}`);
  }
  if (plan.nodes.some((n) => n.security_level > session.max_security_level)) {
    // Comparaison lexicale valable pour L0 < L1 < L2 < L3.
    const bad = plan.nodes.filter((n) => n.security_level > session.max_security_level).map((n) => n.key);
    throw new Error(`plan : nœud(s) au-dessus du plafond ${session.max_security_level} de la mission : ${bad.join(", ")}`);
  }
  await cancelSessionTasks(q, session.id, actor, "plan remplacé");
  const version = session.plan_version + 1;
  const byKey = new Map<string, TaskRow>();
  for (const key of topologicalOrder(plan)) {
    const n = plan.nodes.find((x) => x.key === key)!;
    const { rows } = await q.query(
      `INSERT INTO soulbah.tasks (session_id, user_id, node_key, title, role, security_level, resources, spec, acceptance_criteria,
                                  priority, max_retries, idempotency_key, plan_version, simulated)
       VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8::jsonb, $9::jsonb, $10, $11, $12, $13, $14)
       RETURNING id, session_id, user_id, status, node_key, title, role, security_level, attempt, retry_count, max_retries, priority, plan_version`,
      [
        session.id,
        session.user_id,
        n.key,
        n.title,
        n.role,
        n.security_level,
        JSON.stringify(n.resources),
        JSON.stringify(n.spec),
        JSON.stringify(n.acceptance_criteria),
        n.priority,
        n.max_retries,
        n.idempotency_key ? `${version}:${n.idempotency_key}` : null,
        version,
        session.simulated,
      ],
    );
    byKey.set(key, rows[0] as TaskRow);
  }
  for (const e of plan.edges) {
    await q.query("INSERT INTO soulbah.task_dependencies (task_id, depends_on_task_id, kind) VALUES ($1, $2, $3)", [byKey.get(e.to)!.id, byKey.get(e.from)!.id, e.kind]);
  }
  const updated =
    session.status === "AWAITING_APPROVAL"
      ? await updatePlanInPlace(q, session, plan, version)
      : await transitionSession(q, session, "AWAITING_APPROVAL", actor, { set: { plan, plan_version: version }, data: { plan_version: version, nodes: plan.nodes.length, edges: plan.edges.length } });
  if (!updated) throw new Error("session modifiée concurremment");
  await audit(
    { userId: session.user_id, sessionId: session.id, actor, action: "session.planned", entity: "session", entityId: session.id, data: { plan_version: version, nodes: plan.nodes.map((n) => ({ key: n.key, role: n.role, level: n.security_level })) } },
    q,
  );
  return { session: updated, tasks: [...byKey.values()] };
}

async function updatePlanInPlace(q: Queryable, session: SessionRow, plan: Plan, version: number): Promise<SessionRow | null> {
  const { rows } = await q.query(
    `UPDATE soulbah.sessions SET plan = $1::jsonb, plan_version = $2, updated_at = now() WHERE id = $3 AND status = 'AWAITING_APPROVAL' RETURNING ${SESSION_COLS}`,
    [JSON.stringify(plan), version, session.id],
  );
  return (rows[0] as SessionRow | undefined) ?? null;
}

/** Approbation du plan par l'utilisateur : RUNNING + grant L1 de session (audit §9.10). */
export async function approveSession(q: Queryable, session: SessionRow, userId: string): Promise<SessionRow> {
  if (session.status !== "AWAITING_APPROVAL") throw new Error(`session : approbation impossible dans l'état ${session.status}`);
  const updated = await transitionSession(q, session, "RUNNING", userActor(userId), { data: { plan_version: session.plan_version } });
  if (!updated) throw new Error("session modifiée concurremment");
  const { rows } = await q.query(
    `INSERT INTO soulbah.permissions (user_id, session_id, kind, security_level, scope, status, decided_by, decided_at)
     VALUES ($1, $2, 'grant', 'L1', $3::jsonb, 'approved', $1, now()) RETURNING id`,
    [userId, session.id, JSON.stringify({ tools: ["*"], resources: ["*"], origin: "session_approval", plan_version: session.plan_version })],
  );
  await audit(
    { userId, sessionId: session.id, actor: userActor(userId), action: "permission.granted", entity: "permission", entityId: rows[0].id as string, data: { level: "L1", scope: "session", plan_version: session.plan_version } },
    q,
  );
  return updated;
}

/** Annulation : session CANCELLED, toutes les tâches non terminales CANCELLED, grants révoqués. */
export async function cancelSession(q: Queryable, session: SessionRow, actor: string, reason = "annulée par l'utilisateur"): Promise<SessionRow> {
  if (TERMINAL_SESSION_STATUSES.includes(session.status)) throw new Error(`session déjà terminée (${session.status})`);
  const n = await cancelSessionTasks(q, session.id, actor, reason);
  await q.query("UPDATE soulbah.permissions SET status = 'revoked', updated_at = now() WHERE session_id = $1 AND kind = 'grant' AND status = 'approved'", [session.id]);
  const updated = await transitionSession(q, session, "CANCELLED", actor, { set: { error: reason }, data: { cancelled_tasks: n, reason } });
  if (!updated) throw new Error("session modifiée concurremment");
  return updated;
}

/** Clôture automatique d'une session RUNNING dont plus aucune tâche n'est active (scheduler). */
export async function closeSessionIfDone(q: Queryable, session: SessionRow, actor: string): Promise<SessionRow | null> {
  if (session.status !== "RUNNING") return null;
  const tasks = await listSessionTasks(q, session.id);
  if (tasks.length === 0 || tasks.some((t) => !isTerminal(t.status))) return null;
  const failed = tasks.filter((t) => t.status === "FAILED").length;
  const cancelled = tasks.filter((t) => t.status === "CANCELLED").length;
  const to: SessionStatus = failed > 0 ? "FAILED" : "COMPLETED";
  return transitionSession(q, session, to, actor, {
    set: failed > 0 ? { error: `${failed} tâche(s) en échec` } : {},
    data: { completed: tasks.length - failed - cancelled, failed, cancelled },
  });
}

/** Réglage par mission du parallélisme (§9.6) : relu à chaque tick, n'interrompt rien. */
export async function updateSessionSettings(q: Queryable, session: SessionRow, userId: string, patch: { maxParallelAgents?: number | null }): Promise<SessionRow> {
  const { rows } = await q.query(`UPDATE soulbah.sessions SET max_parallel_agents = $1, updated_at = now() WHERE id = $2 AND user_id = $3 RETURNING ${SESSION_COLS}`, [
    patch.maxParallelAgents ?? null,
    session.id,
    userId,
  ]);
  await audit({ userId, sessionId: session.id, actor: userActor(userId), action: "session.settings", entity: "session", entityId: session.id, data: { max_parallel_agents: patch.maxParallelAgents ?? null } }, q);
  return rows[0] as SessionRow;
}
