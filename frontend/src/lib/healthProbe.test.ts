import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const getSession = vi.fn();
vi.mock("@/integrations/supabase/client", () => ({
  supabase: { auth: { getSession: () => getSession() } },
}));

import { apiUrl } from "@/lib/api";
import { fetchBackendHealth, fetchDeepHealth } from "@/lib/healthProbe";
import { computeOverallStatus, statusView } from "@/lib/systemStatus";

const jsonResponse = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const fetchMock = vi.fn();

beforeEach(() => {
  vi.stubGlobal("fetch", fetchMock);
  getSession.mockResolvedValue({ data: { session: { access_token: "tok-deep" } } });
});

afterEach(() => {
  vi.unstubAllGlobals();
  fetchMock.mockReset();
  getSession.mockReset();
});

describe("fetchDeepHealth (T31)", () => {
  it("joint le JWT de la session (route protégée hors dev)", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ status: "ok", checks: { postgres: "ok", python_ia: "ok" } }));
    await expect(fetchDeepHealth()).resolves.toEqual({ status: "ok", checks: { postgres: "ok", python_ia: "ok" } });
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(apiUrl("/health/deep"));
    expect(init.headers).toEqual({ Authorization: "Bearer tok-deep" });
  });

  it("sans session : pas d'en-tête (dev) et un 401 donne « non vérifié »", async () => {
    getSession.mockResolvedValue({ data: { session: null } });
    fetchMock.mockResolvedValue(jsonResponse({ error: "Non authentifié" }, 401));
    const deep = await fetchDeepHealth();
    expect(fetchMock.mock.calls[0][1].headers).toBeUndefined();
    expect(deep).toBeNull();
    // Scénario du rapport : backend et Supabase OK mais /health/deep refusé → pas « opérationnel ».
    expect(statusView(computeOverallStatus({ backend: "ok", supabase: "ok", deep })).label).toBe("Système dégradé");
  });

  it("réseau en panne ou session illisible : null, sans lever", async () => {
    fetchMock.mockRejectedValueOnce(new TypeError("Failed to fetch"));
    await expect(fetchDeepHealth()).resolves.toBeNull();

    getSession.mockRejectedValueOnce(new Error("storage"));
    fetchMock.mockResolvedValueOnce(jsonResponse({ status: "degraded", checks: { postgres: "down" } }));
    await expect(fetchDeepHealth()).resolves.toEqual({ status: "degraded", checks: { postgres: "down" } });
  });
});

describe("fetchBackendHealth", () => {
  it("ok seulement si /health répond {status:'ok'}", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ status: "ok" }));
    await expect(fetchBackendHealth()).resolves.toBe("ok");
    expect(fetchMock.mock.calls[0][1].headers).toBeUndefined();
    fetchMock.mockResolvedValueOnce(jsonResponse({ status: "starting" }));
    await expect(fetchBackendHealth()).resolves.toBe("down");
    fetchMock.mockResolvedValueOnce(jsonResponse({}, 500));
    await expect(fetchBackendHealth()).resolves.toBe("down");
    fetchMock.mockRejectedValueOnce(new TypeError("Failed to fetch"));
    await expect(fetchBackendHealth()).resolves.toBe("down");
  });
});
