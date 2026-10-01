import { describe, expect, it } from "vitest";
import { sanitizeMediaUrl } from "@/lib/url";

const API = "http://localhost:3000/";

describe("sanitizeMediaUrl", () => {
  it("préfixe les chemins /media/ par l'URL de l'API", () => {
    expect(sanitizeMediaUrl("/media/videos/abc.mp4", API)).toBe("http://localhost:3000/media/videos/abc.mp4");
  });

  it("accepte les URL https absolues", () => {
    expect(sanitizeMediaUrl("https://cdn.exemple.fr/v.mp4", API)).toBe("https://cdn.exemple.fr/v.mp4");
    expect(sanitizeMediaUrl("  HTTPS://cdn.exemple.fr/v.mp4 ", API)).toBe("https://cdn.exemple.fr/v.mp4");
  });

  it.each([
    "javascript:alert(1)",
    "JaVaScRiPt:alert(1)",
    "data:text/html,<script>alert(1)</script>",
    "http://exemple.fr/v.mp4",
    "//evil.example/v.mp4",
    "/api/secret",
    "/media/../api/secret",
    "/media/a\\b.mp4",
    "media/videos/abc.mp4",
    "https://",
    "",
    "   ",
  ])("refuse %j", (url) => {
    expect(sanitizeMediaUrl(url, API)).toBeNull();
  });

  it("refuse les valeurs non textuelles", () => {
    expect(sanitizeMediaUrl(null, API)).toBeNull();
    expect(sanitizeMediaUrl(undefined, API)).toBeNull();
    expect(sanitizeMediaUrl(42, API)).toBeNull();
    expect(sanitizeMediaUrl({ href: "https://x" }, API)).toBeNull();
  });
});
