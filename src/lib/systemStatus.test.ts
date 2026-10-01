import { describe, expect, it } from "vitest";
import { computeOverallStatus, deepCheck } from "@/lib/systemStatus";

describe("computeOverallStatus", () => {
  it("opérationnel quand tout répond", () => {
    expect(
      computeOverallStatus({ backend: "ok", supabase: "ok", deep: { status: "ok", checks: { postgres: "ok", python_ia: "ok" } } }),
    ).toBe("operational");
    expect(computeOverallStatus({ backend: "ok", supabase: "ok", deep: null })).toBe("operational");
  });

  it("dégradé si une dépendance profonde est en panne", () => {
    expect(
      computeOverallStatus({ backend: "ok", supabase: "ok", deep: { status: "degraded", checks: { postgres: "ok", python_ia: "down" } } }),
    ).toBe("degraded");
  });

  it("dégradé si un seul des deux services est injoignable", () => {
    expect(computeOverallStatus({ backend: "down", supabase: "ok", deep: null })).toBe("degraded");
    expect(computeOverallStatus({ backend: "ok", supabase: "down", deep: null })).toBe("degraded");
  });

  it("hors ligne si backend et Supabase sont injoignables", () => {
    expect(computeOverallStatus({ backend: "down", supabase: "down", deep: null })).toBe("offline");
  });

  it("en vérification tant que les sondes n'ont pas répondu", () => {
    expect(computeOverallStatus({ backend: "unknown", supabase: "ok", deep: null })).toBe("checking");
    expect(computeOverallStatus({ backend: "unknown", supabase: "down", deep: null })).toBe("degraded");
  });
});

describe("deepCheck", () => {
  it("lit l'état d'une dépendance", () => {
    const deep = { checks: { postgres: "ok", python_ia: "down" } };
    expect(deepCheck(deep, "postgres")).toBe("ok");
    expect(deepCheck(deep, "python_ia")).toBe("down");
    expect(deepCheck(deep, "redis")).toBe("unknown");
    expect(deepCheck(null, "postgres")).toBe("unknown");
  });
});
