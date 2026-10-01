import { describe, expect, it } from "vitest";
import { buildKnowledgeBody, parseTags } from "@/lib/knowledge";

describe("base de connaissances (contrat §11)", () => {
  it("découpe les tags proprement", () => {
    expect(parseTags(" a, b ,, a ,c ")).toEqual(["a", "b", "c"]);
    expect(parseTags("")).toEqual([]);
  });

  it("n'envoie que les champs saisis (ni user_id, ni hash, ni version)", () => {
    const body = buildKnowledgeBody({ title: "  Titre ", content: "Contenu", category: "", source: "  ", tags: "x, y" });
    expect(body).toEqual({ title: "Titre", content: "Contenu", category: "general", source: null, tags: ["x", "y"] });
    expect(Object.keys(body)).not.toContain("user_id");
    expect(Object.keys(body)).not.toContain("content_hash");
  });
});
