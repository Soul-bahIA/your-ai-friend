// V3 LOT 1 — configuration centrale et modes côté plan de contrôle : mêmes cas de résolution
// que Python (shared/config/resolution_cases.json), démarrage refusé sur une configuration
// invalide ou un service externe en OFFLINE, chat / embeddings / recherche web soumis au mode,
// route GET /api/v2/capabilities.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { fakeDb } from "./helpers/fakeDb";

process.env.SOULBAH_ENV = "test";

vi.mock("../src/db.js", async () => (await import("./helpers/fakeDb")).dbMock);
vi.mock("../src/auth.js", async (importOriginal) => (await import("./helpers/authMock")).mockAuth(await importOriginal()));
vi.mock("../src/clients/iaClient.js", async (importOriginal) => ({ ...(await importOriginal<object>()), modelsStatus: vi.fn() }));

const S = await import("../src/lib/soulbahSettings");
const { checkStartupEnv } = await import("../src/lib/envChecks");
const { resolveChatProvider } = await import("../src/services/chatProvider");
const { embed } = await import("../src/services/knowledge/embeddings");
const { getWebSearchProvider } = await import("../src/services/research/webSearch");
const { serviceCapabilities } = await import("../src/v2/routes/capabilities");
const { config } = await import("../src/config");
const ia = await import("../src/clients/iaClient");
const { buildApp } = await import("../src/app");

const ROOT = path.resolve(__dirname, "../../..");
const CASES = JSON.parse(fs.readFileSync(path.join(ROOT, "shared/config/resolution_cases.json"), "utf8")).cases as {
  name: string;
  env: Record<string, string>;
  file: unknown;
  expect?: Record<string, unknown>;
  derived?: Record<string, unknown>;
  hosts?: Record<string, boolean>;
  errors?: string[];
}[];

const U = "22222222-2222-4222-8222-222222222222";
const settings = (env: Record<string, string>) => {
  const r = S.resolveSettings(env);
  expect(r.errors).toEqual([]);
  return r.settings;
};
const BASE = { SOULBAH_ENV: "test", DATABASE_URL: "postgres://postgres@127.0.0.1:54329/postgres" };

function withMode(env: Record<string, string>) {
  for (const k of Object.keys(S.ENV_KEYS)) delete process.env[k];
  Object.assign(process.env, env);
  S.resetSettingsCache();
}

afterEach(() => withMode({}));

describe("résolution : cas communs avec Python", () => {
  for (const c of CASES) {
    it(c.name, () => {
      const r = S.resolveSettings(c.env, c.file);
      if (c.errors) {
        const all = r.errors.join(" | ");
        for (const f of c.errors) expect(all).toContain(f);
        return;
      }
      expect(r.errors).toEqual([]);
      for (const [k, v] of Object.entries(c.expect ?? {})) expect((r.settings as unknown as Record<string, unknown>)[k], k).toEqual(v);
      const view = S.publicView(r.settings) as Record<string, unknown>;
      for (const [k, v] of Object.entries(c.derived ?? {})) expect(view[k], k).toEqual(v);
      for (const [h, v] of Object.entries(c.hosts ?? {})) expect(S.hostAllowed(r.settings, h), h).toBe(v);
    });
  }

  it("fichier : SOULBAH_CONFIG absent = erreur ; l'exemple versionné est valide", () => {
    expect(S.loadSettings({ SOULBAH_CONFIG: path.join(os.tmpdir(), "absent-soulbah.json") }, null).errors[0]).toContain("introuvable");
    const ex = S.loadSettings({ SOULBAH_CONFIG: path.join(ROOT, "shared/config/soulbah.config.example.json") }, null);
    expect(ex.errors).toEqual([]);
    expect(ex.settings.mode).toBe("HYBRID");
  });
});

