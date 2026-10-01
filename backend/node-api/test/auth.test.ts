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
    // Révoqué sur cette instance : refusé SANS consulter Supabase.
    expect(await auth.verifySupabaseToken("jwt-a")).toEqual({ ok: false, reason: "invalid" });
    expect(fetchMock).toHaveBeenCalledTimes(1);
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

/** JWT non signé (seul `exp` est lu localement, la validité reste vérifiée par Supabase). */
function jwt(expSeconds: number, sub = "u"): string {
  const enc = (o: object) => Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${enc({ alg: "none" })}.${enc({ sub, exp: expSeconds })}.sig`;
}

describe("déconnexion explicite (S26)", () => {
  it("logout AVANT signOut : une requête intermédiaire ne remet PAS le jeton en cache ; après signOut il reste refusé", async () => {
    // Supabase accepte le jeton tant que signOut n'a pas eu lieu.
    let signedOut = false;
    const fetchMock = vi.fn(async () =>
      signedOut ? new Response("{}", { status: 403 }) : new Response(JSON.stringify({ id: "u3" }), { status: 200 }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const token = jwt(Math.floor(Date.now() / 1000) + 3600, "u3");

    expect((await auth.verifySupabaseToken(token)).ok).toBe(true); // 1. requête normale
    auth.forgetToken(token); // 2. POST /api/auth/logout
    expect(await auth.verifySupabaseToken(token)).toEqual({ ok: false, reason: "invalid" }); // 3. poll avant signOut
    expect(auth.cachedUserForToken(token)).toBeUndefined();
    signedOut = true; // 4. supabase.auth.signOut()
    expect(await auth.verifySupabaseToken(token)).toEqual({ ok: false, reason: "invalid" });
    expect(fetchMock).toHaveBeenCalledTimes(1); // jamais re-vérifié auprès de Supabase après le logout
    expect(auth.isTokenRevoked(token)).toBe(true);
  });

  it("révocation jusqu'à l'expiration du JWT (bornée à 1 h), au moins 15 s", () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    const now = Date.now();
    const t30m = jwt(Math.floor(now / 1000) + 30 * 60, "a");
    const tOld = jwt(Math.floor(now / 1000) - 60, "b");
    auth.forgetToken(t30m);
    auth.forgetToken(tOld);
    vi.setSystemTime(now + 20 * 60_000);
    expect(auth.isTokenRevoked(t30m)).toBe(true); // 20 min plus tard : toujours révoqué
    expect(auth.isTokenRevoked(tOld)).toBe(false); // jeton déjà expiré : plancher de 15 s écoulé
    vi.setSystemTime(now + 31 * 60_000);
    expect(auth.isTokenRevoked(t30m)).toBe(false);
  });

  it("logout PENDANT une vérification en cours : le résultat n'est ni accepté ni mis en cache", async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        await gate;
        return new Response(JSON.stringify({ id: "u4" }), { status: 200 });
      }),
    );
    const token = jwt(Math.floor(Date.now() / 1000) + 600, "u4");
    const pending = auth.verifySupabaseToken(token);
    auth.forgetToken(token);
    release();
    expect(await pending).toEqual({ ok: false, reason: "invalid" });
    expect(auth.cachedUserForToken(token)).toBeUndefined();
  });
});
