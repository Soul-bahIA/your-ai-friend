// Reaper GLOBAL des tâches agent (T19) : indépendant du poll du propriétaire, il traite
// toutes les tâches 'in_progress' sans signe de vie depuis AGENT_TASK_STALE_SECONDS :
//  - arrêt demandé (control='stop') → 'cancelled' (jamais ré-exécutée) ;
//  - sinon remise en file (requeue_count+1 = nouvelle tentative), au plus MAX_REQUEUES fois ;
//  - au-delà → 'failed' (boucle de crash).
// Un verrou consultatif transactionnel garantit qu'une seule instance l'exécute à la fois.
import { withTransaction } from "../db.js";
import { config } from "../config.js";
import { buildReaperQueries } from "../lib/agentTaskSql.js";
import { logger } from "../lib/logger.js";

export const MAX_REQUEUES = 3;
/** Clé du verrou consultatif (constante partagée par toutes les instances). */
export const REAPER_LOCK_KEY = 0x50_4c_42_52; // « SBLR »

export interface ReaperReport {
  locked: boolean;
  cancelled: number;
  requeued: number;
  abandoned: number;
}

export async function reapStaleTasks(
  staleSeconds = config.agentTaskStaleSeconds,
  maxRequeues = MAX_REQUEUES,
): Promise<ReaperReport> {
  return withTransaction(async (client) => {
    const lock = await client.query("SELECT pg_try_advisory_xact_lock($1) AS locked", [REAPER_LOCK_KEY]);
    if (lock.rows[0]?.locked !== true) return { locked: false, cancelled: 0, requeued: 0, abandoned: 0 };

    const q = buildReaperQueries(staleSeconds, maxRequeues);
    const cancelled = await client.query(q.cancelStopped.sql, q.cancelStopped.values);
    const requeued = await client.query(q.requeue.sql, q.requeue.values);
    const abandoned = await client.query(q.abandon.sql, q.abandon.values);

    const events = [
      ...cancelled.rows.map((r) => ({ ...r, type: "task_cancelled", msg: "Arrêt demandé et agent injoignable — tâche annulée" })),
      ...requeued.rows.map((r) => ({
        ...r,
        type: "task_requeued",
        msg: `Agent interrompu — tâche remise en file (reprise ${r.requeue_count}/${maxRequeues})`,
      })),
      ...abandoned.rows.map((r) => ({ ...r, type: "task_failed", msg: "Interrompue trop de fois — abandonnée" })),
    ];
    for (const e of events) {
      await client.query(
        "INSERT INTO agent_events (task_id, user_id, type, message, data) VALUES ($1, $2, $3, $4, $5::jsonb)",
        [e.id, e.user_id, e.type, e.msg, JSON.stringify({ source: "agent", reaper: true })],
      );
    }
    const report = {
      locked: true,
      cancelled: cancelled.rowCount ?? 0,
      requeued: requeued.rowCount ?? 0,
      abandoned: abandoned.rowCount ?? 0,
    };
    if (report.cancelled + report.requeued + report.abandoned > 0) logger.warn(report, "reaper : tâches orphelines traitées");
    return report;
  });
}
