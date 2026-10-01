// LOT 6 — flux complet d'approbation et audit chaîné sur un VRAI Postgres (schéma LOT 4) :
// demande (clé agent) → boîte de réception (JWT dev) → approbation liée à l'empreinte →
// jeton HMAC → vérification → chaîne d'audit valide, altération détectée. Sauté sans TEST_DATABASE_URL.
import { randomBytes } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";

const DB_URL = (process.env.TEST_DATABASE_URL ?? "").trim();
const RUN = DB_URL !== "";
const TOKEN = randomBytes(32).toString("hex");
const U = "a0000000-0000-4000-8000-0000000000c6";
const CANARY = "SOULBAH_CANARY_PG_" + randomBytes(6).toString("hex");
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
  process.env.SOULBAH_REDACT_VALUES = CANARY;
  process.env.IA_SERVICE_URL = "http://127.0.0.1:9";
}

type Pool = { query: (sql: string, values?: unknown[]) => Promise<{ rows: Record<string, unknown>[]; rowCount: number | null }>; end: () => Promise<void> };

describe.skipIf(!RUN)("approbations HMAC et audit chaîné sur Postgres réel", () => {
  let app: FastifyInstance;
  let pool: Pool;
  let payloadSha256: (p: unknown) => string;
  const jwt = { authorization: `Bearer ${TOKEN}` };
  const rawKey = "sbk_" + randomBytes(32).toString("hex");
  const agent = { "x-agent-key": rawKey };
  const payload = { type: "type_text", text: `taper ${CANARY} puis Entrée`, window_title: "Bloc-notes" };
  let approvalId = "";
  let token = "";
  let firstSeq = 0;

  beforeAll(async () => {
    ({ pool } = (await import("../../src/db")) as unknown as { pool: Pool });
    const { hashKey } = await import("../../src/services/agentKeys");
    ({ payloadSha256 } = await import("../../src/v2/security/approvals"));
    const { buildApp } = await import("../../src/app");
    app = await buildApp({ mediaDir: path.join(os.tmpdir(), "soulbah-pg-approvals-media") });
    await pool.query("INSERT INTO auth.users (id, email) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING", [U, "approvals@soulbah.local"]);
    await pool.query("INSERT INTO agent_keys (user_id, key_hash, label, allowed_dirs) VALUES ($1, $2, 'PC approbations', '[]'::jsonb)", [U, hashKey(rawKey)]);
    const { rows } = await pool.query("SELECT coalesce(max(seq), 0) AS m FROM soulbah.audit_logs");
    firstSeq = Number(rows[0].m);
  });

  afterAll(async () => {
    await pool.query("DELETE FROM soulbah.permissions WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM agent_keys WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM user_roles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM profiles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM auth.users WHERE id = $1", [U]);
    await app.close();
    await pool.end();
  });

  it("l'agent demande une approbation L2 : 201, ligne pending, payload présenté SANS le canari, audit écrit", async () => {
    const r = await app.inject({
      method: "POST",
      url: "/api/v2/approvals/request",
      headers: agent,
      payload: { task_id: null, attempt: 0, step_index: 2, tool: "type_text", level: "L2", payload, summary: "taper du texte", ttl_s: 120 },
    });
    expect(r.statusCode).toBe(201);
    approvalId = r.json().id;
    expect(r.json().payload_sha256).toBe(payloadSha256(payload));
    const { rows } = await pool.query("SELECT status, security_level, kind, scope, payload_presented, payload_sha256 FROM soulbah.permissions WHERE id = $1", [approvalId]);
    expect(rows[0]).toMatchObject({ status: "pending", security_level: "L2", kind: "request" });
    expect((rows[0].scope as { tool: string; step_index: number }).step_index).toBe(2);
    expect(JSON.stringify(rows[0].payload_presented)).not.toContain(CANARY);
    expect(JSON.stringify(rows[0].payload_presented)).toContain("[secret masqué]");
    const audit = await pool.query("SELECT action, data FROM soulbah.audit_logs WHERE entity_id = $1 ORDER BY seq", [approvalId]);
    expect(audit.rows.map((a) => a.action)).toEqual(["permission.requested"]);
    expect(JSON.stringify(audit.rows)).not.toContain(CANARY);
  });

  it("l'utilisateur la voit dans sa boîte ; l'agent n'a pas encore de jeton", async () => {
    const list = await app.inject({ method: "GET", url: "/api/v2/approvals", headers: jwt });
    expect(list.statusCode).toBe(200);
    const mine = (list.json().approvals as { id: string; tool: string; status: string }[]).find((a) => a.id === approvalId);
    expect(mine).toMatchObject({ tool: "type_text", status: "pending" });
    const st = await app.inject({ method: "GET", url: `/api/v2/approvals/${approvalId}`, headers: agent });
    expect(st.json()).toMatchObject({ status: "pending" });
    expect(st.json().token).toBeUndefined();
  });

  it("approbation : empreinte différente → 409 ; empreinte affichée → approuvée, jeton disponible pour l'agent", async () => {
    const bad = await app.inject({ method: "POST", url: `/api/v2/approvals/${approvalId}/approve`, headers: jwt, payload: { payload_sha256: "0".repeat(64) } });
    expect(bad.statusCode).toBe(409);
    const ok = await app.inject({ method: "POST", url: `/api/v2/approvals/${approvalId}/approve`, headers: jwt, payload: { payload_sha256: payloadSha256(payload) } });
    expect(ok.statusCode).toBe(200);
    expect(ok.json().status).toBe("approved");
    const st = await app.inject({ method: "GET", url: `/api/v2/approvals/${approvalId}`, headers: agent });
    expect(st.json().status).toBe("approved");
    token = st.json().token;
    expect(token).toMatch(/^sbap_/);
    // Rejouer l'approbation → 409 ; la décision est auditée dans la même transaction.
    expect((await app.inject({ method: "POST", url: `/api/v2/approvals/${approvalId}/approve`, headers: jwt, payload: { payload_sha256: payloadSha256(payload) } })).statusCode).toBe(409);
    const audit = await pool.query("SELECT action FROM soulbah.audit_logs WHERE entity_id = $1 ORDER BY seq", [approvalId]);
    expect(audit.rows.map((a) => a.action)).toEqual(["permission.requested", "permission.approved"]);
  });

  it("vérification : payload exact → ok ; payload modifié → payload_mismatch ; jeton altéré → signature", async () => {
    const verify = (body: object) => app.inject({ method: "POST", url: "/api/v2/approvals/verify", headers: agent, payload: body });
    expect((await verify({ token, payload })).json()).toEqual({ ok: true, approval_id: approvalId, level: "L2" });
    expect((await verify({ token, payload: { ...payload, text: "autre texte" } })).json()).toEqual({ ok: false, reason: "payload_mismatch" });
    expect((await verify({ token: token.slice(0, -1) + (token.endsWith("0") ? "1" : "0"), payload })).json()).toEqual({ ok: false, reason: "signature" });
  });

  it("refus et expiration : une demande refusée n'a jamais de jeton ; une demande échue devient expired", async () => {
    const r2 = await app.inject({ method: "POST", url: "/api/v2/approvals/request", headers: agent, payload: { tool: "run_command", level: "L3", payload: { type: "run_command", command: "npm", args: ["test"] } } });
    expect(r2.statusCode).toBe(201);
    const denied = await app.inject({ method: "POST", url: `/api/v2/approvals/${r2.json().id}/deny`, headers: jwt, payload: { reason: "pas maintenant" } });
    expect(denied.json().status).toBe("denied");
    const st = await app.inject({ method: "GET", url: `/api/v2/approvals/${r2.json().id}`, headers: agent });
    expect(st.json()).toMatchObject({ status: "denied", reason: "pas maintenant" });

    const r3 = await app.inject({ method: "POST", url: "/api/v2/approvals/request", headers: agent, payload: { tool: "hotkey", level: "L2", payload: { type: "hotkey", keys: ["ctrl", "s"] }, ttl_s: 30 } });
    await pool.query("UPDATE soulbah.permissions SET expires_at = now() - interval '1 second' WHERE id = $1", [r3.json().id]);
    const exp = await app.inject({ method: "GET", url: `/api/v2/approvals/${r3.json().id}`, headers: agent });
    expect(exp.json().status).toBe("expired");
    expect((await app.inject({ method: "POST", url: `/api/v2/approvals/${r3.json().id}/approve`, headers: jwt, payload: { payload_sha256: r3.json().payload_sha256 } })).statusCode).toBe(409);
  });

  it("deny-list : une écriture sur .env est refusée à la demande (403), et auditée", async () => {
    // L'audit est immuable (jamais purgé) : comptage relatif, pas absolu.
    const before = Number((await pool.query("SELECT count(*) AS n FROM soulbah.audit_logs WHERE user_id = $1 AND action = 'permission.refused'", [U])).rows[0].n);
    const r = await app.inject({ method: "POST", url: "/api/v2/approvals/request", headers: agent, payload: { tool: "write_file", level: "L2", payload: { type: "write_file", path: "C:\\w\\.env", content: "x" } } });
    expect(r.statusCode).toBe(403);
    const { rows } = await pool.query("SELECT count(*) AS n FROM soulbah.audit_logs WHERE user_id = $1 AND action = 'permission.refused'", [U]);
    expect(Number(rows[0].n)).toBe(before + 1);
  });

  it("chaîne d'audit : valide, puis altération d'une ligne détectée (broken_at)", async () => {
    const ok = await app.inject({ method: "GET", url: "/api/v2/audit/verify", headers: jwt });
    expect(ok.json().ok).toBe(true);
    expect(ok.json().checked).toBeGreaterThan(firstSeq);
    const list = await app.inject({ method: "GET", url: "/api/v2/audit?limit=20", headers: jwt });
    expect((list.json().entries as { action: string }[]).map((e) => e.action)).toContain("permission.approved");

    // Altération « hors triggers » dans une transaction annulée : verify_audit_chain la voit.
    const client = await (pool as unknown as { connect: () => Promise<{ query: Pool["query"]; release: () => void }> }).connect();
    try {
      await client.query("BEGIN");
      await client.query("SET LOCAL session_replication_role = replica");
      const target = await client.query("SELECT seq FROM soulbah.audit_logs WHERE user_id = $1 ORDER BY seq LIMIT 1", [U]);
      const seq = Number(target.rows[0].seq);
      await client.query("UPDATE soulbah.audit_logs SET data = '{\"altered\":true}'::jsonb WHERE seq = $1", [seq]);
      const v = await client.query("SELECT ok, broken_at FROM soulbah.verify_audit_chain()");
      expect(v.rows[0].ok).toBe(false);
      expect(Number(v.rows[0].broken_at)).toBe(seq);
      await client.query("ROLLBACK");
    } finally {
      client.release();
    }
    expect((await app.inject({ method: "GET", url: "/api/v2/audit/verify", headers: jwt })).json().ok).toBe(true);
  });

  it("canari : absent des lignes agent_events / agent_tasks écrites par les routes V1", async () => {
    // Tâche V1 réclamée par cette clé, puis évènement et rapport final contenant le canari.
    const task = await pool.query(
      "INSERT INTO agent_tasks (user_id, task_type, status, claimed_by_key_id, payload) SELECT $1, 'goal', 'in_progress', id, '{\"steps\":[]}'::jsonb FROM agent_keys WHERE user_id = $1 LIMIT 1 RETURNING id",
      [U],
    );
    const taskId = task.rows[0].id as string;
    const ev = await app.inject({ method: "POST", url: "/api/agent-tasks/event", headers: agent, payload: { task_id: taskId, type: "step_done", attempt: 0, message: `tapé ${CANARY}`, data: { typed: CANARY, note: "ok" } } });
    expect(ev.statusCode).toBe(200);
    const fin = await app.inject({ method: "POST", url: "/api/agent-tasks/update", headers: agent, payload: { task_id: taskId, status: "completed", attempt: 0, result: { summary: `secret ${CANARY}`, password: "x" } } });
    expect(fin.statusCode).toBe(200);
    const events = await pool.query("SELECT message, data FROM agent_events WHERE task_id = $1", [taskId]);
    const stored = await pool.query("SELECT result FROM agent_tasks WHERE id = $1", [taskId]);
    expect(JSON.stringify(events.rows)).not.toContain(CANARY);
    expect(JSON.stringify(stored.rows)).not.toContain(CANARY);
    expect((stored.rows[0].result as { password: string }).password).toBe("[secret masqué]");
    await pool.query("DELETE FROM agent_events WHERE task_id = $1", [taskId]);
    await pool.query("DELETE FROM agent_tasks WHERE id = $1", [taskId]);
  });
});