describe("démarrage (checkStartupEnv)", () => {
  const errs = (env: Record<string, string>) => checkStartupEnv({ ...BASE, ...env } as NodeJS.ProcessEnv, () => true).errors.join(" | ");

  it("mode invalide : démarrage refusé", () => {
    expect(errs({ SOULBAH_MODE: "OFLINE" })).toContain("mode inconnu");
  });

  it("OFFLINE : base, python-ia et Supabase doivent être locaux", () => {
    expect(errs({ SOULBAH_MODE: "OFFLINE" })).not.toContain("mode OFFLINE");
    const cloudDb = errs({ SOULBAH_MODE: "OFFLINE", DATABASE_URL: "postgres://u:p@aws-0-eu-west-3.pooler.supabase.com:6543/postgres" });
    expect(cloudDb).toContain("DATABASE_URL pointe vers un hôte externe (aws-0-eu-west-3.pooler.supabase.com)");
    expect(cloudDb).not.toContain(":p@");
    expect(errs({ SOULBAH_MODE: "OFFLINE", IA_SERVICE_URL: "http://python-ia:8000" })).not.toContain("IA_SERVICE_URL");
    expect(errs({ SOULBAH_MODE: "OFFLINE", SUPABASE_URL: "https://abc.supabase.co" })).toContain("SUPABASE_URL");
    expect(errs({ SOULBAH_MODE: "OFFLINE", SUPABASE_URL: "https://abc.supabase.co", AUTH_MODE: "dev-local", DEV_LOCAL_TOKEN: "t".repeat(40), DEV_LOCAL_USER_ID: U })).not.toContain("SUPABASE_URL");
  });

  it("LOCAL_LLM_URL hors HYBRID : machine de l'utilisateur seulement", () => {
    expect(errs({ SOULBAH_MODE: "LOCAL_INTERNET", LOCAL_LLM_URL: "https://modeles.exemple.com/v1" })).toContain("LOCAL_LLM_URL vise un hôte externe");
    expect(errs({ SOULBAH_MODE: "LOCAL_INTERNET", LOCAL_LLM_URL: "http://127.0.0.1:8080/v1" })).not.toContain("LOCAL_LLM_URL");
    expect(errs({ SOULBAH_MODE: "OFFLINE", LOCAL_LLM_URL: "http://192.168.1.20:8080/v1", SOULBAH_NETWORK_ALLOW_HOSTS: "192.168.1.20" })).not.toContain("LOCAL_LLM_URL");
    expect(errs({ LOCAL_LLM_URL: "https://modeles.exemple.com/v1" })).not.toContain("LOCAL_LLM_URL"); // HYBRID
  });
});

describe("fournisseurs soumis au mode", () => {
  const keys = { OPENAI_API_KEY: "sk-test", LOCAL_LLM_URL: "http://127.0.0.1:8080/v1" } as NodeJS.ProcessEnv;

  it("chat : cloud seulement en HYBRID ; modèle local seulement sur une machine locale", () => {
    expect(resolveChatProvider(keys, settings({ SOULBAH_MODEL_POLICY: "cloud-first" }))?.provider).toBe("openai");
    expect(resolveChatProvider(keys, settings({ SOULBAH_MODE: "OFFLINE" }))?.provider).toBe("local");
    expect(resolveChatProvider({ OPENAI_API_KEY: "sk-test" } as NodeJS.ProcessEnv, settings({ SOULBAH_MODE: "LOCAL_INTERNET" }))).toBeNull();
    expect(resolveChatProvider({ LOCAL_LLM_URL: "https://modeles.exemple.com/v1" } as NodeJS.ProcessEnv, settings({ SOULBAH_MODE: "OFFLINE" }))).toBeNull();
  });

  it("chat (LOT 3) : local d'abord en « auto », ordre V2 en « cloud-first », local seul en « local-only »", () => {
    expect(resolveChatProvider(keys, settings({}))?.provider).toBe("local");
    expect(resolveChatProvider(keys, settings({ SOULBAH_MODEL_POLICY: "cloud-first" }))?.provider).toBe("openai");
    expect(resolveChatProvider({ OPENAI_API_KEY: "sk-test" } as NodeJS.ProcessEnv, settings({ SOULBAH_MODEL_POLICY: "local-only" }))).toBeNull();
  });

  it("embeddings : aucun appel réseau hors HYBRID", async () => {
    const spy = vi.spyOn(globalThis, "fetch");
    process.env.OPENAI_API_KEY = "sk-test";
    try {
      withMode({ SOULBAH_MODE: "OFFLINE" });
      expect(await embed("bonjour")).toBeNull();
      withMode({ SOULBAH_MODE: "LOCAL_INTERNET" });
      expect(await embed("bonjour")).toBeNull();
      expect(spy).not.toHaveBeenCalled();
    } finally {
      delete process.env.OPENAI_API_KEY;
      spy.mockRestore();
    }
  });

  it("recherche web : désactivée en OFFLINE même avec une clé", () => {
    process.env.TAVILY_API_KEY = "tv-test";
    try {
      withMode({ SOULBAH_MODE: "OFFLINE" });
      const w = getWebSearchProvider() as { available: boolean; reason?: string };
      expect(w.available).toBe(false);
      expect(w.reason).toContain("OFFLINE");
    } finally {
      delete process.env.TAVILY_API_KEY;
    }
  });

  it("plafond d'agents : max_agents, profil ECO = 2", () => {
    withMode({ SOULBAH_MAX_PARALLEL_AGENTS: "5" });
    expect(config.maxParallelAgents).toBe(5);
    withMode({ SOULBAH_MAX_PARALLEL_AGENTS: "5", SOULBAH_RESOURCE_PROFILE: "ECO" });
    expect(config.maxParallelAgents).toBe(2);
  });
});

