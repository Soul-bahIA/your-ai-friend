// LOT 6 — routes /api/v2/approvals et /api/v2/audit (base simulée).
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { fakeDb } from "./helpers/fakeDb";

process.env.SOULBAH_ENV = "test";
process.env.SOULBAH_APPROVAL_SECRET = "s".repeat(40);

vi.mock("../src/db.js", async () => (await import("./helpers/fakeDb")).dbMock);
vi.mock("../src/auth.js", async (importOriginal) => (await import("./helpers/authMock")).mockAuth(await importOriginal()));

const { buildApp } = await import("../src/app");
const { createApprovalToken, payloadSha256, tokenHash } = await import("../src/v2/security/approvals");

const U = "22222222-2222-4222-8222-222222222222";
const K = "33333333-3333-4333-8333-333333333333";
const P = "55555555-5555-4555-8555-555555555555";
const user = { "x-test-user": U };
const agent = { "x-test-agent-user": U, "x-test-agent-key": K };
const payload = { type: "type_text", text: "bonjour le monde", window_title: "Bloc-notes" };
const sha = payloadSha256(payload);
const future = new Date(Date.now() + 600_000).toISOString();

function row(over: Record<string, unknown> = {}) {
  return {
    id: P,
    user_id: U,
    kind: "request",
    security_level: "L2",
    scope: { tool: "type_text", summary: "taper bonjour", v1_task_id: null, attempt: 0, step_index: 1 },
    payload_sha256: sha,
    payload_presented: payload,
    status: "pending",
    decided_by: null,
    decided_at: null,
    expires_at: future,
    token_hash: null,
    created_at: new Date().toISOString(),
    ...over,
  };
}

let app: FastifyInstance;
beforeAll(async () => {
  app = await buildApp({ mediaDir: path.join(os.tmpdir(), "soulbah-approvals-media") });
});
afterAll(async () => {
  await app.close();
});
beforeEach(() => {
  fakeDb.reset();
  fakeDb.on(/INSERT INTO soulbah\.audit_logs/, { rows: [{ seq: 1, row_hash: "a".repeat(64) }] });
});

describe("POST /api/v2/approvals/request (clé agent)", () => {
  it("validation : outil inconnu, niveau, payload", async () => {
    const bad = (body: unknown) => app.inject({ method: "POST", url: "/api/v2/approvals/request", headers: agent, payload: body as object });
    expect((await bad({ tool: "format_disk", level: "L2", payload })).statusCode).toBe(400);
    expect((await bad({ tool: "type_text", level: "L1", payload })).statusCode).toBe(400);
    expect((await bad({ tool: "type_text", level: "L2", payload: "x" })).statusCode).toBe(400);
    expect((await bad({ tool: "type_text", level: "L2", payload, inconnu: 1 })).statusCode).toBe(400);
    expect((await bad({ tool: "type_text", level: "L2", payload, task_id: "pas-un-uuid" })).statusCode).toBe(400);
    expect((await app.inject({ method: "POST", url: "/api/v2/approvals/request", payload: {} })).statusCode).toBe(401);
    expect(fakeDb.find(/INSERT INTO soulbah\.permissions/).length).toBe(0);
  });

  it("chemin interdit (deny-list) → 403 sans demande, refus audité", async () => {
    const r = await app.inject({
      method: "POST",
      url: "/api/v2/approvals/request",
      headers: agent,
      payload: { tool: "write_file", level: "L2", payload: { type: "write_file", path: "C:\\w\\.env", content: "x" } },
    });
    expect(r.statusCode).toBe(403);
    expect(r.json().reason).toContain(".env");
    expect(fakeDb.find(/INSERT INTO soulbah\.permissions/).length).toBe(0);
    expect(fakeDb.find(/INSERT INTO soulbah\.audit_logs/)[0].values).toContain("permission.refused");
  });

  it("201 pending : empreinte, payload présenté rédigé, audit dans la transaction", async () => {
    fakeDb.on(/INSERT INTO soulbah\.permissions/, (_sql, values) => ({ rows: [row({ status: "pending", payload_presented: JSON.parse(String(values[4])) })] }));
    const secretPayload = { ...payload, text: "mot de passe : password=SuperSecret123" };
    const r = await app.inject({
      method: "POST",
      url: "/api/v2/approvals/request",
      headers: agent,
      payload: { task_id: "11111111-1111-4111-8111-111111111111", attempt: 0, step_index: 1, tool: "type_text", level: "L2", payload: secretPayload, summary: "taper", ttl_s: 5 },
    });
    expect(r.statusCode).toBe(201);
    expect(r.json()).toMatchObject({ status: "pending", payload_sha256: payloadSha256(secretPayload) });
    const ins = fakeDb.find(/INSERT INTO soulbah\.permissions/)[0];
    expect(ins.values[1]).toBe("L2");
    expect(JSON.parse(String(ins.values[2]))).toMatchObject({ tool: "type_text", v1_task_id: "11111111-1111-4111-8111-111111111111", step_index: 1, agent_key_id: K });
    expect(String(ins.values[4])).not.toContain("SuperSecret123"); // présenté rédigé
    expect(ins.values[5]).toBe(30); // ttl borné à 30 s minimum
    expect(fakeDb.find(/INSERT INTO soulbah\.audit_logs/)[0].values).toContain("permission.requested");
  });
});

