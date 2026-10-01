// LOT 3 — Tests d'INTÉGRATION : Fastify inject contre un VRAI Postgres migré (auth de dev +
// clé agent réelle). Exécutés seulement si TEST_DATABASE_URL est défini : base jetable
// locale (bash scripts/dev_db/dev_db.sh up && bash scripts/dev_db/dev_db.sh test) ou job CI
// `db`. Sans variable, la suite est marquée « skipped » (npm test reste hermétique).
// Critère de sortie LOT 3 (audit §13) : poll → claim → 409 sur Postgres.
import { randomBytes } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";

const DB_URL = (process.env.TEST_DATABASE_URL ?? "").trim();
const RUN = DB_URL !== "";
const TOKEN = randomBytes(32).toString("hex");
const U = "a0000000-0000-4000-8000-0000000000c1"; // utilisateur propre à cette suite (≠ seed de dev)

if (RUN) {
  process.env.DATABASE_URL = DB_URL;
  process.env.DATABASE_SSL = "false";
  process.env.PG_SSL_CA = "";
  process.env.SOULBAH_ENV = "test";
  process.env.HOST = "127.0.0.1";
  process.env.AUTH_MODE = "dev-local";
  process.env.DEV_LOCAL_TOKEN = TOKEN;
  process.env.DEV_LOCAL_USER_ID = U;
  process.env.IA_SERVICE_URL = "http://127.0.0.1:9"; // port fermé : aucun appel IA attendu ici
}

type Pool = { query: (sql: string, values?: unknown[]) => Promise<{ rows: Record<string, unknown>[]; rowCount: number | null }>; end: () => Promise<void> };

