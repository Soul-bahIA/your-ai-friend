// LOT 3 — AUTH_MODE=dev-local : jeton de dev partagé à la place de la vérification Supabase.
// Accepté uniquement en dev/test, HOST en boucle locale, requêtes depuis la boucle locale.
// Le VRAI requireUser est testé ici (pas de mock de ../src/auth.js).
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { fakeDb } from "./helpers/fakeDb";
import {
  AUTH_MODES,
  DEV_LOCAL_TOKEN_MIN_LENGTH,
  checkStartupEnv,
  isLoopbackAddress,
  isLoopbackHost,
} from "../src/lib/envChecks";

const TOKEN = "0123456789abcdef".repeat(4); // 64 caractères
const U = "a0000000-0000-4000-8000-000000000001";
// La configuration est lue à l'import : fixée AVANT le chargement de l'application.
process.env.SOULBAH_ENV = "test";
process.env.HOST = "127.0.0.1";
process.env.AUTH_MODE = "dev-local";
process.env.DEV_LOCAL_TOKEN = TOKEN;
process.env.DEV_LOCAL_USER_ID = U;

vi.mock("../src/db.js", async () => (await import("./helpers/fakeDb")).dbMock);

const { buildApp } = await import("../src/app");
const { cachedUserForToken, devLocalTokenMatches, DEV_LOCAL_EMAIL } = await import("../src/auth");

const readable = () => true;
const devLocal = { SOULBAH_ENV: "dev", AUTH_MODE: "dev-local", DEV_LOCAL_TOKEN: TOKEN, DEV_LOCAL_USER_ID: U };

describe("checkStartupEnv : AUTH_MODE", () => {
  it("supabase par défaut ; valeur inconnue refusée", () => {
    expect(AUTH_MODES).toEqual(["supabase", "dev-local"]);
    expect(checkStartupEnv({}, readable).errors).toEqual([]);
    expect(checkStartupEnv({ AUTH_MODE: "Supabase " }, readable).errors).toEqual([]);
    expect(checkStartupEnv({ AUTH_MODE: "jwt" }, readable).errors.join(" ")).toContain("AUTH_MODE invalide");
  });

  it("dev-local accepté en dev/test (HOST absent = 127.0.0.1), avec avertissement", () => {
    const r = checkStartupEnv(devLocal, readable);
    expect(r.errors).toEqual([]);
    expect(r.warnings.join(" ")).toContain("dev-local");
    expect(checkStartupEnv({ ...devLocal, SOULBAH_ENV: "test", HOST: "localhost" }, readable).errors).toEqual([]);
    expect(checkStartupEnv({ ...devLocal, HOST: "::1" }, readable).errors).toEqual([]);
  });

  it("dev-local refusé hors dev/test, même bien configuré", () => {
    for (const env of ["staging", "production"]) {
      const r = checkStartupEnv({ ...devLocal, SOULBAH_ENV: env, IA_SERVICE_TOKEN: "t" }, readable);
      expect(r.errors.join(" ")).toContain("dev-local");
      expect(r.errors.join(" ")).toContain("interdit");
    }
  });

  it("dev-local refusé si HOST n'est pas la boucle locale", () => {
    for (const host of ["0.0.0.0", "192.168.1.10", "monpc.local", "::"]) {
      expect(checkStartupEnv({ ...devLocal, HOST: host }, readable).errors.join(" ")).toContain("boucle locale");
    }
  });

  it("dev-local exige un jeton ≥ 32 caractères et un uuid d'utilisateur", () => {
    expect(checkStartupEnv({ ...devLocal, DEV_LOCAL_TOKEN: "court" }, readable).errors.join(" ")).toContain("DEV_LOCAL_TOKEN");
    expect(checkStartupEnv({ ...devLocal, DEV_LOCAL_TOKEN: "x".repeat(DEV_LOCAL_TOKEN_MIN_LENGTH - 1) }, readable).errors.join(" ")).toContain(
      "DEV_LOCAL_TOKEN",
    );
    expect(checkStartupEnv({ ...devLocal, DEV_LOCAL_TOKEN: "x".repeat(DEV_LOCAL_TOKEN_MIN_LENGTH) }, readable).errors).toEqual([]);
    expect(checkStartupEnv({ ...devLocal, DEV_LOCAL_USER_ID: "" }, readable).errors.join(" ")).toContain("DEV_LOCAL_USER_ID");
    expect(checkStartupEnv({ ...devLocal, DEV_LOCAL_USER_ID: "pas-un-uuid" }, readable).errors.join(" ")).toContain("DEV_LOCAL_USER_ID");
  });

  it("en mode supabase, DEV_LOCAL_* sont ignorés", () => {
    expect(checkStartupEnv({ DEV_LOCAL_TOKEN: "x", DEV_LOCAL_USER_ID: "y" }, readable).errors).toEqual([]);
  });
});

