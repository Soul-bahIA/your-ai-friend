import type { FastifyInstance, FastifyReply } from "fastify";
import { pool } from "../db.js";
import { config } from "../config.js";
import { requireUser, requireAgentKey } from "../auth.js";
import { maybeEvaluateGoalTask } from "./agentGoal.js";
import { resolveTargetKey, setAgentAllowedDirs } from "../services/agentKeys.js";
import { findPathOutsideAllowed, requiresConfirmation, validateTaskCreateBody } from "../lib/agentSteps.js";
import {
  buildAgentTaskUpdate,
  buildApprove,
  buildCancel,
  buildPollQuery,
  buildTaskTouch,
  isAgentTaskStatus,
  parseAttempt,
  TERMINAL_STATUSES,
} from "../lib/agentTaskSql.js";
import { isUuid, stripImageB64, isPlainObject } from "../lib/sanitize.js";
import { runInBackground } from "../services/backgroundJobs.js";
import {
  extractEventImage,
  extractResultScreenshots,
  forgetScreenshot,
  getScreenshot,
  rememberScreenshot,
} from "../services/screenshots.js";

// Les routes de l'agent reçoivent encore des captures d'écran base64 (retirées avant
// toute écriture en base) : corps plus gros admis.
const AGENT_BODY_LIMIT = 15 * 1024 * 1024;
const agentRateLimit = { max: config.rateLimitAgent, timeWindow: "1 minute" };
/** Données d'évènement (une fois la capture retirée) et rapport final : bornés. */
const MAX_EVENT_DATA_BYTES = 64 * 1024;
const MAX_RESULT_BYTES = 1024 * 1024;

// Colonnes renvoyées à l'UI (jamais SELECT *).
const LIST_COLS = `id, task_type, status, priority, payload, result, error_message, requeue_count, control,
  target_agent_key_id, claimed_by_key_id, started_at, completed_at, created_at, updated_at`;

/** Réponse pour une tâche supprimée / inexistante (contrat LOT 1 §3) : l'agent l'abandonne. */
function gone(reply: FastifyReply) {
  return reply.status(410).send({ error: "gone", control: "stop" });
}

/** Après un UPDATE gardé à 0 ligne : 410 si la tâche n'existe plus pour cet utilisateur, sinon 409. */
async function guardFailure(reply: FastifyReply, taskId: string, userId: string, attempt?: number) {
  const { rows } = await pool.query(
    "SELECT status, requeue_count FROM agent_tasks WHERE id = $1 AND user_id = $2",
    [taskId, userId],
  );
  if (rows.length === 0) return gone(reply);
  const { status, requeue_count } = rows[0] as { status: string; requeue_count: number };
  if (attempt !== undefined && attempt !== requeue_count) {
    return reply.status(409).send({
      error: `Tentative périmée (attempt ${attempt}, courante ${requeue_count}) — la tâche a été reprise`,
      status,
      requeue_count,
    });
  }
  return reply.status(409).send({ error: `Tâche dans l'état « ${status} » : transition refusée`, status, requeue_count });
}

function insertEventBestEffort(taskId: string, userId: string, type: string, message: string, data: object = {}) {
  pool
    .query(
      "INSERT INTO agent_events (task_id, user_id, type, message, data) VALUES ($1, $2, $3, $4, $5::jsonb)",
      [taskId, userId, type, message, JSON.stringify({ source: "agent", ...data })],
    )
    .catch(() => {});
}

// Port de l'edge function `agent-tasks`.
//  - announce / poll / update / event / control (GET) : worker local, x-agent-key
//  - create / list / control (POST) / cancel / approve / events / screenshot : app web, JWT

