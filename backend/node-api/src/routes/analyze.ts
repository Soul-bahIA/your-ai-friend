import type { FastifyInstance } from "fastify";
import { pool } from "../db";
import { requestInference } from "../clients/iaClient";

export async function analyzeRoutes(app: FastifyInstance): Promise<void> {
  // Flux complet : Node → Postgres → Python IA (→ Rust) → Postgres → client
  app.post("/api/analyze", async (request, reply) => {
    const body = request.body as { text?: string } | undefined;
    const text = body?.text?.trim();
    if (!text) {
      return reply.status(400).send({ error: "Champ 'text' requis" });
    }

    // 1. Persiste la requête entrante
    const insert = await pool.query(
      "INSERT INTO analysis_requests (input_text, status) VALUES ($1, 'processing') RETURNING id",
      [text],
    );
    const requestId: string = insert.rows[0].id;

    try {
      // 2. Délègue au service IA Python (qui appelle Rust pour les calculs lourds)
      const result = await requestInference({ text });

      // 3. Stocke le résultat (colonne JSONB → on sérialise)
      await pool.query(
        "UPDATE analysis_requests SET status = 'done', result = $2 WHERE id = $1",
        [requestId, JSON.stringify(result)],
      );

      return { requestId, ...result };
    } catch (err) {
      await pool.query(
        "UPDATE analysis_requests SET status = 'error' WHERE id = $1",
        [requestId],
      );
      request.log.error(err);
      return reply
        .status(502)
        .send({ error: "Échec de l'inférence IA", requestId });
    }
  });

  // Relecture d'un résultat par id
  app.get("/api/analyze/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    const r = await pool.query(
      "SELECT id, input_text, status, result, created_at FROM analysis_requests WHERE id = $1",
      [id],
    );
    if (r.rowCount === 0) {
      return reply.status(404).send({ error: "Introuvable" });
    }
    return r.rows[0];
  });
}
