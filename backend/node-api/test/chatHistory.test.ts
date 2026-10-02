// V3 — historique du chat via node-api (base locale, sans Supabase dans le navigateur).
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { fakeDb } from "./helpers/fakeDb";

process.env.SOULBAH_ENV = "test";
vi.mock("../src/db.js", async () => (await import("./helpers/fakeDb")).dbMock);
vi.mock("../src/auth.js", async (importOriginal) => (await import("./helpers/authMock")).mockAuth(await importOriginal()));

const { buildApp } = await import("../src/app");
const U = "22222222-2222-4222-8222-222222222222";
const C = "33333333-3333-4333-8333-333333333333";
const user = { "x-test-user": U };
let app: FastifyInstance;

beforeAll(async () => {
  app = await buildApp({ mediaDir: path.join(os.tmpdir(), "soulbah-chat-media") });
});
afterAll(async () => {
  await app.close();
});
beforeEach(() => fakeDb.reset());

describe("/api/chat/conversations", () => {
  it("liste les conversations de l'utilisateur seulement", async () => {
    fakeDb.on(/FROM chat_conversations WHERE user_id/, { rows: [{ id: C, title: "Bonjour", created_at: "2026-10-01" }] });
    const r = await app.inject({ method: "GET", url: "/api/chat/conversations", headers: user });
    expect(r.statusCode).toBe(200);
    expect(r.json().conversations).toHaveLength(1);
    expect(fakeDb.find(/FROM chat_conversations WHERE user_id/)[0].values).toEqual([U]);
  });

  it("crée une conversation (titre requis, borné)", async () => {
    fakeDb.on(/INSERT INTO chat_conversations/, { rows: [{ id: C, title: "x", created_at: "2026-10-01" }] });
    expect((await app.inject({ method: "POST", url: "/api/chat/conversations", headers: user, payload: {} })).statusCode).toBe(400);
    const r = await app.inject({ method: "POST", url: "/api/chat/conversations", headers: user, payload: { title: "t".repeat(500) } });
    expect(r.statusCode).toBe(201);
    expect((fakeDb.find(/INSERT INTO chat_conversations/)[0].values as string[])[1]).toHaveLength(200);
  });

  it("messages : conversation d'un autre compte = 404 ; enregistrement met à jour la conversation", async () => {
    fakeDb.on(/SELECT 1 FROM chat_conversations/, { rows: [], rowCount: 0 });
    expect((await app.inject({ method: "GET", url: `/api/chat/conversations/${C}/messages`, headers: user })).statusCode).toBe(404);
    fakeDb.reset();
    fakeDb.on(/UPDATE chat_conversations SET updated_at/, { rows: [{ id: C }], rowCount: 1 });
    fakeDb.on(/INSERT INTO chat_messages/, { rows: [], rowCount: 1 });
    const bad = await app.inject({ method: "POST", url: `/api/chat/conversations/${C}/messages`, headers: user, payload: { role: "system", content: "x" } });
    expect(bad.statusCode).toBe(400);
    const ok = await app.inject({ method: "POST", url: `/api/chat/conversations/${C}/messages`, headers: user, payload: { role: "assistant", content: "Bonjour" } });
    expect(ok.statusCode).toBe(201);
    expect(fakeDb.find(/INSERT INTO chat_messages/)[0].values).toEqual([C, U, "assistant", "Bonjour"]);
  });

  it("suppression limitée au propriétaire ; sans session : 401", async () => {
    fakeDb.on(/DELETE FROM chat_conversations/, { rows: [], rowCount: 0 });
    expect((await app.inject({ method: "DELETE", url: `/api/chat/conversations/${C}`, headers: user })).statusCode).toBe(404);
    expect((await app.inject({ method: "GET", url: "/api/chat/conversations" })).statusCode).toBe(401);
    expect((await app.inject({ method: "DELETE", url: "/api/chat/conversations/pas-un-uuid", headers: user })).statusCode).toBe(400);
  });
});
