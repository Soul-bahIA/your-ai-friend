// Niveau application : SOULBAH_ENV (contrat §1, S13/S14), /health/deep (S18), /media (S18/T37),
// trustProxy (T37), allowlist des fournisseurs (S32), orchestrateur (T44), /demos (T5).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import Fastify from "fastify";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { fakeDb } from "./helpers/fakeDb";
import { checkStartupEnv } from "../src/lib/envChecks";
import { parseTrustProxy } from "../src/config";
import { checkProviderOverride } from "../src/lib/providerOverride";

vi.mock("../src/db.js", async () => (await import("./helpers/fakeDb")).dbMock);
vi.mock("../src/auth.js", async (importOriginal) => (await import("./helpers/authMock")).mockAuth(await importOriginal()));
vi.mock("../src/clients/iaClient.js", async (importOriginal) => ({
  ...(await importOriginal<object>()),
  routeRequest: vi.fn(),
  planGoal: vi.fn(),
}));
vi.mock("../src/services/formation/index.js", async (importOriginal) => ({
  ...(await importOriginal<object>()),
  formationEngine: { build: vi.fn(async () => Promise.reject(new Error("panne simulée"))) },
}));
vi.mock("../src/services/research/index.js", async (importOriginal) => ({
  ...(await importOriginal<object>()),
  researchService: { research: vi.fn(async (_u: string, q: string) => ({ query: q, source: "kb", fromCache: true })) },
}));

const { buildApp, rateLimitKey, toFastifyTrustProxy } = await import("../src/app");
const { drainBackgroundJobs } = await import("../src/services/backgroundJobs");
const { config } = await import("../src/config");
const iaClient = await import("../src/clients/iaClient");
const research = await import("../src/services/research/index");

const U = "22222222-2222-4222-8222-222222222222";
const F = "88888888-8888-4888-8888-888888888888";
const user = { "x-test-user": U };
const mediaDir = fs.mkdtempSync(path.join(os.tmpdir(), "soulbah-media-"));

describe("checkStartupEnv (contrat §1)", () => {
  const readable = () => true;

  it("dev / test : démarrage toléré sans jeton IA ni CA (avertissements)", () => {
    const r = checkStartupEnv({ DATABASE_SSL: "true" }, readable);
    expect(r).toMatchObject({ soulbahEnv: "dev", strict: false, errors: [] });
    expect(r.warnings.join(" ")).toContain("IA_SERVICE_TOKEN");
    expect(checkStartupEnv({ SOULBAH_ENV: "test" }, readable).errors).toEqual([]);
  });

  it("production sans IA_SERVICE_TOKEN → refus", () => {
    const r = checkStartupEnv({ SOULBAH_ENV: "production" }, readable);
    expect(r.strict).toBe(true);
    expect(r.errors.join(" ")).toContain("IA_SERVICE_TOKEN");
  });

  it("staging avec DATABASE_SSL=true sans PG_SSL_CA → refus ; avec CA lisible → OK", () => {
    expect(checkStartupEnv({ SOULBAH_ENV: "staging", IA_SERVICE_TOKEN: "t", DATABASE_SSL: "true" }, readable).errors.join(" ")).toContain(
      "PG_SSL_CA",
    );
    expect(
      checkStartupEnv(
        { SOULBAH_ENV: "staging", IA_SERVICE_TOKEN: "t", DATABASE_SSL: "true", PG_SSL_CA: "/ca.pem", SOULBAH_APPROVAL_SECRET: "s".repeat(32) },
        readable,
      ).errors,
    ).toEqual([]);
    // LOT 6 : hors dev/test, le secret d'approbation HMAC est obligatoire et ≥ 32 caractères.
    expect(checkStartupEnv({ SOULBAH_ENV: "staging", IA_SERVICE_TOKEN: "t", DATABASE_SSL: "true", PG_SSL_CA: "/ca.pem" }, readable).errors.join(" ")).toContain(
      "SOULBAH_APPROVAL_SECRET",
    );
    expect(checkStartupEnv({ SOULBAH_APPROVAL_SECRET: "court" }, readable).errors.join(" ")).toContain("trop court");
    expect(checkStartupEnv({}, readable).warnings.join(" ")).toContain("SOULBAH_APPROVAL_SECRET");
  });

  it("valeur inconnue → refus (traitée comme stricte) ; CA illisible → refus même en dev", () => {
    const r = checkStartupEnv({ SOULBAH_ENV: "prod", IA_SERVICE_TOKEN: "t" }, readable);
    expect(r.strict).toBe(true);
    expect(r.errors[0]).toContain("SOULBAH_ENV invalide");
    expect(checkStartupEnv({ PG_SSL_CA: "/absent.pem" }, () => false).errors.join(" ")).toContain("illisible");
  });
});

