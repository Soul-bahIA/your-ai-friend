// Scheduler V2 (LOT 7, audit §9.4, §9.6, §9.7, §9.9) :
//  - tick()  : sous verrou consultatif, promeut PENDING → READY (dépendances dures COMPLETED),
//              PENDING → BLOCKED (dépendance dure FAILED/CANCELLED), RETRYING → READY (backoff
//              écoulé), BLOCKED → FAILED (escalade), REAPER : bail expiré → RETRYING direct (ou FAILED
//              quand les reprises sont épuisées), ressources libérées, sessions clôturées.
//  - lease() : attribue des baux à un runtime — SELECT … FOR UPDATE SKIP LOCKED (jamais deux baux sur
//              la même tâche, même sous concurrence), plafond effectif = min(global, utilisateur,
//              mission, slots du runtime), ressources exclusives/partagées acquises dans la même
//              transaction (SAVEPOINT par tâche : un conflit saute la tâche, n'annule rien d'autre).
//  - keepalive() : prolonge les baux d'un runtime, renvoie l'ordre de contrôle par tâche et les
//              messages / réponses en attente.
import type pg from "pg";
import { pool, withTransaction } from "../../db.js";
import { config } from "../../config.js";
import { logger } from "../../lib/logger.js";
import { audit } from "../audit.js";
import { closeSessionIfDone, getSession, type SessionRow } from "../sessions/repo.js";
import { TASK_COLS, transitionTask, type TaskRow } from "../tasks/repo.js";
import { afterFailure, DEFAULT_ESCALATION_MS, LEASED_STATUSES, retryBackoffMs } from "../tasks/stateMachine.js";
import { effectiveMaxParallel, grantableSlots } from "./parallelism.js";

export const SCHEDULER_LOCK_KEY = 0x53_42_53_43; // « SBSC »
export const SYSTEM_SCHEDULER = "system:scheduler";
export const SYSTEM_REAPER = "system:reaper";

export interface TickReport {
  locked: boolean;
  ready: number;
  blocked: number;
  retried: number;
  escalated: number;
  reaped: number;
  leasesReleased: number;
  sessionsClosed: number;
}

const LEASED_SQL = LEASED_STATUSES.map((s) => `'${s}'`).join(", ");