describe("GET /api/v2/approvals/:id et verify (clé agent)", () => {
  it("pending → statut sans jeton ; approuvée → jeton recalculé si le hash correspond ; hash différent → revoked", async () => {
    fakeDb.on(/FROM soulbah\.permissions WHERE id/, { rows: [row()] });
    let r = await app.inject({ method: "GET", url: `/api/v2/approvals/${P}`, headers: agent });
    expect(r.json()).toMatchObject({ id: P, status: "pending" });
    expect(r.json().token).toBeUndefined();

    const token = createApprovalToken({ id: P, payloadSha256: sha, expiresAt: new Date(future), level: "L2" });
    fakeDb.on(/FROM soulbah\.permissions WHERE id/, { rows: [row({ status: "approved", decided_at: future, token_hash: tokenHash(token) })] });
    r = await app.inject({ method: "GET", url: `/api/v2/approvals/${P}`, headers: agent });
    expect(r.json()).toMatchObject({ status: "approved", token });

    fakeDb.on(/FROM soulbah\.permissions WHERE id/, { rows: [row({ status: "approved", decided_at: future, token_hash: "0".repeat(64) })] });
    r = await app.inject({ method: "GET", url: `/api/v2/approvals/${P}`, headers: agent });
    expect(r.json().status).toBe("revoked");
    expect(r.json().token).toBeUndefined();

    // expirée paresseusement
    fakeDb.on(/FROM soulbah\.permissions WHERE id/, { rows: [row({ expires_at: new Date(Date.now() - 1000).toISOString() })] });
    fakeDb.on(/UPDATE soulbah\.permissions SET status = 'expired' WHERE id/, { rows: [row({ status: "expired", expires_at: new Date(Date.now() - 1000).toISOString() })] });
    r = await app.inject({ method: "GET", url: `/api/v2/approvals/${P}`, headers: agent });
    expect(r.json().status).toBe("expired");

    fakeDb.on(/FROM soulbah\.permissions WHERE id/, { rows: [] });
    expect((await app.inject({ method: "GET", url: `/api/v2/approvals/${P}`, headers: agent })).statusCode).toBe(404);
  });

  it("verify : ok pour le payload exact, payload_mismatch, signature, statut non approuvé, hash révoqué", async () => {
    const token = createApprovalToken({ id: P, payloadSha256: sha, expiresAt: new Date(future), level: "L2" });
    fakeDb.on(/FROM soulbah\.permissions WHERE id/, { rows: [row({ status: "approved", decided_at: future, token_hash: tokenHash(token) })] });
    const verify = (body: unknown) => app.inject({ method: "POST", url: "/api/v2/approvals/verify", headers: agent, payload: body as object });
    expect((await verify({ token, payload })).json()).toEqual({ ok: true, approval_id: P, level: "L2" });
    expect((await verify({ token, payload: { ...payload, text: "autre" } })).json()).toEqual({ ok: false, reason: "payload_mismatch" });
    expect((await verify({ token: token.slice(0, -2) + "00", payload })).json()).toEqual({ ok: false, reason: "signature" });
    expect((await verify({ token: "nimporte", payload })).json()).toEqual({ ok: false, reason: "malformed" });
    expect((await verify({ payload })).statusCode).toBe(400);
    fakeDb.on(/FROM soulbah\.permissions WHERE id/, { rows: [row({ status: "denied", decided_at: future })] });
    expect((await verify({ token, payload })).json()).toEqual({ ok: false, reason: "denied" });
    fakeDb.on(/FROM soulbah\.permissions WHERE id/, { rows: [row({ status: "approved", decided_at: future, token_hash: "1".repeat(64) })] });
    expect((await verify({ token, payload })).json()).toEqual({ ok: false, reason: "revoked" });
    fakeDb.on(/FROM soulbah\.permissions WHERE id/, { rows: [] });
    expect((await verify({ token, payload })).json()).toEqual({ ok: false, reason: "unknown" });
  });
});

