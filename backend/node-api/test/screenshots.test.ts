// Captures en mémoire (C§8 / T37 / T20) : validation, budget global et par utilisateur,
// balayage des expirées, retrait en profondeur des image_b64 imbriqués, garde de profondeur.
import { describe, expect, it } from "vitest";
import {
  MAX_SCREENSHOT_B64_CHARS,
  ScreenshotStore,
  extractEventImage,
  extractResultScreenshots,
  screenshotB64Error,
} from "../src/services/screenshots";
import { MAX_SANITIZE_DEPTH, TOO_DEEP_PLACEHOLDER, stripImageB64 } from "../src/lib/sanitize";
import { maskTypedText } from "../src/lib/redact";

const A = "22222222-2222-4222-8222-222222222222";
const B = "99999999-9999-4999-8999-999999999999";
const b64 = (n: number) => "A".repeat(n); // longueur multiple de 4 = base64 valide
const shot = (userId: string, n: number) => ({ userId, image_b64: b64(n), mime: "image/jpeg", at: "t" });

/** Objet imbriqué sur `depth` niveaux, avec `leaf` au fond. */
function nested(depth: number, leaf: Record<string, unknown>): Record<string, unknown> {
  let v: Record<string, unknown> = leaf;
  for (let i = 0; i < depth; i++) v = { n: v };
  return v;
}

describe("screenshotB64Error", () => {
  it("base64 strict et taille bornée (≈ 2 Mo de texte)", () => {
    expect(screenshotB64Error("QUJD")).toBeNull();
    expect(screenshotB64Error("QUI=")).toBeNull();
    expect(screenshotB64Error(b64(MAX_SCREENSHOT_B64_CHARS))).toBeNull();
    expect(screenshotB64Error(b64(MAX_SCREENSHOT_B64_CHARS + 4))).toContain("trop volumineuse");
    expect(screenshotB64Error("pas du base64!")).toContain("base64");
    expect(screenshotB64Error("QUJ")).toContain("base64"); // longueur non multiple de 4
    expect(screenshotB64Error("data:image/png;base64,QUJD")).toContain("base64");
    expect(screenshotB64Error(123)).toContain("texte");
    expect(screenshotB64Error("")).toContain("texte");
  });
});

describe("ScreenshotStore (budget mémoire)", () => {
  const limits = { maxBytes: 100, maxBytesPerUser: 40, maxEntries: 10, maxEntriesPerUser: 3, ttlMs: 1000 };

  it("plafond PAR UTILISATEUR : un compte évince ses propres captures, jamais celles des autres", () => {
    const s = new ScreenshotStore(limits, () => 0);
    s.set("b1", shot(B, 20));
    for (let i = 0; i < 10; i++) s.set(`a${i}`, shot(A, 16));
    expect(s.get("b1")?.userId).toBe(B); // capture de B intacte
    expect(s.userStats(A).bytes).toBeLessThanOrEqual(40);
    expect(s.userStats(A).count).toBeLessThanOrEqual(3);
    expect(s.get("a9")).toBeDefined(); // la plus récente est retenue
    expect(s.get("a0")).toBeUndefined();
  });

  it("budget GLOBAL en octets et en entrées", () => {
    const s = new ScreenshotStore({ ...limits, maxBytes: 60, maxBytesPerUser: 60, maxEntriesPerUser: 10 }, () => 0);
    for (let i = 0; i < 5; i++) s.set(`t${i}`, shot(i % 2 ? A : B, 20));
    expect(s.stats().bytes).toBeLessThanOrEqual(60);
    const c = new ScreenshotStore({ ...limits, maxEntries: 2, maxEntriesPerUser: 10, maxBytesPerUser: 100 }, () => 0);
    for (let i = 0; i < 5; i++) c.set(`t${i}`, shot(A, 4));
    expect(c.stats().entries).toBe(2);
  });

  it("budget global plein : l'éviction frappe le plus gros consommateur, pas les autres comptes", () => {
    const C = "77777777-7777-4777-8777-777777777777";
    const s = new ScreenshotStore({ maxBytes: 100, maxBytesPerUser: 60, maxEntries: 50, maxEntriesPerUser: 10, ttlMs: 1000 }, () => 0);
    s.set("b1", shot(B, 20)); // le plus ancien, mais petit consommateur
    s.set("a1", shot(A, 20));
    s.set("a2", shot(A, 20));
    s.set("a3", shot(A, 20)); // A : 60 octets, total 80
    s.set("c1", shot(C, 40)); // total 120 > 100 → éviction chez A
    expect(s.get("b1")).toBeDefined();
    expect(s.get("c1")).toBeDefined();
    expect(s.get("a1")).toBeUndefined();
    expect(s.stats().bytes).toBeLessThanOrEqual(100);
  });

  it("capture plus grosse qu'un budget : refusée ; remplacement d'une tâche : compté une fois", () => {
    const s = new ScreenshotStore(limits, () => 0);
    expect(s.set("t", shot(A, 44))).toBe(false);
    expect(s.stats()).toEqual({ entries: 0, bytes: 0, users: 0 });
    s.set("t", shot(A, 20));
    s.set("t", shot(A, 12));
    expect(s.stats()).toEqual({ entries: 1, bytes: 12, users: 1 });
  });

  it("entrées expirées balayées (mémoire libérée sans attendre une éviction FIFO)", () => {
    let now = 0;
    const s = new ScreenshotStore(limits, () => now);
    s.set("t1", shot(A, 20));
    s.set("t2", shot(B, 20));
    now = 1500;
    expect(s.sweep()).toBe(2);
    expect(s.stats()).toEqual({ entries: 0, bytes: 0, users: 0 });
    s.set("t3", shot(A, 8));
    now = 3000;
    expect(s.get("t3")).toBeUndefined();
    expect(s.stats().bytes).toBe(0);
  });
});

