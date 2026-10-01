// Routes V2 — runtime (PC exécutant, clé agent) — LOT 7, audit §9.2 (register · lease ·
// keepalive · result · messages · checkpoints). Toute écriture est clôturée par
// (task_id, attempt, lease_owner) : un runtime ne peut agir que sur les tâches qu'il détient.
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { pool, withTransaction } from "../../db.js";
import { requireAgentKey } from "../../auth.js";
import { config } from "../../config.js";
import { isPlainObject, isUuid, unknownKeys } from "../../lib/sanitize.js";
import { isMessageType, postMessage } from "../bus/messages.js";
import { keepalive, lease } from "../scheduler/scheduler.js";
import { effectiveMaxParallel } from "../scheduler/parallelism.js";
import { getTask } from "../tasks/repo.js";
import { LEASED_STATUSES } from "../tasks/stateMachine.js";

function bad(reply: FastifyReply, error: string) {
  return reply.status(400).send({ error });
}

interface RuntimeRow {
  id: string;
  max_slots: number;
  status: string;
}

/** Runtime appartenant à l'utilisateur ET à la clé appelante (une clé = un PC). */
async function ownedRuntime(request: FastifyRequest, runtimeId: unknown): Promise<RuntimeRow | null> {
  if (!isUuid(runtimeId)) return null;
  const { rows } = await pool.query("SELECT id, max_slots, status FROM soulbah.runtimes WHERE id = $1 AND user_id = $2 AND agent_key_id = $3", [
    runtimeId,
    request.agentUserId,
    request.agentKeyId,
  ]);
  return (rows[0] as RuntimeRow | undefined) ?? null;
}

function parseAttempt(v: unknown): number | null {
  return typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : null;
}

