import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const getSession = vi.fn();
vi.mock("@/integrations/supabase/client", () => ({
  supabase: { auth: { getSession: () => getSession() } },
}));

import { apiUrl } from "@/lib/api";
import { listMemories, normalizeMemoryRows, reviewMemory, runSelfImprove } from "@/lib/agentMemory";

const jsonResponse = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const fetchMock = vi.fn();

beforeEach(() => {
  vi.stubGlobal("fetch", fetchMock);
  getSession.mockResolvedValue({ data: { session: { access_token: "tok-mem" } } });
});

afterEach(() => {
  vi.unstubAllGlobals();
  fetchMock.mockReset();
  getSession.mockReset();
});

describe("normalizeMemoryRows", () => {
  it("garde les lignes exploitables, statut effectif par défaut « proposed »", () => {
    expect(
      normalizeMemoryRows([
        { id: "m1", type: "practice", level: "optimization", status: "proposed", goal: "(général)", content: "Attendre 2 s", created_at: "2026-10-01T10:00:00Z", stored_status: "validated" },
        { id: "m2", content: "Leçon", status: "weird" },
        { id: "", content: "x" },
        { id: "m3", content: "  " },
        null,
      ]),
    ).toEqual([
      { id: "m1", type: "practice", level: "optimization", status: "proposed", goal: "(général)", content: "Attendre 2 s", created_at: "2026-10-01T10:00:00Z" },
      { id: "m2", type: "practice", level: "workflow", status: "proposed", goal: "(général)", content: "Leçon", created_at: "" },
    ]);
    expect(normalizeMemoryRows({ memory: [] })).toEqual([]);
  });
});

describe("revue de la mémoire (§9)", () => {
  it("liste les leçons à valider (GET ?status=proposed, JWT)", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ memory: [{ id: "m1", type: "solution", content: "Plan réussi" }] }));
    const list = await listMemories();
    expect(list.map((m) => m.id)).toEqual(["m1"]);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(apiUrl("/api/agent/memory?status=proposed"));
    expect((init.headers as Headers).get("Authorization")).toBe("Bearer tok-mem");
  });

  it("valider / rejeter = PATCH explicite de l'utilisateur", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ success: true, status: "validated" }));
    await expect(reviewMemory("m 1", "validated")).resolves.toBe(true);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(apiUrl("/api/agent/memory/m%201"));
    expect(init.method).toBe("PATCH");
    expect(JSON.parse(init.body)).toEqual({ status: "validated" });

    fetchMock.mockResolvedValueOnce(jsonResponse({ success: true, status: "rejected" }));
    await expect(reviewMemory("m2", "rejected")).resolves.toBe(true);
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({ status: "rejected" });
  });

  it("404 → entrée disparue ; autres erreurs propagées", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: "Entrée introuvable" }, 404));
    await expect(reviewMemory("m1", "validated")).resolves.toBe(false);
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: "status valide requis" }, 400));
    await expect(reviewMemory("m1", "validated")).rejects.toMatchObject({ status: 400 });
  });
});

describe("auto-amélioration", () => {
  it("compte les optimisations proposées", async () => {
    fetchMock.mockResolvedValueOnce(
      jsonResponse({ success: true, tasks_analyzed: 4, report: { suggestions: ["a", "b", "c"] } }),
    );
    await expect(runSelfImprove()).resolves.toEqual({ kind: "ok", proposed: 3, analyzed: 4 });
    expect(fetchMock.mock.calls[0][0]).toBe(apiUrl("/api/agent/self-improve"));
    expect(fetchMock.mock.calls[0][1].method).toBe("POST");
  });

  it("422 → pas assez d'historique ; 503 propagé", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: "Pas encore assez d'historique d'exécution à analyser" }, 422));
    await expect(runSelfImprove()).resolves.toEqual({
      kind: "not_enough_history",
      message: "Pas encore assez d'historique d'exécution à analyser",
    });
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: "IA indisponible" }, 503));
    await expect(runSelfImprove()).rejects.toMatchObject({ status: 503 });
  });
});
