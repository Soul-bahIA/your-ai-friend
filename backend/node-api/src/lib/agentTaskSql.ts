// Construction (pure, testable) des requêtes de la file des tâches agent :
// claim/transitions gardés par tentative (attempt = requeue_count au moment du claim),
// ciblage d'un PC (target_agent_key_id / claimed_by_key_id), poll, annulation, reaper.

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

/** Une tâche en attente d'approbation (correction proposée par l'évaluateur) n'est ni servie ni réclamable. */
export const NOT_AWAITING_APPROVAL = `(payload #> '{goal_meta,awaiting_approval}') IS DISTINCT FROM 'true'::jsonb`;

export interface UpdateInput {
  taskId: string;
  userId: string;
  status: AgentTaskStatus;
  result?: unknown;
  errorMessage?: string | null;
  attempt?: number;
  /** Clé agent appelante : le claim écrit claimed_by_key_id et respecte le ciblage. */
  keyId?: string;
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
 * Si `keyId` est fourni : le claim exige que la tâche cible cette clé (ou aucune) et ne
 * soit pas en attente d'approbation, et écrit claimed_by_key_id ; une transition exige
 * que la tâche ait été réclamée par cette clé (ou par aucune, tâches antérieures).
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

  let keyParam: string | undefined;
  if (input.keyId !== undefined) {
    keyParam = `$${i++}`;
    values.push(input.keyId);
    if (kind === "claim") sets.push(`claimed_by_key_id = ${keyParam}::uuid`);
  }

  const where = [`id = $${i++}`, `user_id = $${i++}`];
  values.push(input.taskId, input.userId);
  where.push(kind === "claim" ? "status = 'pending'" : "status = 'in_progress'");
  if (input.attempt !== undefined) {
    where.push(`requeue_count = $${i++}`);
    values.push(input.attempt);
  }
  if (keyParam) {
    if (kind === "claim") {
      where.push(`(target_agent_key_id IS NULL OR target_agent_key_id = ${keyParam}::uuid)`);
      where.push(NOT_AWAITING_APPROVAL);
    } else {
      where.push(`(claimed_by_key_id IS NULL OR claimed_by_key_id = ${keyParam}::uuid)`);
    }
  }
  return {
    sql: `UPDATE agent_tasks SET ${sets.join(", ")} WHERE ${where.join(" AND ")} RETURNING id, status, requeue_count`,
    values,
    kind,
  };
}

/** Rafraîchit le signe de vie d'une tâche en cours (évènement / heartbeat). */
export function buildTaskTouch(
  taskId: string,
  userId: string,
  attempt?: number,
  keyId?: string,
): { sql: string; values: unknown[] } {
  const values: unknown[] = [taskId, userId];
  let sql = "UPDATE agent_tasks SET updated_at = now() WHERE id = $1 AND user_id = $2 AND status = 'in_progress'";
  if (attempt !== undefined) {
    values.push(attempt);
    sql += ` AND requeue_count = $${values.length}`;
  }
  if (keyId !== undefined) {
    values.push(keyId);
    sql += ` AND (claimed_by_key_id IS NULL OR claimed_by_key_id = $${values.length}::uuid)`;
  }
  return { sql: sql + " RETURNING id", values };
}

export const POLL_COLS = `id, user_id, task_type, status, priority, payload, requeue_count, control,
  target_agent_key_id, created_at, updated_at`;

/**
 * Poll d'un agent : tâches 'pending' de son utilisateur, ciblant SA clé ou aucune,
 * hors corrections en attente d'approbation ; ≤ 5, par priorité puis ancienneté.
 */
export function buildPollQuery(userId: string, keyId: string, limit = 5): { sql: string; values: unknown[] } {
  return {
    sql: `SELECT ${POLL_COLS} FROM agent_tasks
       WHERE user_id = $1 AND status = 'pending'
         AND (target_agent_key_id IS NULL OR target_agent_key_id = $2::uuid)
         AND ${NOT_AWAITING_APPROVAL}
       ORDER BY priority ASC, created_at ASC LIMIT ${Math.max(1, Math.min(Math.trunc(limit), 20))}`,
    values: [userId, keyId],
  };
}

/**
 * Annulation (JWT, propriétaire), atomique :
 *  - pending     → status 'cancelled' immédiatement ;
 *  - in_progress → control 'stop' (l'agent termine l'étape puis envoie 'cancelled').
 * 0 ligne → tâche absente (404) ou déjà terminale (409).
 */
export function buildCancel(taskId: string, userId: string): { sql: string; values: unknown[] } {
  return {
    sql: `UPDATE agent_tasks SET
         status = CASE WHEN status = 'pending' THEN 'cancelled' ELSE status END,
         completed_at = CASE WHEN status = 'pending' THEN now() ELSE completed_at END,
         control = CASE WHEN status = 'in_progress' THEN 'stop' ELSE control END
       WHERE id = $1 AND user_id = $2 AND status IN ('pending', 'in_progress')
       RETURNING id, status, control`,
    values: [taskId, userId],
  };
}

/** Approbation d'une correction proposée : awaiting_approval → false (tâche encore 'pending'). */
export function buildApprove(taskId: string, userId: string): { sql: string; values: unknown[] } {
  return {
    sql: `UPDATE agent_tasks SET payload = jsonb_set(
           jsonb_set(payload, '{goal_meta,awaiting_approval}', 'false'::jsonb),
           '{goal_meta,approved_at}', to_jsonb(now()))
       WHERE id = $1 AND user_id = $2 AND status = 'pending'
         AND (payload #> '{goal_meta,awaiting_approval}') = 'true'::jsonb
       RETURNING id, status, control, payload`,
    values: [taskId, userId],
  };
}

/** Requêtes du reaper GLOBAL (toutes les tâches, tous les utilisateurs). */
export function buildReaperQueries(staleSeconds: number, maxRequeues: number) {
  const stale = `status = 'in_progress' AND updated_at < now() - make_interval(secs => $1)`;
  return {
    /** Arrêt demandé par l'utilisateur mais agent muet : on n'exécute JAMAIS à nouveau → 'cancelled'. */
    cancelStopped: {
      sql: `UPDATE agent_tasks
          SET status = 'cancelled', completed_at = now(), updated_at = now(),
              error_message = 'Arrêt demandé ; agent injoignable — tâche annulée'
        WHERE ${stale} AND control = 'stop'
        RETURNING id, user_id`,
      values: [staleSeconds],
    },
    /** Agent muet : remise en file (requeue_count+1 = nouvelle tentative), au plus maxRequeues fois. */
    requeue: {
      sql: `UPDATE agent_tasks
          SET status = 'pending', started_at = NULL, claimed_by_key_id = NULL,
              requeue_count = requeue_count + 1, updated_at = now()
        WHERE ${stale} AND requeue_count < $2
        RETURNING id, user_id, requeue_count`,
      values: [staleSeconds, maxRequeues],
    },
    /** Boucle de crash : abandon après maxRequeues reprises. */
    abandon: {
      sql: `UPDATE agent_tasks
          SET status = 'failed', completed_at = now(), updated_at = now(),
              error_message = 'Interrompue puis reprise ' || requeue_count || ' fois sans aboutir — abandonnée'
        WHERE ${stale} AND requeue_count >= $2
        RETURNING id, user_id`,
      values: [staleSeconds, maxRequeues],
    },
  };
}
