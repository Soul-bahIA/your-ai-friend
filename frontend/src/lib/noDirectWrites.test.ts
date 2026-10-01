import { describe, expect, it } from "vitest";

// Sources de l'application (hors tests et client Supabase généré), lues brutes.
const sources = import.meta.glob(["../**/*.{ts,tsx}", "!../**/*.test.{ts,tsx}", "!../integrations/**"], {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

/** Écritures Supabase directes (insert/update/upsert/delete) sur `table`, chaînées sur plusieurs lignes ou non. */
const directWrite = (table: string) =>
  new RegExp(`\\.from\\(\\s*["'\`]${table}["'\`]\\s*\\)\\s*\\.\\s*(insert|update|upsert|delete)\\s*\\(`);

const offenders = (table: string) =>
  Object.entries(sources)
    .filter(([, src]) => directWrite(table).test(src))
    .map(([path]) => path);

describe("aucune écriture directe via Supabase sur les tables gardées par l'API", () => {
  it("le scan voit bien les sources de l'application", () => {
    expect(Object.keys(sources).some((p) => p.endsWith("components/AgentTasksPanel.tsx"))).toBe(true);
    expect(directWrite("agent_tasks").test('supabase\n  .from("agent_tasks")\n  .delete()\n  .eq("id", id)')).toBe(true);
    expect(directWrite("agent_tasks").test('supabase.from("agent_tasks").select("*")')).toBe(false);
  });

  it("agent_tasks : suppression via DELETE /api/agent-tasks/:id (S9 — garde « terminée seulement »)", () => {
    expect(offenders("agent_tasks")).toEqual([]);
  });

  it("agent_memory / agent_events / knowledge_base : écritures via l'API uniquement (§9, §8, §11)", () => {
    expect(offenders("agent_memory")).toEqual([]);
    expect(offenders("agent_events")).toEqual([]);
    expect(offenders("knowledge_base")).toEqual([]);
  });
});
