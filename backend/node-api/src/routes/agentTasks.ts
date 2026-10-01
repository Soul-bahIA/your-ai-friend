import type { FastifyInstance, FastifyReply } from "fastify";
import { pool } from "../db";
import { config } from "../config";
import { requireUser, requireAgentKey } from "../auth";
import { maybeEvaluateGoalTask } from "./agentGoal";
import { setAgentAllowedDirs } from "../services/agentKeys";
import { validateTaskCreateBody } from "../lib/agentSteps";
import {
  buildAgentTaskUpdate,
  buildTaskTouch,
  isAgentTaskStatus,
  parseAttempt,
} from "../lib/agentTaskSql";
import { isUuid, stripImageB64, isPlainObject } from "../lib/sanitize";

// Reprise des tâches orphelines : un agent tué en pleine exécution laisse sa
// tâche en 'in_progress' pour toujours (le poll ne lit que les 'pending').
// À chaque poll, les tâches sans signe de vie (updated_at périmé — l'agent
// rafraîchit via heartbeat/évènements) sont remises en file, au plus
// MAX_REQUEUES fois ; au-delà, elles passent en 'failed' (boucle de crash).
// Chaque requeue incrémente requeue_count : c'est le numéro de tentative (attempt)
// que l'agent renvoie ensuite pour prouver qu'il détient toujours la tâche.
const MAX_REQUEUES = 3;

// Les routes de l'agent reçoivent des captures d'écran base64 : corps plus gros admis.
const AGENT_BODY_LIMIT = 15 * 1024 * 1024;
const agentRateLimit = { max: config.rateLimitAgent, timeWindow: "1 minute" };

// Colonnes renvoyées à l'agent / à l'UI (jamais SELECT *).
const POLL_COLS = `id, user_id, task_type, status, priority, payload, requeue_count, control, created_at, updated_at`;
const LIST_COLS = `id, task_type, status, priority, payload, result, error_message, requeue_count, control,
  started_at, completed_at, created_at, updated_at`;

async function requeueStaleTasks(userId: string): Promise<void> {
  const stale = config.agentTaskStaleSeconds;

  const requeued = await pool.query(
    `UPDATE agent_tasks
        SET status = 'pending', started_at = NULL,
            requeue_count = requeue_count + 1, updated_at = now()
      WHERE user_id = $1 AND status = 'in_progress'
        AND updated_at < now() - make_interval(secs => $2)
        AND requeue_count < $3
      RETURNING id, requeue_count`,
    [userId, stale, MAX_REQUEUES],
  );

  const abandoned = await pool.query(
    `UPDATE agent_tasks
        SET status = 'failed', completed_at = now(), updated_at = now(),
            error_message = 'Interrompue puis reprise ' || requeue_count || ' fois sans aboutir — abandonnée'
      WHERE user_id = $1 AND status = 'in_progress'
        AND updated_at < now() - make_interval(secs => $2)
      RETURNING id`,
    [userId, stale],
  );

  // Trace dans la timeline (best-effort, ne bloque jamais le poll).
  const events = [
    ...requeued.rows.map((r) => ({ id: r.id, type: "task_requeued", msg: `Agent interrompu — tâche remise en file (reprise ${r.requeue_count}/${MAX_REQUEUES})` })),
    ...abandoned.rows.map((r) => ({ id: r.id, type: "task_failed", msg: "Interrompue trop de fois — abandonnée" })),
  ];
  for (const e of events) {
    pool
      .query(
        "INSERT INTO agent_events (task_id, user_id, type, message, data) VALUES ($1, $2, $3, $4, '{}'::jsonb)",
        [e.id, userId, e.type, e.msg],
      )
      .catch(() => {});
  }
}