describe("extraction des captures (T20)", () => {
  it("image_b64 racine extraite, image_b64 IMBRIQUÉS retirés en profondeur", () => {
    const out = extractEventImage({
      image_b64: "QUJD",
      media_type: "image/png",
      nested: { image_b64: "SECRET", deeper: [{ image_b64: "SECRET2", keep: 1 }] },
    });
    expect(out.image).toEqual({ b64: "QUJD", mime: "image/png" });
    expect(JSON.stringify(out.data)).not.toContain("SECRET");
    expect(JSON.stringify(out.data)).not.toContain("image_b64");
    expect(out.data).toMatchObject({ has_image: true, nested: { image_omitted: true, deeper: [{ keep: 1, image_omitted: true }] } });
    // sans image racine : imbriqués retirés quand même, pas de has_image
    const plain = extractEventImage({ a: { image_b64: "X" } });
    expect(plain.image).toBeUndefined();
    expect(plain.data).toEqual({ a: { image_omitted: true } });
  });

  it("rapport final : captures invalides ou trop grosses ignorées (jamais retenues)", () => {
    const steps = [
      { data: { image_b64: "QUJD" } },
      { data: { image_b64: "pas base64" } },
      { data: { image_b64: b64(MAX_SCREENSHOT_B64_CHARS + 4) } },
      { data: { image_b64: "QUJE" } },
    ];
    expect(extractResultScreenshots({ steps })).toEqual(["QUJD", "QUJE"]);
  });

  it("au-delà de la profondeur max : sous-arbre REMPLACÉ, jamais recopié non nettoyé", () => {
    const deep = nested(MAX_SANITIZE_DEPTH + 5, { image_b64: "SECRET", text: "mot de passe" });
    const stripped = JSON.stringify(stripImageB64(deep));
    expect(stripped).not.toContain("SECRET");
    expect(stripped).toContain(TOO_DEEP_PLACEHOLDER);
    const masked = JSON.stringify(maskTypedText(deep));
    expect(masked).not.toContain("mot de passe");
    expect(masked).toContain(TOO_DEEP_PLACEHOLDER);
    // en deçà : comportement inchangé
    expect(stripImageB64(nested(3, { image_b64: "x", k: 1 }))).toEqual(nested(3, { k: 1, image_omitted: true }));
  });
});
