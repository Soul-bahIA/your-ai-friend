// Bus de messages structurés (LOT 7, audit §9.5) : 9 types, effets gérés par P1 dans la
// transaction du message. Les messages des workers arrivent par les routes runtime (clé agent,
// bail vérifié) ; ceux de l'utilisateur par les routes sessions (JWT).
//
//   TASK_REQUEST     patch de plan proposé (stocké ; plan_version + 1 au LOT 11)
//   TASK_RESULT      résultat attaché, tâche → VALIDATING (puis COMPLETED si aucun critère ; LOT 10 sinon)
//   QUESTION         tâche → WAITING jusqu'à la réponse de l'utilisateur
//   BLOCKER          tâche → BLOCKED, escalade à 24 h
//   EVIDENCE         preuve rattachée au résultat de la tâche
//   REVIEW_REQUEST   création d'une tâche qa_reviewer dépendant de la tâche courante
//   REVIEW_RESULT    stocké (débloque / refuse le merge au LOT 12)
//   ERROR            journal puis politique de retry (RETRYING / FAILED)
//   KNOWLEDGE_FOUND  proposition mise en file (jamais validée automatiquement)
import type { Queryable } from "../../db.js";
import { isPlainObject } from "../../lib/sanitize.js";
import { audit } from "../audit.js";
import { redactSecrets } from "../security/redactSecrets.js";
import { evaluateAndApply } from "../evaluation/engine.js";
import { getTask, transitionTask, type TaskRow } from "../tasks/repo.js";
import { afterFailure, DEFAULT_ESCALATION_MS, retryBackoffMs, type FailureReason } from "../tasks/stateMachine.js";

export const MESSAGE_TYPES = ["TASK_REQUEST", "TASK_RESULT", "QUESTION", "BLOCKER", "EVIDENCE", "REVIEW_REQUEST", "REVIEW_RESULT", "ERROR", "KNOWLEDGE_FOUND"] as const;
export type MessageType = (typeof MESSAGE_TYPES)[number];
export const MAX_MESSAGE_PAYLOAD_BYTES = 64 * 1024;

export function isMessageType(v: unknown): v is MessageType {
  return typeof v === "string" && (MESSAGE_TYPES as readonly string[]).includes(v);
}

export interface PostMessageInput {
  task: TaskRow;
  type: MessageType;
  payload: Record<string, unknown>;
  actor: string;
  /** Tentative annoncée par l'émetteur : un message d'une tentative périmée est refusé. */
  attempt?: number;
  fromAgentId?: string | null;
  toRole?: string | null;
  correlationId?: string | null;
  replyTo?: string | null;
  requiresAck?: boolean;
  now?: Date;
}

export type PostMessageResult =
  | { ok: true; message_id: string; task: TaskRow; effect: string }
  | { ok: false; status: 400 | 409 | 410; error: string };

