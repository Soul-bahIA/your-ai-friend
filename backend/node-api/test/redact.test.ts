import { describe, expect, it } from "vitest";
import { maskTypedText, omitTypedText } from "../src/lib/redact.js";

describe("maskTypedText — valeurs non textuelles (C§12)", () => {
  it("masque aussi un text/content numérique, tableau ou objet", () => {
    const out = maskTypedText({
      steps: [
        { type: "type_text", text: 123456 },
        { type: "write_file", content: ["secret", "data"] },
        { type: "write_file", content: { nested: "secret" } },
      ],
    });
    const serialized = JSON.stringify(out);
    expect(serialized).not.toContain("123456");
    expect(serialized).not.toContain("secret");
    expect(out.steps[0].text).toMatch(/^\[texte masqué : \d+ car\.\]$/);
  });

  it("laisse les champs absents ou null intacts", () => {
    expect(maskTypedText({ text: null, other: 1 })).toEqual({ text: null, other: 1 });
  });
});

describe("omitTypedText — valeurs non textuelles", () => {
  it("retire text/content quel que soit leur type", () => {
    const out = omitTypedText({ type: "type_text", text: 42, content: ["x"], path: "a.txt" });
    expect(out).toEqual({ type: "type_text", path: "a.txt" });
  });
});