describe("trustProxy et clé de limitation de débit (T37)", () => {
  it("parseTrustProxy", () => {
    expect(parseTrustProxy(undefined)).toBe(false);
    expect(parseTrustProxy("false")).toBe(false);
    expect(parseTrustProxy("true")).toBe(true);
    expect(parseTrustProxy("1")).toBe(1);
    expect(parseTrustProxy("10.0.0.0/8, 127.0.0.1")).toEqual(["10.0.0.0/8", "127.0.0.1"]);
  });

  it("derrière un proxy de confiance (1 saut) request.ip = client réel, utilisée par la clé de débit", async () => {
    const tiny = Fastify({ trustProxy: toFastifyTrustProxy(1) });
    tiny.get("/ip", async (req) => ({ ip: req.ip, key: rateLimitKey(req) }));
    const r = await tiny.inject({ method: "GET", url: "/ip", headers: { "x-forwarded-for": "203.0.113.7" }, remoteAddress: "10.0.0.2" });
    expect(r.json()).toEqual({ ip: "203.0.113.7", key: "ip:203.0.113.7" });
    const direct = Fastify({ trustProxy: toFastifyTrustProxy(false) });
    direct.get("/ip", async (req) => ({ key: rateLimitKey(req) }));
    const d = await direct.inject({ method: "GET", url: "/ip", headers: { "x-forwarded-for": "203.0.113.7" }, remoteAddress: "10.0.0.2" });
    expect(d.json().key).toBe("ip:10.0.0.2"); // en-tête forgé ignoré sans proxy de confiance
    await tiny.close();
    await direct.close();
  });
});

describe("provider override (S32)", () => {
  it("checkProviderOverride : vide = pas de surcharge ; hors allowlist → refus", () => {
    expect(checkProviderOverride(undefined, [])).toEqual({ ok: true, value: undefined });
    expect(checkProviderOverride("openai", []).ok).toBe(false);
    expect(checkProviderOverride("OpenAI", ["openai"])).toEqual({ ok: true, value: "openai" });
    expect(checkProviderOverride({ x: 1 }, ["openai"]).ok).toBe(false);
  });
});

