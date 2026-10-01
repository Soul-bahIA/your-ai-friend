// Tâches V2 : transitions CAS auditées (LOT 7). Chaque changement d'état est un UPDATE gardé
// par l'état de départ (`WHERE status = from`) — si une autre instance a déjà bougé la tâche,
// rien n'est écrit et l'appelant le sait (null). L'audit est écrit dans la même transaction.
import type { Queryable } from "../../db.js";
import { audit } from "../audit.js";
import { assertTransition, isTerminal, LEASED_STATUSES, type TaskStatus } from "./stateMachine.js";

export const TASK_COLS = `id, session_id, user_id, parent_task_id, node_key, title, role, status, attempt, retry_count,
  max_retries, lease_owner, lease_expires_at, idempotency_key, security_level, resources, spec,
  acceptance_criteria, result, error, simulated, blocked_reason, waiting_reason, priority, plan_version,
  next_attempt_at, escalate_at, created_at, updated_at, started_at, finished_at`;

export interface TaskRow {
  id: string;
  session_id: string;
  user_id: string;
  parent_task_id: string | null;
  node_key: string | null;
  title: string;
  role: string;
  status: TaskStatus;
  attempt: number;
  retry_count: number;
  max_retries: number;
  lease_owner: string | null;
  lease_expires_at: string | Date | null;
  idempotency_key: string | null;
  security_level: "L0" | "L1" | "L2" | "L3";
  resources: { key: string; mode: "exclusive" | "shared" }[];
  spec: Record<string, unknown>;
  acceptance_criteria: unknown[];
  result: Record<string, unknown> | null;
  error: string | null;
  simulated: boolean;
  blocked_reason: string | null;
  waiting_reason: string | null;
  priority: number;
  plan_version: number;
  next_attempt_at: string | Date | null;
  escalate_at: string | Date | null;
  created_at: string | Date;
  updated_at: string | Date;
  started_at: string | Date | null;
  finished_at: string | Date | null;
}

export async function getTask(q: Queryable, id: string, userId?: string): Promise<TaskRow | null> {
  const values: unknown[] = [id];
  let where = "id = $1";
  if (userId) {
    values.push(userId);
    where += " AND user_id = $2";
  }
  const { rows } = await q.query(`SELECT ${TASK_COLS} FROM soulbah.tasks WHERE ${where}`, values);
  return (rows[0] as TaskRow | undefined) ?? null;
}

export async function listSessionTasks(q: Queryable, sessionId: string): Promise<TaskRow[]> {
  const { rows } = await q.query(`SELECT ${TASK_COLS} FROM soulbah.tasks WHERE session_id = $1 ORDER BY created_at, node_key`, [sessionId]);
  return rows as TaskRow[];
}

export interface TransitionInput {
  task: Pick<TaskRow, "id" | "user_id" | "session_id" | "status">;
  to: TaskStatus;
  /** Colonnes supplémentaires à poser (SQL `col = $n`), ex. { error: "…", retry_count: 2 }. */
  set?: Record<string, unknown>;
  actor: string;
  data?: Record<string, unknown>;
}

/** Colonnes autorisées dans `set` (jamais status/id/user_id/session_id). */
const SETTABLE = new Set([
  "attempt",
  "retry_count",
  "lease_owner",
  "lease_expires_at",
  "result",
  "error",
  "simulated",
  "blocked_reason",
  "waiting_reason",
  "next_attempt_at",
  "escalate_at",
  "started_at",
  "finished_at",
  "spec",
  "plan_version",
]);
const JSON_COLS = new Set(["result", "spec"]);

/**
 * Transition CAS : vérifie la table §9.4, écrit l'UPDATE gardé par l'état de départ, audite.
 * Renvoie la ligne mise à jour, ou null si la tâche n'était plus dans l'état de départ.
 * Quitter un état à bail vers un état sans bail libère les ressources de la tâche.
 */
export async function transitionTask(q: Queryable, input: TransitionInput): Promise<TaskRow | null> {
  const from = input.task.status;
  assertTransition(from, input.to);
  const sets: string[] = ["status = $1", "updated_at = now()"];
  const values: unknown[] = [input.to];
  for (const [k, v] of Object.entries(input.set ?? {})) {
    if (!SETTABLE.has(k)) throw new Error(`transitionTask : colonne non modifiable « ${k} »`);
    values.push(JSON_COLS.has(k) ? JSON.stringify(v) : v);
    sets.push(`${k} = $${values.length}${JSON_COLS.has(k) ? "::jsonb" : ""}`);
  }
  if (isTerminal(input.to) && !("finished_at" in (input.set ?? {}))) sets.push("finished_at = now()");
  const leavingLease = LEASED_STATUSES.includes(from) && !LEASED_STATUSES.includes(input.to);
  if (leavingLease && !("lease_expires_at" in (input.set ?? {}))) sets.push("lease_expires_at = NULL");
  values.push(input.task.id, from);
  const { rows } = await q.query(
    `UPDATE soulbah.tasks SET ${sets.join(", ")} WHERE id = $${values.length - 1} AND status = $${values.length} RETURNING ${TASK_COLS}`,
    values,
  );
  if (rows.length !== 1) return null;
  const row = rows[0] as TaskRow;
  if (leavingLease) {
    await q.query("DELETE FROM soulbah.resource_leases WHERE holder_task_id = $1", [row.id]);
    await q.query(
      "UPDATE soulbah.agents SET status = $2, current_task_id = NULL, updated_at = now() WHERE current_task_id = $1",
      [row.id, isTerminal(input.to) ? "STOPPED" : "IDLE"],
    );
  }
  await audit(
    {
      userId: input.task.user_id,
      sessionId: input.task.session_id,
      taskId: input.task.id,
      actor: input.actor,
      action: "task.transition",
      entity: "task",
      entityId: input.task.id,
      data: { from, to: input.to, attempt: row.attempt, ...(input.data ?? {}) },
    },
    q,
  );
  return row;
}

/** Annule toutes les tâches non terminales d'une session (CAS ligne par ligne, auditées). */
export async function cancelSessionTasks(q: Queryable, sessionId: string, actor: string, reason: string): Promise<number> {
  const tasks = await listSessionTasks(q, sessionId);
  let n = 0;
  for (const t of tasks) {
    if (isTerminal(t.status)) continue;
    const r = await transitionTask(q, { task: t, to: "CANCELLED", set: { error: reason }, actor, data: { reason } });
    if (r) n++;
  }
  return n;
}