/** Un passage du scheduler (idempotent, une seule instance à la fois). */
export async function tick(now = new Date()): Promise<TickReport> {
  return withTransaction(async (client) => {
    const lock = await client.query("SELECT pg_try_advisory_xact_lock($1) AS locked", [SCHEDULER_LOCK_KEY]);
    const report: TickReport = { locked: lock.rows[0]?.locked === true, ready: 0, blocked: 0, retried: 0, escalated: 0, reaped: 0, leasesReleased: 0, sessionsClosed: 0 };
    if (!report.locked) return report;

    // Ressources dont le bail est échu ou dont le détenteur n'a plus de bail.
    const released = await client.query(
      `DELETE FROM soulbah.resource_leases rl
        WHERE rl.expires_at <= $1
           OR NOT EXISTS (SELECT 1 FROM soulbah.tasks t WHERE t.id = rl.holder_task_id AND t.status IN (${LEASED_SQL}))`,
      [now],
    );
    report.leasesReleased = released.rowCount ?? 0;

    // REAPER : bail expiré → RETRYING directement (jamais via FAILED), ou FAILED si épuisé.
    const stale = await client.query(
      `SELECT ${TASK_COLS} FROM soulbah.tasks WHERE status IN (${LEASED_SQL}) AND lease_expires_at IS NOT NULL AND lease_expires_at <= $1 FOR UPDATE SKIP LOCKED`,
      [now],
    );
    for (const t of stale.rows as TaskRow[]) {
      const to = afterFailure(t.retry_count, t.max_retries, "lease_expired");
      const set =
        to === "RETRYING"
          ? { retry_count: t.retry_count + 1, next_attempt_at: new Date(now.getTime() + retryBackoffMs(t.retry_count)), lease_owner: null, error: `bail expiré (tentative ${t.attempt})` }
          : { lease_owner: null, error: `bail expiré (tentative ${t.attempt}) : reprises épuisées (${t.retry_count}/${t.max_retries})` };
      const r = await transitionTask(client, { task: t, to, set, actor: SYSTEM_REAPER, data: { reason: "lease_expired", lease_owner: t.lease_owner } });
      if (r) report.reaped++;
    }

    // Escalade des blocages.
    const blocked = await client.query(
      `SELECT ${TASK_COLS} FROM soulbah.tasks WHERE status = 'BLOCKED' AND escalate_at IS NOT NULL AND escalate_at <= $1 FOR UPDATE SKIP LOCKED`,
      [now],
    );
    for (const t of blocked.rows as TaskRow[]) {
      const r = await transitionTask(client, { task: t, to: "FAILED", set: { error: `blocage non levé : ${t.blocked_reason ?? "raison inconnue"}` }, actor: SYSTEM_SCHEDULER, data: { reason: "escalation" } });
      if (r) report.escalated++;
    }

    // Sessions RUNNING : promotion des PENDING et des RETRYING, blocage des dépendances échouées.
    const sessions = await client.query(
      `SELECT id, user_id FROM soulbah.sessions WHERE status = 'RUNNING' FOR UPDATE SKIP LOCKED`,
    );
    for (const s of sessions.rows as { id: string; user_id: string }[]) {
      const pending = await client.query(
        `SELECT ${TASK_COLS} FROM soulbah.tasks WHERE session_id = $1 AND status IN ('PENDING', 'RETRYING') ORDER BY created_at FOR UPDATE SKIP LOCKED`,
        [s.id],
      );
      for (const t of pending.rows as TaskRow[]) {
        if (t.status === "RETRYING") {
          if (t.next_attempt_at && new Date(t.next_attempt_at).getTime() <= now.getTime()) {
            const r = await transitionTask(client, { task: t, to: "READY", set: { next_attempt_at: null }, actor: SYSTEM_SCHEDULER, data: { reason: "backoff_elapsed" } });
            if (r) report.retried++;
          }
          continue;
        }
        const deps = await client.query(
          `SELECT d.kind, dt.status, dt.node_key FROM soulbah.task_dependencies d JOIN soulbah.tasks dt ON dt.id = d.depends_on_task_id WHERE d.task_id = $1`,
          [t.id],
        );
        const hard = (deps.rows as { kind: string; status: string; node_key: string | null }[]).filter((d) => d.kind === "hard");
        const failed = hard.filter((d) => d.status === "FAILED" || d.status === "CANCELLED");
        if (failed.length > 0) {
          const r = await transitionTask(client, {
            task: t,
            to: "BLOCKED",
            set: { blocked_reason: `dépendance ${failed[0].status.toLowerCase()} : ${failed.map((d) => d.node_key ?? "?").join(", ")}`, escalate_at: new Date(now.getTime() + DEFAULT_ESCALATION_MS) },
            actor: SYSTEM_SCHEDULER,
            data: { reason: "dependency_failed", dependencies: failed.map((d) => d.node_key) },
          });
          if (r) report.blocked++;
        } else if (hard.every((d) => d.status === "COMPLETED")) {
          const r = await transitionTask(client, { task: t, to: "READY", actor: SYSTEM_SCHEDULER, data: { reason: "dependencies_completed" } });
          if (r) report.ready++;
        }
      }
      const session = await getSession(client, s.user_id, s.id, true);
      if (session && (await closeSessionIfDone(client, session, SYSTEM_SCHEDULER))) report.sessionsClosed++;
    }
    return report;
  });
}

export interface LeaseRequest {
  runtimeId: string;
  userId: string;
  /** Slots libres annoncés par le runtime pour cet appel. */
  slots: number;
  leaseSeconds?: number;
  now?: Date;
}

export interface LeasedTask {
  id: string;
  session_id: string;
  node_key: string | null;
  title: string;
  role: string;
  security_level: string;
  attempt: number;
  spec: Record<string, unknown>;
  resources: { key: string; mode: string }[];
  acceptance_criteria: unknown[];
  simulated: boolean;
  lease_owner: string;
  lease_expires_at: string | Date;
  max_security_level: string;
}

export interface LeaseReport {
  granted: LeasedTask[];
  max_parallel: number;
  running: number;
  skipped_resources: number;
}

async function leasedCount(client: pg.PoolClient, where: string, values: unknown[]): Promise<number> {
  const { rows } = await client.query(`SELECT count(*)::int AS n FROM soulbah.tasks WHERE status IN (${LEASED_SQL}) AND ${where}`, values);
  return Number(rows[0].n);
}

