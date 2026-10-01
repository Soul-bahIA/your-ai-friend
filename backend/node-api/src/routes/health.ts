import type { FastifyInstance } from "fastify";
import { pool } from "../db";
import { config } from "../config";
import { iaHeaders } from "../clients/iaClient";

export async function healthRoutes(app: FastifyInstance): Promise<void> {
  // Liveness simple (ne dépend d'aucun service externe).
  app.get("/health", async () => ({ status: "ok", service: "node-api" }));

  // Readiness : vérifie les dépendances (Postgres + service IA), avec délais courts.
  app.get("/health/deep", async () => {
    const checks: Record<string, string> = {};

    try {
      await pool.query("SELECT 1");
      checks.postgres = "ok";
    } catch {
      checks.postgres = "down";
    }

    try {
      const r = await fetch(`${config.iaServiceUrl}/health`, {
        headers: iaHeaders(),
        signal: AbortSignal.timeout(3_000),
      });
      checks.python_ia = r.ok ? "ok" : "down";
    } catch {
      checks.python_ia = "down";
    }

    const healthy = Object.values(checks).every((v) => v === "ok");
    return { status: healthy ? "ok" : "degraded", checks };
  });
}
