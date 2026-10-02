// Historique du chat via le plan de contrôle (V3) : conversations et messages dans la base de
// node-api (PostgreSQL local en mode hors ligne), sans dépendre de Supabase depuis le navigateur.
// Toujours limité à l'utilisateur authentifié : une conversation d'un autre compte est « introuvable ».
//
//   GET    /api/chat/conversations                → { conversations: [{id, title, created_at}] }
//   POST   /api/chat/conversations {title}        → 201 { conversation }
//   DELETE /api/chat/conversations/:id            → 204
//   GET    /api/chat/conversations/:id/messages   → { messages: [{role, content}] }
//   POST   /api/chat/conversations/:id/messages {role, content} → 201 (met à jour updated_at)
import type { FastifyInstance, FastifyReply } from "fastify";
import { pool } from "../db.js";
import { requireUser } from "../auth.js";
import { isPlainObject, isUuid } from "../lib/sanitize.js";

const MAX_TITLE = 200;
const MAX_CONTENT = 100_000;
const ROLES = ["user", "assistant"];

const bad = (reply: FastifyReply, error: string) => reply.status(400).send({ error });
const notFound = (reply: FastifyReply) => reply.status(404).send({ error: "conversation introuvable" });

export async function chatHistoryRoutes(app: FastifyInstance): Promise<void> {
  app.get("/api/chat/conversations", { preHandler: requireUser }, async (request) => {
    const { rows } = await pool.query(
      "SELECT id, title, created_at FROM chat_conversations WHERE user_id = $1 ORDER BY updated_at DESC LIMIT 200",
      [request.user!.id],
    );
    return { conversations: rows };
  });

  app.post("/api/chat/conversations", { preHandler: requireUser }, async (request, reply) => {
    const body = request.body;
    if (!isPlainObject(body) || typeof body.title !== "string" || !body.title.trim()) return bad(reply, "title requis");
    const { rows } = await pool.query(
      "INSERT INTO chat_conversations (user_id, title) VALUES ($1, $2) RETURNING id, title, created_at",
      [request.user!.id, body.title.trim().slice(0, MAX_TITLE)],
    );
    return reply.status(201).send({ conversation: rows[0] });
  });

  app.delete("/api/chat/conversations/:id", { preHandler: requireUser }, async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const { rowCount } = await pool.query("DELETE FROM chat_conversations WHERE id = $1 AND user_id = $2", [id, request.user!.id]);
    if (!rowCount) return notFound(reply);
    return reply.status(204).send();
  });

  app.get("/api/chat/conversations/:id/messages", { preHandler: requireUser }, async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const own = await pool.query("SELECT 1 FROM chat_conversations WHERE id = $1 AND user_id = $2", [id, request.user!.id]);
    if (!own.rowCount) return notFound(reply);
    const { rows } = await pool.query(
      "SELECT role, content FROM chat_messages WHERE conversation_id = $1 AND user_id = $2 ORDER BY created_at ASC LIMIT 2000",
      [id, request.user!.id],
    );
    return { messages: rows };
  });

  app.post("/api/chat/conversations/:id/messages", { preHandler: requireUser }, async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return bad(reply, "id invalide");
    const body = request.body;
    if (!isPlainObject(body) || typeof body.role !== "string" || !ROLES.includes(body.role)) return bad(reply, "role : user | assistant");
    if (typeof body.content !== "string" || !body.content.length) return bad(reply, "content requis");
    const own = await pool.query("UPDATE chat_conversations SET updated_at = now() WHERE id = $1 AND user_id = $2 RETURNING id", [id, request.user!.id]);
    if (!own.rowCount) return notFound(reply);
    await pool.query("INSERT INTO chat_messages (conversation_id, user_id, role, content) VALUES ($1, $2, $3, $4)", [
      id,
      request.user!.id,
      body.role,
      body.content.slice(0, MAX_CONTENT),
    ]);
    return reply.status(201).send({ ok: true });
  });
}
