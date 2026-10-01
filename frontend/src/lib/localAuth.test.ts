import { describe, expect, it } from "vitest";
import { devLocalAuthFrom, devLocalSession } from "@/lib/localAuth";

const TOKEN = "a".repeat(64);
const USER = "a0000000-0000-4000-8000-000000000001";

describe("connexion locale (V3)", () => {
  it("active seulement sur le serveur de développement, avec jeton et uuid valides", () => {
    expect(devLocalAuthFrom({ DEV: true, VITE_AUTH_MODE: "dev-local", VITE_DEV_LOCAL_TOKEN: TOKEN, VITE_DEV_LOCAL_USER_ID: USER })).toEqual({ token: TOKEN, userId: USER });
    // Version de production : ignorée même si les variables existent.
    expect(devLocalAuthFrom({ DEV: false, VITE_AUTH_MODE: "dev-local", VITE_DEV_LOCAL_TOKEN: TOKEN, VITE_DEV_LOCAL_USER_ID: USER })).toBeNull();
    expect(devLocalAuthFrom({ DEV: true, VITE_AUTH_MODE: "supabase", VITE_DEV_LOCAL_TOKEN: TOKEN, VITE_DEV_LOCAL_USER_ID: USER })).toBeNull();
    expect(devLocalAuthFrom({ DEV: true, VITE_AUTH_MODE: "dev-local", VITE_DEV_LOCAL_TOKEN: "court", VITE_DEV_LOCAL_USER_ID: USER })).toBeNull();
    expect(devLocalAuthFrom({ DEV: true, VITE_AUTH_MODE: "dev-local", VITE_DEV_LOCAL_TOKEN: TOKEN, VITE_DEV_LOCAL_USER_ID: "pas-un-uuid" })).toBeNull();
  });

  it("session au format Supabase : jeton de développement et utilisateur local", () => {
    const s = devLocalSession({ token: TOKEN, userId: USER });
    expect(s.access_token).toBe(TOKEN);
    expect(s.user.id).toBe(USER);
    expect(s.user.email).toBe("dev@soulbah.local");
  });
});
