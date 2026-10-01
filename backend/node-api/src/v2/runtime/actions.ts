// Journal des actions d'une tâche (LOT 8, audit §9.8–9.9) : une action = une étape d'une
// tentative, clé d'idempotence (task_id, attempt, step_index). Les états avancent dans un seul
// sens — planned → attempted → executed → verified — ou se terminent (failed, skipped,
// simulated) ; toute régression est refusée (409). C'est sur ces états que la reprise après
// crash décide quoi rejouer.
import type { Queryable } from "../../db.js";
import { TOOL_BY_TYPE } from "../../lib/agentSteps.js";
import { maskTypedText } from "../../lib/redact.js";
import { redactSecrets } from "../security/redactSecrets.js";

export const ACTION_STATUSES = ["planned", "attempted", "executed", "verified", "failed", "skipped", "simulated"] as const;
export type ActionStatus = (typeof ACTION_STATUSES)[number];
const RANK: Record<ActionStatus, number> = { planned: 0, attempted: 1, executed: 2, verified: 3, failed: 9, skipped: 9, simulated: 9 };
const TERMINAL: readonly ActionStatus[] = ["verified", "failed", "skipped", "simulated"];

export function isActionStatus(v: unknown): v is ActionStatus {
  return typeof v === "string" && (ACTION_STATUSES as readonly string[]).includes(v);
}

/** Vrai si `to` peut succéder à `from` (identique = idempotent, accepté). */
export function canAdvance(from: ActionStatus | null, to: ActionStatus): boolean {
  if (from === null || from === to) return true;
  if (TERMINAL.includes(from)) return false;
  return RANK[to] > RANK[from];
}

export interface ActionInput {
  taskId: string;
  userId: string;
  attempt: number;
  stepIndex: number;
  tool: string;
  params?: Record<string, unknown>;
  status: ActionStatus;
  evidence?: unknown[];
  error?: string | null;
  securityLevel?: string;
  simulated?: boolean;
}

export type ActionResult = { ok: true; id: string; status: ActionStatus; previous: ActionStatus | null } | { ok: false; status: 409; error: string };

/** Insère ou fait avancer une action (CAS sous FOR UPDATE). */
export async function upsertAction(q: Queryable, input: ActionInput): Promise<ActionResult> {
  const existing = await q.query("SELECT id, status FROM soulbah.actions WHERE task_id = $1 AND attempt = $2 AND step_index = $3 FOR UPDATE", [
    input.taskId,
    input.attempt,
    input.stepIndex,
  ]);
  const level = input.securityLevel ?? TOOL_BY_TYPE.get(input.tool)?.security_level ?? "L1";
  const evidence = JSON.stringify(redactSecrets(input.evidence ?? []));
  const simulated = input.simulated === true || input.status === "simulated";
  const confidence = Array.isArray(input.evidence) && input.evidence.length ? bestConfidence(input.evidence) : null;
  if (existing.rows.length === 0) {
    const { rows } = await q.query(
      `INSERT INTO soulbah.actions (task_id, user_id, attempt, step_index, tool, params, security_level, status, evidence, evidence_confidence, simulated, error, started_at, finished_at)
       VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9::jsonb, $10, $11, $12,
               CASE WHEN $8 IN ('attempted', 'executed', 'verified', 'failed') THEN now() END,
               CASE WHEN $8 IN ('verified', 'failed', 'skipped', 'simulated') THEN now() END)
       RETURNING id`,
      // Paramètres : texte saisi masqué (LOT 1) puis secrets rédigés (LOT 6) — jamais en clair en base.
      [input.taskId, input.userId, input.attempt, input.stepIndex, input.tool, JSON.stringify(redactSecrets(maskTypedText(input.params ?? {}))), level, input.status, evidence, confidence, simulated, input.error ?? null],
    );
    return { ok: true, id: rows[0].id as string, status: input.status, previous: null };
  }
  const prev = existing.rows[0].status as ActionStatus;
  if (!canAdvance(prev, input.status)) {
    return { ok: false, status: 409, error: `action ${input.stepIndex} : passage ${prev} → ${input.status} refusé (états monotones)` };
  }
  await q.query(
    `UPDATE soulbah.actions
        SET status = $2,
            evidence = CASE WHEN $3::jsonb = '[]'::jsonb THEN evidence ELSE evidence || $3::jsonb END,
            evidence_confidence = coalesce($4, evidence_confidence),
            error = coalesce($5, error),
            simulated = simulated OR $6,
            started_at = coalesce(started_at, CASE WHEN $2 IN ('attempted', 'executed', 'verified', 'failed') THEN now() END),
            finished_at = CASE WHEN $2 IN ('verified', 'failed', 'skipped', 'simulated') THEN now() ELSE finished_at END,
            updated_at = now()
      WHERE id = $1`,
    [existing.rows[0].id, input.status, evidence, confidence, input.error ?? null, simulated],
  );
  return { ok: true, id: existing.rows[0].id as string, status: input.status, previous: prev };
}

const CONF_RANK: Record<string, number> = { high: 3, medium: 2, low: 1, none: 0 };
function bestConfidence(evidence: unknown[]): string | null {
  let best: string | null = null;
  for (const e of evidence) {
    const c = e && typeof e === "object" ? (e as { confidence?: unknown }).confidence : undefined;
    if (typeof c === "string" && c in CONF_RANK && (best === null || CONF_RANK[c] > CONF_RANK[best])) best = c;
  }
  return best;
}

export interface ActionView {
  step_index: number;
  tool: string;
  status: ActionStatus;
  idempotent: boolean;
  attempt: number;
  evidence_confidence: string | null;
  error: string | null;
  updated_at: string | Date;
}

export async function listActions(q: Queryable, taskId: string, attempt?: number): Promise<ActionView[]> {
  const values: unknown[] = [taskId];
  let where = "task_id = $1";
  if (attempt !== undefined) {
    values.push(attempt);
    where += " AND attempt = $2";
  }
  const { rows } = await q.query(`SELECT attempt, step_index, tool, status, evidence_confidence, error, updated_at FROM soulbah.actions WHERE ${where} ORDER BY attempt, step_index`, values);
  return rows.map((r) => ({ ...(r as Omit<ActionView, "idempotent">), idempotent: TOOL_BY_TYPE.get((r as { tool: string }).tool)?.idempotent ?? false }));
}

/**
 * Décision de reprise (§9.9) pour une action : verified → skip ; executed → verify (seule la
 * vérification est rejouée) ; attempted → replay si l'outil est idempotent, sinon ask (un humain
 * tranche) ; planned ou absente → run ; failed/skipped/simulated → skip.
 */
export function resumeDecision(a: Pick<ActionView, "status" | "idempotent">): "skip" | "verify" | "replay" | "ask" | "run" {
  switch (a.status) {
    case "verified":
    case "failed":
    case "skipped":
    case "simulated":
      return "skip";
    case "executed":
      return "verify";
    case "attempted":
      return a.idempotent ? "replay" : "ask";
    case "planned":
      return "run";
  }
}
