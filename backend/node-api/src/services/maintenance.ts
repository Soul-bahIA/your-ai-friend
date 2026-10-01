// Tâches de maintenance périodiques (et au démarrage, dès que la DB est joignable).
import { pool } from "../db";
import { config } from "../config";
import { activeGenerations } from "./activeJobs";
import { logger } from "../lib/logger";

// Statuts « en cours » utilisés par le front (pages Formations/Applications) et le backend.
const IN_FLIGHT_STATUSES = ["Génération...", "En cours"];

/**
 * Générations bloquées : une formation/application restée en 'Génération...'/'En cours'
 * depuis plus de STALE_GENERATION_MINUTES (process redémarré, crash…) passe en 'Erreur'
 * — l'utilisateur peut relancer. Les générations actives de CE processus sont exclues.
 */
export async function recoverStaleGenerations(): Promise<number> {
  const active = [...activeGenerations];
  let total = 0;
  for (const table of ["formations", "applications"] as const) {
    const { rowCount } = await pool.query(
      `UPDATE ${table} SET status = 'Erreur'
        WHERE status = ANY($1::text[])
          AND updated_at < now() - make_interval(mins => $2)
          AND NOT (id = ANY($3::uuid[]))`,
      [IN_FLIGHT_STATUSES, config.staleGenerationMinutes, active],
    );
    total += rowCount ?? 0;
  }
  if (total > 0) logger.warn({ count: total }, "générations bloquées marquées en erreur");
  return total;
}

/**
 * Rétention des évènements agent (captures base64 volumineuses) :
 *  - tout évènement de plus de 3 jours ;
 *  - les heartbeats (anciens agents) de tâches qui ne sont plus en cours, > 1 jour.
 */
export async function purgeAgentEvents(): Promise<number> {
  const old = await pool.query("DELETE FROM agent_events WHERE created_at < now() - interval '3 days'");
  const hb = await pool.query(
    `DELETE FROM agent_events e
      WHERE e.type = 'heartbeat' AND e.created_at < now() - interval '1 day'
        AND NOT EXISTS (SELECT 1 FROM agent_tasks t WHERE t.id = e.task_id AND t.status = 'in_progress')`,
  );
  const n = (old.rowCount ?? 0) + (hb.rowCount ?? 0);
  if (n > 0) logger.info({ count: n }, "évènements agent purgés");
  return n;
}

export async function runMaintenance(): Promise<void> {
  for (const job of [recoverStaleGenerations, purgeAgentEvents]) {
    try {
      await job();
    } catch (e) {
      logger.warn({ job: job.name, err: (e as Error).message }, "tâche de maintenance échouée");
    }
  }
}