describe("routes (application complète)", () => {
  let app: FastifyInstance;
  let prodApp: FastifyInstance;
  beforeAll(async () => {
    fs.writeFileSync(path.join(mediaDir, "formation_x.mp4"), "MP4");
    fs.writeFileSync(path.join(mediaDir, ".secret"), "s");
    vi.stubGlobal("fetch", vi.fn(async () => new Response("{}", { status: 200 })));
    config.soulbahEnv = "dev";
    app = await buildApp({ mediaDir });
    config.soulbahEnv = "production";
    prodApp = await buildApp({ mediaDir });
    config.soulbahEnv = "dev";
  });
  afterAll(async () => {
    await app.close();
    await prodApp.close();
    vi.unstubAllGlobals();
  });
  beforeEach(() => fakeDb.reset());
  afterEach(() => {
    config.llmAllowedOverrides = [];
  });

  it("/health/deep : JWT exigé hors dev, public en dev ; /health toujours public", async () => {
    expect((await prodApp.inject({ method: "GET", url: "/health/deep" })).statusCode).toBe(401);
    expect((await prodApp.inject({ method: "GET", url: "/health/deep", headers: user })).statusCode).toBe(200);
    expect((await app.inject({ method: "GET", url: "/health/deep" })).json()).toMatchObject({ status: "ok" });
    expect((await prodApp.inject({ method: "GET", url: "/health" })).statusCode).toBe(200);
  });

  it("/media : cache privé, nosniff, pas de listing ni de fichier caché", async () => {
    const r = await app.inject({ method: "GET", url: "/media/formation_x.mp4" });
    expect(r.statusCode).toBe(200);
    expect(r.headers["cache-control"]).toBe("private, max-age=3600");
    expect(r.headers["x-content-type-options"]).toBe("nosniff");
    expect((await app.inject({ method: "GET", url: "/media/" })).statusCode).toBeGreaterThanOrEqual(400);
    expect((await app.inject({ method: "GET", url: "/media/.secret" })).statusCode).toBeGreaterThanOrEqual(400);
  });

  it("provider non autorisé → 400 sur /api/research et /api/generate/formation, sans appel amont", async () => {
    const res = await app.inject({ method: "POST", url: "/api/research", headers: user, payload: { query: "q", provider: "anthropic" } });
    expect(res.statusCode).toBe(400);
    const gen = await app.inject({
      method: "POST",
      url: "/api/generate/formation",
      headers: user,
      payload: { topic: "t", formationId: F, provider: "xai" },
    });
    expect(gen.statusCode).toBe(400);
    expect(research.researchService.research).not.toHaveBeenCalled();
    expect(fakeDb.calls).toHaveLength(0);
  });

  it("provider dans LLM_ALLOWED_OVERRIDES → accepté et transmis", async () => {
    config.llmAllowedOverrides = ["anthropic"];
    const r = await app.inject({ method: "POST", url: "/api/research", headers: user, payload: { query: "q", provider: "Anthropic" } });
    expect(r.statusCode).toBe(200);
    expect(vi.mocked(research.researchService.research).mock.calls.at(-1)?.[2]).toMatchObject({ provider: "anthropic" });
  });

  it("orchestrateur : planification en échec → 502 success:false (T44) ; objectif irréalisable → 422", async () => {
    vi.mocked(iaClient.routeRequest).mockResolvedValue({
      agent: "desktop", agent_label: "Desktop", capability: "agent_goal", task_type: "t", reason: "", complexity: "low",
      subtasks: [], needs_memory_check: false,
    });
    fakeDb.on(/FROM agent_keys WHERE user_id = \$1 ORDER BY created_at/, { rows: [{ id: F, label: "PC", allowed_dirs: [] }] });
    vi.mocked(iaClient.planGoal).mockRejectedValueOnce(new iaClient.ServiceError(503, "Service IA temporairement indisponible"));
    const r = await app.inject({ method: "POST", url: "/api/orchestrator/route", headers: user, payload: { request: "ouvre le bloc-notes", execute: true } });
    expect(r.statusCode).toBe(502);
    expect(r.json()).toMatchObject({ success: false, executed: "agent_goal" });
    vi.mocked(iaClient.planGoal).mockResolvedValueOnce({ understanding: "u", feasible: false, reason: "non", steps: [] });
    const r2 = await app.inject({ method: "POST", url: "/api/orchestrator/route", headers: user, payload: { request: "x", execute: true } });
    expect(r2.statusCode).toBe(422);
    expect(r2.json().success).toBe(false);
  });

  it("POST /api/formations/:id/demos → 501, aucune tâche sans étapes mise en file (T5)", async () => {
    const r = await app.inject({ method: "POST", url: `/api/formations/${F}/demos`, headers: user });
    expect(r.statusCode).toBe(501);
    expect(r.json().code).toBe("demos_not_implemented");
    expect(fakeDb.find(/INSERT INTO agent_tasks/)).toHaveLength(0);
  });

  it("progression d'une formation : évènements data.source='formation' (T21/T29), échec sans détail interne", async () => {
    fakeDb.on(/UPDATE formations SET status = 'Génération\.\.\.'/, { rowCount: 1 });
    const r = await app.inject({ method: "POST", url: "/api/generate/formation", headers: user, payload: { topic: "SQL", formationId: F } });
    expect(r.json()).toMatchObject({ success: true, async: true });
    await drainBackgroundJobs(2000);
    const events = fakeDb.find(/INSERT INTO agent_events/).map((c) => ({ type: c.values[2], msg: c.values[3], data: JSON.parse(c.values[4] as string) }));
    expect(events.map((e) => e.type)).toEqual(["task_started", "task_failed"]);
    expect(events.every((e) => e.data.source === "formation" && e.data.formation_id === F)).toBe(true);
    expect(events[1].msg).not.toContain("panne simulée");
  });

  it("POST /api/auth/logout : 401 sans jeton, 200 avec", async () => {
    expect((await app.inject({ method: "POST", url: "/api/auth/logout" })).statusCode).toBe(401);
    const r = await app.inject({ method: "POST", url: "/api/auth/logout", headers: { authorization: "Bearer abc" } });
    expect(r.json()).toEqual({ success: true });
  });
});