/** Tente d'acquérir toutes les ressources d'une tâche ; false au premier conflit. */
async function acquireResources(client: pg.PoolClient, task: TaskRow, expiresAt: Date, now: Date): Promise<boolean> {
  for (const r of task.resources ?? []) {
    await client.query("DELETE FROM soulbah.resource_leases WHERE resource_key = $1 AND expires_at <= $2", [r.key, now]);
    const held = await client.query("SELECT mode FROM soulbah.resource_leases WHERE resource_key = $1 AND holder_task_id <> $2 FOR UPDATE", [r.key, task.id]);
    const conflict = held.rows.some((h) => h.mode === "exclusive" || r.mode === "exclusive");
    if (conflict) return false;
    await client.query(
      `INSERT INTO soulbah.resource_leases (resource_key, holder_task_id, mode, expires_at) VALUES ($1, $2, $3, $4)
       ON CONFLICT (resource_key, holder_task_id) DO UPDATE SET expires_at = EXCLUDED.expires_at`,
      [r.key, task.id, r.mode, expiresAt],
    );
  }
  return true;
}

/** Baux pour un runtime : jamais deux fois la même tâche (SKIP LOCKED), plafonds relus à chaque appel. */
export async function lease(req: LeaseRequest): Promise<LeaseReport> {
  const now = req.now ?? new Date();
  const leaseMs = Math.max(10, Math.min(3600, Math.trunc(req.leaseSeconds ?? config.v2LeaseSeconds))) * 1000;
  return withTransaction(async (client) => {
    const rt = await client.query("SELECT id, max_slots, status FROM soulbah.runtimes WHERE id = $1 AND user_id = $2", [req.runtimeId, req.userId]);
    if (rt.rows.length !== 1) throw new Error("runtime inconnu");
    const us = await client.query("SELECT max_parallel_agents FROM soulbah.user_settings WHERE user_id = $1", [req.userId]);
    const maxParallel = effectiveMaxParallel({ global: config.maxParallelAgents, user: us.rows[0]?.max_parallel_agents ?? null, runtime: rt.rows[0].max_slots });
    const running = await leasedCount(client, "user_id = $1", [req.userId]);
    const report: LeaseReport = { granted: [], max_parallel: maxParallel, running, skipped_resources: 0 };
    let grantable = grantableSlots(maxParallel, running, req.slots);
    if (grantable === 0) return report;

    const candidates = await client.query(
      `SELECT ${TASK_COLS.split(",").map((c) => `t.${c.trim()}`).join(", ")}, s.max_parallel_agents AS session_cap, s.max_security_level
         FROM soulbah.tasks t JOIN soulbah.sessions s ON s.id = t.session_id
        WHERE t.user_id = $1 AND t.status = 'READY' AND s.status = 'RUNNING'
        ORDER BY t.priority ASC, t.created_at ASC
        FOR UPDATE OF t SKIP LOCKED LIMIT $2`,
      [req.userId, Math.max(grantable * 3, 6)],
    );
    const owner = `runtime:${req.runtimeId}`;
    const expiresAt = new Date(now.getTime() + leaseMs);
    for (const row of candidates.rows as (TaskRow & { session_cap: number | null; max_security_level: string })[]) {
      if (grantable <= 0) break;
      if (row.session_cap !== null) {
        const inSession = await leasedCount(client, "session_id = $1", [row.session_id]);
        if (inSession >= row.session_cap) continue;
      }
      await client.query("SAVEPOINT lease_task");
      try {
        if (!(await acquireResources(client, row, expiresAt, now))) {
          await client.query("ROLLBACK TO SAVEPOINT lease_task");
          report.skipped_resources++;
          continue;
        }
        const t = await transitionTask(client, {
          task: row,
          to: "RUNNING",
          set: { attempt: row.attempt + 1, lease_owner: owner, lease_expires_at: expiresAt, started_at: row.started_at ?? now, waiting_reason: null, blocked_reason: null },
          actor: owner,
          data: { lease_seconds: leaseMs / 1000 },
        });
        if (!t) {
          await client.query("ROLLBACK TO SAVEPOINT lease_task");
          continue;
        }
        await client.query(
          `INSERT INTO soulbah.agents (session_id, user_id, role, runtime_id, status, current_task_id, name)
           VALUES ($1, $2, $3, $4, 'BUSY', $5, $6)`,
          [t.session_id, t.user_id, t.role, req.runtimeId, t.id, `${t.role}#${t.attempt}`],
        );
        await client.query("RELEASE SAVEPOINT lease_task");
        report.granted.push({
          id: t.id,
          session_id: t.session_id,
          node_key: t.node_key,
          title: t.title,
          role: t.role,
          security_level: t.security_level,
          attempt: t.attempt,
          spec: t.spec,
          resources: t.resources,
          acceptance_criteria: t.acceptance_criteria,
          simulated: t.simulated,
          lease_owner: owner,
          lease_expires_at: expiresAt,
          max_security_level: row.max_security_level,
        });
        grantable--;
        report.running++;
      } catch (e) {
        await client.query("ROLLBACK TO SAVEPOINT lease_task");
        logger.warn({ task: row.id, err: (e as Error).message }, "lease : tâche sautée");
      }
    }
    await client.query("UPDATE soulbah.runtimes SET last_seen_at = now(), status = 'online', updated_at = now() WHERE id = $1", [req.runtimeId]);
    return report;
  });
}

