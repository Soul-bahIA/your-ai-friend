// V3 LOT 6 — Resource Manager côté plan de contrôle, sur un VRAI Postgres : l'état mémoire des PC
// (lease, keepalive) est rangé dans runtimes.capabilities.live ; mémoire critique récente → aucun
// nouveau bail ; GET /api/v2/resources réunit agents logiques, file READY, PC et modèle.
// Sauté sans TEST_DATABASE_URL.
import { randomBytes } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";

const DB_URL = (process.env.TEST_DATABASE_URL ?? "").trim();
const RUN = DB_URL !== "";
const TOKEN = randomBytes(32).toString("hex");
const U = "a0000000-0000-4000-8000-0000000000d6";
if (RUN) {
  process.env.DATABASE_URL = DB_URL;
  process.env.DATABASE_SSL = "false";
  process.env.PG_SSL_CA = "";
  process.env.SOULBAH_ENV = "test";
  process.env.HOST = "127.0.0.1";
  process.env.AUTH_MODE = "dev-local";
  process.env.DEV_LOCAL_TOKEN = TOKEN;
  process.env.DEV_LOCAL_USER_ID = U;
  process.env.SOULBAH_APPROVAL_SECRET = randomBytes(32).toString("hex");
  process.env.SOULBAH_MAX_PARALLEL_AGENTS = "6";
  process.env.IA_SERVICE_URL = "http://127.0.0.1:9";
}

type Pool = { query: (sql: string, values?: unknown[]) => Promise<{ rows: Record<string, unknown>[]; rowCount: number | null }>; end: () => Promise<void> };

describe.skipIf(!RUN)("Resource Manager V3 (LOT 6) sur Postgres réel", () => {
  let app: FastifyInstance;
  let pool: Pool;
  let sched: typeof import("../../src/v2/scheduler/scheduler");
  const jwt = { authorization: `Bearer ${TOKEN}` };
  const rawKey = "sbk_" + randomBytes(32).toString("hex");
  const agent = { "x-agent-key": rawKey };
  let runtimeId = "";

  beforeAll(async () => {
    ({ pool } = (await import("../../src/db")) as unknown as { pool: Pool });
    const { hashKey } = await import("../../src/services/agentKeys");
    sched = await import("../../src/v2/scheduler/scheduler");
    const { buildApp } = await import("../../src/app");
    app = await buildApp({ mediaDir: path.join(os.tmpdir(), "soulbah-pg-v3-resources-media") });
    await pool.query("INSERT INTO auth.users (id, email) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING", [U, "resources@soulbah.local"]);
    await pool.query("INSERT INTO agent_keys (user_id, key_hash, label, allowed_dirs) VALUES ($1, $2, 'PC ressources', '[]'::jsonb)", [U, hashKey(rawKey)]);
    const reg = await app.inject({ method: "POST", url: "/api/v2/runtime/register", headers: agent, payload: { hostname: "pc-ram", version: "2.0.0", protocol: 1, max_slots: 6 } });
    expect(reg.statusCode, reg.body).toBe(200);
    runtimeId = reg.json().runtime_id;
  });

  afterAll(async () => {
    await pool.query("DELETE FROM soulbah.sessions WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM soulbah.runtimes WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM soulbah.permissions WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM agent_keys WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM user_roles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM profiles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM auth.users WHERE id = $1", [U]);
    await app.close();
    await pool.end();
  });

  const six = { nodes: Array.from({ length: 6 }, (_, i) => ({ key: `agent_${i}`, title: `Agent ${i}`, role: "researcher", security_level: "L0" })) };
  const live = (free_mb: number, pressure: string) => ({ free_mb, total_mb: 8000, load_percent: 92, pressure, held: 0, max_slots: 6, allowed_new: pressure === "critical" ? 0 : 6, throttled: false, note: "ignoré" });

  it("6 agents logiques prêts ; mémoire critique → aucun bail ; mémoire normale → baux ; vue d'ensemble", async () => {
    const created = await app.inject({ method: "POST", url: "/api/v2/sessions", headers: jwt, payload: { goal: "six agents", plan: six } });
    expect(created.statusCode, created.body).toBe(201);
    const sid = created.json().session.id as string;
    expect((await app.inject({ method: "POST", url: `/api/v2/sessions/${sid}/approve`, headers: jwt })).statusCode).toBe(200);
    await sched.tick();

    // PC sous pression critique : aucun bail, même s'il en demande.
    const refused = await app.inject({ method: "POST", url: "/api/v2/runtime/lease", headers: agent, payload: { runtime_id: runtimeId, slots: 3, resources: live(150, "critical") } });
    expect(refused.statusCode, refused.body).toBe(200);
    expect(refused.json()).toMatchObject({ tasks: [], memory_limited: true });
    const stored = await pool.query("SELECT capabilities->'live' AS live FROM soulbah.runtimes WHERE id = $1", [runtimeId]);
    expect(stored.rows[0].live).toMatchObject({ free_mb: 150, pressure: "critical", throttled: false });
    expect((stored.rows[0].live as Record<string, unknown>).note).toBeUndefined(); // champs inconnus ignorés

    let view = await app.inject({ method: "GET", url: "/api/v2/resources", headers: jwt });
    expect(view.statusCode, view.body).toBe(200);
    expect(view.json().agents).toMatchObject({ ready: 6, running: 0 });
    expect(view.json().runtimes[0]).toMatchObject({ id: runtimeId, live: { pressure: "critical" } });
    expect(view.json().model).toBeNull(); // python-ia injoignable dans ce test
    expect(view.json().max_parallel_agents).toBe(6);

    // Mémoire revenue : le PC demande 2 workers (sa propre limite) et les obtient.
    const granted = await app.inject({ method: "POST", url: "/api/v2/runtime/lease", headers: agent, payload: { runtime_id: runtimeId, slots: 2, resources: live(900, "ok") } });
    expect(granted.json().tasks).toHaveLength(2);
    expect(granted.json().memory_limited).toBe(false);
    view = await app.inject({ method: "GET", url: "/api/v2/resources", headers: jwt });
    expect(view.json().agents).toMatchObject({ ready: 4, running: 2, by_role: { researcher: 2 } });

    // keepalive : l'état mémoire est mis à jour aussi.
    const items = granted.json().tasks.map((t: { id: string; attempt: number }) => ({ task_id: t.id, attempt: t.attempt }));
    const kept = await app.inject({ method: "POST", url: "/api/v2/runtime/keepalive", headers: agent, payload: { runtime_id: runtimeId, tasks: items, resources: { ...live(640, "high"), held: 2 } } });
    expect(kept.statusCode, kept.body).toBe(200);
    view = await app.inject({ method: "GET", url: "/api/v2/resources", headers: jwt });
    expect(view.json().runtimes[0].live).toMatchObject({ free_mb: 640, pressure: "high", held: 2 });
  });

  it("un état critique ancien ne bloque plus (garde-fou limité aux états récents)", async () => {
    const old = new Date(Date.now() - 5 * 60_000).toISOString();
    await pool.query("UPDATE soulbah.runtimes SET capabilities = capabilities || jsonb_build_object('live', $2::jsonb) WHERE id = $1", [runtimeId, JSON.stringify({ pressure: "critical", at: old })]);
    const r = await sched.lease({ runtimeId, userId: U, slots: 1 });
    expect(r.memory_limited).toBeUndefined();
    expect(r.granted.length).toBe(1);
  });
});