describe.skipIf(!RUN)("file agent sur Postgres réel : création, poll, claim, 409, final", () => {
  let app: FastifyInstance;
  let pool: Pool;
  let drain: (ms: number) => Promise<boolean>;
  let hashKey: (raw: string) => string;
  const jwt = { authorization: `Bearer ${TOKEN}` };
  const rawKey = "sbk_" + randomBytes(32).toString("hex");
  const rawKey2 = "sbk_" + randomBytes(32).toString("hex");
  const agent = { "x-agent-key": rawKey };
  const agent2 = { "x-agent-key": rawKey2 };
  let keyId = "";
  let key2Id = "";
  let taskId = "";
  let targetedId = "";

  beforeAll(async () => {
    ({ pool } = (await import("../../src/db")) as unknown as { pool: Pool });
    ({ hashKey } = await import("../../src/services/agentKeys"));
    ({ drainBackgroundJobs: drain } = await import("../../src/services/backgroundJobs"));
    const { buildApp } = await import("../../src/app");
    app = await buildApp({ mediaDir: path.join(os.tmpdir(), "soulbah-pg-test-media") });

    await pool.query("INSERT INTO auth.users (id, email) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING", [U, "pg-test@soulbah.local"]);
    const k = await pool.query(
      "INSERT INTO agent_keys (user_id, key_hash, label, allowed_dirs) VALUES ($1, $2, $3, '[]'::jsonb) RETURNING id",
      [U, hashKey(rawKey), "PC test 1"],
    );
    keyId = k.rows[0].id as string;
  });

  afterAll(async () => {
    await pool.query("DELETE FROM agent_events WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM agent_tasks WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM agent_keys WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM user_roles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM profiles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM auth.users WHERE id = $1", [U]);
    await app.close();
    await pool.end();
  });

  it("schéma LOT 1 présent (colonnes de ciblage) et base joignable", async () => {
    const { rows } = await pool.query(
      `SELECT column_name FROM information_schema.columns
        WHERE table_name = 'agent_tasks' AND column_name IN ('target_agent_key_id', 'claimed_by_key_id', 'requeue_count')`,
    );
    expect(rows.map((r) => r.column_name).sort()).toEqual(["claimed_by_key_id", "requeue_count", "target_agent_key_id"]);
  });

  it("JWT de dev : sans jeton → 401, mauvais jeton → 401, bon jeton → 200", async () => {
    expect((await app.inject({ method: "GET", url: "/api/agent-tasks" })).statusCode).toBe(401);
    expect((await app.inject({ method: "GET", url: "/api/agent-tasks", headers: { authorization: "Bearer " + "0".repeat(64) } })).statusCode).toBe(401);
    const r = await app.inject({ method: "GET", url: "/api/agent-tasks", headers: jwt });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ tasks: [] });
  });

  it("clé agent inconnue → 401", async () => {
    const r = await app.inject({ method: "GET", url: "/api/agent-tasks/poll", headers: { "x-agent-key": "sbk_inconnue" } });
    expect(r.statusCode).toBe(401);
  });

  it("POST /api/agent-tasks crée une tâche pending ciblant la seule clé de l'utilisateur", async () => {
    const r = await app.inject({
      method: "POST",
      url: "/api/agent-tasks",
      headers: jwt,
      payload: { task_type: "desktop", payload: { steps: [{ type: "wait", seconds: 1, note: "test d'intégration" }] } },
    });
    expect(r.statusCode).toBe(200);
    const task = r.json().task;
    expect(task).toMatchObject({ status: "pending", requeue_count: 0, target_agent_key_id: keyId, task_type: "desktop" });
    expect(task.payload.requires_confirmation).toBe(false);
    taskId = task.id;
  });

  it("poll (clé agent) renvoie la tâche avec requeue_count = 0", async () => {
    const r = await app.inject({ method: "GET", url: "/api/agent-tasks/poll", headers: agent });
    expect(r.statusCode).toBe(200);
    const found = (r.json().tasks as { id: string; requeue_count: number; status: string }[]).find((t) => t.id === taskId);
    expect(found).toMatchObject({ requeue_count: 0, status: "pending" });
  });

  it("claim in_progress (attempt 0) → 200 ; second claim → 409 ; la tâche quitte le poll", async () => {
    const claim = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/update",
      headers: agent,
      payload: { task_id: taskId, status: "in_progress", attempt: 0 },
    });
    expect(claim.statusCode).toBe(200);
    expect(claim.json()).toMatchObject({ success: true, status: "in_progress", requeue_count: 0 });

    const again = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/update",
      headers: agent,
      payload: { task_id: taskId, status: "in_progress", attempt: 0 },
    });
    expect(again.statusCode).toBe(409);

    const poll = await app.inject({ method: "GET", url: "/api/agent-tasks/poll", headers: agent });
    expect((poll.json().tasks as { id: string }[]).some((t) => t.id === taskId)).toBe(false);

    const { rows } = await pool.query("SELECT status, claimed_by_key_id, started_at FROM agent_tasks WHERE id = $1", [taskId]);
    expect(rows[0]).toMatchObject({ status: "in_progress", claimed_by_key_id: keyId });
    expect(rows[0].started_at).not.toBeNull();
  });

  it("heartbeat : attempt courant → 200 ; attempt périmé → 409", async () => {
    const ok = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/event",
      headers: agent,
      payload: { task_id: taskId, type: "heartbeat", attempt: 0 },
    });
    expect(ok.statusCode).toBe(200);
    const stale = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/event",
      headers: agent,
      payload: { task_id: taskId, type: "heartbeat", attempt: 1 },
    });
    expect(stale.statusCode).toBe(409);
    expect(stale.json().error).toContain("périmée");
  });

  it("évènement step_done écrit en base avec source=agent", async () => {
    const r = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/event",
      headers: agent,
      payload: { task_id: taskId, type: "step_done", message: "attente terminée", attempt: 0, data: { index: 0 } },
    });
    expect(r.statusCode).toBe(200);
    const ev = await app.inject({ method: "GET", url: `/api/agent-tasks/${taskId}/events`, headers: jwt });
    expect(ev.statusCode).toBe(200);
    const events = ev.json().events as { type: string; data: Record<string, unknown> }[];
    expect(events.some((e) => e.type === "step_done" && e.data.source === "agent" && e.data.index === 0)).toBe(true);
  });

  it("final : mauvais attempt → 409 ; bon attempt → completed ; rejeu → 409", async () => {
    const bad = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/update",
      headers: agent,
      payload: { task_id: taskId, status: "completed", attempt: 1, result: { summary: "non" } },
    });
    expect(bad.statusCode).toBe(409);

    const done = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/update",
      headers: agent,
      payload: { task_id: taskId, status: "completed", attempt: 0, result: { summary: "ok", executed: [{ ok: true }] } },
    });
    expect(done.statusCode).toBe(200);
    expect(done.json()).toMatchObject({ success: true, status: "completed" });
    expect(await drain(10_000)).toBe(true); // évaluation d'objectif : sautée (pas de goal_meta), aucun appel IA

    const replay = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/update",
      headers: agent,
      payload: { task_id: taskId, status: "completed", attempt: 0 },
    });
    expect(replay.statusCode).toBe(409);

    const { rows } = await pool.query("SELECT status, result, completed_at FROM agent_tasks WHERE id = $1", [taskId]);
    expect(rows[0].status).toBe("completed");
    expect((rows[0].result as { summary: string }).summary).toBe("ok");
    expect(rows[0].completed_at).not.toBeNull();
  });

  it("liste ?status=completed la contient ; DELETE d'une tâche terminée → 204", async () => {
    const list = await app.inject({ method: "GET", url: "/api/agent-tasks?status=completed", headers: jwt });
    expect((list.json().tasks as { id: string }[]).some((t) => t.id === taskId)).toBe(true);
    expect((await app.inject({ method: "DELETE", url: `/api/agent-tasks/${taskId}`, headers: jwt })).statusCode).toBe(204);
    expect((await app.inject({ method: "GET", url: `/api/agent-tasks/${taskId}/control`, headers: agent })).statusCode).toBe(410);
  });

  it("ciblage d'un PC : une tâche pour la clé 2 n'est ni servie ni réclamable par la clé 1", async () => {
    const k2 = await pool.query(
      "INSERT INTO agent_keys (user_id, key_hash, label, allowed_dirs) VALUES ($1, $2, $3, '[]'::jsonb) RETURNING id",
      [U, hashKey(rawKey2), "PC test 2"],
    );
    key2Id = k2.rows[0].id as string;

    // Deux clés : sans agent_key_id, la création demande de choisir.
    const ambiguous = await app.inject({
      method: "POST",
      url: "/api/agent-tasks",
      headers: jwt,
      payload: { task_type: "desktop", payload: { steps: [{ type: "wait", seconds: 1 }] } },
    });
    expect(ambiguous.statusCode).toBe(400);
    expect((ambiguous.json().agents as { id: string }[]).map((a) => a.id).sort()).toEqual([keyId, key2Id].sort());

    const created = await app.inject({
      method: "POST",
      url: "/api/agent-tasks",
      headers: jwt,
      payload: { task_type: "desktop", payload: { steps: [{ type: "wait", seconds: 1 }] }, agent_key_id: key2Id },
    });
    expect(created.statusCode).toBe(200);
    targetedId = created.json().task.id;
    expect(created.json().task.target_agent_key_id).toBe(key2Id);

    const poll1 = await app.inject({ method: "GET", url: "/api/agent-tasks/poll", headers: agent });
    expect((poll1.json().tasks as { id: string }[]).some((t) => t.id === targetedId)).toBe(false);
    const claim1 = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/update",
      headers: agent,
      payload: { task_id: targetedId, status: "in_progress", attempt: 0 },
    });
    expect(claim1.statusCode).toBe(409);

    const poll2 = await app.inject({ method: "GET", url: "/api/agent-tasks/poll", headers: agent2 });
    expect((poll2.json().tasks as { id: string }[]).some((t) => t.id === targetedId)).toBe(true);
    const claim2 = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/update",
      headers: agent2,
      payload: { task_id: targetedId, status: "in_progress", attempt: 0 },
    });
    expect(claim2.statusCode).toBe(200);
  });

  it("annulation d'une tâche en cours → control 'stop', puis final 'cancelled' accepté", async () => {
    const cancel = await app.inject({ method: "POST", url: `/api/agent-tasks/${targetedId}/cancel`, headers: jwt });
    expect(cancel.statusCode).toBe(200);
    expect(cancel.json()).toMatchObject({ success: true, status: "in_progress", control: "stop" });
    const ctl = await app.inject({ method: "GET", url: `/api/agent-tasks/${targetedId}/control`, headers: agent2 });
    expect(ctl.json()).toEqual({ control: "stop" });
    const fin = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/update",
      headers: agent2,
      payload: { task_id: targetedId, status: "cancelled", attempt: 0 },
    });
    expect(fin.statusCode).toBe(200);
    expect(fin.json()).toMatchObject({ status: "cancelled" });
    const { rows } = await pool.query("SELECT status FROM agent_tasks WHERE id = $1", [targetedId]);
    expect(rows[0].status).toBe("cancelled");
  });
});
