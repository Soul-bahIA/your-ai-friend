// Journal d'audit V2 (LOT 6) : écriture dans soulbah.audit_logs (ajout seul, chaîné par les
// triggers du LOT 4) et vérification de la chaîne. Les données passent par la rédaction des
// secrets. `audit()` s'exécute dans la transaction de l'appelant quand un client est fourni
// (le changement d'état et son audit réussissent ou échouent ensemble, audit §9.3).
import { pool, type Queryable } from "../db.js";
import { logger } from "../lib/logger.js";
import { redactSecrets } from "./security/redactSecrets.js";

export interface AuditEntry {
  userId?: string | null;
  sessionId?: string | null;
  taskId?: string | null;
  /** user:<uuid>, system:<composant>, runtime:<id>, agent:<rôle>… */
  actor: string;
  /** permission.requested, permission.approved, task.transition, memory.validated… */
  action: string;
  entity?: string | null;
  entityId?: string | null;
  data?: Record<string, unknown>;
}

export function userActor(userId: string): string {
  return `user:${userId}`;
}

export async function audit(entry: AuditEntry, q: Queryable = pool): Promise<{ seq: number; row_hash: string }> {
  const { rows } = await q.query(
    `INSERT INTO soulbah.audit_logs (user_id, session_id, task_id, actor, action, entity, entity_id, data)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb)
     RETURNING seq, row_hash`,
    [
      entry.userId ?? null,
      entry.sessionId ?? null,
      entry.taskId ?? null,
      entry.actor.slice(0, 200),
      entry.action,
      entry.entity ?? null,
      entry.entityId ?? null,
      JSON.stringify(redactSecrets(entry.data ?? {})),
    ],
  );
  return { seq: Number(rows[0].seq), row_hash: rows[0].row_hash as string };
}

/** Audit « au mieux » hors transaction : un échec est journalisé, jamais propagé. */
export async function auditBestEffort(entry: AuditEntry): Promise<void> {
  try {
    await audit(entry);
  } catch (e) {
    logger.warn({ action: entry.action, err: (e as Error).message }, "audit : écriture impossible");
  }
}

export interface ChainVerification {
  ok: boolean;
  checked: number;
  broken_at: number | null;
}

/** Recalcule toute la chaîne (fonction SQL soulbah.verify_audit_chain du LOT 4). */
export async function verifyChain(q: Queryable = pool): Promise<ChainVerification> {
  const { rows } = await q.query("SELECT ok, checked, broken_at FROM soulbah.verify_audit_chain()");
  const r = rows[0] as { ok: boolean; checked: string | number; broken_at: string | number | null };
  return { ok: r.ok === true, checked: Number(r.checked ?? 0), broken_at: r.broken_at === null || r.broken_at === undefined ? null : Number(r.broken_at) };
}

export interface AuditRow {
  seq: number;
  action: string;
  actor: string;
  entity: string | null;
  entity_id: string | null;
  session_id: string | null;
  task_id: string | null;
  data: Record<string, unknown>;
  created_at: string;
}

export async function listAudit(userId: string, opts: { sessionId?: string; limit?: number } = {}, q: Queryable = pool): Promise<AuditRow[]> {
  const limit = Math.max(1, Math.min(500, Math.trunc(opts.limit ?? 100)));
  const values: unknown[] = [userId];
  let where = "user_id = $1";
  if (opts.sessionId) {
    values.push(opts.sessionId);
    where += ` AND session_id = $${values.length}`;
  }
  const { rows } = await q.query(
    `SELECT seq, action, actor, entity, entity_id, session_id, task_id, data, created_at
       FROM soulbah.audit_logs WHERE ${where} ORDER BY seq DESC LIMIT ${limit}`,
    values,
  );
  return rows.map((r) => ({ ...(r as AuditRow), seq: Number((r as { seq: unknown }).seq) }));
}
