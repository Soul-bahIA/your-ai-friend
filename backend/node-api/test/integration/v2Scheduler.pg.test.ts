// LOT 7 — sessions, file, scheduler et bus sur un VRAI Postgres (schéma LOT 4). Critères §13 :
// 6 workers factices, 1 000 entrelacements → 0 double bail ; RUNNING ≤ max pour 1, 3 et 6 ;
// dépendances, ressources exclusives, reaper (bail expiré → RETRYING → READY), messages,
// clôture de session. Sauté sans TEST_DATABASE_URL.
import { randomBytes } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";

const DB_URL = (process.env.TEST_DATABASE_URL ?? "").trim();
const RUN = DB_URL !== "";
const TOKEN = randomBytes(32).toString("hex");
const U = "a0000000-0000-4000-8000-0000000000c7";
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

describe.skipIf(!RUN)("sessions / scheduler / bus V2 sur Postgres réel", () => {
  let app: FastifyInstance;
  let pool: Pool;
  let sched: typeof import("../../src/v2/scheduler/scheduler");
  const jwt = { authorization: `Bearer ${TOKEN}` };
  const rawKey = "sbk_" + randomBytes(32).toString("hex");
  const agent = { "x-agent-key": rawKey };
  const runtimeIds: string[] = [];
  let sessionId = "";

  beforeAll(async () => {
    ({ pool } = (await import("../../src/db")) as unknown as { pool: Pool });
    const { hashKey } = await import("../../src/services/agentKeys");
    sched = (await import("../../src/v2/scheduler/scheduler")) as unknown as typeof sched;
    const { buildApp } = await import("../../src/app");
    app = await buildApp({ mediaDir: path.join(os.tmpdir(), "soulbah-pg-v2-media") });
    await pool.query("INSERT INTO auth.users (id, email) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING", [U, "v2@soulbah.local"]);
    const k = await pool.query("INSERT INTO agent_keys (user_id, key_hash, label, allowed_dirs) VALUES ($1, $2, 'PC v2', '[]'::jsonb) RETURNING id", [U, hashKey(rawKey)]);
    // 6 runtimes factices (6 workers) : un seul est lié à la clé (register), les autres sont créés en base
    // avec des clés dédiées pour simuler plusieurs PC du même utilisateur.
    const reg = await app.inject({ method: "POST", url: "/api/v2/runtime/register", headers: agent, payload: { hostname: "pc-1", version: "2.0.0", protocol: 1, max_slots: 6 } });
    expect(reg.statusCode).toBe(200);
    runtimeIds.push(reg.json().runtime_id);
    for (let i = 2; i <= 6; i++) {
      const kk = await pool.query("INSERT INTO agent_keys (user_id, key_hash, label, allowed_dirs) VALUES ($1, $2, $3, '[]'::jsonb) RETURNING id", [U, hashKey("sbk_" + randomBytes(32).toString("hex")), `PC v2 ${i}`]);
      const rt = await pool.query("INSERT INTO soulbah.runtimes (user_id, agent_key_id, hostname, max_slots, status) VALUES ($1, $2, $3, 6, 'online') RETURNING id", [U, kk.rows[0].id, `pc-${i}`]);
      runtimeIds.push(rt.rows[0].id as string);
    }
    void k;
  });

  afterAll(async () => {
    await pool.query("DELETE FROM soulbah.sessions WHERE user_id = $1", [U]); // cascade tasks, agents, messages, deps
    await pool.query("DELETE FROM soulbah.runtimes WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM soulbah.permissions WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM soulbah.user_settings WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM agent_keys WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM user_roles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM profiles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM auth.users WHERE id = $1", [U]);
    await app.close();
    await pool.end();
  });

  const nodes = (n: number, extra: Record<string, unknown> = {}) =>
    Array.from({ length: n }, (_, i) => ({ key: `t${i}`, title: `Tâche ${i}`, role: "coder", security_level: "L1", ...extra }));

  async function setMaxParallel(user: number) {
    await pool.query(
      "INSERT INTO soulbah.user_settings (user_id, max_parallel_agents) VALUES ($1, $2) ON CONFLICT (user_id) DO UPDATE SET max_parallel_agents = EXCLUDED.max_parallel_agents",
      [U, user],
    );
  }

  it("création avec plan (DAG) → AWAITING_APPROVAL, tâches PENDING ; approbation → RUNNING + grant L1 ; tick → READY", async () => {
    const r = await app.inject({
      method: "POST",
      url: "/api/v2/sessions",
      headers: jwt,
      payload: { goal: "mission de test", plan: { nodes: [...nodes(2), { key: "fin", title: "Fin", role: "coder", security_level: "L0" }], edges: [{ from: "t0", to: "fin" }, { from: "t1", to: "fin" }] } },
    });
    expect(r.statusCode).toBe(201);
    sessionId = r.json().session.id;
    expect(r.json().session.status).toBe("AWAITING_APPROVAL");
    expect(r.json().tasks.length).toBe(3);
    const bad = await app.inject({ method: "POST", url: `/api/v2/sessions/${sessionId}/plan`, headers: jwt, payload: { plan: { nodes: nodes(2), edges: [{ from: "t0", to: "t1" }, { from: "t1", to: "t0" }] } } });
    expect(bad.statusCode).toBe(400);
    expect(bad.json().error).toContain("cycle");

    const ap = await app.inject({ method: "POST", url: `/api/v2/sessions/${sessionId}/approve`, headers: jwt });
    expect(ap.statusCode).toBe(200);
    expect(ap.json().session.status).toBe("RUNNING");
    const grants = await pool.query("SELECT security_level, status FROM soulbah.permissions WHERE session_id = $1 AND kind = 'grant'", [sessionId]);
    expect(grants.rows).toEqual([{ security_level: "L1", status: "approved" }]);
    expect((await app.inject({ method: "POST", url: `/api/v2/sessions/${sessionId}/approve`, headers: jwt })).statusCode).toBe(409);

    const t = await sched.tick();
    expect(t.locked).toBe(true);
    const st = await pool.query("SELECT node_key, status FROM soulbah.tasks WHERE session_id = $1 ORDER BY node_key", [sessionId]);
    expect(st.rows).toEqual([{ node_key: "fin", status: "PENDING" }, { node_key: "t0", status: "READY" }, { node_key: "t1", status: "READY" }]);
  });

  it("bail via la route runtime, résultat → VALIDATING → COMPLETED (sans critère) ; dépendance promue ; session clôturée", async () => {
    const l = await app.inject({ method: "POST", url: "/api/v2/runtime/lease", headers: agent, payload: { runtime_id: runtimeIds[0], slots: 6 } });
    expect(l.statusCode).toBe(200);
    const granted = l.json().tasks as { id: string; attempt: number; node_key: string }[];
    expect(granted.map((g) => g.node_key).sort()).toEqual(["t0", "t1"]);
    expect(granted.every((g) => g.attempt === 1)).toBe(true);
    const busy = await pool.query("SELECT count(*)::int AS n FROM soulbah.agents WHERE session_id = $1 AND status = 'BUSY'", [sessionId]);
    expect(Number(busy.rows[0].n)).toBe(2);

    // Mauvaise tentative / autre runtime → 409 ; keepalive prolonge ; résultat accepté.
    expect((await app.inject({ method: "POST", url: `/api/v2/runtime/tasks/${granted[0].id}/result`, headers: agent, payload: { runtime_id: runtimeIds[0], attempt: 7, result: {} } })).statusCode).toBe(409);
    const ka = await app.inject({ method: "POST", url: "/api/v2/runtime/keepalive", headers: agent, payload: { runtime_id: runtimeIds[0], tasks: granted.map((g) => ({ task_id: g.id, attempt: g.attempt })) } });
    expect(ka.json().tasks.every((t: { control: string }) => t.control === "continue")).toBe(true);
    for (const g of granted) {
      const res = await app.inject({ method: "POST", url: `/api/v2/runtime/tasks/${g.id}/result`, headers: agent, payload: { runtime_id: runtimeIds[0], attempt: g.attempt, result: { summary: "ok" } } });
      expect(res.statusCode).toBe(200);
      expect(res.json().status).toBe("COMPLETED");
    }
    const ka2 = await app.inject({ method: "POST", url: "/api/v2/runtime/keepalive", headers: agent, payload: { runtime_id: runtimeIds[0], tasks: [{ task_id: granted[0].id, attempt: 1 }] } });
    expect(ka2.json().tasks[0].control).toBe("stop");

    await sched.tick();
    const fin = await pool.query("SELECT id, status FROM soulbah.tasks WHERE session_id = $1 AND node_key = 'fin'", [sessionId]);
    expect(fin.rows[0].status).toBe("READY");
    const l2 = await app.inject({ method: "POST", url: "/api/v2/runtime/lease", headers: agent, payload: { runtime_id: runtimeIds[0], slots: 1 } });
    expect(l2.json().tasks.length).toBe(1);
    await app.inject({ method: "POST", url: `/api/v2/runtime/tasks/${fin.rows[0].id}/result`, headers: agent, payload: { runtime_id: runtimeIds[0], attempt: 1, result: {} } });
    await sched.tick();
    const s = await app.inject({ method: "GET", url: `/api/v2/sessions/${sessionId}`, headers: jwt });
    expect(s.json().session.status).toBe("COMPLETED");
    expect(s.json().busy_agents).toBe(0);
    const ev = await pool.query("SELECT count(*)::int AS n FROM soulbah.evaluations e JOIN soulbah.tasks t ON t.id = e.task_id WHERE t.session_id = $1", [sessionId]);
    expect(Number(ev.rows[0].n)).toBe(3);
  });

  async function newRunningSession(plan: unknown, extra: Record<string, unknown> = {}): Promise<string> {
    const r = await app.inject({ method: "POST", url: "/api/v2/sessions", headers: jwt, payload: { goal: "concurrence", plan, ...extra } });
    expect(r.statusCode).toBe(201);
    const id = r.json().session.id as string;
    expect((await app.inject({ method: "POST", url: `/api/v2/sessions/${id}/approve`, headers: jwt })).statusCode).toBe(200);
    await sched.tick();
    return id;
  }

  async function cancelAllSessions() {
    const { rows } = await pool.query("SELECT id FROM soulbah.sessions WHERE user_id = $1 AND status NOT IN ('COMPLETED', 'FAILED', 'CANCELLED')", [U]);
    for (const r of rows) {
      const c = await app.inject({ method: "POST", url: `/api/v2/sessions/${r.id}/cancel`, headers: jwt, payload: {} });
      expect(c.statusCode, c.body).toBe(200);
    }
  }

  async function runningCount(): Promise<number> {
    const { rows } = await pool.query("SELECT count(*)::int AS n FROM soulbah.tasks WHERE user_id = $1 AND status IN ('RUNNING', 'WAITING', 'VALIDATING')", [U]);
    return Number(rows[0].n);
  }

  it("6 workers, 1 000 entrelacements : 0 double bail, chaque tâche réclamée une seule fois, RUNNING ≤ 6", async () => {
    await cancelAllSessions();
    await setMaxParallel(32); // plafond effectif = min(global 6, utilisateur 32, runtime 6) = 6
    const sid = await newRunningSession({ nodes: nodes(40) });
    const results = await Promise.all(Array.from({ length: 1000 }, (_, i) => sched.lease({ runtimeId: runtimeIds[i % 6], userId: U, slots: 1 })));
    const granted = results.flatMap((r) => r.granted);
    const ids = granted.map((g) => g.id);
    expect(ids.length).toBeGreaterThan(0);
    expect(new Set(ids).size).toBe(ids.length); // jamais la même tâche deux fois
    const rows = await pool.query("SELECT status, attempt, lease_owner FROM soulbah.tasks WHERE session_id = $1", [sid]);
    const running = rows.rows.filter((r) => r.status === "RUNNING");
    expect(running.length).toBe(6);
    expect(running.length).toBe(ids.length);
    expect(running.every((r) => r.attempt === 1 && String(r.lease_owner).startsWith("runtime:"))).toBe(true);
    // Chaque bail compte un agent BUSY, et l'audit trace chaque READY → RUNNING une seule fois.
    const busy = await pool.query("SELECT count(*)::int AS n FROM soulbah.agents WHERE session_id = $1 AND status = 'BUSY'", [sid]);
    expect(Number(busy.rows[0].n)).toBe(6);
    const au = await pool.query("SELECT count(*)::int AS n FROM soulbah.audit_logs WHERE session_id = $1 AND action = 'task.transition' AND data ->> 'to' = 'RUNNING'", [sid]);
    expect(Number(au.rows[0].n)).toBe(6);
  }, 60_000);

  it("RUNNING ≤ max pour 1, 3 et 6 (plafond utilisateur relu à chaque bail)", async () => {
    for (const cap of [1, 3, 6]) {
      await cancelAllSessions();
      await setMaxParallel(cap);
      expect(await runningCount()).toBe(0);
      await newRunningSession({ nodes: nodes(12) });
      await Promise.all(Array.from({ length: 300 }, (_, i) => sched.lease({ runtimeId: runtimeIds[i % 6], userId: U, slots: 3 })));
      expect(await runningCount()).toBe(cap);
    }
  }, 60_000);

  it("surcharge par mission : sessions.max_parallel_agents = 2 borne la mission, pas l'utilisateur", async () => {
    await cancelAllSessions();
    await setMaxParallel(6);
    const sid = await newRunningSession({ nodes: nodes(8) }, { max_parallel_agents: 2 });
    await Promise.all(Array.from({ length: 50 }, (_, i) => sched.lease({ runtimeId: runtimeIds[i % 6], userId: U, slots: 6 })));
    const { rows } = await pool.query("SELECT count(*)::int AS n FROM soulbah.tasks WHERE session_id = $1 AND status = 'RUNNING'", [sid]);
    expect(Number(rows[0].n)).toBe(2);
    // PATCH abaisse à 1 : aucun nouveau bail tant que 2 tournent, les 2 en cours continuent.
    expect((await app.inject({ method: "PATCH", url: `/api/v2/sessions/${sid}`, headers: jwt, payload: { max_parallel_agents: 1 } })).statusCode).toBe(200);
    await sched.lease({ runtimeId: runtimeIds[0], userId: U, slots: 6 });
    expect(Number((await pool.query("SELECT count(*)::int AS n FROM soulbah.tasks WHERE session_id = $1 AND status = 'RUNNING'", [sid])).rows[0].n)).toBe(2);
  });

  it("ressource exclusive desktop.input : une seule tâche à la fois ; partagée : plusieurs", async () => {
    await cancelAllSessions();
    await setMaxParallel(6);
    const sid = await newRunningSession({
      nodes: [
        ...nodes(3, { resources: ["desktop.input:pc-1"] }),
        { key: "s1", title: "partagée 1", role: "coder", security_level: "L1", resources: [{ key: "cpu.heavy", mode: "shared" }] },
        { key: "s2", title: "partagée 2", role: "coder", security_level: "L1", resources: [{ key: "cpu.heavy", mode: "shared" }] },
      ],
    });
    const r = await sched.lease({ runtimeId: runtimeIds[0], userId: U, slots: 6 });
    const keys = r.granted.map((g) => g.node_key).sort();
    expect(keys.filter((k) => k?.startsWith("t")).length).toBe(1);
    expect(keys).toContain("s1");
    expect(keys).toContain("s2");
    expect(r.skipped_resources).toBe(2);
    const leases = await pool.query("SELECT resource_key, mode FROM soulbah.resource_leases rl JOIN soulbah.tasks t ON t.id = rl.holder_task_id WHERE t.session_id = $1 ORDER BY resource_key", [sid]);
    expect(leases.rows.map((l) => l.resource_key)).toEqual(["cpu.heavy", "cpu.heavy", "desktop.input:pc-1"]);
  });

  it("reaper : bail expiré → RETRYING (backoff) → READY ; reprises épuisées → FAILED ; relance manuelle", async () => {
    await cancelAllSessions();
    await setMaxParallel(6);
    const sid = await newRunningSession({ nodes: [{ key: "x", title: "x", role: "coder", security_level: "L1", max_retries: 1 }] });
    const l = await sched.lease({ runtimeId: runtimeIds[0], userId: U, slots: 1 });
    const id = l.granted[0].id;
    await pool.query("UPDATE soulbah.tasks SET lease_expires_at = now() - interval '1 second' WHERE id = $1", [id]);
    const t1 = await sched.tick();
    expect(t1.reaped).toBe(1);
    let row = (await pool.query("SELECT status, retry_count, attempt, next_attempt_at, lease_owner FROM soulbah.tasks WHERE id = $1", [id])).rows[0];
    expect(row).toMatchObject({ status: "RETRYING", retry_count: 1, attempt: 1, lease_owner: null });
    expect(row.next_attempt_at).not.toBeNull();
    expect((await pool.query("SELECT count(*)::int AS n FROM soulbah.resource_leases WHERE holder_task_id = $1", [id])).rows[0].n).toBe(0);
    // Backoff non écoulé : reste RETRYING ; écoulé : READY ; nouveau bail → attempt 2.
    expect((await sched.tick()).retried).toBe(0);
    await pool.query("UPDATE soulbah.tasks SET next_attempt_at = now() - interval '1 second' WHERE id = $1", [id]);
    expect((await sched.tick()).retried).toBe(1);
    const l2 = await sched.lease({ runtimeId: runtimeIds[1], userId: U, slots: 1 });
    expect(l2.granted[0]?.attempt).toBe(2);
    // Deuxième expiration : max_retries = 1 atteint → FAILED, puis relance manuelle → READY.
    await pool.query("UPDATE soulbah.tasks SET lease_expires_at = now() - interval '1 second' WHERE id = $1", [id]);
    await sched.tick();
    row = (await pool.query("SELECT status FROM soulbah.tasks WHERE id = $1", [id])).rows[0];
    expect(row.status).toBe("FAILED");
    const s = await app.inject({ method: "GET", url: `/api/v2/sessions/${sid}`, headers: jwt });
    expect(s.json().session.status).toBe("FAILED");
    const retry = await app.inject({ method: "POST", url: `/api/v2/tasks/${id}/retry`, headers: jwt });
    expect(retry.statusCode).toBe(200);
    expect(retry.json().task.status).toBe("READY");
  });

  it("bus : QUESTION → WAITING → réponse → RUNNING ; EVIDENCE ; REVIEW_REQUEST ; BLOCKER ; ERROR → RETRYING", async () => {
    await cancelAllSessions();
    const sid = await newRunningSession({ nodes: nodes(3) });
    const l = await sched.lease({ runtimeId: runtimeIds[0], userId: U, slots: 3 });
    const [a, b, c] = l.granted;
    const rt = { runtime_id: runtimeIds[0], attempt: 1 };
    const msg = (taskId: string, type: string, payload: Record<string, unknown>) =>
      app.inject({ method: "POST", url: `/api/v2/runtime/tasks/${taskId}/message`, headers: agent, payload: { ...rt, type, payload } });

    expect((await msg(a.id, "QUESTION", { question: "Quel dossier ?" })).json().status).toBe("WAITING");
    expect((await app.inject({ method: "POST", url: `/api/v2/tasks/${a.id}/answer`, headers: jwt, payload: { answer: "C:\\w" } })).json().task.status).toBe("RUNNING");
    const ka = await app.inject({ method: "POST", url: "/api/v2/runtime/keepalive", headers: agent, payload: { runtime_id: runtimeIds[0], tasks: [{ task_id: a.id, attempt: 1 }] } });
    expect(ka.json().tasks[0].answers[0]).toMatchObject({ question: "Quel dossier ?", answer: "C:\\w" });

    expect((await msg(a.id, "EVIDENCE", { kind: "exit_code", confidence: "high", value: 0 })).json().effect).toBe("preuve rattachée");
    const rr = await msg(a.id, "REVIEW_REQUEST", { summary: "relire" });
    expect(rr.json().effect).toContain("qa_reviewer");
    const review = await pool.query("SELECT status, role, parent_task_id FROM soulbah.tasks WHERE session_id = $1 AND role = 'qa_reviewer'", [sid]);
    expect(review.rows[0]).toMatchObject({ status: "PENDING", parent_task_id: a.id });

    expect((await msg(b.id, "BLOCKER", { reason: "conflit git" })).json().status).toBe("BLOCKED");
    expect((await msg(b.id, "ERROR", { message: "x" })).statusCode).toBe(409); // plus de bail actif sur une tâche BLOCKED
    // Une tâche RUNNING qui remonte une erreur rejouable passe en RETRYING.
    const res = await app.inject({ method: "POST", url: `/api/v2/runtime/tasks/${a.id}/result`, headers: agent, payload: { ...rt, result: { summary: "fini" } } });
    expect(res.json().status).toBe("COMPLETED");
    await sched.tick();
    expect((await pool.query("SELECT status FROM soulbah.tasks WHERE session_id = $1 AND role = 'qa_reviewer'", [sid])).rows[0].status).toBe("READY");
    // LOT 10 : la relecture qa_reviewer n'est JAMAIS confiée à un runtime — P1 l'exécute.
    const l3 = await sched.lease({ runtimeId: runtimeIds[0], userId: U, slots: 6 });
    expect(l3.granted.some((g) => g.role === "qa_reviewer")).toBe(false);
    const { runReviews } = await import("../../src/v2/evaluation/reviewer");
    expect((await runReviews()).reviewed).toBe(1);
    const reviewRow = (await pool.query("SELECT id, status, result FROM soulbah.tasks WHERE session_id = $1 AND role = 'qa_reviewer'", [sid])).rows[0];
    expect(reviewRow.status).toBe("COMPLETED");
    expect((reviewRow.result as { approved: boolean }).approved).toBe(true);
    const rres = await pool.query("SELECT payload FROM soulbah.messages WHERE task_id = $1 AND type = 'REVIEW_RESULT'", [reviewRow.id]);
    expect(rres.rows[0].payload).toMatchObject({ review_of: a.id, approved: true, evaluation_verdict: "success" });
    // Une tâche RUNNING qui remonte une erreur rejouable passe en RETRYING.
    const err = await msg(c.id, "ERROR", { kind: "crash", message: "boum" });
    expect(err.statusCode, err.body).toBe(200);
    expect(err.json().status).toBe("RETRYING");
    const refused = await msg(b.id, "ERROR", { kind: "policy_refused" });
    expect(refused.statusCode).toBe(409);
  });

  it("flux SSE : instantané de session cohérent", async () => {
    const { loadSnapshot, snapshotDigest } = await import("../../src/v2/routes/stream");
    const { rows } = await pool.query("SELECT id FROM soulbah.sessions WHERE user_id = $1 ORDER BY created_at DESC LIMIT 1", [U]);
    const snap = await loadSnapshot(U, rows[0].id as string);
    expect(snap).not.toBeNull();
    expect(snap!.tasks.length).toBeGreaterThan(0);
    expect(snapshotDigest(snap!)).toMatch(/^[0-9a-f]{40}$/);
    expect((await app.inject({ method: "GET", url: "/api/v2/stream?session_id=pas-un-uuid", headers: jwt })).statusCode).toBe(400);
    expect((await app.inject({ method: "GET", url: `/api/v2/stream?session_id=${U}`, headers: jwt })).statusCode).toBe(404);
  });
});
