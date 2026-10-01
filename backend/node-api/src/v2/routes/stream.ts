// Flux SSE V2 (LOT 7) : GET /api/v2/stream?session_id=… (JWT). Instantané de la session
// (statut, tâches, agents, dernier message, dernière ligne d'audit) relu toutes les
// SOULBAH_STREAM_INTERVAL_MS et émis seulement quand il change (`event: snapshot`), avec un
// `: ping` périodique. Le polling de la base est le repli robuste prévu par l'audit (§14 :
// LISTEN exige le pooler :5432) ; LISTEN/NOTIFY pourra s'y brancher sans changer le contrat.
import { createHash } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { pool } from "../../db.js";
import { requireUser } from "../../auth.js";
import { config } from "../../config.js";
import { isUuid } from "../../lib/sanitize.js";
import { getSession } from "../sessions/repo.js";

export interface Snapshot {
  session: { id: string; status: string; plan_version: number; updated_at: string | Date };
  tasks: { id: string; node_key: string | null; status: string; attempt: number; updated_at: string | Date }[];
  busy_agents: number;
  last_message_at: string | Date | null;
  last_audit_seq: number;
}

/** Empreinte stable d'un instantané (ordre des tâches fixé par la requête). */
export function snapshotDigest(s: Snapshot): string {
  const canon = JSON.stringify({
    s: [s.session.status, s.session.plan_version, String(s.session.updated_at)],
    t: s.tasks.map((t) => [t.id, t.status, t.attempt, String(t.updated_at)]),
    b: s.busy_agents,
    m: s.last_message_at === null ? null : String(s.last_message_at),
    a: s.last_audit_seq,
  });
  return createHash("sha1").update(canon).digest("hex");
}

/** Encodage d'un évènement SSE. */
export function sseFrame(event: string, data: unknown, id?: string): string {
  return `${id ? `id: ${id}\n` : ""}event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
}

export async function loadSnapshot(userId: string, sessionId: string): Promise<Snapshot | null> {
  const session = await getSession(pool, userId, sessionId);
  if (!session) return null;
  const tasks = await pool.query("SELECT id, node_key, status, attempt, updated_at FROM soulbah.tasks WHERE session_id = $1 ORDER BY created_at, id", [sessionId]);
  const agents = await pool.query("SELECT count(*)::int AS n FROM soulbah.agents WHERE session_id = $1 AND status = 'BUSY'", [sessionId]);
  const msg = await pool.query("SELECT max(created_at) AS m FROM soulbah.messages WHERE session_id = $1", [sessionId]);
  const au = await pool.query("SELECT coalesce(max(seq), 0)::bigint AS s FROM soulbah.audit_logs WHERE session_id = $1", [sessionId]);
  return {
    session: { id: session.id, status: session.status, plan_version: session.plan_version, updated_at: session.updated_at },
    tasks: tasks.rows as Snapshot["tasks"],
    busy_agents: Number(agents.rows[0].n),
    last_message_at: (msg.rows[0].m as string | null) ?? null,
    last_audit_seq: Number(au.rows[0].s),
  };
}

export async function streamRoutes(app: FastifyInstance): Promise<void> {
  app.get("/api/v2/stream", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const q = request.query as { session_id?: string };
    if (!isUuid(q.session_id)) return reply.status(400).send({ error: "session_id (uuid) requis" });
    const sessionId = q.session_id;
    const first = await loadSnapshot(userId, sessionId);
    if (!first) return reply.status(404).send({ error: "Session introuvable" });

    reply.hijack();
    const res = reply.raw;
    res.writeHead(200, {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    });
    let last = snapshotDigest(first);
    res.write(sseFrame("snapshot", first, last));

    let closed = false;
    const poll = setInterval(async () => {
      if (closed) return;
      try {
        const snap = await loadSnapshot(userId, sessionId);
        if (!snap) {
          res.write(sseFrame("gone", { session_id: sessionId }));
          end();
          return;
        }
        const digest = snapshotDigest(snap);
        if (digest !== last) {
          last = digest;
          res.write(sseFrame("snapshot", snap, digest));
        }
      } catch (e) {
        res.write(sseFrame("error", { error: "lecture impossible", detail: (e as Error).message.slice(0, 200) }));
      }
    }, config.streamIntervalMs);
    const ping = setInterval(() => {
      if (!closed) res.write(": ping\n\n");
    }, 15_000);
    const end = () => {
      if (closed) return;
      closed = true;
      clearInterval(poll);
      clearInterval(ping);
      res.end();
    };
    request.raw.on("close", end);
    request.raw.on("error", end);
  });
}