export async function agentTaskRoutes(app: FastifyInstance): Promise<void> {
  // --- Worker local : annonce de sa configuration (au démarrage) ---
  app.post(
    "/api/agent-tasks/announce",
    { preHandler: requireAgentKey, config: { rateLimit: agentRateLimit } },
    async (request, reply) => {
      const body = (request.body ?? {}) as { allowed_dirs?: unknown };
      const dirs = Array.isArray(body.allowed_dirs)
        ? body.allowed_dirs
            .filter((d): d is string => typeof d === "string" && d.length > 0 && d.length <= 1024)
            .slice(0, 50)
        : null;
      if (!dirs) return reply.status(400).send({ error: "allowed_dirs (liste) requis" });
      await setAgentAllowedDirs(request.agentKeyId!, dirs);
      return { success: true };
    },
  );

  // --- Worker local : poll des tâches en attente (inclut requeue_count = attempt) ---
  // Seulement les tâches ciblant CETTE clé (ou aucune), hors corrections en attente
  // d'approbation. La remise en file des tâches orphelines est faite par le reaper global.
  app.get(
    "/api/agent-tasks/poll",
    { preHandler: requireAgentKey, config: { rateLimit: agentRateLimit } },
    async (request) => {
      const q = buildPollQuery(request.agentUserId!, request.agentKeyId!);
      const { rows } = await pool.query(q.sql, q.values);
      return { tasks: rows };
    },
  );

  // --- Worker local : mise à jour du statut d'une tâche (claim / fin) ---
  app.post(
    "/api/agent-tasks/update",
    { preHandler: requireAgentKey, bodyLimit: AGENT_BODY_LIMIT, config: { rateLimit: agentRateLimit } },
    async (request, reply) => {
      const userId = request.agentUserId!;
      const body = (request.body ?? {}) as {
        task_id?: unknown;
        status?: unknown;
        result?: unknown;
        error_message?: unknown;
        attempt?: unknown;
      };
      if (!isUuid(body.task_id)) return reply.status(400).send({ error: "task_id (uuid) requis" });
      if (!isAgentTaskStatus(body.status)) {
        return reply.status(400).send({ error: "status invalide (pending|in_progress|completed|failed|cancelled)" });
      }
      const attempt = parseAttempt(body.attempt);
      if (attempt === null) return reply.status(400).send({ error: "attempt doit être un entier ≥ 0" });
      if (body.error_message !== undefined && body.error_message !== null && typeof body.error_message !== "string") {
        return reply.status(400).send({ error: "error_message doit être un texte" });
      }

      // Les captures du rapport final ne sont JAMAIS stockées : les dernières sont passées
      // en mémoire à l'évaluation, le résultat écrit en base en est débarrassé.
      const finalShots = body.status === "completed" || body.status === "failed" ? extractResultScreenshots(body.result) : [];
      const result = body.result === undefined ? undefined : stripImageB64(body.result);
      if (result !== undefined && Buffer.byteLength(JSON.stringify(result) ?? "", "utf8") > MAX_RESULT_BYTES) {
        return reply.status(400).send({ error: "result trop volumineux (1 Mo max hors captures)" });
      }

      // Claim (in_progress) : exige status='pending' (+ ciblage + pas d'approbation en attente).
      // Toute autre transition exige status='in_progress' (+ requeue_count = attempt si fourni,
      // + réclamée par cette clé). 'cancelled' est un final accepté (stop demandé).
      const q = buildAgentTaskUpdate({
        taskId: body.task_id,
        userId,
        status: body.status,
        result,
        errorMessage:
          typeof body.error_message === "string" ? body.error_message.slice(0, 4000) : (body.error_message as null | undefined),
        attempt,
        keyId: request.agentKeyId,
      });
      const { rows, rowCount } = await pool.query(q.sql, q.values);
      if (rowCount !== 1) {
        if (q.kind === "claim") {
          const exists = await pool.query("SELECT 1 FROM agent_tasks WHERE id = $1 AND user_id = $2", [body.task_id, userId]);
          if (exists.rowCount === 0) return gone(reply);
          return reply.status(409).send({ error: "Tâche déjà prise par un autre agent (ou plus en attente)" });
        }
        return guardFailure(reply, body.task_id, userId, attempt);
      }

      // Boucle Observer → Corriger : uniquement si CETTE requête a effectivement terminé la
      // tâche (rowCount=1) et jamais pour 'cancelled'. Tâche de fond suivie (erreurs journalisées).
      if (body.status === "completed" || body.status === "failed") {
        const taskId = body.task_id;
        void runInBackground("évaluation d'objectif", () =>
          maybeEvaluateGoalTask(taskId, userId, { screenshots: finalShots }),
        );
      }
      return { success: true, status: rows[0].status, requeue_count: rows[0].requeue_count };
    },
  );

  // --- Worker local : évènement d'exécution (timeline) / heartbeat ---
  app.post(
    "/api/agent-tasks/event",
    { preHandler: requireAgentKey, bodyLimit: AGENT_BODY_LIMIT, config: { rateLimit: agentRateLimit } },
    async (request, reply) => {
      const userId = request.agentUserId!;
      const body = (request.body ?? {}) as {
        task_id?: unknown;
        type?: unknown;
        message?: unknown;
        data?: unknown;
        attempt?: unknown;
      };
      if (!isUuid(body.task_id)) return reply.status(400).send({ error: "task_id (uuid) requis" });
      if (typeof body.type !== "string" || !/^[a-z][a-z0-9_]{0,63}$/.test(body.type)) {
        return reply.status(400).send({ error: "type requis" });
      }
      const attempt = parseAttempt(body.attempt);
      if (attempt === null) return reply.status(400).send({ error: "attempt doit être un entier ≥ 0" });
      if (body.data !== undefined && body.data !== null && !isPlainObject(body.data)) {
        return reply.status(400).send({ error: "data doit être un objet" });
      }

      // La tâche doit appartenir à l'utilisateur de la clé, être en cours et (si fourni)
      // à la même tentative. Ce même UPDATE sert de signe de vie.
      const touch = buildTaskTouch(body.task_id, userId, attempt, request.agentKeyId);
      const { rowCount } = await pool.query(touch.sql, touch.values);
      if (rowCount !== 1) return guardFailure(reply, body.task_id, userId, attempt);

      // Heartbeat : simple signe de vie, pas de ligne d'évènement (évite de remplir la table).
      if (body.type === "heartbeat") return { success: true };

      // Capture : gardée EN MÉMOIRE (GET /:id/screenshot), jamais insérée en base.
      const { data, image } = extractEventImage(body.data ?? {});
      if (image) rememberScreenshot(body.task_id, userId, image.b64, image.mime);
      const stored = { ...data, source: "agent" }; // un agent ne peut pas se faire passer pour une formation
      if (Buffer.byteLength(JSON.stringify(stored), "utf8") > MAX_EVENT_DATA_BYTES) {
        return reply.status(400).send({ error: "data trop volumineux (64 Ko max hors capture)" });
      }

      await pool.query(
        `INSERT INTO agent_events (task_id, user_id, type, message, data)
         VALUES ($1, $2, $3, $4, $5::jsonb)`,
        [
          body.task_id,
          userId,
          body.type,
          typeof body.message === "string" ? body.message.slice(0, 4000) : null,
          JSON.stringify(stored),
        ],
      );
      return { success: true };
    },
  );

  // --- Worker local : lire l'ordre de contrôle courant (none|pause|stop) ---
  app.get(
    "/api/agent-tasks/:id/control",
    { preHandler: requireAgentKey, config: { rateLimit: agentRateLimit } },
    async (request, reply) => {
      const userId = request.agentUserId!;
      const { id } = request.params as { id: string };
      if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
      const { rows } = await pool.query("SELECT control FROM agent_tasks WHERE id = $1 AND user_id = $2", [id, userId]);
      if (rows.length === 0) return gone(reply);
      return { control: rows[0].control ?? "none" };
    },
  );

  // --- App web : piloter l'exécution (pause | resume | stop) ---
  // Renvoyer la même valeur est un no-op (ne prolonge pas le bail, cf. T45).
  app.post("/api/agent-tasks/:id/control", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const { control } = (request.body ?? {}) as { control?: string };
    const value = control === "resume" ? "none" : control;
    if (!value || !["none", "pause", "stop"].includes(value)) {
      return reply.status(400).send({ error: "control requis (pause|resume|stop)" });
    }
    const { rows } = await pool.query(
      `UPDATE agent_tasks SET control = $1
        WHERE id = $2 AND user_id = $3 AND status IN ('pending', 'in_progress')
          AND control IS DISTINCT FROM $1
        RETURNING control`,
      [value, id, userId],
    );
    if (rows.length === 1) return { success: true, control: value };
    const cur = await pool.query("SELECT status, control FROM agent_tasks WHERE id = $1 AND user_id = $2", [id, userId]);
    if (cur.rows.length === 0) return reply.status(404).send({ error: "Tâche introuvable" });
    const { status, control: current } = cur.rows[0] as { status: string; control: string | null };
    if ((TERMINAL_STATUSES as readonly string[]).includes(status)) {
      return reply.status(409).send({ error: `Tâche déjà terminée (« ${status} »)`, status });
    }
    return { success: true, control: current ?? value, unchanged: true };
  });

  // --- App web : annuler une tâche (contrat LOT 1 §2) ---
  //  pending → 'cancelled' immédiatement ; in_progress → control 'stop' (l'agent termine
  //  l'étape courante puis envoie un final 'cancelled'). Rejeter une correction = annuler.
  app.post("/api/agent-tasks/:id/cancel", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const q = buildCancel(id, userId);
    const { rows } = await pool.query(q.sql, q.values);
    if (rows.length === 1) {
      // Réponse : statut APRÈS l'appel et valeur de control (le front l'applique localement).
      const row = rows[0] as { id: string; status: string; control: string | null };
      if (row.status === "cancelled") {
        insertEventBestEffort(id, userId, "task_cancelled", "Tâche annulée par l'utilisateur");
      }
      const control = row.control ?? "none";
      return { success: true, status: row.status, control, task: { id, status: row.status, control } };
    }
    const cur = await pool.query("SELECT status FROM agent_tasks WHERE id = $1 AND user_id = $2", [id, userId]);
    if (cur.rows.length === 0) return reply.status(404).send({ error: "Tâche introuvable" });
    const status = cur.rows[0].status as string;
    return reply.status(409).send({ error: `Tâche déjà terminée (« ${status} ») : annulation impossible`, status });
  });

  // --- App web : approuver une correction proposée par l'évaluateur (contrat LOT 1 §6) ---
  app.post("/api/agent-tasks/:id/approve", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const q = buildApprove(id, userId);
    const { rows } = await pool.query(q.sql, q.values);
    if (rows.length === 1) {
      insertEventBestEffort(id, userId, "task_approved", "Correction approuvée par l'utilisateur");
      const t = rows[0] as { id: string; status: string; control: string | null; payload: unknown };
      return {
        success: true,
        task_id: id,
        status: t.status,
        task: { id: t.id, status: t.status, control: t.control, payload: t.payload },
      };
    }
    const cur = await pool.query("SELECT status FROM agent_tasks WHERE id = $1 AND user_id = $2", [id, userId]);
    if (cur.rows.length === 0) return reply.status(404).send({ error: "Tâche introuvable" });
    return reply
      .status(409)
      .send({ error: "Cette tâche n'est pas en attente d'approbation", status: cur.rows[0].status });
  });

  // --- App web : supprimer une tâche TERMINÉE (completed|failed|cancelled) → 204 ---
  // Une tâche active s'arrête par /cancel, jamais par suppression (S9) ; prépare le retrait
  // de la policy RLS DELETE côté client.
  app.delete("/api/agent-tasks/:id", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const del = await pool.query(
      `DELETE FROM agent_tasks WHERE id = $1 AND user_id = $2 AND status IN ('completed', 'failed', 'cancelled') RETURNING id`,
      [id, userId],
    );
    if (del.rowCount === 1) {
      forgetScreenshot(id);
      return reply.status(204).send();
    }
    const cur = await pool.query("SELECT status FROM agent_tasks WHERE id = $1 AND user_id = $2", [id, userId]);
    if (cur.rows.length === 0) return reply.status(404).send({ error: "Tâche introuvable" });
    return reply.status(409).send({
      error: "Tâche active : annulez-la d'abord (POST /api/agent-tasks/:id/cancel)",
      status: cur.rows[0].status,
    });
  });

  // --- App web : dernière capture d'écran d'une tâche (mémoire, TTL 10 min) ---
  app.get("/api/agent-tasks/:id/screenshot", { preHandler: requireUser }, async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const shot = getScreenshot(id, request.user!.id);
    if (!shot) return reply.status(404).send({ error: "Aucune capture récente pour cette tâche" });
    reply.header("Cache-Control", "no-store");
    return { image_b64: shot.image_b64, mime: shot.mime, at: shot.at };
  });

  // --- App web : historique d'évènements d'une tâche (sans aucune image) ---
  app.get("/api/agent-tasks/:id/events", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const { rows } = await pool.query(
      `SELECT id, type, message,
              CASE WHEN data ? 'image_b64' THEN (data - 'image_b64') || '{"has_image": true}'::jsonb ELSE data END AS data,
              created_at
         FROM agent_events
        WHERE task_id = $1 AND user_id = $2 ORDER BY created_at ASC LIMIT 500`,
      [id, userId],
    );
    return { events: rows };
  });

  // --- App web : créer une tâche (JWT) — étapes validées strictement côté serveur ---
  // Seul point de création des tâches (la policy RLS INSERT sur agent_tasks est retirée).
  app.post("/api/agent-tasks", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const parsed = validateTaskCreateBody(request.body);
    if (!parsed.ok) return reply.status(400).send({ error: parsed.error });
    const { task_type, priority, agent_key_id } = parsed.value;

    // PC ciblé (contrat §7) puis chemins confinés à SES dossiers autorisés (S21).
    const target = await resolveTargetKey(userId, agent_key_id);
    if (!target.ok) return reply.status(target.status).send({ error: target.error, agents: target.agents });
    const steps = parsed.value.payload.steps as Record<string, unknown>[];
    const outside = findPathOutsideAllowed(steps, target.key?.allowed_dirs ?? []);
    if (outside) return reply.status(400).send({ error: outside });
    // Actions à effet réel → confirmation exigée sur le PC (le client ne peut pas l'abaisser).
    const payload = {
      ...parsed.value.payload,
      requires_confirmation: requiresConfirmation(steps) || parsed.value.payload.requires_confirmation === true,
    };

    const { rows } = await pool.query(
      `INSERT INTO agent_tasks (user_id, task_type, payload, priority, target_agent_key_id)
       VALUES ($1, $2, $3::jsonb, $4, $5) RETURNING ${LIST_COLS}`,
      [userId, task_type, JSON.stringify(payload), priority, target.key?.id ?? null],
    );
    return { success: true, task: rows[0] };
  });

  // --- App web : lister ses tâches (JWT) — captures retirées des résultats ---
  app.get("/api/agent-tasks", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const status = (request.query as { status?: string }).status;
    if (status !== undefined && !isAgentTaskStatus(status)) {
      return reply.status(400).send({ error: "status invalide" });
    }

    const { rows } = status
      ? await pool.query(
          `SELECT ${LIST_COLS} FROM agent_tasks WHERE user_id = $1 AND status = $2
           ORDER BY created_at DESC LIMIT 50`,
          [userId, status],
        )
      : await pool.query(
          `SELECT ${LIST_COLS} FROM agent_tasks WHERE user_id = $1 ORDER BY created_at DESC LIMIT 50`,
          [userId],
        );
    return { tasks: rows.map((r) => ({ ...r, result: stripImageB64(r.result) })) };
  });
}
