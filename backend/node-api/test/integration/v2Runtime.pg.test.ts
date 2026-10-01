// LOT 8 — routes runtime sur Postgres réel : poignée de main (426), journal des actions
// (monotone, 409 en régression), réconciliation (resume / abandon / cancel). Sauté sans TEST_DATABASE_URL.
import { randomBytes } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";

const DB_URL = (process.env.TEST_DATABASE_URL ?? "").trim();
const RUN = DB_URL !== "";
const TOKEN = randomBytes(32).toString("hex");
const U = "a0000000-0000-4000-8000-0000000000c8";
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
  process.env.SOULBAH_RUNTIME_MIN_VERSION = "2.0.0";
  process.env.IA_SERVICE_URL = "http://127.0.0.1:9";
}

type Pool = { query: (sql: string, values?: unknown[]) => Promise<{ rows: Record<string, unknown>[]; rowCount: number | null }>; end: () => Promise<void> };

describe.skipIf(!RUN)("runtime V2 : poignée de main, actions, réconciliation", () => {
  let app: FastifyInstance;
  let pool: Pool;
  let sched: typeof import("../../src/v2/scheduler/scheduler");
  const jwt = { authorization: `Bearer ${TOKEN}` };
  const rawKey = "sbk_" + randomBytes(32).toString("hex");
  const agent = { "x-agent-key": rawKey };
  let runtimeId = "";
  let taskId = "";

  beforeAll(async () => {
    ({ pool } = (await import("../../src/db")) as unknown as { pool: Pool });
    const { hashKey } = await import("../../src/services/agentKeys");
    sched = await import("../../src/v2/scheduler/scheduler");
    const { buildApp } = await import("../../src/app");
    app = await buildApp({ mediaDir: path.join(os.tmpdir(), "soulbah-pg-rt-media") });
    await pool.query("INSERT INTO auth.users (id, email) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING", [U, "rt@soulbah.local"]);
    await pool.query("INSERT INTO agent_keys (user_id, key_hash, label, allowed_dirs) VALUES ($1, $2, 'PC rt', '[]'::jsonb)", [U, hashKey(rawKey)]);
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

  it("poignée de main : protocole absent ou version trop ancienne → 426 ; compatible → runtime_id", async () => {
    const reg = (payload: object) => app.inject({ method: "POST", url: "/api/v2/runtime/register", headers: agent, payload });
    const noProto = await reg({ hostname: "pc", version: "2.0.0", max_slots: 2 });
    expect(noProto.statusCode).toBe(426);
    expect(noProto.json()).toMatchObject({ min_version: "2.0.0", protocol: 1 });
    expect((await reg({ hostname: "pc", version: "1.5.0", protocol: 1, max_slots: 2 })).statusCode).toBe(426);
    expect((await reg({ hostname: "pc", version: "2.0.0", protocol: 2, max_slots: 2 })).statusCode).toBe(426);
    expect(Number((await pool.query("SELECT count(*)::int AS n FROM soulbah.runtimes WHERE user_id = $1", [U])).rows[0].n)).toBe(0);
    const refused = await pool.query("SELECT count(*)::int AS n FROM soulbah.audit_logs WHERE user_id = $1 AND action = 'runtime.refused'", [U]);
    expect(Number(refused.rows[0].n)).toBeGreaterThanOrEqual(3);
    const ok = await reg({ hostname: "pc", version: "2.0.0", protocol: 1, max_slots: 2 });
    expect(ok.statusCode).toBe(200);
    expect(ok.json()).toMatchObject({ protocol: 1, max_slots: 2 });
    runtimeId = ok.json().runtime_id;
    const kind = await pool.query("SELECT kind FROM agent_keys WHERE user_id = $1", [U]);
    expect(kind.rows[0].kind).toBe("runtime");
  });

  it("journal des actions : états monotones, régression → 409, preuves cumulées, liste", async () => {
    const s = await app.inject({
      method: "POST",
      url: "/api/v2/sessions",
      headers: jwt,
      payload: { goal: "reprise", plan: { nodes: [{ key: "a", title: "A", role: "coder", security_level: "L1", spec: { steps: [{ type: "wait", seconds: 1 }, { type: "type_text", text: "x" }, { type: "wait", seconds: 1 }] } }] } },
    });
    expect(s.statusCode).toBe(201);
    await app.inject({ method: "POST", url: `/api/v2/sessions/${s.json().session.id}/approve`, headers: jwt });
    await sched.tick();
    const l = await app.inject({ method: "POST", url: "/api/v2/runtime/lease", headers: agent, payload: { runtime_id: runtimeId, slots: 1 } });
    expect(l.json().tasks.length).toBe(1);
    taskId = l.json().tasks[0].id;
    const act = (body: object) => app.inject({ method: "POST", url: `/api/v2/runtime/tasks/${taskId}/actions`, headers: agent, payload: { runtime_id: runtimeId, attempt: 1, ...body } });

    expect((await act({ step_index: 0, tool: "wait", status: "planned" })).statusCode).toBe(200);
    expect((await act({ step_index: 0, tool: "wait", status: "attempted" })).json().previous).toBe("planned");
    expect((await act({ step_index: 0, tool: "wait", status: "executed", evidence: [{ kind: "exit_code", confidence: "high", value: 0 }] })).statusCode).toBe(200);
    expect((await act({ step_index: 0, tool: "wait", status: "verified" })).statusCode).toBe(200);
    expect((await act({ step_index: 0, tool: "wait", status: "attempted" })).statusCode).toBe(409); // régression
    expect((await act({ step_index: 1, tool: "type_text", status: "attempted", params: { text: "mot de passe secret" } })).statusCode).toBe(200);
    expect((await act({ step_index: 1, tool: "type_text", status: "attempted" })).statusCode).toBe(200); // identique = idempotent
    expect((await act({ step_index: 9, tool: "nope!", status: "planned" })).statusCode).toBe(400);
    expect((await act({ step_index: 2, tool: "wait", status: "chouette" })).statusCode).toBe(400);
    // Mauvaise tentative → 409 (bail non détenu pour cette tentative).
    expect((await app.inject({ method: "POST", url: `/api/v2/runtime/tasks/${taskId}/actions`, headers: agent, payload: { runtime_id: runtimeId, attempt: 3, step_index: 0, tool: "wait", status: "planned" } })).statusCode).toBe(409);

    const list = await app.inject({ method: "GET", url: `/api/v2/runtime/tasks/${taskId}/actions?runtime_id=${runtimeId}&attempt=1`, headers: agent });
    expect(list.statusCode).toBe(200);
    const actions = list.json().actions as { step_index: number; status: string; idempotent: boolean; evidence_confidence: string | null }[];
    expect(actions.map((a) => [a.step_index, a.status, a.idempotent])).toEqual([
      [0, "verified", true],
      [1, "attempted", false],
    ]);
    expect(actions[0].evidence_confidence).toBe("high");
    const stored = await pool.query("SELECT params FROM soulbah.actions WHERE task_id = $1 AND step_index = 1", [taskId]);
    expect(JSON.stringify(stored.rows[0].params)).not.toContain("mot de passe secret"); // texte saisi masqué
  });

  it("réconciliation : resume (bail prolongé + actions), abandon (autre tentative), cancel (inconnue)", async () => {
    const before = (await pool.query("SELECT lease_expires_at FROM soulbah.tasks WHERE id = $1", [taskId])).rows[0].lease_expires_at as string;
    await pool.query("UPDATE soulbah.tasks SET lease_expires_at = now() + interval '1 second' WHERE id = $1", [taskId]);
    const r = await app.inject({
      method: "POST",
      url: "/api/v2/runtime/reconcile",
      headers: agent,
      payload: { runtime_id: runtimeId, tasks: [{ task_id: taskId, attempt: 1 }, { task_id: taskId, attempt: 0 }, { task_id: U, attempt: 1 }] },
    });
    expect(r.statusCode).toBe(200);
    const d = r.json().decisions as { task_id: string; attempt: number; decision: string; actions: { step_index: number; status: string; idempotent: boolean }[] }[];
    expect(d[0]).toMatchObject({ decision: "resume", status: "RUNNING" });
    expect(d[0].actions.map((a) => [a.step_index, a.status, a.idempotent])).toEqual([[0, "verified", true], [1, "attempted", false]]);
    expect(d[1]).toMatchObject({ decision: "abandon", current_attempt: 1 });
    expect(d[2]).toMatchObject({ decision: "cancel", status: "gone" });
    const after = (await pool.query("SELECT lease_expires_at FROM soulbah.tasks WHERE id = $1", [taskId])).rows[0].lease_expires_at as string;
    expect(new Date(after).getTime()).toBeGreaterThan(Date.now() + 30_000);
    void before;
    // Tâche terminée → abandon ; annulée → cancel.
    await app.inject({ method: "POST", url: `/api/v2/runtime/tasks/${taskId}/result`, headers: agent, payload: { runtime_id: runtimeId, attempt: 1, result: { ok: true } } });
    const r2 = await app.inject({ method: "POST", url: "/api/v2/runtime/reconcile", headers: agent, payload: { runtime_id: runtimeId, tasks: [{ task_id: taskId, attempt: 1 }] } });
    expect(r2.json().decisions[0]).toMatchObject({ decision: "abandon", status: "COMPLETED" });
  });
});
