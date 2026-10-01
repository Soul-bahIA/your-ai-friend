// S26 : cache des JWT vérifiés (15 s) et invalidation à la déconnexion.
import { afterEach, describe, expect, it, vi } from "vitest";

process.env.SUPABASE_URL = "https://exemple.supabase.co";
process.env.SUPABASE_ANON_KEY = "anon";
const auth = await import("../src/auth");

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe("cache des JWT (S26)", () => {
  it("TTL de 15 s", () => {
    expect(auth.TOKEN_CACHE_TTL_MS).toBe(15_000);
  });

  it("forgetToken (POST /api/auth/logout) : le jeton repasse par Supabase, qui le refuse", async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ id: "u1" }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    expect(await auth.verifySupabaseToken("jwt-a")).toEqual({ ok: true, user: { id: "u1", email: undefined } });
    await auth.verifySupabaseToken("jwt-a");
    expect(fetchMock).toHaveBeenCalledTimes(1); // servi par le cache
    expect(auth.cachedUserForToken("jwt-a")).toEqual({ id: "u1", email: undefined });

    auth.forgetToken("jwt-a");
    expect(auth.cachedUserForToken("jwt-a")).toBeUndefined();
    fetchMock.mockImplementationOnce(async () => new Response("{}", { status: 401 }));
    expect(await auth.verifySupabaseToken("jwt-a")).toEqual({ ok: false, reason: "invalid" });
  });

  it("au-delà de 15 s, le jeton est revérifié", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ id: "u2" }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    await auth.verifySupabaseToken("jwt-b");
    vi.setSystemTime(Date.now() + 16_000);
    await auth.verifySupabaseToken("jwt-b");
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});
