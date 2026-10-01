import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const getSession = vi.fn();
vi.mock("@/integrations/supabase/client", () => ({
  supabase: { auth: { getSession: () => getSession() } },
}));

import {
  AI_UNAVAILABLE_MESSAGE,
  ApiError,
  apiFetch,
  apiFetchRaw,
  apiUrl,
  errorMessageForStatus,
  NETWORK_ERROR_MESSAGE,
  resolveApiUrl,
  SESSION_EXPIRED_MESSAGE,
  TOO_MANY_REQUESTS_MESSAGE,
  toApiError,
} from "@/lib/api";

const jsonResponse = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

describe("resolveApiUrl", () => {
  it("utilise VITE_API_URL sans slash final", () => {
    expect(resolveApiUrl({ VITE_API_URL: "https://api.exemple.fr///" })).toBe("https://api.exemple.fr");
  });

  it("se replie sur localhost en dev sans log", () => {
    const log = vi.fn();
    expect(resolveApiUrl({ PROD: false }, log)).toBe("http://localhost:3000");
    expect(log).not.toHaveBeenCalled();
  });

  it("se replie sur localhost en production mais journalise une erreur", () => {
    const log = vi.fn();
    expect(resolveApiUrl({ PROD: true, VITE_API_URL: "  " }, log)).toBe("http://localhost:3000");
    expect(log).toHaveBeenCalledTimes(1);
    expect(log.mock.calls[0][0]).toContain("VITE_API_URL");
  });
});

describe("errorMessageForStatus", () => {
  it("mappe les statuts spéciaux", () => {
    expect(errorMessageForStatus(401, { error: "jwt expired" })).toBe(SESSION_EXPIRED_MESSAGE);
    expect(errorMessageForStatus(429)).toBe(TOO_MANY_REQUESTS_MESSAGE);
    expect(errorMessageForStatus(502)).toBe(AI_UNAVAILABLE_MESSAGE);
    expect(errorMessageForStatus(503)).toBe(AI_UNAVAILABLE_MESSAGE);
  });

  it("reprend le message d'erreur du serveur", () => {
    expect(errorMessageForStatus(400, { error: "Sujet manquant" })).toBe("Sujet manquant");
    expect(errorMessageForStatus(422, { message: "Invalide" })).toBe("Invalide");
    expect(errorMessageForStatus(500, { error: { message: "Boom" } })).toBe("Boom");
  });

  it("a un message générique sinon", () => {
    expect(errorMessageForStatus(500)).toBe("Erreur serveur (HTTP 500).");
    expect(errorMessageForStatus(404, { error: "" })).toBe("Erreur serveur (HTTP 404).");
  });
});

describe("toApiError", () => {
  it("gère un corps non JSON", async () => {
    const err = await toApiError(new Response("Requête invalide", { status: 400 }));
    expect(err).toBeInstanceOf(ApiError);
    expect(err.status).toBe(400);
    expect(err.message).toBe("Requête invalide");
  });
});

describe("apiFetch / apiFetchRaw", () => {
  const fetchMock = vi.fn();

  beforeEach(() => {
    vi.stubGlobal("fetch", fetchMock);
    getSession.mockResolvedValue({ data: { session: { access_token: "tok-123" } } });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    fetchMock.mockReset();
    getSession.mockReset();
  });

  it("attache le jeton et sérialise le JSON", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ ok: true }));
    const data = await apiFetch<{ ok: boolean }>("/api/x", { method: "POST", json: { a: 1 } });
    expect(data).toEqual({ ok: true });
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(apiUrl("/api/x"));
    const headers = init.headers as Headers;
    expect(headers.get("Authorization")).toBe("Bearer tok-123");
    expect(headers.get("Content-Type")).toBe("application/json");
    expect(init.body).toBe(JSON.stringify({ a: 1 }));
  });

  it("n'attache pas de jeton avec auth: false", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ status: "ok" }));
    await apiFetch("/health", { auth: false });
    expect((fetchMock.mock.calls[0][1].headers as Headers).has("Authorization")).toBe(false);
    expect(getSession).not.toHaveBeenCalled();
  });

  it("lève une ApiError 401 sans session, sans appeler le réseau", async () => {
    getSession.mockResolvedValue({ data: { session: null } });
    await expect(apiFetch("/api/x")).rejects.toMatchObject({ status: 401, message: SESSION_EXPIRED_MESSAGE });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("transforme les réponses non-2xx en ApiError", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ error: "Quota dépassé" }, 429));
    await expect(apiFetch("/api/x")).rejects.toMatchObject({ status: 429, message: TOO_MANY_REQUESTS_MESSAGE });

    fetchMock.mockResolvedValue(jsonResponse({ error: "Formation introuvable" }, 404));
    await expect(apiFetch("/api/x")).rejects.toMatchObject({ status: 404, message: "Formation introuvable" });
  });

  it("signale un backend injoignable", async () => {
    fetchMock.mockRejectedValue(new TypeError("Failed to fetch"));
    await expect(apiFetch("/api/x")).rejects.toMatchObject({ status: 0, message: NETWORK_ERROR_MESSAGE });
  });

  it("propage l'annulation telle quelle", async () => {
    fetchMock.mockRejectedValue(new DOMException("aborted", "AbortError"));
    await expect(apiFetchRaw("/api/x")).rejects.toMatchObject({ name: "AbortError" });
  });

  it("renvoie la Response brute pour le streaming", async () => {
    const resp = new Response("data: {}\n\n", { status: 200 });
    fetchMock.mockResolvedValue(resp);
    await expect(apiFetchRaw("/api/chat", { method: "POST", json: {} })).resolves.toBe(resp);
  });

  it("accepte une réponse vide (204)", async () => {
    fetchMock.mockResolvedValue(new Response(null, { status: 204 }));
    await expect(apiFetch("/api/x", { method: "DELETE" })).resolves.toBeUndefined();
  });
});