/** Après un UPDATE gardé à 0 ligne : 404 si la tâche n'existe pas pour cet utilisateur, sinon 409. */
async function guardFailure(reply: FastifyReply, taskId: string, userId: string, attempt?: number) {
  const { rows } = await pool.query(
    "SELECT status, requeue_count FROM agent_tasks WHERE id = $1 AND user_id = $2",
    [taskId, userId],
  );
  if (rows.length === 0) return reply.status(404).send({ error: "Tâche introuvable" });
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

// Port de l'edge function `agent-tasks`.
//  - announce / poll / update / event / control (GET) : worker local, x-agent-key
//  - create (POST) / list (GET) / control (POST) / events : app web, JWT

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
  app.get(
    "/api/agent-tasks/poll",
    { preHandler: requireAgentKey, config: { rateLimit: agentRateLimit } },
    async (request) => {
      const userId = request.agentUserId!;
      await requeueStaleTasks(userId);
      const { rows } = await pool.query(
        `SELECT ${POLL_COLS} FROM agent_tasks
         WHERE user_id = $1 AND status = 'pending'
         ORDER BY priority ASC, created_at ASC LIMIT 5`,
        [userId],
      );
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

      // Claim (in_progress) : exige status='pending'. Toute autre transition exige
      // status='in_progress' (+ requeue_count = attempt si fourni). Un agent dont la
      // tâche a été requeue puis reprise ne peut donc plus l'écraser.
      const q = buildAgentTaskUpdate({
        taskId: body.task_id,
        userId,
        status: body.status,
        result: body.result,
        errorMessage:
          typeof body.error_message === "string" ? body.error_message.slice(0, 4000) : (body.error_message as null | undefined),
        attempt,
      });
      const { rows, rowCount } = await pool.query(q.sql, q.values);
      if (rowCount !== 1) {
        if (q.kind === "claim") {
          return reply.status(409).send({ error: "Tâche déjà prise par un autre agent (ou plus en attente)" });
        }
        return guardFailure(reply, body.task_id, userId, attempt);
      }

      // Boucle Observer → Corriger : uniquement si CETTE requête a effectivement
      // terminé la tâche (rowCount=1) — pas de double évaluation.
      if (body.status === "completed" || body.status === "failed") {
        const taskId = body.task_id;
        maybeEvaluateGoalTask(taskId, userId).catch((e) =>
          request.log.error({ err: e }, "évaluation d'objectif échouée"),
        );
      }
      return { success: true, status: rows[0].status, requeue_count: rows[0].requeue_count };
    },
  );

  // --- Worker local : évènement d'exécution (timeline + captures live) / heartbeat ---
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

      // La tâche doit appartenir à l'utilisateur de la clé, être en cours et (si
      // fourni) à la même tentative. Ce même UPDATE sert de signe de vie.
      const touch = buildTaskTouch(body.task_id, userId, attempt);
      const { rowCount } = await pool.query(touch.sql, touch.values);
      if (rowCount !== 1) return guardFailure(reply, body.task_id, userId, attempt);

      // Heartbeat : simple signe de vie, pas de ligne d'évènement (évite de remplir la table).
      if (body.type === "heartbeat") return { success: true };

      await pool.query(
        `INSERT INTO agent_events (task_id, user_id, type, message, data)
         VALUES ($1, $2, $3, $4, $5::jsonb)`,
        [
          body.task_id,
          userId,
          body.type,
          typeof body.message === "string" ? body.message.slice(0, 4000) : null,
          JSON.stringify(body.data ?? {}),
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
      const { rows } = await pool.query(
        "SELECT control FROM agent_tasks WHERE id = $1 AND user_id = $2",
        [id, userId],
      );
      return { control: rows[0]?.control ?? "none" };
    },
  );

  // --- App web : piloter l'exécution (pause | resume | stop) ---
  app.post("/api/agent-tasks/:id/control", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const { control } = (request.body ?? {}) as { control?: string };
    const value = control === "resume" ? "none" : control;
    if (!value || !["none", "pause", "stop"].includes(value)) {
      return reply.status(400).send({ error: "control requis (pause|resume|stop)" });
    }
    const { rowCount } = await pool.query(
      "UPDATE agent_tasks SET control = $1, updated_at = now() WHERE id = $2 AND user_id = $3",
      [value, id, userId],
    );
    if (rowCount === 0) return reply.status(404).send({ error: "Tâche introuvable" });
    return { success: true, control: value };
  });

  // --- App web : historique d'évènements d'une tâche (chargement initial de la timeline) ---
  app.get("/api/agent-tasks/:id/events", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const { rows } = await pool.query(
      `SELECT id, type, message, data, created_at FROM agent_events
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
    const { task_type, payload, priority } = parsed.value;

    const { rows } = await pool.query(
      `INSERT INTO agent_tasks (user_id, task_type, payload, priority)
       VALUES ($1, $2, $3::jsonb, $4) RETURNING ${LIST_COLS}`,
      [userId, task_type, JSON.stringify(payload), priority],
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

