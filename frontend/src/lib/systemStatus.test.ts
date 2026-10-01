import { describe, expect, it } from "vitest";
import { computeOverallStatus, deepCheck, SERVICE_STATE_LABELS, statusView } from "@/lib/systemStatus";

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

describe("statusView (barre latérale, T31)", () => {
  it("reflète l'état réel au lieu d'un « opérationnel » figé", () => {
    expect(statusView("operational")).toEqual({ label: "Système opérationnel", dotClass: "bg-success", pulse: true });
    expect(statusView("degraded")).toMatchObject({ label: "Système dégradé", dotClass: "bg-warning", pulse: false });
    expect(statusView("offline")).toMatchObject({ label: "Système hors ligne", dotClass: "bg-destructive" });
    expect(statusView("checking").label).toBe("Vérification des services…");
  });

  it("enchaîne sondes → état → pastille", () => {
    const overall = computeOverallStatus({ backend: "ok", supabase: "down", deep: null });
    expect(statusView(overall).dotClass).toBe("bg-warning");
    expect(statusView(computeOverallStatus({ backend: "down", supabase: "down", deep: null })).label).toBe(
      "Système hors ligne",
    );
  });

  it("libellés de service", () => {
    expect(SERVICE_STATE_LABELS).toEqual({ ok: "OK", down: "hors ligne", unknown: "inconnu" });
  });
});