describe("registre des capacités", () => {
  it("OFFLINE sans modèle local : raisonnement désactivé avec la raison, recherche web désactivée", () => {
    const caps = serviceCapabilities(settings({ SOULBAH_MODE: "OFFLINE" }), { reasoning_available: false, blocked_by_mode: { anthropic: "x" }, configured: [] }, {} as NodeJS.ProcessEnv);
    expect(caps["reasoning.plan"]).toMatchObject({ status: "disabled" });
    expect(caps["reasoning.plan"].reason).toContain("anthropic");
    expect(caps["web.search"]).toMatchObject({ status: "disabled" });
    expect(caps["knowledge.fulltext"]).toEqual({ status: "available", via: "local" });
    expect(caps["knowledge.vector"].status).toBe("unavailable");
  });

  it("modèle local configuré : raisonnement disponible via local ; python-ia injoignable : indisponible", () => {
    expect(serviceCapabilities(settings({ SOULBAH_MODE: "OFFLINE" }), { reasoning_available: true, configured: ["local"] }, {} as NodeJS.ProcessEnv)["reasoning.plan"]).toEqual({ status: "available", via: "local" });
    expect(serviceCapabilities(settings({}), null, {} as NodeJS.ProcessEnv)["reasoning.plan"].status).toBe("unavailable");
  });

  describe("GET /api/v2/capabilities", () => {
    let app: FastifyInstance;
    beforeAll(async () => {
      app = await buildApp({ mediaDir: path.join(os.tmpdir(), "soulbah-caps-media") });
    });
    afterAll(async () => {
      await app.close();
    });
    beforeEach(() => fakeDb.reset());

    it("mode, modèles, services et PC enregistrés (profil matériel compris)", async () => {
      withMode({ SOULBAH_MODE: "OFFLINE" });
      vi.mocked(ia.modelsStatus).mockResolvedValueOnce({ mode: "OFFLINE", reasoning_available: false, blocked_by_mode: { openai: "refusé" }, configured: [] });
      fakeDb.on(/FROM soulbah\.runtimes/, {
        rows: [{ id: "r1", hostname: "pc", version: "2.0.0", status: "online", max_slots: 6, last_seen_at: new Date().toISOString(), capabilities: { hardware: { cpu: { threads: 4 } }, local: { "voice.stt": { status: "unavailable" } }, mode: "OFFLINE" } }],
      });
      const r = await app.inject({ method: "GET", url: "/api/v2/capabilities", headers: { "x-test-user": U } });
      expect(r.statusCode, r.body).toBe(200);
      const body = r.json();
      expect(body.settings).toMatchObject({ mode: "OFFLINE", label: "OFFLINE — 100% LOCAL", cloud_models_allowed: false, internet_allowed: false });
      expect(body.models).toMatchObject({ reachable: true, blocked_by_mode: { openai: "refusé" } });
      expect(body.services["reasoning.plan"].status).toBe("disabled");
      expect(body.runtimes[0]).toMatchObject({ hostname: "pc", hardware: { cpu: { threads: 4 } }, capabilities: { "voice.stt": { status: "unavailable" } } });
      expect(JSON.stringify(body)).not.toMatch(/sk-|password/i);
    });

    it("sans session : 401", async () => {
      expect((await app.inject({ method: "GET", url: "/api/v2/capabilities" })).statusCode).toBe(401);
    });
  });
});
