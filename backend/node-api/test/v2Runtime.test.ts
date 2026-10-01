// LOT 8 — poignée de main de version et états des actions (fonctions pures).
import { describe, expect, it } from "vitest";
import { RUNTIME_PROTOCOL, checkRuntimeCompatibility, compareSemver, parseSemver } from "../src/v2/runtime/version";
import { ACTION_STATUSES, canAdvance, resumeDecision } from "../src/v2/runtime/actions";

describe("version du runtime", () => {
  it("semver : analyse et comparaison", () => {
    expect(parseSemver("2.0.0")).toEqual({ major: 2, minor: 0, patch: 0 });
    expect(parseSemver("v2.1.3-beta+win")).toEqual({ major: 2, minor: 1, patch: 3 });
    expect(parseSemver("2.0")).toBeNull();
    expect(parseSemver(2)).toBeNull();
    expect(compareSemver(parseSemver("2.0.0")!, parseSemver("1.9.9")!)).toBeGreaterThan(0);
    expect(compareSemver(parseSemver("2.0.0")!, parseSemver("2.0.0")!)).toBe(0);
    expect(compareSemver(parseSemver("2.0.0")!, parseSemver("2.0.1")!)).toBeLessThan(0);
  });

  it("compatibilité : protocole, version absente, trop ancienne, acceptée", () => {
    expect(RUNTIME_PROTOCOL).toBe(1);
    expect(checkRuntimeCompatibility({ version: "2.0.0", protocol: 1, minVersion: "0.0.0" })).toEqual({ ok: true });
    expect(checkRuntimeCompatibility({ version: "2.0.0", protocol: 2, minVersion: "0.0.0" }).ok).toBe(false);
    expect(checkRuntimeCompatibility({ version: "2.0.0", protocol: undefined, minVersion: "0.0.0" }).ok).toBe(false);
    expect(checkRuntimeCompatibility({ version: undefined, protocol: 1, minVersion: "0.0.0" }).ok).toBe(false);
    const old = checkRuntimeCompatibility({ version: "1.9.9", protocol: 1, minVersion: "2.0.0" });
    expect(old.ok).toBe(false);
    if (!old.ok) expect(old.reason).toContain("trop ancien");
    expect(checkRuntimeCompatibility({ version: "2.0.0", protocol: 1, minVersion: "pas-un-semver" })).toEqual({ ok: true });
  });
});

describe("états des actions (§9.8–9.9)", () => {
  it("monotones : planned → attempted → executed → verified ; terminaux figés ; identique accepté", () => {
    expect(ACTION_STATUSES.length).toBe(7);
    expect(canAdvance(null, "planned")).toBe(true);
    expect(canAdvance("planned", "attempted") && canAdvance("attempted", "executed") && canAdvance("executed", "verified")).toBe(true);
    expect(canAdvance("planned", "executed")).toBe(true); // sauter un cran est permis, revenir non
    expect(canAdvance("executed", "attempted")).toBe(false);
    expect(canAdvance("verified", "executed")).toBe(false);
    expect(canAdvance("attempted", "failed") && canAdvance("planned", "skipped") && canAdvance("attempted", "simulated")).toBe(true);
    expect(canAdvance("failed", "verified")).toBe(false);
    expect(canAdvance("simulated", "verified")).toBe(false);
    expect(canAdvance("attempted", "attempted")).toBe(true);
  });

  it("décision de reprise", () => {
    expect(resumeDecision({ status: "verified", idempotent: false })).toBe("skip");
    expect(resumeDecision({ status: "executed", idempotent: false })).toBe("verify");
    expect(resumeDecision({ status: "attempted", idempotent: true })).toBe("replay");
    expect(resumeDecision({ status: "attempted", idempotent: false })).toBe("ask");
    expect(resumeDecision({ status: "planned", idempotent: false })).toBe("run");
    expect(resumeDecision({ status: "failed", idempotent: true })).toBe("skip");
  });
});
