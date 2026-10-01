// TLS Postgres (S13 / contrat §1) : les paramètres TLS de DATABASE_URL ne peuvent plus
// contourner DATABASE_SSL/PG_SSL_CA, et une base distante exige DATABASE_SSL=true hors dev/test.
import { createRequire } from "node:module";
import { describe, expect, it, vi } from "vitest";
import {
  checkStartupEnv,
  databaseHost,
  databaseUrlSslParams,
  isLocalDbHost,
  stripDatabaseUrlSslParams,
} from "../src/lib/envChecks";

vi.mock("../src/config.js", async (importOriginal) => {
  const orig = await importOriginal<{ config: Record<string, unknown> }>();
  return { ...orig, config: { ...orig.config, databaseSsl: false, pgSslCa: "", databaseUrl: "postgres://u:p@postgres:5432/db" } };
});
const { effectiveDatabaseUrl, pool } = await import("../src/db");

// Analyse RÉELLE de pg (celle qui écrase l'option ssl) — preuve de bout en bout.
const require = createRequire(import.meta.url);
const ConnectionParameters = require("pg/lib/connection-parameters.js") as new (c: object) => { ssl: unknown; host: string };

const readable = () => true;
const REMOTE = "postgresql://postgres.abc:secret@aws-0-eu-west-3.pooler.supabase.com:6543/postgres";
const prodBase = { SOULBAH_ENV: "production", IA_SERVICE_TOKEN: "t", DATABASE_SSL: "true", PG_SSL_CA: "/ca.pem" };

describe("garde-fou de démarrage TLS (S13)", () => {
  it("production + DATABASE_SSL non défini + base distante → refus (plus de Postgres en clair silencieux)", () => {
    const r = checkStartupEnv({ SOULBAH_ENV: "production", IA_SERVICE_TOKEN: "t", DATABASE_URL: REMOTE }, readable);
    expect(r.errors.join(" ")).toContain("DATABASE_SSL=true est obligatoire");
    expect(r.errors.join(" ")).not.toContain("secret"); // jamais l'URL (mot de passe) dans un message
  });

  it("production + sslmode=no-verify / require / sslrootcert dans l'URL → refus, même avec PG_SSL_CA", () => {
    for (const q of ["sslmode=no-verify", "sslmode=require", "sslrootcert=/x.pem&application_name=a", "ssl=0"]) {
      const r = checkStartupEnv({ ...prodBase, DATABASE_URL: `${REMOTE}?${q}` }, readable);
      expect(r.errors.join(" ")).toContain("paramètres TLS");
      expect(r.errors.join(" ")).not.toContain("secret");
    }
  });

  it("le paramètre `host` de la query string (prioritaire pour pg) est pris en compte", () => {
    const sneaky = "postgres://u:p@localhost:5432/db?host=db.example.com";
    expect(databaseHost(sneaky)).toBe("db.example.com");
    const r = checkStartupEnv({ SOULBAH_ENV: "staging", IA_SERVICE_TOKEN: "t", DATABASE_URL: sneaky }, readable);
    expect(r.errors.join(" ")).toContain("DATABASE_SSL=true est obligatoire");
  });

  it("configurations saines acceptées : CA + URL sans paramètre TLS ; Postgres du compose / local sans TLS", () => {
    expect(checkStartupEnv({ ...prodBase, DATABASE_URL: REMOTE }, readable).errors).toEqual([]);
    expect(checkStartupEnv({ SOULBAH_ENV: "production", IA_SERVICE_TOKEN: "t" }, readable).errors).toEqual([]); // défaut compose
    for (const url of ["postgres://u:p@postgres:5432/db", "postgres://u:p@127.0.0.1/db", "postgres://u:p@[::1]:5432/db", "/var/run/postgresql db"]) {
      expect(checkStartupEnv({ SOULBAH_ENV: "production", IA_SERVICE_TOKEN: "t", DATABASE_URL: url }, readable).errors).toEqual([]);
    }
  });

  it("dev : toléré, avec avertissement", () => {
    const r = checkStartupEnv({ DATABASE_URL: `${REMOTE}?sslmode=require` }, readable);
    expect(r.errors).toEqual([]);
    expect(r.warnings.join(" ")).toContain("sslmode");
  });

  it("hôtes locaux / distants", () => {
    expect(["postgres", "db", "localhost", "127.0.0.1", "::1", "", "/tmp"].every(isLocalDbHost)).toBe(true);
    expect(["db.example.com", "10.0.0.5", "aws-0-eu-west-3.pooler.supabase.com"].some(isLocalDbHost)).toBe(false);
    expect(isLocalDbHost(null)).toBe(false);
  });
});

describe("chaîne effective passée à pg (S13)", () => {
  const CA = { rejectUnauthorized: true, ca: "-----BEGIN CERTIFICATE-----" };

  it("sans correctif, pg laisse sslmode ÉCRASER la vérification par la CA (preuve du défaut)", () => {
    const raw = new ConnectionParameters({ connectionString: `${REMOTE}?sslmode=no-verify`, ssl: CA });
    expect(raw.ssl).toMatchObject({ rejectUnauthorized: false });
  });

  it("DATABASE_SSL=true + PG_SSL_CA : paramètres TLS retirés, la CA fait foi", () => {
    for (const q of ["sslmode=no-verify", "sslmode=require", "ssl=false&sslmode=disable"]) {
      const url = effectiveDatabaseUrl(`${REMOTE}?${q}&application_name=soulbah`, true, "/ca.pem");
      expect(databaseUrlSslParams(url)).toEqual([]);
      const p = new ConnectionParameters({ connectionString: url, ssl: CA });
      expect(p.ssl).toEqual(CA);
      expect(p.host).toBe("aws-0-eu-west-3.pooler.supabase.com");
      expect(url).toContain("application_name=soulbah");
    }
  });

  it("sans CA (dev) : URL inchangée ; URL sans query : inchangée", () => {
    expect(effectiveDatabaseUrl(`${REMOTE}?sslmode=require`, true, "")).toBe(`${REMOTE}?sslmode=require`);
    expect(effectiveDatabaseUrl(`${REMOTE}?sslmode=require`, false, "/ca.pem")).toBe(`${REMOTE}?sslmode=require`);
    expect(stripDatabaseUrlSslParams(REMOTE)).toBe(REMOTE);
    expect(stripDatabaseUrlSslParams(`${REMOTE}?sslmode=require`)).toBe(REMOTE);
    void pool.end();
  });
});
