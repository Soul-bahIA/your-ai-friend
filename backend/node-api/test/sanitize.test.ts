import { describe, expect, it } from "vitest";
import { clampInt, isUuid, optionalFiniteNumber, sanitizeLimit, stripImageB64 } from "../src/lib/sanitize";
import { TtlCache } from "../src/lib/ttlCache";
import { mapUpstreamStatus } from "../src/lib/upstream";

describe("sanitizeLimit / clampInt", () => {
  it("NaN et valeurs invalides → défaut", () => {
    expect(sanitizeLimit(Number("abc"))).toBe(10);
    expect(sanitizeLimit(undefined)).toBe(10);
    expect(sanitizeLimit("abc")).toBe(10);
    expect(sanitizeLimit(null)).toBe(10);
  });
  it("borne et tronque", () => {
    expect(sanitizeLimit(0)).toBe(1);
    expect(sanitizeLimit(-5)).toBe(1);
    expect(sanitizeLimit(1000)).toBe(100);
    expect(sanitizeLimit("25")).toBe(25);
    expect(sanitizeLimit(7.9)).toBe(7);
    expect(clampInt("0", 1, 1, 100_000)).toBe(1); // page >= 1
    expect(clampInt(Infinity, 50, 1, 200)).toBe(50);
  });
  it("optionalFiniteNumber", () => {
    expect(optionalFiniteNumber("0.5")).toBe(0.5);
    expect(optionalFiniteNumber("x")).toBeUndefined();
    expect(optionalFiniteNumber("")).toBeUndefined();
  });
});

describe("isUuid", () => {
  it("valide/invalide", () => {
    expect(isUuid("00000000-0000-4000-8000-0000000000a1")).toBe(true);
    expect(isUuid("00000000-0000-4000-8000-00000000ra01")).toBe(false);
    expect(isUuid(42)).toBe(false);
  });
});

describe("stripImageB64", () => {
  it("retire récursivement image_b64 sans muter l'original", () => {
    const result = {
      ok: true,
      steps: [
        { index: 0, type: "screenshot", data: { image_b64: "AAAA", media_type: "image/jpeg" } },
        { index: 1, type: "wait", data: { nested: [{ image_b64: "BBBB" }] } },
      ],
    };
    const out = stripImageB64(result);
    expect(JSON.stringify(out)).not.toContain("AAAA");
    expect(JSON.stringify(out)).not.toContain("BBBB");
    expect(out.steps[0].data).toEqual({ media_type: "image/jpeg", image_omitted: true });
    expect(result.steps[0].data.image_b64).toBe("AAAA");
  });
  it("laisse passer null / scalaires", () => {
    expect(stripImageB64(null)).toBeNull();
    expect(stripImageB64("x")).toBe("x");
  });
});

describe("TtlCache", () => {
  it("expire et borne la taille", () => {
    let now = 0;
    const c = new TtlCache<number>(2, 100, () => now);
    c.set("a", 1);
    c.set("b", 2);
    c.set("c", 3); // évince "a"
    expect(c.get("a")).toBeUndefined();
    expect(c.get("b")).toBe(2);
    now = 150;
    expect(c.get("c")).toBeUndefined();
    c.set("d", 4, 0); // TTL nul : non stocké
    expect(c.get("d")).toBeUndefined();
  });
});

describe("mapUpstreamStatus", () => {
  it("ne relaie jamais 401/403 amont", () => {
    expect(mapUpstreamStatus(401).status).toBe(502);
    expect(mapUpstreamStatus(403).status).toBe(502);
    expect(mapUpstreamStatus(500).status).toBe(502);
    expect(mapUpstreamStatus(429).status).toBe(429);
    expect(mapUpstreamStatus(503).status).toBe(503);
    expect(mapUpstreamStatus(422)).toMatchObject({ status: 422, exposeDetail: true });
  });
});