/** Insère le message puis applique son effet d'état (même transaction). */
export async function postMessage(q: Queryable, input: PostMessageInput): Promise<PostMessageResult> {
  const now = input.now ?? new Date();
  if (!isPlainObject(input.payload)) return { ok: false, status: 400, error: "payload : objet attendu" };
  if (Buffer.byteLength(JSON.stringify(input.payload), "utf8") > MAX_MESSAGE_PAYLOAD_BYTES) return { ok: false, status: 400, error: "payload trop volumineux (64 Ko max)" };
  const task = input.task;
  if (input.attempt !== undefined && input.attempt !== task.attempt) {
    return { ok: false, status: 409, error: `tentative périmée (attempt ${input.attempt}, courante ${task.attempt})` };
  }
  const payload = redactSecrets(input.payload);
  const { rows } = await q.query(
    `INSERT INTO soulbah.messages (session_id, task_id, from_agent_id, to_role, type, correlation_id, reply_to, payload, requires_ack)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9) RETURNING id`,
    [task.session_id, task.id, input.fromAgentId ?? null, input.toRole ?? null, input.type, input.correlationId ?? null, input.replyTo ?? null, JSON.stringify(payload), input.requiresAck === true],
  );
  const messageId = rows[0].id as string;
  const base = { userId: task.user_id, sessionId: task.session_id, taskId: task.id, actor: input.actor, entity: "message", entityId: messageId };

  switch (input.type) {
    case "TASK_RESULT": {
      if (task.status !== "RUNNING" && task.status !== "WAITING") return { ok: false, status: 409, error: `résultat refusé : tâche ${task.status}` };
      // Simulé si la tâche, le message OU le résultat lui-même le déclare (un dry-run ne peut
      // jamais être « blanchi » en COMPLETED par un drapeau de message à false — LOT 10).
      const simulated =
        task.simulated || payload.simulated === true || (isPlainObject(payload.result) && payload.result.simulated === true);
      const result = { ...(isPlainObject(payload.result) ? payload.result : { value: payload.result ?? null }), simulated, attempt: task.attempt, message_id: messageId };
      const validating = await transitionTask(q, { task, to: "VALIDATING", set: { result, simulated }, actor: input.actor, data: { message_id: messageId } });
      if (!validating) return { ok: false, status: 409, error: "tâche modifiée concurremment" };
      const final = await validate(q, validating, input.actor, now);
      await audit({ ...base, action: "message.task_result", data: { effect: final.status, simulated } }, q);
      return { ok: true, message_id: messageId, task: final, effect: `VALIDATING → ${final.status}` };
    }
    case "QUESTION": {
      if (task.status !== "RUNNING") return { ok: false, status: 409, error: `question refusée : tâche ${task.status}` };
      const question = typeof payload.question === "string" ? payload.question.slice(0, 2000) : "question sans texte";
      const t = await transitionTask(q, { task, to: "WAITING", set: { waiting_reason: question }, actor: input.actor, data: { message_id: messageId, question } });
      if (!t) return { ok: false, status: 409, error: "tâche modifiée concurremment" };
      await audit({ ...base, action: "message.question", data: { question } }, q);
      return { ok: true, message_id: messageId, task: t, effect: "RUNNING → WAITING" };
    }
    case "BLOCKER": {
      if (task.status !== "RUNNING" && task.status !== "WAITING") return { ok: false, status: 409, error: `blocage refusé : tâche ${task.status}` };
      const reason = typeof payload.reason === "string" ? payload.reason.slice(0, 2000) : "blocage sans motif";
      const t = await transitionTask(q, { task, to: "BLOCKED", set: { blocked_reason: reason, escalate_at: new Date(now.getTime() + DEFAULT_ESCALATION_MS) }, actor: input.actor, data: { message_id: messageId, reason } });
      if (!t) return { ok: false, status: 409, error: "tâche modifiée concurremment" };
      await audit({ ...base, action: "message.blocker", data: { reason } }, q);
      return { ok: true, message_id: messageId, task: t, effect: `${task.status} → BLOCKED` };
    }
    case "EVIDENCE": {
      const { rows: upd } = await q.query(
        `UPDATE soulbah.tasks SET result = coalesce(result, '{}'::jsonb) || jsonb_build_object('evidence', coalesce(result -> 'evidence', '[]'::jsonb) || $2::jsonb), updated_at = now()
          WHERE id = $1 RETURNING id`,
        [task.id, JSON.stringify([{ ...payload, message_id: messageId, attempt: task.attempt }])],
      );
      await audit({ ...base, action: "message.evidence", data: { kind: payload.kind ?? null, confidence: payload.confidence ?? null } }, q);
      const t = (await getTask(q, task.id)) ?? task;
      return { ok: true, message_id: messageId, task: t, effect: upd.length ? "preuve rattachée" : "aucune tâche" };
    }
    case "REVIEW_REQUEST": {
      const { rows: ins } = await q.query(
        `INSERT INTO soulbah.tasks (session_id, user_id, parent_task_id, node_key, title, role, security_level, spec, acceptance_criteria, priority, max_retries, plan_version, simulated)
         VALUES ($1, $2, $3, $4, $5, 'qa_reviewer', 'L0', $6::jsonb, '[]'::jsonb, $7, 1, $8, $9) RETURNING id`,
        [
          task.session_id,
          task.user_id,
          task.id,
          task.node_key ? `${task.node_key}.review${task.attempt}` : null,
          `Revue : ${task.title}`.slice(0, 500),
          JSON.stringify({ review_of: task.id, attempt: task.attempt, request: payload }),
          Math.max(1, task.priority - 1),
          task.plan_version,
          task.simulated,
        ],
      );
      await q.query("INSERT INTO soulbah.task_dependencies (task_id, depends_on_task_id, kind) VALUES ($1, $2, 'hard')", [ins[0].id, task.id]);
      await audit({ ...base, action: "message.review_request", data: { review_task_id: ins[0].id } }, q);
      return { ok: true, message_id: messageId, task, effect: `tâche qa_reviewer ${ins[0].id as string} créée` };
    }
    case "ERROR": {
      if (task.status !== "RUNNING" && task.status !== "WAITING") return { ok: false, status: 409, error: `erreur refusée : tâche ${task.status}` };
      const reason: FailureReason = payload.kind === "policy_refused" ? "policy_refused" : payload.kind === "timeout" ? "timeout" : payload.kind === "crash" ? "crash" : "error";
      const to = afterFailure(task.retry_count, task.max_retries, reason);
      const message = typeof payload.message === "string" ? payload.message.slice(0, 2000) : reason;
      const set = to === "RETRYING" ? { retry_count: task.retry_count + 1, next_attempt_at: new Date(now.getTime() + retryBackoffMs(task.retry_count)), error: message, lease_owner: null } : { error: message, lease_owner: null };
      const t = await transitionTask(q, { task, to, set, actor: input.actor, data: { message_id: messageId, reason, message } });
      if (!t) return { ok: false, status: 409, error: "tâche modifiée concurremment" };
      await audit({ ...base, action: "message.error", data: { reason, to } }, q);
      return { ok: true, message_id: messageId, task: t, effect: `${task.status} → ${to}` };
    }
    case "REVIEW_RESULT":
    case "TASK_REQUEST":
    case "KNOWLEDGE_FOUND": {
      const action = input.type === "REVIEW_RESULT" ? "message.review_result" : input.type === "TASK_REQUEST" ? "message.task_request" : "message.knowledge_found";
      await audit({ ...base, action, data: { summary: typeof payload.summary === "string" ? payload.summary.slice(0, 300) : null } }, q);
      return { ok: true, message_id: messageId, task, effect: "stocké" };
    }
  }
}

