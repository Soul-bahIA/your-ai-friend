import type { FastifyInstance } from "fastify";
import { pool } from "../db";
import { config } from "../config";

export async function healthRoutes(app: FastifyInstance): Promise<void> {
  // Liveness simple
  app.get("/health", async () => ({ status: "ok", service: "node-api" }));

  // Readiness : vérifie les dépendances (Postgres + service IA)
  app.get("/health/deep", async () => {
    const checks: Record<string, string> = {};

    try {
      await pool.query("SELECT 1");
      checks.postgres = "ok";
    } catch {
      checks.postgres = "down";
    }

    try {
      const r = await fetch(`${config.iaServiceUrl}/health`);
      checks.python_ia = r.ok ? "ok" : "down";
    } catch {
      checks.python_ia = "down";
    }

    const healthy = Object.values(checks).every((v) => v === "ok");
    return { status: healthy ? "ok" : "degraded", checks };
  });
}
