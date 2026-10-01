import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const getSession = vi.fn();
vi.mock("@/integrations/supabase/client", () => ({
  supabase: { auth: { getSession: () => getSession() } },
}));

import { ApiError, apiUrl } from "@/lib/api";
import {
  agentChoiceFromError,
  approveAgentTask,
  cancelAgentTask,
  deleteAgentTask,
  fetchTaskScreenshot,
  goalErrorMessage,
  listAgents,
  normalizeAgents,
  notifyServerLogout,
  submitGoal,
  toImageDataUrl,
} from "@/lib/agentApi";

const jsonResponse = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const fetchMock = vi.fn();

beforeEach(() => {
  vi.stubGlobal("fetch", fetchMock);
  getSession.mockResolvedValue({ data: { session: { access_token: "tok-1" } } });
});

afterEach(() => {
  vi.unstubAllGlobals();
  fetchMock.mockReset();
  getSession.mockReset();
});

describe("normalizeAgents / agentChoiceFromError", () => {
  it("accepte {id,name} et {id,label}, ignore les entrées invalides ou révoquées", () => {
    expect(
      normalizeAgents([
        { id: "a", name: "PC bureau" },
        { id: "b", label: "Portable" },
        { id: "c" },
        { name: "sans id" },
        { id: "d", name: "Vieux PC", revoked_at: "2026-01-01" },
        null,
      ]),
    ).toEqual([
      { id: "a", name: "PC bureau" },
      { id: "b", name: "Portable" },
      { id: "c", name: "PC c" },
    ]);
    expect(normalizeAgents("x")).toEqual([]);
  });

  it("reconnaît un 400 avec une liste d'agents", () => {
    const err = new ApiError("Plusieurs agents", 400, { error: "Plusieurs agents", agents: [{ id: "a", name: "A" }] });
    expect(agentChoiceFromError(err)).toEqual([{ id: "a", name: "A" }]);
  });

  it("ignore les autres erreurs", () => {
    expect(agentChoiceFromError(new ApiError("x", 400, { error: "goal requis" }))).toBeNull();
    expect(agentChoiceFromError(new ApiError("x", 422, { agents: [{ id: "a", name: "A" }] }))).toBeNull();
    expect(agentChoiceFromError(new ApiError("x", 400, { agents: [] }))).toBeNull();
    expect(agentChoiceFromError(new Error("x"))).toBeNull();
  });

  it("goalErrorMessage ajoute la raison du refus 422", () => {
    const err = new ApiError("Plan incomplet", 422, { error: "Plan incomplet", reason: "étape 2 : champ « app » manquant" });
    expect(goalErrorMessage(err)).toBe("Plan incomplet — étape 2 : champ « app » manquant");
    expect(goalErrorMessage(new ApiError("Boom", 500, { error: "Boom" }))).toBe("Boom");
  });
});

describe("submitGoal", () => {
  it("envoie agent_key_id quand un PC est choisi", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ success: true, task_id: "t1", steps: [{}, {}], understanding: "ok" }));
    const out = await submitGoal("Ouvre Notepad", "key-1");
    expect(out).toMatchObject({ kind: "ok", data: { task_id: "t1" } });
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(apiUrl("/api/agent/goal"));
    expect(JSON.parse(init.body)).toEqual({ goal: "Ouvre Notepad", agent_key_id: "key-1" });
  });

  it("n'envoie pas agent_key_id sans choix", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ success: true }));
    await submitGoal("x");
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({ goal: "x" });
  });

  it("transforme le 400 « plusieurs agents » en demande de choix", async () => {
    fetchMock.mockResolvedValue(
      jsonResponse(
        { error: "Plusieurs agents sont enregistrés : précisez agent_key_id", agents: [{ id: "a", name: "A" }, { id: "b", name: "B" }] },
        400,
      ),
    );
    const out = await submitGoal("x");
    expect(out.kind).toBe("choose_agent");
    if (out.kind === "choose_agent") {
      expect(out.agents.map((a) => a.id)).toEqual(["a", "b"]);
      expect(out.message).toContain("Plusieurs agents");
    }
  });

  it("renvoie une erreur lisible sinon", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ error: "Objectif non réalisable", reason: "pas de navigateur" }, 422));
    expect(await submitGoal("x")).toEqual({ kind: "error", message: "Objectif non réalisable — pas de navigateur" });
  });
});

