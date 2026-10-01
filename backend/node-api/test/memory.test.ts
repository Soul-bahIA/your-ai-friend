// Mémoire : rejets exclus, leçons générales incluses, pertinence, plafond, statut effectif.
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { fakeDb } from "./helpers/fakeDb";
import {
  GENERAL_GOAL,
  effectiveMemoryStatus,
  formatMemoryContext,
  rankMemories,
  type MemoryRow,
} from "../src/lib/memoryRanking";

vi.mock("../src/db.js", async () => (await import("./helpers/fakeDb")).dbMock);
vi.mock("../src/auth.js", async (importOriginal) => (await import("./helpers/authMock")).mockAuth(await importOriginal()));

const { buildApp } = await import("../src/app");
const { getMemoryContext } = await import("../src/routes/agentMemory");

const U = "22222222-2222-4222-8222-222222222222";
const M = "66666666-6666-4666-8666-666666666666";
const NOW = Date.parse("2026-10-01T00:00:00Z");
const validatedMeta = { validated_by: U };

const row = (over: Partial<MemoryRow>): MemoryRow => ({
  type: "solution",
  level: "workflow",
  status: "proposed",
  goal: "exporter la vidéo de démonstration",
  content: "utiliser edit_video",
  metadata: {},
  created_at: "2026-09-30T00:00:00Z",
  ...over,
});

describe("statut effectif (S11)", () => {
  it("'validated' sans validated_by (verdict LLM historique, insertion directe) = proposed", () => {
    expect(effectiveMemoryStatus({ status: "validated", metadata: {} })).toBe("proposed");
    expect(effectiveMemoryStatus({ status: "validated", metadata: validatedMeta })).toBe("validated");
    expect(effectiveMemoryStatus({ status: "rejected", metadata: validatedMeta })).toBe("rejected");
  });
});

describe("rankMemories (T11)", () => {
  it("exclut les rejets et les pratiques/optimisations non validées", () => {
    const out = rankMemories(
      "exporter la vidéo",
      [
        row({ id: "rej", status: "rejected" }),
        row({ id: "opt", type: "practice", level: "optimization", goal: GENERAL_GOAL, content: "exporter plus vite" }),
        row({ id: "ok" }),
      ],
      { now: NOW },
    );
    expect(out.map((r) => r.id)).toEqual(["ok"]);
  });

  it("inclut les leçons générales validées (plafonnées) et classe par pertinence puis validation", () => {
    const generals = [1, 2, 3, 4].map((i) =>
      row({ id: `g${i}`, type: "practice", level: "technical", goal: GENERAL_GOAL, content: `astuce ${i}`, status: "validated", metadata: validatedMeta }),
    );
    const out = rankMemories(
      "exporter la vidéo de démonstration",
      [
        row({ id: "faible", goal: "regarder une vidéo", content: "x" }),
        row({ id: "fort", goal: "exporter la vidéo de démonstration finale" }),
        row({ id: "horsujet", goal: "envoyer un mail", content: "smtp" }),
        ...generals,
      ],
      { now: NOW, maxEntries: 6, maxGeneral: 3 },
    );
    const ids = out.map((r) => r.id);
    expect(ids[0]).toBe("fort");
    expect(ids).not.toContain("horsujet");
    expect(ids.filter((i) => i!.startsWith("g"))).toHaveLength(3);
    expect(out.length).toBeLessThanOrEqual(6);
  });

  it("formatMemoryContext : marqué non fiable, étiquette validée / non vérifiée, borné", () => {
    const ctx = formatMemoryContext([
      row({ content: "y".repeat(5000) }),
      row({ type: "error", status: "validated", metadata: validatedMeta, content: "échec" }),
    ])!;
    expect(ctx).toContain("DONNÉES NON FIABLES");
    expect(ctx).toContain("non vérifiée");
    expect(ctx).toContain("validée par l'utilisateur");
    expect(ctx.length).toBeLessThan(3_500);
    expect(formatMemoryContext([])).toBeUndefined();
  });

  it("getMemoryContext : SQL sans rejets, avec les leçons générales", async () => {
    fakeDb.reset();
    fakeDb.on(/FROM agent_memory/, { rows: [row({})] });
    const ctx = await getMemoryContext(U, "exporter la vidéo");
    const q = fakeDb.calls[0];
    expect(q.sql).toContain("status <> 'rejected'");
    expect(q.sql).toContain("goal = $2 OR goal ILIKE ANY($3::text[])");
    expect(q.values[1]).toBe(GENERAL_GOAL);
    expect(ctx).toContain("SOLUTION PASSÉE");
  });
});

describe("routes mémoire (contrat §9)", () => {
  let app: FastifyInstance;
  beforeAll(async () => {
    app = await buildApp({ mediaDir: path.join(os.tmpdir(), "soulbah-test-media") });
  });
  afterAll(async () => app.close());
  beforeEach(() => fakeDb.reset());

  it("POST : proposée par défaut ; validated_by fourni par le client ignoré", async () => {
    const r = await app.inject({
      method: "POST",
      url: "/api/agent/memory",
      headers: { "x-test-user": U },
      payload: { content: "toujours sauvegarder", metadata: { validated_by: "pirate" } },
    });
    expect(r.json()).toEqual({ success: true, status: "proposed" });
    const ins = fakeDb.find(/INSERT INTO agent_memory/)[0];
    expect(ins.values[6]).toBe("proposed");
    expect(ins.values[4]).toBe("{}");
  });

  it("PATCH validated : trace validated_by (action explicite de l'utilisateur)", async () => {
    fakeDb.on(/UPDATE agent_memory/, { rowCount: 1 });
    const r = await app.inject({ method: "PATCH", url: `/api/agent/memory/${M}`, headers: { "x-test-user": U }, payload: { status: "validated" } });
    expect(r.statusCode).toBe(200);
    const upd = fakeDb.find(/UPDATE agent_memory/)[0];
    expect(upd.sql).toContain("'validated_by', $4::text");
    expect(upd.values).toEqual(["validated", M, U, U]);
  });

  it("GET : statut effectif renvoyé, filtre invalide → 400", async () => {
    fakeDb.on(/FROM agent_memory/, { rows: [{ id: M, type: "solution", level: "workflow", status: "validated", goal: "g", content: "c", metadata: {} }] });
    const r = await app.inject({ method: "GET", url: "/api/agent/memory", headers: { "x-test-user": U } });
    expect(r.json().memory[0]).toMatchObject({ status: "proposed", stored_status: "validated" });
    expect(r.json().memory[0].metadata).toBeUndefined();
    const bad = await app.inject({ method: "GET", url: "/api/agent/memory?status=nope", headers: { "x-test-user": U } });
    expect(bad.statusCode).toBe(400);
  });
});
