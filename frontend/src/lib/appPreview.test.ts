import { describe, expect, it } from "vitest";
import { buildPreviewHtml, escapeHtml, parsePreviewMessage, scriptString } from "@/lib/appPreview";

const frame = { name: "iframe-window" };
const msg = (over: Partial<{ origin: string; source: unknown; data: unknown }> = {}) => ({
  origin: "null",
  source: frame,
  data: { type: "element-selected", elementType: "table", elementName: "users", text: "users id email" },
  ...over,
});

describe("parsePreviewMessage (S31)", () => {
  it("accepte une sélection venant de l'iframe sandboxée", () => {
    expect(parsePreviewMessage(msg(), frame)).toEqual({ type: "table", name: "users", text: "users id email" });
  });

  it("refuse une autre source (autre fenêtre, onglet, extension)", () => {
    expect(parsePreviewMessage(msg({ source: { other: true } }), frame)).toBeNull();
    expect(parsePreviewMessage(msg({ source: null }), frame)).toBeNull();
    expect(parsePreviewMessage(msg(), null)).toBeNull();
  });

  it("refuse une origine non opaque", () => {
    expect(parsePreviewMessage(msg({ origin: "https://evil.example" }), frame)).toBeNull();
    expect(parsePreviewMessage(msg({ origin: "http://localhost:8080" }), frame)).toBeNull();
  });

  it("refuse un message mal formé", () => {
    expect(parsePreviewMessage(msg({ data: "element-selected" }), frame)).toBeNull();
    expect(parsePreviewMessage(msg({ data: { type: "other" } }), frame)).toBeNull();
    expect(
      parsePreviewMessage(msg({ data: { type: "element-selected", elementType: "script", elementName: "x" } }), frame),
    ).toBeNull();
    expect(
      parsePreviewMessage(msg({ data: { type: "element-selected", elementType: "table", elementName: "  " } }), frame),
    ).toBeNull();
  });

  it("borne la taille des champs", () => {
    const out = parsePreviewMessage(
      msg({ data: { type: "element-selected", elementType: "nav", elementName: "n".repeat(500), text: "t".repeat(500) } }),
      frame,
    );
    expect(out?.name).toHaveLength(200);
    expect(out?.text).toHaveLength(120);
  });
});

describe("échappement du HTML de prévisualisation", () => {
  it("escapeHtml couvre texte et attributs", () => {
    expect(escapeHtml(`<img src=x onerror="alert(1)">'&`)).toBe(
      "&lt;img src=x onerror=&quot;alert(1)&quot;&gt;&#39;&amp;",
    );
    expect(escapeHtml(undefined)).toBe("");
    expect(escapeHtml(42)).toBe("42");
  });

  it("scriptString ne peut pas refermer le <script>", () => {
    expect(scriptString("</script><script>alert(1)</script>")).not.toContain("</script>");
  });

  it("aucune valeur de l'architecture n'est injectée brute", () => {
    const payload = `"><script>alert('xss')</script>`;
    const html = buildPreviewHtml(
      payload,
      {
        frontend: { components: [{ name: payload, description: payload, code: payload }] },
        backend: { endpoints: [{ method: payload, path: payload, description: payload }] },
        database: { tables: [{ name: payload, columns: [payload], description: payload }] },
      },
      true,
      "http://localhost:8080",
    );
    expect(html).not.toContain("<script>alert");
    expect(html).not.toContain(`""><script`);
    expect(html).toContain("&quot;&gt;&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;");
    // Seul le script de sélection (mode édition) est présent.
    expect(html.match(/<script>/g)).toHaveLength(1);
    expect(html).toContain('var PARENT_ORIGIN = "http://localhost:8080"');
  });

  it("pas de script hors mode édition et tolère une architecture incomplète", () => {
    const html = buildPreviewHtml("App", { database: { tables: [{ name: "t", columns: undefined as unknown as string[] }] } }, false);
    expect(html).not.toContain("<script>");
    expect(html).toContain("📦 t");
  });
});
