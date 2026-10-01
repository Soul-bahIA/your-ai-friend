// Moteur d'évaluation V2 (LOT 10, audit §9.8, §9.9 « VALIDATING durable ») :
//  - `evaluateAndApply` : dans la transaction de l'appelant (ligne de la tâche verrouillée),
//    évalue la tentative (critères + règles), écrit UNE ligne soulbah.evaluations (UNIQUE
//    task_id, attempt) et applique le verdict : COMPLETED, RETRYING (seulement si toutes les
//    étapes exécutées sont idempotentes — rejouer ne double aucun effet) ou FAILED ;
//  - `runEvaluations` : reprend les tâches restées en VALIDATING (critère llm_rubric, ou
//    évaluation interrompue par un arrêt de node) — `FOR UPDATE SKIP LOCKED` : jamais deux
//    évaluateurs sur la même tâche ; un crash avant COMMIT annule tout, la tâche reste en
//    VALIDATING et sera évaluée une seule fois au passage suivant.
import { withTransaction, type Queryable } from "../../db.js";
import { TOOL_BY_TYPE } from "../../lib/agentSteps.js";
import { isPlainObject } from "../../lib/sanitize.js";
import { logger } from "../../lib/logger.js";
import { audit } from "../audit.js";
import type { Evidence } from "../evidence.js";
import { redactSecrets } from "../security/redactSecrets.js";
import { TASK_COLS, transitionTask, type TaskRow } from "../tasks/repo.js";
import { afterFailure, retryBackoffMs } from "../tasks/stateMachine.js";
import { assess, parseCriteria, type ActionEvidence, type Assessment, type Criterion, type CriterionResult } from "./criteria.js";

export const SYSTEM_EVALUATOR = "system:evaluator";
/** Au-delà, une tâche bloquée en VALIDATING (jugement de modèle impossible) est conclue en échec. */
export const EVALUATION_TIMEOUT_MS = 60 * 60 * 1000;

export interface RubricInput {
  rubric: string;
  task: Pick<TaskRow, "id" | "title" | "role" | "security_level">;
  actions: ActionEvidence[];
  result: Record<string, unknown> | null;
}
/** Jugement d'un critère llm_rubric (python-ia, ou faux juge dans les tests). */
export type RubricJudge = (input: RubricInput) => Promise<{ passed: boolean; reason: string }>;

interface ActionRow extends ActionEvidence {
  id: string;
}

export async function loadActions(q: Queryable, taskId: string, attempt: number): Promise<ActionRow[]> {
  const { rows } = await q.query(
    "SELECT id, step_index, tool, status, params, evidence FROM soulbah.actions WHERE task_id = $1 AND attempt = $2 ORDER BY step_index",
    [taskId, attempt],
  );
  return rows.map((r) => ({
    id: r.id as string,
    step_index: Number(r.step_index),
    tool: r.tool as string,
    status: r.status as string,
    params: isPlainObject(r.params) ? r.params : {},
    evidence: Array.isArray(r.evidence) ? (r.evidence as Evidence[]) : [],
  }));
}

export function criteriaOf(task: Pick<TaskRow, "acceptance_criteria">): { ok: true; value: Criterion[] } | { ok: false; error: string } {
  return parseCriteria(task.acceptance_criteria ?? []);
}

export function needsJudge(criteria: readonly Criterion[]): boolean {
  return criteria.some((c) => c.type === "llm_rubric");
}

/** Toutes les étapes exécutées sont-elles rejouables sans double effet ? */
export function allIdempotent(actions: readonly ActionEvidence[]): boolean {
  const done = actions.filter((a) => a.status === "executed" || a.status === "verified" || a.status === "attempted");
  return done.every((a) => TOOL_BY_TYPE.get(a.tool)?.idempotent === true);
}

