// Exécution par P1 des tâches de rédaction (rôle content_writer, LOT 11) : modules de formation
// rédigés EN PARALLÈLE via python-ia, puis assemblage. Trois temps :
//   1. réservation : READY → RUNNING (bail court `p1:content_writer`) des tâches prêtes, en une
//      transaction (SKIP LOCKED : jamais deux nœuds sur la même tâche) ;
//   2. génération concurrente HORS transaction (appels modèle longs) ;
//   3. dépôt : TASK_RESULT (→ VALIDATING → COMPLETED) ou ERROR (→ RETRYING / FAILED), chacun
//      dans sa transaction, seulement si la tâche est toujours la nôtre (même tentative).
// Si node meurt entre 1 et 3, le bail expire et le reaper relance la tâche (rédaction
// idempotente). Un contenu volumineux est stocké comme artefact (sha256), jamais en ligne.
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { withTransaction, type Queryable } from "../../db.js";
import { buildModule } from "../../clients/iaClient.js";
import { isPlainObject } from "../../lib/sanitize.js";
import { logger } from "../../lib/logger.js";
import { resolveMediaDir } from "../../lib/mediaDir.js";
import { postMessage } from "../bus/messages.js";
import { artifactPath } from "../routes/artifacts.js";
import { TASK_COLS, getTask, transitionTask, type TaskRow } from "../tasks/repo.js";

export const SYSTEM_WRITER = "p1:content_writer";
const WRITER_LEASE_MS = 15 * 60 * 1000;
/** Au-delà, le contenu part en artefact et le résultat n'en garde que la référence. */
export const INLINE_RESULT_MAX_BYTES = 32 * 1024;

export interface ContentInput {
  task: Pick<TaskRow, "id" | "title" | "user_id" | "session_id">;
  spec: Record<string, unknown>;
  /** Résultats des dépendances dures (assemblage). */
  inputs: { node_key: string | null; title: string; result: Record<string, unknown> | null }[];
}
export type ContentGenerator = (input: ContentInput) => Promise<Record<string, unknown>>;

/** Générateur par défaut : python-ia pour un module, simple agrégation pour l'assemblage. */
export const defaultGenerator: ContentGenerator = async ({ spec, inputs }) => {
  if (spec.kind === "formation_module") {
    const module = isPlainObject(spec.module) ? spec.module : { title: String(spec.module ?? "") };
    const built = await buildModule({ program_title: String(spec.program_title ?? spec.topic ?? ""), module, research_notes: [] });
    return { kind: "formation_module", module: built };
  }
  if (spec.kind === "formation_assemble") {
    return { kind: "formation", topic: spec.topic ?? null, modules: inputs.map((i) => ({ node_key: i.node_key, title: i.title, result: i.result })) };
  }
  throw new Error(`contenu : type « ${String(spec.kind)} » inconnu`);
};

interface Claimed {
  task: TaskRow;
  inputs: ContentInput["inputs"];
}

async function claim(limit: number, now: Date): Promise<Claimed[]> {
  return withTransaction(async (client) => {
    const { rows } = await client.query(
      `SELECT ${TASK_COLS.split(",").map((c) => `t.${c.trim()}`).join(", ")}
         FROM soulbah.tasks t JOIN soulbah.sessions s ON s.id = t.session_id
        WHERE t.status = 'READY' AND t.role = 'content_writer' AND s.status = 'RUNNING'
        ORDER BY t.priority, t.created_at FOR UPDATE OF t SKIP LOCKED LIMIT $1`,
      [limit],
    );
    const out: Claimed[] = [];
    for (const ready of rows as TaskRow[]) {
      const t = await transitionTask(client, {
        task: ready,
        to: "RUNNING",
        set: { attempt: ready.attempt + 1, lease_owner: SYSTEM_WRITER, lease_expires_at: new Date(now.getTime() + WRITER_LEASE_MS), started_at: now },
        actor: SYSTEM_WRITER,
        data: { executed_by: "p1" },
      });
      if (!t) continue;
      const deps = await client.query(
        `SELECT dt.node_key, dt.title, dt.result FROM soulbah.task_dependencies d JOIN soulbah.tasks dt ON dt.id = d.depends_on_task_id
          WHERE d.task_id = $1 AND d.kind = 'hard' ORDER BY dt.node_key`,
        [t.id],
      );
      out.push({ task: t, inputs: deps.rows as ContentInput["inputs"] });
    }
    return out;
  });
}