describe("boîte de réception (JWT)", () => {
  it("liste pending par défaut (expiration paresseuse d'abord), DTO complet, filtres", async () => {
    fakeDb.on(/FROM soulbah\.permissions WHERE user_id/, { rows: [row()] });
    const r = await app.inject({ method: "GET", url: "/api/v2/approvals", headers: user });
    expect(r.statusCode).toBe(200);
    expect(r.json().approvals[0]).toMatchObject({ id: P, status: "pending", security_level: "L2", tool: "type_text", summary: "taper bonjour", step_index: 1, payload_sha256: sha, payload_presented: payload });
    expect(fakeDb.find(/SET status = 'expired' WHERE user_id/).length).toBe(1);
    expect((await app.inject({ method: "GET", url: "/api/v2/approvals?status=nimporte", headers: user })).statusCode).toBe(400);
    expect((await app.inject({ method: "GET", url: "/api/v2/approvals?status=all", headers: user })).statusCode).toBe(200);
    expect((await app.inject({ method: "GET", url: "/api/v2/approvals" })).statusCode).toBe(401);
  });

  it("approve : empreinte obligatoire et identique ; 409 sinon ; UPDATE + audit", async () => {
    fakeDb.on(/FROM soulbah\.permissions WHERE id/, { rows: [row()] });
    expect((await app.inject({ method: "POST", url: `/api/v2/approvals/${P}/approve`, headers: user, payload: {} })).statusCode).toBe(400);
    const mismatch = await app.inject({ method: "POST", url: `/api/v2/approvals/${P}/approve`, headers: user, payload: { payload_sha256: "0".repeat(64) } });
    expect(mismatch.statusCode).toBe(409);
    expect(fakeDb.find(/SET status = 'approved'/).length).toBe(0);

    fakeDb.on(/SET status = 'approved'/, (_sql, values) => ({ rows: [row({ status: "approved", decided_at: future, token_hash: values[2] })] }));
    const ok = await app.inject({ method: "POST", url: `/api/v2/approvals/${P}/approve`, headers: user, payload: { payload_sha256: sha } });
    expect(ok.statusCode).toBe(200);
    expect(ok.json()).toMatchObject({ id: P, status: "approved" });
    const upd = fakeDb.find(/SET status = 'approved'/)[0];
    expect(upd.values[1]).toBe(U);
    const expectedToken = createApprovalToken({ id: P, payloadSha256: sha, expiresAt: new Date(future), level: "L2" });
    expect(upd.values[2]).toBe(tokenHash(expectedToken));
    expect(fakeDb.find(/INSERT INTO soulbah\.audit_logs/).some((c) => c.values.includes("permission.approved"))).toBe(true);

    fakeDb.on(/FROM soulbah\.permissions WHERE id/, { rows: [row({ status: "approved", decided_at: future })] });
    expect((await app.inject({ method: "POST", url: `/api/v2/approvals/${P}/approve`, headers: user, payload: { payload_sha256: sha } })).statusCode).toBe(409);
  });

  it("deny : motif conservé, audité ; déjà décidée → 409 ; inexistante → 404", async () => {
    fakeDb.on(/SET status = 'denied'/, { rows: [row({ status: "denied", decided_at: future, scope: { tool: "type_text", reason: "non" } })] });
    const r = await app.inject({ method: "POST", url: `/api/v2/approvals/${P}/deny`, headers: user, payload: { reason: "non" } });
    expect(r.json()).toEqual({ id: P, status: "denied" });
    expect(fakeDb.find(/SET status = 'denied'/)[0].values[2]).toBe("non");
    expect(fakeDb.find(/INSERT INTO soulbah\.audit_logs/).some((c) => c.values.includes("permission.denied"))).toBe(true);

    fakeDb.on(/SET status = 'denied'/, { rows: [] });
    fakeDb.on(/FROM soulbah\.permissions WHERE id/, { rows: [row({ status: "approved", decided_at: future })] });
    expect((await app.inject({ method: "POST", url: `/api/v2/approvals/${P}/deny`, headers: user, payload: {} })).statusCode).toBe(409);
    fakeDb.on(/FROM soulbah\.permissions WHERE id/, { rows: [] });
    expect((await app.inject({ method: "POST", url: `/api/v2/approvals/${P}/deny`, headers: user, payload: {} })).statusCode).toBe(404);
  });
});

describe("audit (JWT)", () => {
  it("verify et liste", async () => {
    fakeDb.on(/verify_audit_chain/, { rows: [{ ok: true, checked: "3", broken_at: null }] });
    const v = await app.inject({ method: "GET", url: "/api/v2/audit/verify", headers: user });
    expect(v.json()).toEqual({ ok: true, checked: 3, broken_at: null });
    fakeDb.on(/FROM soulbah\.audit_logs WHERE user_id/, { rows: [{ seq: "9", action: "permission.approved", actor: `user:${U}`, entity: "permission", entity_id: P, session_id: null, task_id: null, data: {}, created_at: future }] });
    const l = await app.inject({ method: "GET", url: "/api/v2/audit?limit=5", headers: user });
    expect(l.json().entries[0]).toMatchObject({ seq: 9, action: "permission.approved" });
    expect(fakeDb.find(/FROM soulbah\.audit_logs WHERE user_id/)[0].sql).toContain("LIMIT 5");
    expect((await app.inject({ method: "GET", url: "/api/v2/audit?session_id=x", headers: user })).statusCode).toBe(400);
    expect((await app.inject({ method: "GET", url: "/api/v2/audit/verify" })).statusCode).toBe(401);
  });
});