/**
 * Validation (LOT 10) : le moteur d'évaluation conclut immédiatement quand il n'a besoin que de
 * règles (critères DSL sur les preuves) ; avec un critère llm_rubric, la tâche reste en
 * VALIDATING et `runEvaluations` (boucle du scheduler) la reprendra — VALIDATING est durable.
 * Un run simulé n'est JAMAIS COMPLETED ; un plan non joué non plus (§9.8).
 */
export async function validate(q: Queryable, task: TaskRow, actor: string, now: Date): Promise<TaskRow> {
  const out = await evaluateAndApply(q, task, actor, undefined, now);
  return out?.task ?? task;
}

/** Réponse de l'utilisateur à une QUESTION : WAITING → RUNNING (même bail), réponse livrée au keepalive. */
export async function answerQuestion(q: Queryable, task: TaskRow, answer: string, userId: string): Promise<TaskRow | null> {
  if (task.status !== "WAITING") return null;
  const spec = { ...task.spec, answers: [...(Array.isArray((task.spec as { answers?: unknown[] }).answers) ? (task.spec as { answers: unknown[] }).answers : []), { question: task.waiting_reason, answer: answer.slice(0, 4000), at: new Date().toISOString(), attempt: task.attempt }] };
  return transitionTask(q, { task, to: "RUNNING", set: { waiting_reason: null, spec }, actor: `user:${userId}`, data: { answered: true } });
}