export interface KeepaliveItem {
  task_id: string;
  attempt: number;
}
export interface KeepaliveResult {
  task_id: string;
  status: string;
  /** continue : poursuivre ; stop : arrêter (bail perdu, annulée, autre tentative) */
  control: "continue" | "stop";
  lease_expires_at: string | Date | null;
  answers: unknown[];
  messages: { id: string; type: string; payload: unknown; created_at: string | Date }[];
}

/** Prolonge les baux détenus par ce runtime et renvoie les ordres de contrôle. */
export async function keepalive(req: { runtimeId: string; userId: string; items: KeepaliveItem[]; leaseSeconds?: number; now?: Date }): Promise<KeepaliveResult[]> {
  const now = req.now ?? new Date();
  const leaseMs = Math.max(10, Math.min(3600, Math.trunc(req.leaseSeconds ?? config.v2LeaseSeconds))) * 1000;
  const owner = `runtime:${req.runtimeId}`;
  const expiresAt = new Date(now.getTime() + leaseMs);
  const out: KeepaliveResult[] = [];
  await pool.query("UPDATE soulbah.runtimes SET last_seen_at = now(), status = 'online', updated_at = now() WHERE id = $1 AND user_id = $2", [req.runtimeId, req.userId]);
  for (const item of req.items) {
    const { rows } = await pool.query(
      `UPDATE soulbah.tasks SET lease_expires_at = $3, updated_at = now()
        WHERE id = $1 AND user_id = $2 AND attempt = $4 AND lease_owner = $5 AND status IN (${LEASED_SQL})
        RETURNING id, status, lease_expires_at, spec`,
      [item.task_id, req.userId, expiresAt, item.attempt, owner],
    );
    if (rows.length !== 1) {
      const cur = await pool.query("SELECT status FROM soulbah.tasks WHERE id = $1 AND user_id = $2", [item.task_id, req.userId]);
      out.push({ task_id: item.task_id, status: (cur.rows[0]?.status as string) ?? "unknown", control: "stop", lease_expires_at: null, answers: [], messages: [] });
      continue;
    }
    await pool.query("UPDATE soulbah.resource_leases SET expires_at = $2 WHERE holder_task_id = $1", [item.task_id, expiresAt]);
    const spec = rows[0].spec as { answers?: unknown[] };
    const msgs = await pool.query(
      `SELECT m.id, m.type, m.payload, m.created_at FROM soulbah.messages m
         JOIN soulbah.agents a ON a.id = m.to_agent_id
        WHERE a.current_task_id = $1 AND m.requires_ack AND m.acked_at IS NULL ORDER BY m.created_at LIMIT 50`,
      [item.task_id],
    );
    out.push({
      task_id: item.task_id,
      status: rows[0].status as string,
      control: rows[0].status === "RUNNING" || rows[0].status === "WAITING" ? "continue" : "stop",
      lease_expires_at: rows[0].lease_expires_at as string,
      answers: Array.isArray(spec?.answers) ? spec.answers : [],
      messages: msgs.rows as KeepaliveResult["messages"],
    });
  }
  return out;
}

/** Rapport d'un tick pour les journaux (une ligne seulement s'il s'est passé quelque chose). */
export function tickSummary(r: TickReport): string | null {
  const parts = Object.entries(r)
    .filter(([k, v]) => k !== "locked" && typeof v === "number" && v > 0)
    .map(([k, v]) => `${k}=${v}`);
  return parts.length ? parts.join(" ") : null;
}

export async function auditSchedulerError(err: Error): Promise<void> {
  logger.warn({ err: err.message }, "scheduler : tick en échec (nouvel essai au prochain tick)");
  await audit({ actor: SYSTEM_SCHEDULER, action: "scheduler.error", data: { message: err.message.slice(0, 500) } }).catch(() => {});
}

export type { SessionRow };