/** Juge les critères llm_rubric (index → résultat, confiance « low »). */
export async function judgeRubrics(
  task: TaskRow,
  criteria: readonly Criterion[],
  actions: ActionEvidence[],
  judge: RubricJudge,
): Promise<Map<number, CriterionResult>> {
  const judged = new Map<number, CriterionResult>();
  for (const [i, c] of criteria.entries()) {
    if (c.type !== "llm_rubric") continue;
    const out = await judge({
      rubric: String(c.params.rubric),
      task: { id: task.id, title: task.title, role: task.role, security_level: task.security_level },
      actions: redactSecrets(actions),
      result: task.result ? redactSecrets(task.result) : null,
    });
    const passed = out.passed === true && c.min_confidence !== "medium" && c.min_confidence !== "high";
    judged.set(i, {
      type: c.type,
      required: c.required,
      min_confidence: c.min_confidence,
      passed,
      confidence: "low",
      reason: out.passed === true && !passed ? `${out.reason} — un jugement de modèle (low) ne suffit pas pour ${c.min_confidence}` : String(out.reason || "").slice(0, 500),
      steps: [],
    });
  }
  return judged;
}

export interface EvaluationOutcome {
  task: TaskRow;
  verdict: Assessment["verdict"];
  action_taken: string;
  evaluation_id: string;
}

/**
 * Évalue la tentative courante d'une tâche VALIDATING (ligne verrouillée par l'appelant) et
 * applique le verdict. Retourne null si un critère llm_rubric attend un jugement (`judged`
 * absent) ou si cette tentative a déjà été évaluée.
 */
export async function evaluateAndApply(
  q: Queryable,
  task: TaskRow,
  actor: string,
  judged?: Map<number, CriterionResult>,
  now: Date = new Date(),
): Promise<EvaluationOutcome | null> {
  if (task.status !== "VALIDATING") return null;
  const parsed = criteriaOf(task);
  const criteria = parsed.ok ? parsed.value : [];
  const actions = await loadActions(q, task.id, task.attempt);
  if (parsed.ok && needsJudge(criteria) && !judged && !task.simulated) return null;

  const result = isPlainObject(task.result) ? task.result : {};
  const spec = isPlainObject(task.spec) ? task.spec : {};
  const assessment: Assessment = parsed.ok
    ? assess(
        criteria,
        actions,
        {
          simulated: task.simulated || result.simulated === true,
          hasSteps: Array.isArray(spec.steps) && spec.steps.length > 0,
          resultOk: typeof result.ok === "boolean" ? result.ok : null,
          securityLevel: task.security_level,
        },
        judged,
      )
    : { verdict: "failure", confidence: "none", results: [], reasons: [`critères invalides : ${parsed.error}`] };

  let to: "COMPLETED" | "RETRYING" | "FAILED";
  let actionTaken: string;
  const set: Record<string, unknown> = { lease_owner: null };
  if (assessment.verdict === "success" || assessment.verdict === "partial") {
    to = "COMPLETED";
    actionTaken = "completed";
  } else if (assessment.verdict === "not_evaluable") {
    to = "FAILED";
    actionTaken = "failed_not_evaluable";
    set.error = assessment.reasons.join(" ; ").slice(0, 2000);
  } else if (allIdempotent(actions) && afterFailure(task.retry_count, task.max_retries, "criteria_failed") === "RETRYING") {
    to = "RETRYING";
    actionTaken = "retry_scheduled";
    set.retry_count = task.retry_count + 1;
    set.next_attempt_at = new Date(now.getTime() + retryBackoffMs(task.retry_count));
    set.error = assessment.reasons.join(" ; ").slice(0, 2000);
  } else {
    to = "FAILED";
    actionTaken = allIdempotent(actions) ? "failed_retries_exhausted" : "failed_needs_human";
    set.error = assessment.reasons.join(" ; ").slice(0, 2000);
  }

  const used = new Set(assessment.results.flatMap((r) => r.steps));
  const evidenceIds = actions.filter((a) => used.has(a.step_index)).map((a) => a.id);
  const ins = await q.query(
    `INSERT INTO soulbah.evaluations (task_id, user_id, attempt, criteria, results, verdict, confidence, evidence_ids, action_taken, evaluator)
     VALUES ($1, $2, $3, $4::jsonb, $5::jsonb, $6, $7, $8::jsonb, $9, $10)
     ON CONFLICT (task_id, attempt) DO NOTHING RETURNING id`,
    [
      task.id,
      task.user_id,
      task.attempt,
      JSON.stringify(criteria),
      JSON.stringify(assessment.results),
      assessment.verdict,
      assessment.confidence,
      JSON.stringify(evidenceIds),
      actionTaken,
      judged && judged.size ? "llm" : "rules",
    ],
  );
  if (ins.rows.length !== 1) return null; // déjà évaluée (ne devrait pas arriver sous verrou)
  const evaluationId = ins.rows[0].id as string;
  const updated = await transitionTask(q, {
    task,
    to,
    set,
    actor,
    data: { verdict: assessment.verdict, evaluation_id: evaluationId, action_taken: actionTaken, reasons: assessment.reasons.slice(0, 5) },
  });
  if (!updated) throw new Error(`évaluation : la tâche ${task.id} a quitté VALIDATING pendant l'évaluation`);
  await audit(
    {
      userId: task.user_id,
      sessionId: task.session_id,
      taskId: task.id,
      actor,
      action: "evaluation.recorded",
      entity: "evaluation",
      entityId: evaluationId,
      data: { attempt: task.attempt, verdict: assessment.verdict, confidence: assessment.confidence, action_taken: actionTaken },
    },
    q,
  );
  return { task: updated, verdict: assessment.verdict, action_taken: actionTaken, evaluation_id: evaluationId };
}

