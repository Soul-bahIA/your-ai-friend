// Couche de requêtes simulée pour les tests de routes (Supabase en pause : aucune DB réelle).
// Les règles sont évaluées de la plus récente à la plus ancienne (la dernière gagne).
/* eslint-disable @typescript-eslint/no-explicit-any */
export interface FakeResult {
  rows: any[];
  rowCount: number;
}
type Partial = { rows?: any[]; rowCount?: number };
type Responder = (sql: string, values: unknown[]) => Partial | undefined | void | Promise<Partial | undefined | void>;

export class FakeDb {
  calls: { sql: string; values: unknown[] }[] = [];
  private rules: { match: RegExp; respond: Responder }[] = [];

  reset(): void {
    this.calls = [];
    this.rules = [];
  }

  on(match: RegExp, respond: Responder | Partial): this {
    this.rules.push({ match, respond: typeof respond === "function" ? respond : () => respond });
    return this;
  }

  query = async (sql: unknown, values: unknown[] = []): Promise<FakeResult> => {
    const s = String(sql);
    this.calls.push({ sql: s, values });
    for (let i = this.rules.length - 1; i >= 0; i--) {
      const r = this.rules[i];
      if (!r.match.test(s)) continue;
      const out = await r.respond(s, values);
      if (out) {
        const rows = out.rows ?? [];
        return { rows, rowCount: out.rowCount ?? rows.length };
      }
    }
    return { rows: [], rowCount: 0 };
  };

  find(re: RegExp): { sql: string; values: unknown[] }[] {
    return this.calls.filter((c) => re.test(c.sql));
  }
}

export const fakeDb = new FakeDb();

/** Remplace src/db.ts : pool.query et withTransaction passent par fakeDb. */
export const dbMock = {
  pool: { query: (sql: unknown, values?: unknown[]) => fakeDb.query(sql, values), end: async () => {}, on: () => {} },
  withTransaction: async <T>(fn: (client: { query: FakeDb["query"]; release: () => void }) => Promise<T>) =>
    fn({ query: fakeDb.query, release: () => {} }),
  initDb: async () => {},
  isDbReady: () => true,
};