/** Résultat déposé : en ligne s'il est petit, sinon artefact JSON (sha256) référencé. */
async function packResult(q: Queryable, task: TaskRow, content: Record<string, unknown>, mediaDir: string): Promise<Record<string, unknown>> {
  const json = JSON.stringify(content);
  if (Buffer.byteLength(json, "utf8") <= INLINE_RESULT_MAX_BYTES) return { ok: true, ...content };
  const buf = Buffer.from(json, "utf8");
  const sha = createHash("sha256").update(buf).digest("hex");
  const file = artifactPath(mediaDir, task.user_id, sha);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (!fs.existsSync(file)) {
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, buf);
    fs.renameSync(tmp, file);
  }
  const { rows } = await q.query(
    `INSERT INTO soulbah.artifacts (user_id, session_id, task_id, sha256, mime, size_bytes, uri, kind, retention_class, metadata)
     VALUES ($1, $2, $3, $4, 'application/json', $5, $6, 'report', 'session', '{}'::jsonb)
     ON CONFLICT (user_id, sha256) DO UPDATE SET task_id = coalesce(soulbah.artifacts.task_id, EXCLUDED.task_id)
     RETURNING id`,
    [task.user_id, task.session_id, task.id, sha, buf.length, `file://artifacts/${task.user_id}/${sha}`],
  );
  return { ok: true, kind: content.kind ?? null, artifact_id: rows[0].id, sha256: sha, size_bytes: buf.length };
}

export interface ContentReport {
  started: number;
  completed: number;
  failed: number;
}

export async function runContentTasks(opts: { limit?: number; generate?: ContentGenerator; now?: Date; mediaDir?: string } = {}): Promise<ContentReport> {
  const now = opts.now ?? new Date();
  const generate = opts.generate ?? defaultGenerator;
  const mediaDir = opts.mediaDir ?? resolveMediaDir();
  const claimed = await claim(Math.max(1, Math.min(20, opts.limit ?? 6)), now);
  const report: ContentReport = { started: claimed.length, completed: 0, failed: 0 };
  if (!claimed.length) return report;
  // Génération concurrente : les modules d'une formation sont rédigés en même temps.
  const settled = await Promise.allSettled(
    claimed.map((c) => generate({ task: c.task, spec: isPlainObject(c.task.spec) ? c.task.spec : {}, inputs: c.inputs })),
  );
  for (const [i, s] of settled.entries()) {
    const c = claimed[i];
    try {
      await withTransaction(async (client) => {
        const fresh = await getTask(client, c.task.id);
        if (!fresh || fresh.status !== "RUNNING" || fresh.attempt !== c.task.attempt || fresh.lease_owner !== SYSTEM_WRITER) return; // reprise par le reaper entre-temps
        if (s.status === "fulfilled") {
          const result = await packResult(client, fresh, s.value, mediaDir);
          const out = await postMessage(client, { task: fresh, type: "TASK_RESULT", payload: { result }, actor: SYSTEM_WRITER, attempt: fresh.attempt });
          if (!out.ok) throw new Error(out.error);
          report.completed++;
        } else {
          const message = s.reason instanceof Error ? s.reason.message : String(s.reason);
          const out = await postMessage(client, { task: fresh, type: "ERROR", payload: { kind: "error", message: message.slice(0, 1000) }, actor: SYSTEM_WRITER, attempt: fresh.attempt });
          if (!out.ok) throw new Error(out.error);
          report.failed++;
        }
      });
    } catch (e) {
      logger.warn({ task: c.task.id, err: (e as Error).message }, "rédaction : dépôt du résultat impossible (le bail expirera, tâche reprise)");
    }
  }
  return report;
}
