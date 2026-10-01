// LOT 5 — métrage des modèles sur un VRAI Postgres migré V2 : la ligne soulbah.tool_calls est
// écrite avec le schéma du LOT 4 (CHECK, FK utilisateur). Sautée sans TEST_DATABASE_URL.
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const DB_URL = (process.env.TEST_DATABASE_URL ?? "").trim();
const RUN = DB_URL !== "";
const U = "a0000000-0000-4000-8000-0000000000c5";
if (RUN) {
  process.env.DATABASE_URL = DB_URL;
  process.env.DATABASE_SSL = "false";
  process.env.PG_SSL_CA = "";
  process.env.SOULBAH_ENV = "test";
}

type Pool = { query: (sql: string, values?: unknown[]) => Promise<{ rows: Record<string, unknown>[] }>; end: () => Promise<void> };

describe.skipIf(!RUN)("soulbah.tool_calls sur Postgres réel", () => {
  let pool: Pool;
  let recordLlmUsage: typeof import("../../src/services/llmUsage").recordLlmUsage;

  beforeAll(async () => {
    const db = (await import("../../src/db")) as unknown as { pool: Pool; initDb: () => Promise<void> };
    pool = db.pool;
    await db.initDb();
    ({ recordLlmUsage } = await import("../../src/services/llmUsage"));
    await pool.query("INSERT INTO auth.users (id, email) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING", [U, "tool-calls@soulbah.local"]);
  });

  afterAll(async () => {
    await pool.query("DELETE FROM soulbah.tool_calls WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM user_roles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM profiles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM auth.users WHERE id = $1", [U]);
    await pool.end();
  });

  it("un appel au tarif connu → ligne kind=model avec coût ; un appel sans tarif → cost_usd NULL", async () => {
    expect(
      await recordLlmUsage(
        "/agent/plan",
        { calls: 2, input_tokens: 1000, output_tokens: 200, cost_usd: 0.0084, models: ["anthropic:claude-opus-5-5"] },
        { userId: U },
      ),
    ).toBe(true);
    expect(
      await recordLlmUsage("/v2/models/complete", { calls: 1, input_tokens: 11, output_tokens: 7, cost_usd: null, models: ["fake:fake-model"] }, { userId: U }),
    ).toBe(true);

    const { rows } = await pool.query(
      "SELECT kind, name, provider, model, status, input_tokens, output_tokens, cost_usd, metadata FROM soulbah.tool_calls WHERE user_id = $1 ORDER BY created_at",
      [U],
    );
    expect(rows.length).toBe(2);
    expect(rows[0]).toMatchObject({ kind: "model", name: "agent.plan", provider: "anthropic", model: "claude-opus-5-5", status: "ok", input_tokens: 1000, output_tokens: 200 });
    expect(Number(rows[0].cost_usd)).toBeCloseTo(0.0084, 6);
    expect((rows[0].metadata as { calls: number }).calls).toBe(2);
    expect(rows[1]).toMatchObject({ name: "v2.models.complete", provider: "fake", model: "fake-model", cost_usd: null });
    expect((rows[1].metadata as { cost_known: boolean }).cost_known).toBe(false);
  });

  it("budget : le coût du jour se lit par utilisateur (index partiel kind=model)", async () => {
    const { rows } = await pool.query(
      `SELECT coalesce(sum(cost_usd), 0) AS spent, count(*) AS n FROM soulbah.tool_calls
        WHERE user_id = $1 AND kind = 'model' AND created_at >= date_trunc('day', now() AT TIME ZONE 'UTC')`,
      [U],
    );
    expect(Number(rows[0].spent)).toBeCloseTo(0.0084, 6);
    expect(Number(rows[0].n)).toBe(2);
  });
});
