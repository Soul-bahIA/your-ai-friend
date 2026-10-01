import type { FastifyInstance } from "fastify";
import { pool } from "../db";
import { config } from "../config";
import { requireUser, requireAgentKey } from "../auth";
import { maybeEvaluateGoalTask } from "./agentGoal";
import { setAgentAllowedDirs } from "../services/agentKeys";

// Reprise des tâches orphelines : un agent tué en pleine exécution laisse sa
// tâche en 'in_progress' pour toujours (le poll ne lit que les 'pending').
// À chaque poll, les tâches sans signe de vie (updated_at périmé — l'agent
// rafraîchit via heartbeat/évènements) sont remises en file, au plus
// MAX_REQUEUES fois ; au-delà, elles passent en 'failed' (boucle de crash).
const MAX_REQUEUES = 3;

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

// Port de l'edge function `agent-tasks`.
//  - poll / update : worker local, authentifié par x-agent-key
//  - create (POST) / list (GET) : app web, authentifiée par JWT
// On conserve la sémantique d'origine (action en query pour poll/update).

export async function agentTaskRoutes(app: FastifyInstance): Promise<void> {
  // --- Worker local : annonce de sa configuration (au démarrage) ---
  // L'agent déclare ses dossiers autorisés ; le planificateur les injecte
  // dans le contexte pour ne générer que des chemins réellement whitelistés.
  app.post("/api/agent-tasks/announce", { preHandler: requireAgentKey }, async (request, reply) => {
    const body = (request.body ?? {}) as { allowed_dirs?: unknown };
    const dirs = Array.isArray(body.allowed_dirs)
      ? body.allowed_dirs.filter((d): d is string => typeof d === "string" && d.length > 0).slice(0, 50)
      : null;
    if (!dirs) return reply.status(400).send({ error: "allowed_dirs (liste) requis" });
    await setAgentAllowedDirs(request.agentKeyId!, dirs);
    return { success: true };
  });

  // --- Worker local : poll des tâches en attente ---
  // Le user_id est déduit de la clé agent (agentUserId), plus passé en clair.
  app.get("/api/agent-tasks/poll", { preHandler: requireAgentKey }, async (request) => {
    const userId = request.agentUserId!;
    await requeueStaleTasks(userId);
    const { rows } = await pool.query(
      `SELECT * FROM agent_tasks
       WHERE user_id = $1 AND status = 'pending'
       ORDER BY priority ASC, created_at ASC LIMIT 5`,
      [userId],
    );
    return { tasks: rows };
  });

  // --- Worker local : mise à jour du statut d'une tâche (scopée par user_id) ---
  app.post("/api/agent-tasks/update", { preHandler: requireAgentKey }, async (request, reply) => {
    const userId = request.agentUserId!;
    const body = (request.body ?? {}) as {
      task_id?: string;
      status?: string;
      result?: unknown;
      error_message?: string;
    };
    if (!body.task_id || !body.status) {
      return reply.status(400).send({ error: "task_id et status requis" });
    }

    const sets: string[] = ["status = $1", "updated_at = now()"];
    const values: unknown[] = [body.status];
    let i = 2;
    if (body.result !== undefined) { sets.push(`result = $${i++}::jsonb`); values.push(JSON.stringify(body.result)); }
    if (body.error_message !== undefined) { sets.push(`error_message = $${i++}`); values.push(body.error_message); }
    if (body.status === "in_progress") sets.push("started_at = now()");
    if (body.status === "completed" || body.status === "failed") sets.push("completed_at = now()");

    // Filtre par task_id ET user_id : on ne peut modifier que ses propres tâches.
    // Le passage à in_progress est un CLAIM atomique : il exige status='pending',
    // donc si deux agents (deux clés du même compte) pollent la même tâche, un
    // seul obtient rowCount=1 ; l'autre reçoit 409 et passe à la suivante.
    values.push(body.task_id, userId);
    const claimGuard = body.status === "in_progress" ? " AND status = 'pending'" : "";
    const { rowCount } = await pool.query(
      `UPDATE agent_tasks SET ${sets.join(", ")} WHERE id = $${i++} AND user_id = $${i}${claimGuard}`,
      values,
    );
    if (rowCount === 0) {
      if (body.status === "in_progress") {
        return reply.status(409).send({ error: "Tâche déjà prise par un autre agent" });
      }
      return reply.status(404).send({ error: "Tâche introuvable" });
    }

    // Boucle Observer → Corriger : si la tâche vient d'un objectif (moteur de
    // raisonnement) et se termine, on l'évalue en arrière-plan sans bloquer l'agent.
    if (body.status === "completed" || body.status === "failed") {
      maybeEvaluateGoalTask(body.task_id, userId).catch((e) =>
        request.log.error({ err: e }, "évaluation d'objectif échouée"),
      );
    }
    return { success: true };
  });

  // --- Worker local : émettre un évènement d'exécution (timeline + captures live) ---
  app.post("/api/agent-tasks/event", { preHandler: requireAgentKey }, async (request, reply) => {
    const userId = request.agentUserId!;
    const body = (request.body ?? {}) as {
      task_id?: string;
      type?: string;
      message?: string;
      data?: unknown;
    };
    if (!body.task_id || !body.type) {
      return reply.status(400).send({ error: "task_id et type requis" });
    }
    await pool.query(
      `INSERT INTO agent_events (task_id, user_id, type, message, data)
       VALUES ($1, $2, $3, $4, $5::jsonb)`,
      [body.task_id, userId, body.type, body.message ?? null, JSON.stringify(body.data ?? {})],
    );
    // Signe de vie : tout évènement (heartbeat, étape…) atteste que l'agent
    // travaille encore — on rafraîchit updated_at pour éviter le requeue.
    pool
      .query(
        "UPDATE agent_tasks SET updated_at = now() WHERE id = $1 AND user_id = $2 AND status = 'in_progress'",
        [body.task_id, userId],
      )
      .catch(() => {});
    // Rétention : à la fin d'une tâche, purge les évènements de plus de 3 jours
    // (les captures base64 sont volumineuses — on évite une croissance non bornée).
    if (body.type === "task_completed" || body.type === "task_failed") {
      pool
        .query("DELETE FROM agent_events WHERE user_id = $1 AND created_at < now() - interval '3 days'", [userId])
        .catch(() => {});
    }
    return { success: true };
  });

  // --- Worker local : lire l'ordre de contrôle courant (none|pause|stop) ---
  app.get("/api/agent-tasks/:id/control", { preHandler: requireAgentKey }, async (request) => {
    const userId = request.agentUserId!;
    const { id } = request.params as { id: string };
    const { rows } = await pool.query(
      "SELECT control FROM agent_tasks WHERE id = $1 AND user_id = $2",
      [id, userId],
    );
    return { control: rows[0]?.control ?? "none" };
  });

  // --- App web : piloter l'exécution (pause | resume | stop) ---
  app.post("/api/agent-tasks/:id/control", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
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
  app.get("/api/agent-tasks/:id/events", { preHandler: requireUser }, async (request) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    const { rows } = await pool.query(
      `SELECT id, type, message, data, created_at FROM agent_events
       WHERE task_id = $1 AND user_id = $2 ORDER BY created_at ASC LIMIT 500`,
      [id, userId],
    );
    return { events: rows };
  });

  // --- App web : créer une tâche (JWT) ---
  app.post("/api/agent-tasks", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const body = (request.body ?? {}) as { task_type?: string; payload?: unknown; priority?: number };
    if (!body.task_type) return reply.status(400).send({ error: "task_type requis" });

    const { rows } = await pool.query(
      `INSERT INTO agent_tasks (user_id, task_type, payload, priority)
       VALUES ($1, $2, $3::jsonb, $4) RETURNING *`,
      [userId, body.task_type, JSON.stringify(body.payload ?? {}), body.priority ?? 5],
    );
    return { success: true, task: rows[0] };
  });

  // --- App web : lister ses tâches (JWT) ---
  app.get("/api/agent-tasks", { preHandler: requireUser }, async (request) => {
    const userId = request.user!.id;
    const status = (request.query as { status?: string }).status;

    if (status) {
      const { rows } = await pool.query(
        `SELECT * FROM agent_tasks WHERE user_id = $1 AND status = $2
         ORDER BY created_at DESC LIMIT 50`,
        [userId, status],
      );
      return { tasks: rows };
    }
    const { rows } = await pool.query(
      "SELECT * FROM agent_tasks WHERE user_id = $1 ORDER BY created_at DESC LIMIT 50",
      [userId],
    );
    return { tasks: rows };
  });
}