describe("cancel / approve", () => {
  it("POST /:id/cancel avec le jeton", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ success: true, status: "cancelled" }));
    await expect(cancelAgentTask("t-1")).resolves.toEqual({ success: true, status: "cancelled" });
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(apiUrl("/api/agent-tasks/t-1/cancel"));
    expect(init.method).toBe("POST");
    expect((init.headers as Headers).get("Authorization")).toBe("Bearer tok-1");
  });

  it("POST /:id/approve", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ success: true, task_id: "t-2", status: "pending" }));
    await approveAgentTask("t-2");
    expect(fetchMock.mock.calls[0][0]).toBe(apiUrl("/api/agent-tasks/t-2/approve"));
  });

  it("encode l'identifiant et propage un 409", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ error: "Tâche déjà terminée" }, 409));
    await expect(cancelAgentTask("a/b")).rejects.toMatchObject({ status: 409, message: "Tâche déjà terminée" });
    expect(fetchMock.mock.calls[0][0]).toBe(apiUrl("/api/agent-tasks/a%2Fb/cancel"));
  });
});

describe("suppression (S9)", () => {
  it("DELETE /api/agent-tasks/:id avec le jeton (plus d'écriture Supabase directe) → 204", async () => {
    fetchMock.mockResolvedValue(new Response(null, { status: 204 }));
    await expect(deleteAgentTask("t-9")).resolves.toEqual({ kind: "deleted" });
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(apiUrl("/api/agent-tasks/t-9"));
    expect(init.method).toBe("DELETE");
    expect((init.headers as Headers).get("Authorization")).toBe("Bearer tok-1");
  });

  it("404 → déjà supprimée ; 409 → tâche active avec son statut réel", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: "Tâche introuvable" }, 404));
    await expect(deleteAgentTask("t-9")).resolves.toEqual({ kind: "gone" });
    fetchMock.mockResolvedValueOnce(
      jsonResponse({ error: "Tâche active : annulez-la d'abord (POST /api/agent-tasks/:id/cancel)", status: "in_progress" }, 409),
    );
    await expect(deleteAgentTask("t-9")).resolves.toEqual({ kind: "active", status: "in_progress" });
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: "conflit" }, 409));
    await expect(deleteAgentTask("t-9")).resolves.toEqual({ kind: "active", status: null });
  });

  it("encode l'identifiant et propage les autres erreurs", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ error: "Boom" }, 500));
    await expect(deleteAgentTask("a/b")).rejects.toMatchObject({ status: 500 });
    expect(fetchMock.mock.calls[0][0]).toBe(apiUrl("/api/agent-tasks/a%2Fb"));
  });
});

describe("captures", () => {
  it("toImageDataUrl n'accepte que des types d'image sûrs et du base64", () => {
    expect(toImageDataUrl("QUJD", "image/png")).toBe("data:image/png;base64,QUJD");
    expect(toImageDataUrl("QUJD", "text/html")).toBe("data:image/jpeg;base64,QUJD");
    expect(toImageDataUrl("<script>", "image/png")).toBeNull();
    expect(toImageDataUrl("", "image/png")).toBeNull();
    expect(toImageDataUrl(undefined)).toBeNull();
  });

  it("fetchTaskScreenshot renvoie une data URL, ou null en 404", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ image_b64: "QUJD", mime: "image/webp", at: "now" }));
    await expect(fetchTaskScreenshot("t1")).resolves.toBe("data:image/webp;base64,QUJD");
    expect(fetchMock.mock.calls[0][0]).toBe(apiUrl("/api/agent-tasks/t1/screenshot"));

    fetchMock.mockResolvedValueOnce(jsonResponse({ error: "Aucune capture" }, 404));
    await expect(fetchTaskScreenshot("t1")).resolves.toBeNull();

    fetchMock.mockResolvedValueOnce(jsonResponse({ error: "Boom" }, 500));
    await expect(fetchTaskScreenshot("t1")).rejects.toMatchObject({ status: 500 });
  });
});

describe("listAgents / notifyServerLogout", () => {
  it("liste les clés comme PC", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ keys: [{ id: "k1", label: "Bureau" }, { id: "k2", label: null }] }));
    await expect(listAgents()).resolves.toEqual([
      { id: "k1", name: "Bureau" },
      { id: "k2", name: "PC k2" },
    ]);
  });

  it("appelle /api/auth/logout et ignore les erreurs", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ success: true }));
    await notifyServerLogout();
    expect(fetchMock.mock.calls[0][0]).toBe(apiUrl("/api/auth/logout"));

    fetchMock.mockRejectedValueOnce(new TypeError("Failed to fetch"));
    await expect(notifyServerLogout()).resolves.toBeUndefined();

    getSession.mockResolvedValue({ data: { session: null } });
    await expect(notifyServerLogout()).resolves.toBeUndefined();
  });
});
