// LOT 5 — métrage des appels de modèles dans soulbah.tool_calls (x-llm-usage → ligne kind='model').
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { FastifyRequest } from "fastify";
import { fakeDb } from "./helpers/fakeDb";

vi.mock("../src/db.js", async () => (await import("./helpers/fakeDb")).dbMock);

const { parseLlmUsage, toolCallName, splitSingleModel, modelCallRow, recordLlmUsage, llmUsageTotals } = await import(
  "../src/services/llmUsage"
);
const { requestStore } = await import("../src/lib/requestStore");

const U = "a0000000-0000-4000-8000-0000000000aa";
const usage = { calls: 2, input_tokens: 120, output_tokens: 40, cost_usd: 0.00123, models: ["anthropic:claude-opus-5-5"] };

beforeEach(() => fakeDb.reset());

describe("parseLlmUsage (en-tête x-llm-usage)", () => {
  it("lit calls, jetons, cost_usd et modèles ; tolère les valeurs absentes ou invalides", () => {
    expect(parseLlmUsage(JSON.stringify(usage))).toEqual(usage);
    expect(parseLlmUsage('{"calls":1,"cost_usd":null,"models":["fake:fake-model", 3]}')).toEqual({
      calls: 1,
      input_tokens: 0,
      output_tokens: 0,
      cost_usd: null,
      models: ["fake:fake-model"],
    });
    expect(parseLlmUsage('{"calls":"x","cost_usd":-1,"input_tokens":-5}')).toMatchObject({ calls: 0, cost_usd: null, input_tokens: 0 });
    expect(parseLlmUsage("")).toBeNull();
    expect(parseLlmUsage(null)).toBeNull();
    expect(parseLlmUsage("pas du json")).toBeNull();
    expect(parseLlmUsage("[1]")).toBeNull();
  });
});

describe("ligne tool_calls", () => {
  it("nom pointé depuis le chemin python-ia", () => {
    expect(toolCallName("/agent/plan")).toBe("agent.plan");
    expect(toolCallName("/v2/models/complete")).toBe("v2.models.complete");
    expect(toolCallName("///")).toBe("python-ia");
    expect(toolCallName("/a b/é")).toBe("a_b._");
  });

  it("fournisseur et modèle seulement quand un seul couple a servi", () => {
    expect(splitSingleModel(["anthropic:claude-opus-5-5"])).toEqual({ provider: "anthropic", model: "claude-opus-5-5" });
    expect(splitSingleModel(["anthropic:a", "openai:b"])).toEqual({ provider: null, model: null });
    expect(splitSingleModel([])).toEqual({ provider: null, model: null });
    expect(splitSingleModel(["sans-deux-points"])).toEqual({ provider: null, model: "sans-deux-points" });
  });

  it("modelCallRow : kind model, statut ok, contexte et métadonnées", () => {
    const q = modelCallRow("/agent/plan", usage, { userId: U, sessionId: null, taskId: "t1" });
    expect(q.sql).toContain("INSERT INTO soulbah.tool_calls");
    expect(q.sql).toContain("'model'");
    expect(q.values.slice(0, 9)).toEqual([U, null, "t1", "agent.plan", "anthropic", "claude-opus-5-5", 120, 40, 0.00123]);
    expect(JSON.parse(q.values[9] as string)).toEqual({ path: "/agent/plan", calls: 2, models: usage.models, cost_known: true });
  });
});

describe("recordLlmUsage : agrégation + persistance", () => {
  it("contexte explicite → une ligne écrite ; agrégats mis à jour", async () => {
    fakeDb.on(/INSERT INTO soulbah\.tool_calls/, { rows: [{ id: "x" }] });
    const before = llmUsageTotals();
    expect(await recordLlmUsage("/agent/plan", usage, { userId: U })).toBe(true);
    const ins = fakeDb.find(/INSERT INTO soulbah\.tool_calls/);
    expect(ins.length).toBe(1);
    expect(ins[0].values[0]).toBe(U);
    const after = llmUsageTotals();
    expect(after.calls - before.calls).toBe(2);
    expect(after.input_tokens - before.input_tokens).toBe(120);
    expect(after.cost_usd - before.cost_usd).toBeCloseTo(0.00123, 8);
    expect(after.by_path["/agent/plan"].models).toContain("anthropic:claude-opus-5-5");
  });

  it("sans contexte ni requête courante → agrégé mais pas de ligne", async () => {
    expect(await recordLlmUsage("/agent/plan", usage)).toBe(false);
    expect(fakeDb.find(/INSERT INTO soulbah\.tool_calls/).length).toBe(0);
  });

  it("requête courante (JWT) → attribuée à request.user ; clé agent → agentUserId", async () => {
    fakeDb.on(/INSERT INTO soulbah\.tool_calls/, { rows: [{ id: "x" }] });
    const jwtReq = { user: { id: U } } as unknown as FastifyRequest;
    expect(await requestStore.run(jwtReq, () => recordLlmUsage("/agent/evaluate", usage))).toBe(true);
    const agentReq = { agentUserId: "b0000000-0000-4000-8000-0000000000bb" } as unknown as FastifyRequest;
    expect(await requestStore.run(agentReq, () => recordLlmUsage("/agent/evaluate", usage))).toBe(true);
    const ins = fakeDb.find(/INSERT INTO soulbah\.tool_calls/);
    expect(ins.map((i) => i.values[0])).toEqual([U, "b0000000-0000-4000-8000-0000000000bb"]);
    expect(ins[0].values[3]).toBe("agent.evaluate");
  });

  it("aucun appel LLM (calls = 0) → pas de ligne ; erreur d'écriture → false sans exception", async () => {
    expect(await recordLlmUsage("/health", { ...usage, calls: 0 }, { userId: U })).toBe(false);
    fakeDb.on(/INSERT INTO soulbah\.tool_calls/, () => {
      throw new Error("relation inexistante");
    });
    expect(await recordLlmUsage("/agent/plan", usage, { userId: U })).toBe(false);
  });
});
