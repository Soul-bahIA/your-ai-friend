// Métrage des appels LLM rapportés par python-ia (en-tête de réponse x-llm-usage) :
// journalisé à chaque appel et agrégé en mémoire, en attendant la table tool_calls (V2).
import { logger } from "../lib/logger.js";

export interface LlmUsage {
  calls: number;
  input_tokens: number;
  output_tokens: number;
  models: string[];
}

const totals = { calls: 0, input_tokens: 0, output_tokens: 0, byPath: new Map<string, LlmUsage>() };

const nonNeg = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? Math.trunc(v) : 0);

/** Analyse (tolérante) de l'en-tête x-llm-usage ; null si absent ou invalide. */
export function parseLlmUsage(raw: string | null | undefined): LlmUsage | null {
  if (!raw) return null;
  try {
    const v = JSON.parse(raw) as Record<string, unknown>;
    if (!v || typeof v !== "object" || Array.isArray(v)) return null;
    return {
      calls: nonNeg(v.calls),
      input_tokens: nonNeg(v.input_tokens),
      output_tokens: nonNeg(v.output_tokens),
      models: Array.isArray(v.models) ? v.models.filter((m): m is string => typeof m === "string").slice(0, 10) : [],
    };
  } catch {
    return null;
  }
}

export function recordLlmUsage(path: string, usage: LlmUsage): void {
  totals.calls += usage.calls;
  totals.input_tokens += usage.input_tokens;
  totals.output_tokens += usage.output_tokens;
  const cur = totals.byPath.get(path) ?? { calls: 0, input_tokens: 0, output_tokens: 0, models: [] };
  cur.calls += usage.calls;
  cur.input_tokens += usage.input_tokens;
  cur.output_tokens += usage.output_tokens;
  cur.models = [...new Set([...cur.models, ...usage.models])].slice(0, 20);
  totals.byPath.set(path, cur);
  logger.info({ path, llm_usage: usage }, "usage LLM (python-ia)");
}

/** Agrégats depuis le démarrage (futur métrage des coûts). */
export function llmUsageTotals() {
  return {
    calls: totals.calls,
    input_tokens: totals.input_tokens,
    output_tokens: totals.output_tokens,
    by_path: Object.fromEntries(totals.byPath),
  };
}
