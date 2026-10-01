// Construction (pure, testable) des requêtes de mise à jour des tâches agent avec
// garde de tentative (attempt = requeue_count au moment du claim).

export const AGENT_TASK_STATUSES = ["pending", "in_progress", "completed", "failed", "cancelled"] as const;
export type AgentTaskStatus = (typeof AGENT_TASK_STATUSES)[number];
export const TERMINAL_STATUSES: readonly AgentTaskStatus[] = ["completed", "failed", "cancelled"];

export function isAgentTaskStatus(v: unknown): v is AgentTaskStatus {
  return typeof v === "string" && (AGENT_TASK_STATUSES as readonly string[]).includes(v);
}

/** attempt optionnel : undefined si absent, null si invalide, sinon l'entier. */
export function parseAttempt(v: unknown): number | undefined | null {
  if (v === undefined || v === null) return undefined;
  if (typeof v === "number" && Number.isInteger(v) && v >= 0) return v;
  return null;
}

export interface UpdateInput {
  taskId: string;
  userId: string;
  status: AgentTaskStatus;
  result?: unknown;
  errorMessage?: string | null;
  attempt?: number;
}

export interface BuiltQuery {
  sql: string;
  values: unknown[];
  /** 'claim' : pending → in_progress ; 'transition' : depuis in_progress. */
  kind: "claim" | "transition";
}

/**
 * - in_progress = CLAIM atomique : exige status='pending'.
 * - tout autre statut (terminal ou remise en pending) exige status='in_progress'.
 * Si `attempt` est fourni, exige aussi requeue_count = attempt : un agent dont la
 * tâche a été requeue (et reprise par un autre) ne peut plus l'écraser.
 */
export function buildAgentTaskUpdate(input: UpdateInput): BuiltQuery {
  const sets: string[] = ["status = $1", "updated_at = now()"];
  const values: unknown[] = [input.status];
  let i = 2;
  if (input.result !== undefined) {
    sets.push(`result = $${i++}::jsonb`);
    values.push(JSON.stringify(input.result));
  }
  if (input.errorMessage !== undefined) {
    sets.push(`error_message = $${i++}`);
    values.push(input.errorMessage);
  }
  const kind: BuiltQuery["kind"] = input.status === "in_progress" ? "claim" : "transition";
  if (kind === "claim") sets.push("started_at = now()");
  if ((TERMINAL_STATUSES as readonly string[]).includes(input.status)) sets.push("completed_at = now()");
  if (input.status === "pending") sets.push("started_at = NULL");

  const where = [`id = $${i++}`, `user_id = $${i++}`];
  values.push(input.taskId, input.userId);
  where.push(kind === "claim" ? "status = 'pending'" : "status = 'in_progress'");
  if (input.attempt !== undefined) {
    where.push(`requeue_count = $${i++}`);
    values.push(input.attempt);
  }
  return {
    sql: `UPDATE agent_tasks SET ${sets.join(", ")} WHERE ${where.join(" AND ")} RETURNING id, status, requeue_count`,
    values,
    kind,
  };
}

/** Rafraîchit le signe de vie d'une tâche en cours (évènement / heartbeat). */
export function buildTaskTouch(taskId: string, userId: string, attempt?: number): { sql: string; values: unknown[] } {
  const values: unknown[] = [taskId, userId];
  let sql = "UPDATE agent_tasks SET updated_at = now() WHERE id = $1 AND user_id = $2 AND status = 'in_progress'";
  if (attempt !== undefined) {
    sql += " AND requeue_count = $3";
    values.push(attempt);
  }
  return { sql: sql + " RETURNING id", values };
}
