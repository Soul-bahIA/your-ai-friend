// Tâches de maintenance périodiques (et au démarrage, dès que la DB est joignable).
import fs from "node:fs";
import path from "node:path";
import { pool } from "../db.js";
import { config } from "../config.js";
import { activeGenerations } from "./activeJobs.js";
import { logger } from "../lib/logger.js";
import { resolveMediaDir } from "../lib/mediaDir.js";

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
 * Rétention des évènements agent :
 *  - tout évènement de plus de 3 jours ;
 *  - les heartbeats (anciens agents) de tâches qui ne sont plus en cours, > 1 jour ;
 *  - captures base64 héritées (avant LOT 1) retirées des lignes restantes (has_image=true).
 */
export async function purgeAgentEvents(): Promise<number> {
  const old = await pool.query("DELETE FROM agent_events WHERE created_at < now() - interval '3 days'");
  const hb = await pool.query(
    `DELETE FROM agent_events e
      WHERE e.type = 'heartbeat' AND e.created_at < now() - interval '1 day'
        AND NOT EXISTS (SELECT 1 FROM agent_tasks t WHERE t.id = e.task_id AND t.status = 'in_progress')`,
  );
  const img = await pool.query(
    `UPDATE agent_events SET data = (data - 'image_b64') || '{"has_image": true}'::jsonb
      WHERE data ? 'image_b64'`,
  );
  const n = (old.rowCount ?? 0) + (hb.rowCount ?? 0);
  if (n > 0 || (img.rowCount ?? 0) > 0) {
    logger.info({ deleted: n, images_stripped: img.rowCount ?? 0 }, "évènements agent purgés");
  }
  return n;
}

/**
 * Évaluations interrompues (processus arrêté pendant l'appel au LLM) : marquées en erreur
 * après 15 min pour que l'UI n'affiche pas « en cours » indéfiniment.
 */
export async function recoverStuckEvaluations(): Promise<number> {
  const { rowCount } = await pool.query(
    `UPDATE agent_tasks
        SET result = result || jsonb_build_object('evaluation_status', 'error',
              'evaluation', jsonb_build_object('verdict', NULL, 'action_taken', 'evaluation_failed',
                                               'reason', 'Évaluation interrompue (redémarrage du serveur)'))
      WHERE status IN ('completed', 'failed')
        AND result ->> 'evaluation_status' = 'running'
        AND COALESCE(completed_at, updated_at) < now() - interval '15 minutes'`,
  );
  return rowCount ?? 0;
}

export interface MediaFile {
  name: string;
  mtimeMs: number;
  isFile: boolean;
}

/** Nom de fichier référencé par une URL /media/<nom> (null si autre chose). */
export function mediaNameFromUrl(url: unknown): string | null {
  if (typeof url !== "string") return null;
  const m = /^\/media\/([^/?#]+)/.exec(url.trim());
  return m ? decodeURIComponent(m[1]) : null;
}

/**
 * Fichiers à purger (pur) : fichiers ordinaires du dossier média, plus vieux que
 * `retentionDays`, jamais référencés par une formation, jamais cachés (dotfiles).
 */
export function selectMediaToPurge(
  files: MediaFile[],
  referenced: ReadonlySet<string>,
  now: number,
  retentionDays: number,
): string[] {
  if (!(retentionDays > 0)) return [];
  const cutoff = now - retentionDays * 86_400_000;
  return files
    .filter((f) => f.isFile && !f.name.startsWith(".") && f.mtimeMs < cutoff && !referenced.has(f.name))
    .map((f) => f.name);
}

/**
 * Rétention des médias (T37) : supprime les MP4/PDF de MEDIA_DIR plus vieux que
 * MEDIA_RETENTION_DAYS (défaut 30) qui ne sont référencés par AUCUNE formation
 * (video_url / pdf_url). Si la liste des références ne peut pas être lue, rien n'est supprimé.
 */
export async function purgeMedia(dir = resolveMediaDir(), now = Date.now()): Promise<number> {
  if (!(config.mediaRetentionDays > 0)) return 0;
  const { rows } = await pool.query(
    "SELECT video_url, pdf_url FROM formations WHERE video_url IS NOT NULL OR pdf_url IS NOT NULL",
  );
  const referenced = new Set<string>();
  for (const r of rows) {
    for (const u of [r.video_url, r.pdf_url]) {
      const name = mediaNameFromUrl(u);
      if (name) referenced.add(name);
    }
  }
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return 0; // dossier absent : rien à purger
  }
  const files: MediaFile[] = [];
  for (const e of entries) {
    if (!e.isFile()) continue;
    try {
      files.push({ name: e.name, mtimeMs: fs.statSync(path.join(dir, e.name)).mtimeMs, isFile: true });
    } catch {
      /* fichier disparu entre-temps */
    }
  }
  let removed = 0;
  for (const name of selectMediaToPurge(files, referenced, now, config.mediaRetentionDays)) {
    try {
      fs.unlinkSync(path.join(dir, name));
      removed++;
    } catch (e) {
      // Volume en lecture seule (docker) : la purge doit alors être faite côté python-ia.
      logger.warn({ file: name, err: (e as Error).message }, "purge média impossible");
      break;
    }
  }
  if (removed > 0) logger.info({ count: removed, retentionDays: config.mediaRetentionDays }, "médias non référencés purgés");
  return removed;
}

export async function runMaintenance(): Promise<void> {
  for (const job of [recoverStaleGenerations, purgeAgentEvents, recoverStuckEvaluations, () => purgeMedia()]) {
    try {
      await job();
    } catch (e) {
      logger.warn({ job: job.name || "purgeMedia", err: (e as Error).message }, "tâche de maintenance échouée");
    }
  }
}
