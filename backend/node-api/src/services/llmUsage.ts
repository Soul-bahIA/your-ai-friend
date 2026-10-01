// Métrage des appels de modèles rapportés par python-ia (en-tête de réponse x-llm-usage,
// LOT 5 : calls, input_tokens, output_tokens, cost_usd, models) :
//  - journalisé à chaque appel et agrégé en mémoire (llmUsageTotals) ;
//  - PERSISTÉ dans soulbah.tool_calls (kind = 'model') dès que l'appel est attribuable à un
//    utilisateur — contexte explicite, sinon requête courante (JWT ou clé agent) — et que la
//    base répond. Une ligne par appel à python-ia (les sauts de repli sont agrégés par
//    python-ia ; la liste des modèles va dans metadata.models). Jamais bloquant : un échec
//    d'écriture est journalisé, la réponse à l'utilisateur n'en dépend pas.
import { isDbReady, pool } from "../db.js";
import { logger } from "../lib/logger.js";
import { currentUserId } from "../lib/requestStore.js";

export interface LlmUsage {
  calls: number;
  input_tokens: number;
  output_tokens: number;
  /** Coût estimé (USD) des sauts au tarif connu ; null si aucun tarif connu. */
  cost_usd: number | null;
  /** "fournisseur:modèle" distincts, triés. */
  models: string[];
}

export interface ToolCallContext {
  userId: string;
  sessionId?: string | null;
  taskId?: string | null;
}

const totals = { calls: 0, input_tokens: 0, output_tokens: 0, cost_usd: 0, byPath: new Map<string, LlmUsage>() };

const nonNeg = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? Math.trunc(v) : 0);
const cost = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : null);

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
      cost_usd: cost(v.cost_usd),
      models: Array.isArray(v.models) ? v.models.filter((m): m is string => typeof m === "string").slice(0, 10) : [],
    };
  } catch {
    return null;
  }
}

/** Nom de l'appel dans tool_calls : chemin python-ia → identifiant pointé ("/agent/plan" → "agent.plan"). */
export function toolCallName(path: string): string {
  const name = path.replace(/^\/+/, "").replace(/\/+/g, ".").replace(/[^a-zA-Z0-9_.-]/g, "_");
  return (name || "python-ia").slice(0, 120);
}

/** (fournisseur, modèle) quand un seul couple a servi ; sinon null (détail dans metadata.models). */
export function splitSingleModel(models: string[]): { provider: string | null; model: string | null } {
  if (models.length !== 1) return { provider: null, model: null };
  const i = models[0].indexOf(":");
  if (i <= 0) return { provider: null, model: models[0].slice(0, 120) || null };
  return { provider: models[0].slice(0, i).slice(0, 120), model: models[0].slice(i + 1).slice(0, 120) || null };
}

/** Requête d'insertion (pure, testable) d'un appel de modèle dans soulbah.tool_calls. */
export function modelCallRow(path: string, usage: LlmUsage, ctx: ToolCallContext): { sql: string; values: unknown[] } {
  const { provider, model } = splitSingleModel(usage.models);
  return {
    sql: `INSERT INTO soulbah.tool_calls
            (user_id, session_id, task_id, kind, name, provider, model, status, input_tokens, output_tokens, cost_usd, metadata)
          VALUES ($1, $2, $3, 'model', $4, $5, $6, 'ok', $7, $8, $9, $10::jsonb)
          RETURNING id`,
    values: [
      ctx.userId,
      ctx.sessionId ?? null,
      ctx.taskId ?? null,
      toolCallName(path),
      provider,
      model,
      usage.input_tokens,
      usage.output_tokens,
      usage.cost_usd,
      JSON.stringify({ path, calls: usage.calls, models: usage.models, cost_known: usage.cost_usd !== null }),
    ],
  };
}

/** Écrit l'appel dans soulbah.tool_calls ; false si sauté (base non prête, aucun appel) ou en échec. */
export async function persistModelCall(path: string, usage: LlmUsage, ctx: ToolCallContext): Promise<boolean> {
  if (usage.calls <= 0 || !isDbReady()) return false;
  const q = modelCallRow(path, usage, ctx);
  try {
    await pool.query(q.sql, q.values);
    return true;
  } catch (e) {
    logger.warn({ path, err: (e as Error).message }, "tool_calls : métrage du modèle non enregistré");
    return false;
  }
}

/**
 * Agrège, journalise et persiste un usage rapporté par python-ia. `ctx` explicite, sinon
 * l'utilisateur de la requête courante ; sans utilisateur attribuable, pas de ligne.
 * Renvoie true si une ligne tool_calls a été écrite.
 */
export async function recordLlmUsage(path: string, usage: LlmUsage, ctx?: ToolCallContext): Promise<boolean> {
  totals.calls += usage.calls;
  totals.input_tokens += usage.input_tokens;
  totals.output_tokens += usage.output_tokens;
  if (usage.cost_usd !== null) totals.cost_usd += usage.cost_usd;
  const cur = totals.byPath.get(path) ?? { calls: 0, input_tokens: 0, output_tokens: 0, cost_usd: 0, models: [] };
  cur.calls += usage.calls;
  cur.input_tokens += usage.input_tokens;
  cur.output_tokens += usage.output_tokens;
  if (usage.cost_usd !== null) cur.cost_usd = (cur.cost_usd ?? 0) + usage.cost_usd;
  cur.models = [...new Set([...cur.models, ...usage.models])].slice(0, 20);
  totals.byPath.set(path, cur);
  logger.info({ path, llm_usage: usage }, "usage LLM (python-ia)");

  const context = ctx ?? (() => {
    const userId = currentUserId();
    return userId ? { userId } : undefined;
  })();
  if (!context) return false;
  return persistModelCall(path, usage, context);
}

/** Agrégats depuis le démarrage (par processus ; la vérité durable est soulbah.tool_calls). */
export function llmUsageTotals() {
  return {
    calls: totals.calls,
    input_tokens: totals.input_tokens,
    output_tokens: totals.output_tokens,
    cost_usd: Math.round(totals.cost_usd * 1e8) / 1e8,
    by_path: Object.fromEntries(totals.byPath),
  };
}
