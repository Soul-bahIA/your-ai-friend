// Relecteur QA exécuté par le plan de contrôle (LOT 10) : les tâches de rôle `qa_reviewer`
// (créées par un message REVIEW_REQUEST, dépendant de la tâche relue) ne vont jamais à un
// runtime — P1 les exécute : il lit la tâche relue, sa dernière évaluation et ses preuves,
// applique éventuellement une grille (llm_rubric, confiance faible), puis émet REVIEW_RESULT
// et TASK_RESULT (→ VALIDATING → COMPLETED). Tout dans UNE transaction par tâche.
import { withTransaction } from "../../db.js";
import { isPlainObject } from "../../lib/sanitize.js";
import { logger } from "../../lib/logger.js";
import { postMessage } from "../bus/messages.js";
import { TASK_COLS, getTask, transitionTask, type TaskRow } from "../tasks/repo.js";
import { loadActions, type RubricJudge } from "./engine.js";

/** Rôles exécutés par P1 lui-même (jamais attribués à un runtime). */
export const P1_ROLES: readonly string[] = ["qa_reviewer"];
export const SYSTEM_REVIEWER = "p1:qa_reviewer";
const REVIEW_LEASE_MS = 5 * 60 * 1000;

export interface ReviewReport {
  reviewed: number;
  errors: number;
}

export async function runReviews(opts: { limit?: number; judge?: RubricJudge; now?: Date } = {}): Promise<ReviewReport> {
  const limit = Math.max(1, Math.min(20, opts.limit ?? 5));
  const report: ReviewReport = { reviewed: 0, errors: 0 };
  const seen: string[] = [];
  for (let i = 0; i < limit; i++) {
    let picked: string | null = null;
    try {
      const outcome = await withTransaction(async (client) => {
        const now = opts.now ?? new Date();
        const { rows } = await client.query(
          `SELECT ${TASK_COLS.split(",").map((c) => `t.${c.trim()}`).join(", ")}
             FROM soulbah.tasks t JOIN soulbah.sessions s ON s.id = t.session_id
            WHERE t.status = 'READY' AND t.role = ANY($1::text[]) AND s.status = 'RUNNING' AND NOT (t.id = ANY($2::uuid[]))
            ORDER BY t.priority, t.created_at FOR UPDATE OF t SKIP LOCKED LIMIT 1`,
          [P1_ROLES, seen],
        );
        if (rows.length === 0) return "empty" as const;
        const ready = rows[0] as TaskRow;
        picked = ready.id;
        const running = await transitionTask(client, {
          task: ready,
          to: "RUNNING",
          set: { attempt: ready.attempt + 1, lease_owner: SYSTEM_REVIEWER, lease_expires_at: new Date(now.getTime() + REVIEW_LEASE_MS), started_at: ready.started_at ?? now },
          actor: SYSTEM_REVIEWER,
          data: { executed_by: "p1" },
        });
        if (!running) return "skip" as const;

        const spec = isPlainObject(running.spec) ? running.spec : {};
        const reviewOf = typeof spec.review_of === "string" ? spec.review_of : null;
        const reviewed = reviewOf ? await getTask(client, reviewOf, running.user_id) : null;
        const reasons: string[] = [];
        let approved = false;
        let verdict: string | null = null;
        if (!reviewed) {
          reasons.push("tâche relue introuvable");
        } else {
          const ev = await client.query(
            "SELECT verdict, confidence, results FROM soulbah.evaluations WHERE task_id = $1 ORDER BY attempt DESC LIMIT 1",
            [reviewed.id],
          );
          verdict = (ev.rows[0]?.verdict as string | undefined) ?? null;
          approved = reviewed.status === "COMPLETED" && (verdict === "success" || verdict === "partial");
          reasons.push(`tâche relue : ${reviewed.status}, évaluation ${verdict ?? "absente"} (confiance ${ev.rows[0]?.confidence ?? "—"})`);
          const request = isPlainObject(spec.request) ? spec.request : {};
          if (approved && typeof request.rubric === "string" && request.rubric.trim()) {
            if (!opts.judge) {
              approved = false;
              reasons.push("grille de relecture demandée mais aucun juge de modèle disponible");
            } else {
              const actions = await loadActions(client, reviewed.id, reviewed.attempt);
              const out = await opts.judge({ rubric: request.rubric, task: reviewed, actions, result: isPlainObject(reviewed.result) ? reviewed.result : null });
              approved = out.passed === true;
              reasons.push(`grille (modèle, confiance faible) : ${String(out.reason).slice(0, 300)}`);
            }
          }
        }
        const rr = await postMessage(client, {
          task: running,
          type: "REVIEW_RESULT",
          payload: { review_of: reviewOf, approved, evaluation_verdict: verdict, reasons, summary: approved ? "relecture approuvée" : "relecture refusée" },
          actor: SYSTEM_REVIEWER,
          attempt: running.attempt,
          toRole: "planner",
        });
        if (!rr.ok) throw new Error(`REVIEW_RESULT refusé : ${rr.error}`);
        const res = await postMessage(client, {
          task: (await getTask(client, running.id)) ?? running,
          type: "TASK_RESULT",
          payload: { result: { ok: true, review_of: reviewOf, approved, reasons } },
          actor: SYSTEM_REVIEWER,
          attempt: running.attempt,
        });
        if (!res.ok) throw new Error(`TASK_RESULT refusé : ${res.error}`);
        return "done" as const;
      });
      if (outcome === "empty") break;
      if (outcome === "done") report.reviewed++;
    } catch (e) {
      report.errors++;
      logger.warn({ task: picked, err: (e as Error).message }, "relecture QA : échec (nouvel essai)");
    }
    if (picked) seen.push(picked);
  }
  return report;
}
