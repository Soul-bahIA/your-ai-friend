import type { FastifyInstance } from "fastify";
import { pool } from "../db.js";
import { requireUser } from "../auth.js";
import { requestInference } from "../clients/iaClient.js";
import { isUuid } from "../lib/sanitize.js";

// Démo Node → Python → Rust. Authentifiée : chaque requête est rattachée à son
// utilisateur (analysis_requests.user_id) et seule sa propre ligne est relisible.

export async function analyzeRoutes(app: FastifyInstance): Promise<void> {
  app.post("/api/analyze", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const body = request.body as { text?: unknown } | undefined;
    const text = typeof body?.text === "string" ? body.text.trim() : "";
    if (!text) {
      return reply.status(400).send({ error: "Champ 'text' requis" });
    }
    if (text.length > 10_000) {
      return reply.status(400).send({ error: "Champ 'text' trop long (10000 car. max)" });
    }

    // 1. Persiste la requête entrante
    const insert = await pool.query(
      "INSERT INTO analysis_requests (input_text, status, user_id) VALUES ($1, 'processing', $2) RETURNING id",
      [text, userId],
    );
    const requestId: string = insert.rows[0].id;

    try {
      // 2. Délègue au service IA Python (qui appelle Rust pour les calculs lourds)
      const result = await requestInference({ text });

      // 3. Stocke le résultat (colonne JSONB → on sérialise)
      await pool.query(
        "UPDATE analysis_requests SET status = 'done', result = $2 WHERE id = $1 AND user_id = $3",
        [requestId, JSON.stringify(result), userId],
      );

      return { requestId, ...result };
    } catch (err) {
      await pool
        .query("UPDATE analysis_requests SET status = 'error' WHERE id = $1 AND user_id = $2", [requestId, userId])
        .catch(() => {});
      request.log.error(err);
      return reply.status(502).send({ error: "Échec de l'inférence IA", requestId });
    }
  });

  // Relecture d'un résultat par id (uniquement les siens)
  app.get("/api/analyze/:id", { preHandler: requireUser }, async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const r = await pool.query(
      "SELECT id, input_text, status, result, created_at FROM analysis_requests WHERE id = $1 AND user_id = $2",
      [id, request.user!.id],
    );
    if (r.rowCount === 0) {
      return reply.status(404).send({ error: "Introuvable" });
    }
    return r.rows[0];
  });
}