/** Critères llm_rubric conclus en échec (juge absent ou en panne au-delà du délai). */
export function failedRubrics(criteria: readonly Criterion[], reason: string): Map<number, CriterionResult> {
  const out = new Map<number, CriterionResult>();
  criteria.forEach((c, idx) => {
    if (c.type === "llm_rubric") {
      out.set(idx, { type: c.type, required: c.required, min_confidence: c.min_confidence, passed: false, confidence: "none", reason, steps: [] });
    }
  });
  return out;
}

export interface RunReport {
  evaluated: number;
  waiting: number;
  errors: number;
}

/**
 * Reprend les tâches en VALIDATING (une transaction et un verrou de ligne par tâche).
 * Un jugement de modèle en échec annule la transaction : la tâche reste en VALIDATING et sera
 * reprise — sauf au-delà d'EVALUATION_TIMEOUT_MS, où elle est conclue en échec.
 */
export async function runEvaluations(opts: { limit?: number; judge?: RubricJudge; now?: Date } = {}): Promise<RunReport> {
  const limit = Math.max(1, Math.min(50, opts.limit ?? 10));
  const report: RunReport = { evaluated: 0, waiting: 0, errors: 0 };
  const seen: string[] = [];
  for (let i = 0; i < limit; i++) {
    let picked: string | null = null;
    try {
      const outcome = await withTransaction(async (client) => {
        const { rows } = await client.query(
          `SELECT ${TASK_COLS} FROM soulbah.tasks WHERE status = 'VALIDATING' AND NOT (id = ANY($1::uuid[]))
            ORDER BY updated_at FOR UPDATE SKIP LOCKED LIMIT 1`,
          [seen],
        );
        if (rows.length === 0) return "empty" as const;
        const task = rows[0] as TaskRow;
        picked = task.id;
        const parsed = criteriaOf(task);
        let judged: Map<number, CriterionResult> | undefined;
        if (parsed.ok && needsJudge(parsed.value) && !task.simulated) {
          const actions = await loadActions(client, task.id, task.attempt);
          const now = opts.now ?? new Date();
          if (!opts.judge) {
            if (now.getTime() - new Date(task.updated_at).getTime() < EVALUATION_TIMEOUT_MS) return "waiting" as const;
            judged = failedRubrics(parsed.value, "aucun juge de modèle disponible");
          } else {
            try {
              judged = await judgeRubrics(task, parsed.value, actions, opts.judge);
            } catch (e) {
              if (now.getTime() - new Date(task.updated_at).getTime() < EVALUATION_TIMEOUT_MS) throw e;
              judged = failedRubrics(parsed.value, `jugement impossible : ${(e as Error).message.slice(0, 200)}`);
            }
          }
        }
        const out = await evaluateAndApply(client, task, SYSTEM_EVALUATOR, judged, opts.now);
        return out ? ("done" as const) : ("waiting" as const);
      });
      if (outcome === "empty") break;
      if (outcome === "done") report.evaluated++;
      else report.waiting++;
    } catch (e) {
      report.errors++;
      logger.warn({ task: picked, err: (e as Error).message }, "évaluation : échec (tâche laissée en VALIDATING, nouvel essai)");
    }
    if (picked) seen.push(picked);
  }
  return report;
}
