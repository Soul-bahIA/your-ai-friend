// V3 LOT 6 — Resource Manager (plan de contrôle) : nettoyage de l'état mémoire envoyé par un PC,
// garde-fou « mémoire critique récente », réparation d'un plan du modèle (V3 LOT 4).
import { describe, expect, it } from "vitest";
import { LIVE_FRESH_MS, memoryCap, sanitizeLiveResources } from "../src/v2/resources/resourceManager";
import { MAX_LLM_PLAN_ATTEMPTS, repairContext } from "../src/v2/planner/planner";

describe("état mémoire d'un runtime", () => {
  const now = new Date("2026-10-02T10:00:00Z");

  it("ne garde que des nombres bornés et un niveau connu", () => {
    const live = sanitizeLiveResources({ free_mb: 812.4, total_mb: 8000, load_percent: 150, pressure: "high", held: 2, max_slots: 6, allowed_new: 1, throttled: true, hostname: "x", cmd: "rm -rf" }, now);
    expect(live).toEqual({ free_mb: 812, total_mb: 8000, load_percent: null, pressure: "high", held: 2, max_slots: 6, allowed_new: 1, throttled: true, at: now.toISOString() });
    expect(sanitizeLiveResources({ free_mb: -1, pressure: "panique" }, now)).toMatchObject({ free_mb: null, pressure: "unknown" });
    expect(sanitizeLiveResources("texte", now)).toBeNull();
    expect(sanitizeLiveResources(undefined, now)).toBeNull();
  });

  it("garde-fou : seulement pour un état critique ET récent", () => {
    const fresh = new Date(now.getTime() - 10_000).toISOString();
    const stale = new Date(now.getTime() - LIVE_FRESH_MS - 1).toISOString();
    expect(memoryCap({ pressure: "critical", at: fresh }, now)).toBe(0);
    expect(memoryCap({ pressure: "critical", at: stale }, now)).toBeNull();
    expect(memoryCap({ pressure: "high", at: fresh }, now)).toBeNull();
    expect(memoryCap(null, now)).toBeNull();
  });
});

describe("réparation d'un plan proposé par le modèle", () => {
  it("le contexte de réparation liste les erreurs et le plan refusé, en gardant le contexte d'origine", () => {
    expect(MAX_LLM_PLAN_ATTEMPTS).toBe(2);
    const ctx = repairContext("Données du projet", { nodes: [{ key: "act" }] }, ["nœud act : sans observation préalable", "nœud act : sans critère d'acceptation requis"]);
    expect(ctx.startsWith("Données du projet")).toBe(true);
    expect(ctx).toContain("PLAN PRÉCÉDENT REFUSÉ");
    expect(ctx).toContain("- nœud act : sans observation préalable");
    expect(ctx).toContain('{"nodes":[{"key":"act"}]}');
    expect(repairContext(undefined, {}, ["x"]).startsWith("PLAN PRÉCÉDENT")).toBe(true);
  });
});
