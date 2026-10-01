// T13 : sans clé web, la synthèse du modèle est un finding non vérifié, à confiance basse,
// jamais resservi comme connaissance « kb ».
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../src/services/knowledge/index.js", () => ({
  knowledgeService: { search: vi.fn(), remember: vi.fn() },
}));
vi.mock("../src/services/research/webSearch.js", () => ({
  getWebSearchProvider: vi.fn(() => ({ id: "none", available: false, search: vi.fn(async () => []) })),
}));
vi.mock("../src/clients/iaClient.js", () => ({ synthesizeKnowledge: vi.fn() }));

const { ResearchService, cappedConfidence, isServableKnowledge, markSourcesVerified, LLM_ONLY_MAX_CONFIDENCE } = await import(
  "../src/services/research/index"
);
const { knowledgeService } = await import("../src/services/knowledge/index");
const { getWebSearchProvider } = await import("../src/services/research/webSearch");
const { synthesizeKnowledge } = await import("../src/clients/iaClient");

const U = "22222222-2222-4222-8222-222222222222";
const entry = (over: Record<string, unknown>) => ({
  id: "e1", title: "t", content: "c", summary: null, confidence: 0.9, source: null, category: "general", sources: [], ...over,
});
const synthesis = {
  title: "Synthèse",
  summary: "s",
  content: "contenu",
  keywords: [],
  domain: "general",
  confidence: 0.95,
  sources: [{ title: "inventée", url: "https://exemple.org/page" }],
};

beforeEach(() => {
  vi.mocked(knowledgeService.search).mockReset();
  vi.mocked(knowledgeService.remember).mockReset();
  vi.mocked(synthesizeKnowledge).mockReset();
  vi.mocked(knowledgeService.remember).mockImplementation(async (_u, input) => ({ entry: entry(input as never) as never, deduped: false }));
  vi.mocked(synthesizeKnowledge).mockResolvedValue(synthesis);
});

describe("règles pures", () => {
  it("URL citées vérifiées seulement si récupérées ; confiance plafonnée selon la provenance", () => {
    const fetched = [{ url: "https://a.org/x/" }];
    expect(markSourcesVerified([{ title: "A", url: "https://A.org/x" }, { title: "B", url: "https://b.org" }], fetched)).toEqual([
      { title: "A", url: "https://A.org/x", verified: true },
      { title: "B", url: "https://b.org", verified: false },
    ]);
    expect(cappedConfidence(0.95, false)).toBe(LLM_ONLY_MAX_CONFIDENCE);
    expect(cappedConfidence(0.95, true)).toBe(0.8);
    expect(cappedConfidence("x", false)).toBe(0.2);
    expect(isServableKnowledge({ source: "llm_synthesis" })).toBe(false);
    expect(isServableKnowledge({ source: "chat" })).toBe(true);
  });
});

describe("ResearchService (T13)", () => {
  it("sans web : finding 'recherche' / source llm_synthesis, confiance ≤ 0.3, URL non vérifiées", async () => {
    vi.mocked(knowledgeService.search).mockResolvedValue([]);
    const r = await new ResearchService().research(U, "question");
    const stored = vi.mocked(knowledgeService.remember).mock.calls[0][1];
    expect(stored).toMatchObject({ category: "recherche", source: "llm_synthesis", confidence: 0.3 });
    expect(stored.sources).toEqual([{ title: "inventée", url: "https://exemple.org/page", verified: false }]);
    expect(r).toMatchObject({ source: "model-synthesis", verified: false, fromCache: false });
  });

  it("un finding LLM existant n'est JAMAIS resservi comme « kb », même avec minConfidence=0", async () => {
    vi.mocked(knowledgeService.search).mockResolvedValue([entry({ source: "llm_synthesis", confidence: 0.3 })] as never);
    const r = await new ResearchService().research(U, "question", { minConfidence: 0 });
    expect(r.source).not.toBe("kb");
    expect(synthesizeKnowledge).toHaveBeenCalled();
    expect(vi.mocked(synthesizeKnowledge).mock.calls[0][0].known).toEqual([]); // findings exclus des « connus »
  });

  it("connaissance vérifiée fiable → servie depuis la KB, sans synthèse", async () => {
    vi.mocked(knowledgeService.search).mockResolvedValue([entry({ id: "ok", source: "chat", confidence: 0.8 })] as never);
    const r = await new ResearchService().research(U, "question");
    expect(r).toMatchObject({ source: "kb", verified: true });
    expect(r.entry.id).toBe("ok");
    expect(synthesizeKnowledge).not.toHaveBeenCalled();
  });

  it("avec web : source web_synthesis, URL récupérées marquées vérifiées, confiance ≤ 0.8", async () => {
    vi.mocked(knowledgeService.search).mockResolvedValue([]);
    vi.mocked(getWebSearchProvider).mockReturnValueOnce({
      id: "tavily",
      available: true,
      search: vi.fn(async () => [{ title: "p", url: "https://exemple.org/page", snippet: "s" }]),
    } as never);
    const r = await new ResearchService().research(U, "question");
    const stored = vi.mocked(knowledgeService.remember).mock.calls[0][1];
    expect(stored).toMatchObject({ source: "web_synthesis", confidence: 0.8 });
    expect(stored.sources?.[0].verified).toBe(true);
    expect(r).toMatchObject({ source: "web+synthesis", verified: true, webUsed: true });
  });
});