export async function runtimeRoutes(app: FastifyInstance): Promise<void> {
  const agentOpts = { preHandler: requireAgentKey, config: { rateLimit: { max: config.rateLimitAgent, timeWindow: "1 minute" } } };

  // --- Enregistrement (au démarrage du superviseur) ------------------------------------
  app.post("/api/v2/runtime/register", agentOpts, async (request, reply) => {
    const body = (request.body ?? {}) as Record<string, unknown>;
    if (!isPlainObject(body)) return bad(reply, "corps JSON objet attendu");
    const extra = unknownKeys(body, ["hostname", "version", "max_slots", "capabilities"]);
    if (extra.length) return bad(reply, `champ(s) inconnu(s) : ${extra.join(", ")}`);
    let maxSlots = 6;
    if (body.max_slots !== undefined) {
      if (typeof body.max_slots !== "number" || !Number.isInteger(body.max_slots) || body.max_slots < 1 || body.max_slots > 32) return bad(reply, "max_slots : entier 1–32 attendu");
      maxSlots = body.max_slots;
    }
    if (body.capabilities !== undefined && !isPlainObject(body.capabilities)) return bad(reply, "capabilities : objet attendu");
    const hostname = typeof body.hostname === "string" ? body.hostname.slice(0, 200) : null;
    const version = typeof body.version === "string" ? body.version.slice(0, 50) : null;
    const capabilities = JSON.stringify(body.capabilities ?? {});
    const { rows } = await pool.query(
      `INSERT INTO soulbah.runtimes (user_id, agent_key_id, hostname, version, max_slots, capabilities, status, last_seen_at)
       VALUES ($1, $2, $3, $4, $5, $6::jsonb, 'online', now())
       ON CONFLICT (agent_key_id) DO UPDATE
         SET hostname = EXCLUDED.hostname, version = EXCLUDED.version, max_slots = EXCLUDED.max_slots,
             capabilities = EXCLUDED.capabilities, status = 'online', last_seen_at = now(), updated_at = now()
       RETURNING id, max_slots`,
      [request.agentUserId, request.agentKeyId, hostname, version, maxSlots, capabilities],
    );
    await pool.query("UPDATE agent_keys SET kind = 'runtime', capabilities = $2::jsonb, last_seen_at = now() WHERE id = $1", [request.agentKeyId, capabilities]);
    const us = await pool.query("SELECT max_parallel_agents FROM soulbah.user_settings WHERE user_id = $1", [request.agentUserId]);
    return {
      runtime_id: rows[0].id,
      max_slots: rows[0].max_slots,
      lease_seconds: config.v2LeaseSeconds,
      max_parallel: effectiveMaxParallel({ global: config.maxParallelAgents, user: us.rows[0]?.max_parallel_agents ?? null, runtime: rows[0].max_slots as number }),
    };
  });

  // --- Baux --------------------------------------------------------------------------------
  app.post("/api/v2/runtime/lease", agentOpts, async (request, reply) => {
    const body = (request.body ?? {}) as { runtime_id?: unknown; slots?: unknown };
    const rt = await ownedRuntime(request, body.runtime_id);
    if (!rt) return reply.status(404).send({ error: "runtime inconnu (enregistrez-le d'abord)" });
    const slots = typeof body.slots === "number" && Number.isInteger(body.slots) ? Math.max(0, Math.min(32, body.slots)) : 1;
    const out = await lease({ runtimeId: rt.id, userId: request.agentUserId!, slots });
    return { tasks: out.granted, max_parallel: out.max_parallel, running: out.running, skipped_resources: out.skipped_resources, lease_seconds: config.v2LeaseSeconds };
  });

  app.post("/api/v2/runtime/keepalive", agentOpts, async (request, reply) => {
    const body = (request.body ?? {}) as { runtime_id?: unknown; tasks?: unknown };
    const rt = await ownedRuntime(request, body.runtime_id);
    if (!rt) return reply.status(404).send({ error: "runtime inconnu" });
    const items: { task_id: string; attempt: number }[] = [];
    if (body.tasks !== undefined) {
      if (!Array.isArray(body.tasks) || body.tasks.length > 64) return bad(reply, "tasks : liste (≤ 64) de { task_id, attempt } attendue");
      for (const t of body.tasks) {
        if (!isPlainObject(t) || !isUuid(t.task_id) || parseAttempt(t.attempt) === null) return bad(reply, "tasks[] : { task_id (uuid), attempt (entier) } attendu");
        items.push({ task_id: t.task_id, attempt: t.attempt as number });
      }
    }
    return { tasks: await keepalive({ runtimeId: rt.id, userId: request.agentUserId!, items }), lease_seconds: config.v2LeaseSeconds };
  });

  // --- Résultat, messages, checkpoints d'une tâche détenue ------------------------------
  async function heldTask(request: FastifyRequest, reply: FastifyReply, taskId: string, body: Record<string, unknown>) {
    if (!isUuid(taskId)) {
      await bad(reply, "id invalide");
      return null;
    }
    const rt = await ownedRuntime(request, body.runtime_id);
    if (!rt) {
      await reply.status(404).send({ error: "runtime inconnu" });
      return null;
    }
    const attempt = parseAttempt(body.attempt);
    if (attempt === null) {
      await bad(reply, "attempt : entier ≥ 0 requis");
      return null;
    }
    const task = await getTask(pool, taskId, request.agentUserId);
    if (!task) {
      await reply.status(410).send({ error: "gone" });
      return null;
    }
    const owner = `runtime:${rt.id}`;
    if (task.lease_owner !== owner || task.attempt !== attempt || !LEASED_STATUSES.includes(task.status)) {
      await reply.status(409).send({ error: "bail non détenu pour cette tentative", status: task.status, attempt: task.attempt, lease_owner: task.lease_owner });
      return null;
    }
    return { task, rt, owner, attempt };
  }

  app.post("/api/v2/runtime/tasks/:id/result", { ...agentOpts, bodyLimit: 2 * 1024 * 1024 }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const body = (request.body ?? {}) as Record<string, unknown>;
    const held = await heldTask(request, reply, id, body);
    if (!held) return;
    const payload = { result: body.result ?? {}, simulated: body.simulated === true };
    const out = await withTransaction(async (client) => {
      const fresh = await getTask(client, id, request.agentUserId);
      if (!fresh) return { ok: false as const, status: 410 as const, error: "gone" };
      return postMessage(client, { task: fresh, type: "TASK_RESULT", payload, actor: held.owner, attempt: held.attempt });
    });
    if (!out.ok) return reply.status(out.status).send({ error: out.error });
    return { task_id: id, status: out.task.status, effect: out.effect, message_id: out.message_id };
  });

  app.post("/api/v2/runtime/tasks/:id/message", { ...agentOpts, bodyLimit: 256 * 1024 }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const body = (request.body ?? {}) as Record<string, unknown>;
    const held = await heldTask(request, reply, id, body);
    if (!held) return;
    if (!isMessageType(body.type)) return bad(reply, "type : l'un des 9 types de messages attendu");
    if (!isPlainObject(body.payload)) return bad(reply, "payload : objet attendu");
    const toRole = typeof body.to_role === "string" ? body.to_role.slice(0, 64) : null;
    const correlationId = isUuid(body.correlation_id) ? body.correlation_id : null;
    const replyTo = isUuid(body.reply_to) ? body.reply_to : null;
    const out = await withTransaction(async (client) => {
      const fresh = await getTask(client, id, request.agentUserId);
      if (!fresh) return { ok: false as const, status: 410 as const, error: "gone" };
      return postMessage(client, { task: fresh, type: body.type as never, payload: body.payload as Record<string, unknown>, actor: held.owner, attempt: held.attempt, toRole, correlationId, replyTo });
    });
    if (!out.ok) return reply.status(out.status).send({ error: out.error });
    return { task_id: id, status: out.task.status, effect: out.effect, message_id: out.message_id };
  });

  app.post("/api/v2/runtime/tasks/:id/checkpoint", { ...agentOpts, bodyLimit: 512 * 1024 }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const body = (request.body ?? {}) as Record<string, unknown>;
    const held = await heldTask(request, reply, id, body);
    if (!held) return;
    const seq = parseAttempt(body.seq);
    const cursor = parseAttempt(body.step_cursor);
    if (seq === null || cursor === null) return bad(reply, "seq et step_cursor : entiers ≥ 0 requis");
    if (body.variables !== undefined && !isPlainObject(body.variables)) return bad(reply, "variables : objet attendu");
    const { rows } = await pool.query(
      `INSERT INTO soulbah.checkpoints (task_id, attempt, seq, step_cursor, variables) VALUES ($1, $2, $3, $4, $5::jsonb)
       ON CONFLICT (task_id, attempt, seq) DO NOTHING RETURNING id`,
      [id, held.attempt, seq, cursor, JSON.stringify(body.variables ?? {})],
    );
    const expires = new Date(Date.now() + config.v2LeaseSeconds * 1000);
    await pool.query("UPDATE soulbah.tasks SET lease_expires_at = $2, updated_at = now() WHERE id = $1 AND lease_owner = $3 AND attempt = $4", [id, expires, held.owner, held.attempt]);
    return { task_id: id, checkpoint_id: rows[0]?.id ?? null, duplicate: rows.length === 0, lease_expires_at: expires };
  });

  app.get("/api/v2/runtime/tasks/:id", agentOpts, async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const task = await getTask(pool, id, request.agentUserId);
    if (!task) return reply.status(410).send({ error: "gone" });
    const spec = task.spec as { answers?: unknown[] };
    const last = await pool.query("SELECT attempt, seq, step_cursor, variables FROM soulbah.checkpoints WHERE task_id = $1 AND attempt = $2 ORDER BY seq DESC LIMIT 1", [id, task.attempt]);
    return {
      task_id: id,
      status: task.status,
      attempt: task.attempt,
      lease_owner: task.lease_owner,
      lease_expires_at: task.lease_expires_at,
      waiting_reason: task.waiting_reason,
      answers: Array.isArray(spec.answers) ? spec.answers : [],
      last_checkpoint: last.rows[0] ?? null,
    };
  });

  app.post("/api/v2/runtime/messages/:id/ack", agentOpts, async (request, reply) => {
    const { id } = request.params as { id: string };
    const body = (request.body ?? {}) as { runtime_id?: unknown };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const rt = await ownedRuntime(request, body.runtime_id);
    if (!rt) return reply.status(404).send({ error: "runtime inconnu" });
    const { rowCount } = await pool.query(
      `UPDATE soulbah.messages m SET acked_at = now() FROM soulbah.sessions s
        WHERE m.id = $1 AND s.id = m.session_id AND s.user_id = $2 AND m.acked_at IS NULL`,
      [id, request.agentUserId],
    );
    return { acked: rowCount === 1 };
  });
}