describe("boucle locale", () => {
  it("adresses", () => {
    for (const ip of ["127.0.0.1", "127.1.2.3", "::1", "::ffff:127.0.0.1", "::FFFF:127.0.0.1"]) expect(isLoopbackAddress(ip)).toBe(true);
    for (const ip of ["", "0.0.0.0", "10.0.0.5", "192.168.1.1", "::", "::ffff:10.0.0.1", "localhost", undefined]) {
      expect(isLoopbackAddress(ip)).toBe(false);
    }
  });
  it("hôtes d'écoute (vide = défaut 127.0.0.1)", () => {
    for (const h of ["", "127.0.0.1", "localhost", "LOCALHOST", "::1"]) expect(isLoopbackHost(h)).toBe(true);
    for (const h of ["0.0.0.0", "::", "192.168.0.2", "example.com"]) expect(isLoopbackHost(h)).toBe(false);
  });
});

describe("devLocalTokenMatches (temps constant)", () => {
  it("égalité stricte ; vide, longueur différente, même longueur différente → faux", () => {
    expect(devLocalTokenMatches(TOKEN)).toBe(true);
    expect(devLocalTokenMatches("")).toBe(false);
    expect(devLocalTokenMatches(TOKEN + "0")).toBe(false);
    expect(devLocalTokenMatches("f" + TOKEN.slice(1))).toBe(false);
    expect(devLocalTokenMatches(TOKEN, "")).toBe(false);
  });
});

describe("requireUser en dev-local (fastify.inject)", () => {
  let app: FastifyInstance;
  const url = "/api/agent-tasks";
  beforeAll(async () => {
    app = await buildApp({ mediaDir: path.join(os.tmpdir(), "soulbah-devlocal-media") });
  });
  afterAll(async () => {
    await app.close();
  });
  beforeEach(() => fakeDb.reset());

  it("jeton de dev depuis 127.0.0.1 → 200 avec l'utilisateur de dev", async () => {
    const r = await app.inject({ method: "GET", url, headers: { authorization: `Bearer ${TOKEN}` } });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ tasks: [] });
    const q = fakeDb.find(/FROM agent_tasks WHERE user_id = \$1/);
    expect(q.length).toBe(1);
    expect(q[0].values[0]).toBe(U);
  });

  it("IPv6 locale → 200 ; adresse non locale → 403 même avec le bon jeton", async () => {
    const ok = await app.inject({ method: "GET", url, headers: { authorization: `Bearer ${TOKEN}` }, remoteAddress: "::1" });
    expect(ok.statusCode).toBe(200);
    const r = await app.inject({ method: "GET", url, headers: { authorization: `Bearer ${TOKEN}` }, remoteAddress: "10.0.0.5" });
    expect(r.statusCode).toBe(403);
    expect(fakeDb.find(/FROM agent_tasks/).length).toBe(1);
  });

  it("sans jeton → 401 ; mauvais jeton → 401 ; un JWT Supabase n'est PAS vérifié en ligne", async () => {
    expect((await app.inject({ method: "GET", url })).statusCode).toBe(401);
    expect((await app.inject({ method: "GET", url, headers: { authorization: "Bearer " + "f".repeat(64) } })).statusCode).toBe(401);
    const jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.sig";
    expect((await app.inject({ method: "GET", url, headers: { authorization: `Bearer ${jwt}` } })).statusCode).toBe(401);
    // l'en-tête de test des autres suites (x-test-user) n'a aucun effet sans mock
    expect((await app.inject({ method: "GET", url, headers: { "x-test-user": U } })).statusCode).toBe(401);
    expect(fakeDb.calls.length).toBe(0);
  });

  it("clé de limitation de débit : l'utilisateur de dev est connu sans requête", () => {
    expect(cachedUserForToken(TOKEN)).toEqual({ id: U, email: DEV_LOCAL_EMAIL });
    expect(cachedUserForToken("autre")).toBeUndefined();
  });
});
