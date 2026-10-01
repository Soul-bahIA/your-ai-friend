// LOT 9 — passerelle d'outils et preuves sur Postgres réel : artefacts (PUT idempotent par sha256,
// GET authentifié), 0 base64 en base, et un appel L2 sans grant : tâche en WAITING puis reprise
// UNE seule fois à l'approbation (refus → BLOCKED). Sauté sans TEST_DATABASE_URL.
import { createHash, randomBytes } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";

const DB_URL = (process.env.TEST_DATABASE_URL ?? "").trim();
const RUN = DB_URL !== "";
const TOKEN = randomBytes(32).toString("hex");
const U = "a0000000-0000-4000-8000-0000000000c9";
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
  process.env.IA_SERVICE_URL = "http://127.0.0.1:9";
}

type Pool = { query: (sql: string, values?: unknown[]) => Promise<{ rows: Record<string, unknown>[]; rowCount: number | null }>; end: () => Promise<void> };

describe.skipIf(!RUN)("passerelle d'outils et preuves (LOT 9)", () => {
  let app: FastifyInstance;
  let pool: Pool;
  let sched: typeof import("../../src/v2/scheduler/scheduler");
  const jwt = { authorization: `Bearer ${TOKEN}` };
  const rawKey = "sbk_" + randomBytes(32).toString("hex");
  const agent = { "x-agent-key": rawKey };
  const mediaDir = fs.mkdtempSync(path.join(os.tmpdir(), "soulbah-artifacts-"));
  let runtimeId = "";

  beforeAll(async () => {
    ({ pool } = (await import("../../src/db")) as unknown as { pool: Pool });
    const { hashKey } = await import("../../src/services/agentKeys");
    sched = await import("../../src/v2/scheduler/scheduler");
    const { buildApp } = await import("../../src/app");
    app = await buildApp({ mediaDir });
    await pool.query("INSERT INTO auth.users (id, email) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING", [U, "gw@soulbah.local"]);
    await pool.query("INSERT INTO agent_keys (user_id, key_hash, label, allowed_dirs) VALUES ($1, $2, 'PC gw', '[]'::jsonb)", [U, hashKey(rawKey)]);
    const reg = await app.inject({ method: "POST", url: "/api/v2/runtime/register", headers: agent, payload: { hostname: "pc", version: "2.0.0", protocol: 1, max_slots: 6 } });
    expect(reg.statusCode, reg.body).toBe(200);
    runtimeId = reg.json().runtime_id;
  });

  afterAll(async () => {
    await pool.query("DELETE FROM soulbah.sessions WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM soulbah.artifacts WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM soulbah.runtimes WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM soulbah.permissions WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM agent_keys WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM user_roles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM profiles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM auth.users WHERE id = $1", [U]);
    await app.close();
    await pool.end();
    fs.rmSync(mediaDir, { recursive: true, force: true });
  });

  it("artefact : PUT idempotent par sha256, empreinte vérifiée, GET par id ou sha (JWT et clé agent), liste", async () => {
    const content = Buffer.from("capture PNG factice " + randomBytes(16).toString("hex"));
    const sha = createHash("sha256").update(content).digest("hex");
    const put = (body: Buffer, s = sha, qs = "?kind=screenshot") =>
      app.inject({ method: "PUT", url: `/api/v2/artifacts/${s}${qs}`, headers: { ...agent, "content-type": "image/png" }, payload: body });
    expect((await put(content, "0".repeat(64))).statusCode).toBe(400); // empreinte différente
    expect((await put(content, sha, "?kind=inconnu")).statusCode).toBe(400);
    const first = await put(content);
    expect(first.statusCode).toBe(201);
    expect(first.json()).toMatchObject({ created: true, artifact: { sha256: sha, mime: "image/png", kind: "screenshot", size_bytes: String(content.length) } });
    const again = await put(content);
    expect(again.statusCode).toBe(200);
    expect(again.json().created).toBe(false);
    expect(again.json().artifact.id).toBe(first.json().artifact.id);
    expect(fs.existsSync(path.join(mediaDir, "artifacts", U, sha))).toBe(true);
    expect(Number((await pool.query("SELECT count(*)::int AS n FROM soulbah.artifacts WHERE user_id = $1 AND sha256 = $2", [U, sha])).rows[0].n)).toBe(1);

    const byId = await app.inject({ method: "GET", url: `/api/v2/artifacts/${first.json().artifact.id}`, headers: jwt });
    expect(byId.statusCode).toBe(200);
    expect(byId.headers["content-type"]).toContain("image/png");
    expect(byId.rawPayload.equals(content)).toBe(true);
    const bySha = await app.inject({ method: "GET", url: `/api/v2/artifacts/${sha}`, headers: agent });
    expect(bySha.rawPayload.equals(content)).toBe(true);
    expect((await app.inject({ method: "GET", url: `/api/v2/artifacts/${sha}?meta=1`, headers: jwt })).json().artifact.sha256).toBe(sha);
    expect((await app.inject({ method: "GET", url: `/api/v2/artifacts/${sha}` })).statusCode).toBe(401);
    expect((await app.inject({ method: "GET", url: `/api/v2/artifacts/${"1".repeat(64)}`, headers: jwt })).statusCode).toBe(404);
    const list = await app.inject({ method: "GET", url: "/api/v2/artifacts", headers: jwt });
    expect((list.json().artifacts as { sha256: string }[]).some((a) => a.sha256 === sha)).toBe(true);
    // JSON sur la route PUT → 415 (corps binaire attendu)
    expect((await app.inject({ method: "PUT", url: `/api/v2/artifacts/${sha}`, headers: agent, payload: { a: 1 } })).statusCode).toBe(415);
  });

  it("0 base64 en base : preuves et paramètres refusent les blobs ; capture = référence d'artefact", async () => {
    const s = await app.inject({
      method: "POST",
      url: "/api/v2/sessions",
      headers: jwt,
      payload: { goal: "preuves", plan: { nodes: [{ key: "shot", title: "capture", role: "desktop_operator", security_level: "L1", spec: { steps: [{ type: "screenshot" }] } }] } },
    });
    expect(s.statusCode, s.body).toBe(201);
    const ap = await app.inject({ method: "POST", url: `/api/v2/sessions/${s.json().session.id}/approve`, headers: jwt });
    expect(ap.statusCode, ap.body).toBe(200);
    await sched.tick();
    const l = await app.inject({ method: "POST", url: "/api/v2/runtime/lease", headers: agent, payload: { runtime_id: runtimeId, slots: 1 } });
    expect(l.statusCode, l.body).toBe(200);
    expect(l.json().tasks.length, l.body).toBe(1);
    const taskId = l.json().tasks[0].id as string;
    const act = (body: object) => app.inject({ method: "POST", url: `/api/v2/runtime/tasks/${taskId}/actions`, headers: agent, payload: { runtime_id: runtimeId, attempt: 1, step_index: 0, tool: "screenshot", ...body } });
    const blob = "iVBORw0KGgo" + "A".repeat(400);
    expect((await act({ status: "executed", evidence: [{ kind: "screenshot", confidence: "medium", value: blob }] })).statusCode).toBe(400);
    expect((await act({ status: "executed", evidence: [{ kind: "screenshot", confidence: "medium" }] })).statusCode).toBe(400); // artefact obligatoire
    expect((await act({ status: "executed", params: { image_b64: blob } })).statusCode).toBe(400);
    const ok = await act({ status: "executed", evidence: [{ kind: "screenshot", confidence: "medium", sha256: "b".repeat(64) }, { kind: "window_title", confidence: "medium", value: "Bloc-notes" }] });
    expect(ok.statusCode).toBe(200);
    const msg = await app.inject({ method: "POST", url: `/api/v2/runtime/tasks/${taskId}/message`, headers: agent, payload: { runtime_id: runtimeId, attempt: 1, type: "EVIDENCE", payload: { kind: "file_content", confidence: "high", value: blob } } });
    expect(msg.statusCode).toBe(400);
    const res = await app.inject({ method: "POST", url: `/api/v2/runtime/tasks/${taskId}/result`, headers: agent, payload: { runtime_id: runtimeId, attempt: 1, result: { screenshot: blob } } });
    expect(res.statusCode).toBe(400);
    // Aucune ligne de la base ne contient le blob.
    for (const t of ["soulbah.actions", "soulbah.messages", "soulbah.tasks", "soulbah.audit_logs"]) {
      const col = t === "soulbah.messages" ? "session_id" : "user_id";
      const { rows } = await pool.query(`SELECT count(*)::int AS n FROM ${t} r WHERE r.${col} = $1 AND r::text LIKE $2`, [t === "soulbah.messages" ? s.json().session.id : U, `%${blob.slice(0, 60)}%`]);
      expect(Number(rows[0].n), t).toBe(0);
    }
    const stored = await pool.query("SELECT evidence, evidence_confidence FROM soulbah.actions WHERE task_id = $1", [taskId]);
    expect((stored.rows[0].evidence as unknown[]).length).toBe(2);
    expect(stored.rows[0].evidence_confidence).toBe("medium");
  });

  it("appel L2 sans grant : la tâche passe en WAITING, reprend UNE seule fois à l'approbation ; refus → BLOCKED", async () => {
    const s = await app.inject({
      method: "POST",
      url: "/api/v2/sessions",
      headers: jwt,
      payload: { goal: "L2", plan: { nodes: [{ key: "t", title: "taper", role: "desktop_operator", security_level: "L2", spec: { steps: [{ type: "type_text", text: "bonjour" }] } }, { key: "u", title: "taper 2", role: "desktop_operator", security_level: "L2" }] } },
    });
    expect(s.statusCode, s.body).toBe(201);
    const ap = await app.inject({ method: "POST", url: `/api/v2/sessions/${s.json().session.id}/approve`, headers: jwt });
    expect(ap.statusCode, ap.body).toBe(200);
    await sched.tick();
    const l = await app.inject({ method: "POST", url: "/api/v2/runtime/lease", headers: agent, payload: { runtime_id: runtimeId, slots: 2 } });
    expect(l.statusCode, l.body).toBe(200);
    expect(l.json().tasks.length, l.body).toBe(2);
    const [a, b] = l.json().tasks as { id: string; attempt: number }[];

    const payload = { type: "type_text", text: "bonjour" };
    const req = await app.inject({ method: "POST", url: "/api/v2/approvals/request", headers: agent, payload: { v2_task_id: a.id, attempt: a.attempt, step_index: 0, tool: "type_text", level: "L2", payload } });
    expect(req.statusCode).toBe(201);
    let row = (await pool.query("SELECT status, waiting_reason FROM soulbah.tasks WHERE id = $1", [a.id])).rows[0];
    expect(row.status).toBe("WAITING");
    expect(String(row.waiting_reason)).toContain("type_text");
    // Le keepalive dit « continue » : le worker attend la décision.
    const ka = await app.inject({ method: "POST", url: "/api/v2/runtime/keepalive", headers: agent, payload: { runtime_id: runtimeId, tasks: [{ task_id: a.id, attempt: a.attempt }] } });
    expect(ka.json().tasks[0]).toMatchObject({ status: "WAITING", control: "continue" });

    const approve = await app.inject({ method: "POST", url: `/api/v2/approvals/${req.json().id}/approve`, headers: jwt, payload: { payload_sha256: req.json().payload_sha256 } });
    expect(approve.statusCode).toBe(200);
    row = (await pool.query("SELECT status, waiting_reason FROM soulbah.tasks WHERE id = $1", [a.id])).rows[0];
    expect(row).toEqual({ status: "RUNNING", waiting_reason: null });
    // Rejouer l'approbation → 409 et la tâche ne « reprend » pas une seconde fois (une seule transition WAITING → RUNNING auditée).
    expect((await app.inject({ method: "POST", url: `/api/v2/approvals/${req.json().id}/approve`, headers: jwt, payload: { payload_sha256: req.json().payload_sha256 } })).statusCode).toBe(409);
    const resumed = await pool.query("SELECT count(*)::int AS n FROM soulbah.audit_logs WHERE task_id = $1 AND action = 'task.transition' AND data ->> 'from' = 'WAITING' AND data ->> 'to' = 'RUNNING'", [a.id]);
    expect(Number(resumed.rows[0].n)).toBe(1);
    const st = await app.inject({ method: "GET", url: `/api/v2/approvals/${req.json().id}`, headers: agent });
    expect(st.json().token).toMatch(/^sbap_/);

    // Refus : la seconde tâche passe BLOCKED.
    const req2 = await app.inject({ method: "POST", url: "/api/v2/approvals/request", headers: agent, payload: { v2_task_id: b.id, attempt: b.attempt, tool: "hotkey", level: "L2", payload: { type: "hotkey", keys: ["win", "r"] } } });
    expect((await pool.query("SELECT status FROM soulbah.tasks WHERE id = $1", [b.id])).rows[0].status).toBe("WAITING");
    await app.inject({ method: "POST", url: `/api/v2/approvals/${req2.json().id}/deny`, headers: jwt, payload: { reason: "non" } });
    row = (await pool.query("SELECT status, blocked_reason FROM soulbah.tasks WHERE id = $1", [b.id])).rows[0];
    expect(row.status).toBe("BLOCKED");
    expect(String(row.blocked_reason)).toContain("refusée");
    const kb = await app.inject({ method: "POST", url: "/api/v2/runtime/keepalive", headers: agent, payload: { runtime_id: runtimeId, tasks: [{ task_id: b.id, attempt: b.attempt }] } });
    expect(kb.json().tasks[0].control).toBe("stop");
  });
});
