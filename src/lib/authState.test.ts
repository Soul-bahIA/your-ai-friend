import { describe, expect, it } from "vitest";
import type { Session } from "@supabase/supabase-js";
import { sessionChanged } from "@/lib/authState";

const makeSession = (token: string, userId = "u1", updatedAt = "2026-01-01T00:00:00Z") =>
  ({
    access_token: token,
    refresh_token: "r",
    expires_in: 3600,
    token_type: "bearer",
    user: { id: userId, updated_at: updatedAt },
  }) as unknown as Session;

describe("sessionChanged", () => {
  it("ignore un SIGNED_IN répété (nouvel objet, même utilisateur et même jeton)", () => {
    expect(sessionChanged(makeSession("t1"), makeSession("t1"))).toBe(false);
  });

  it("détecte un nouveau jeton (TOKEN_REFRESHED)", () => {
    expect(sessionChanged(makeSession("t1"), makeSession("t2"))).toBe(true);
  });

  it("détecte un changement d'utilisateur ou de profil", () => {
    expect(sessionChanged(makeSession("t1", "u1"), makeSession("t1", "u2"))).toBe(true);
    expect(sessionChanged(makeSession("t1", "u1", "a"), makeSession("t1", "u1", "b"))).toBe(true);
  });

  it("gère connexion et déconnexion", () => {
    expect(sessionChanged(null, makeSession("t1"))).toBe(true);
    expect(sessionChanged(makeSession("t1"), null)).toBe(true);
    expect(sessionChanged(null, null)).toBe(false);
  });
});
