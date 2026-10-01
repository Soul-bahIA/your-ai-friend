// Revue de la mémoire d'exécution de l'agent (contrat LOT 1 §9) : l'évaluateur et
// l'auto-amélioration écrivent en `proposed` ; seule une action EXPLICITE de l'utilisateur
// (PATCH /api/agent/memory/:id {status}) valide ou rejette une entrée. Une bonne pratique /
// optimisation proposée ne nourrit jamais la planification ; une entrée rejetée est exclue.
import { ApiError, apiFetch } from "@/lib/api";

export type MemoryStatus = "proposed" | "validated" | "rejected";
export type MemoryDecision = Exclude<MemoryStatus, "proposed">;

export interface MemoryEntry {
  id: string;
  type: string;
  level: string;
  /** Statut EFFECTIF renvoyé par l'API (un « validated » sans validateur est lu « proposed »). */
  status: MemoryStatus;
  goal: string;
  content: string;
  created_at: string;
}

/** Objectif des leçons générales (node-api GENERAL_GOAL). */
export const GENERAL_GOAL = "(général)";

export const MEMORY_TYPE_LABELS: Record<string, string> = {
  error: "Erreur",
  solution: "Solution",
  practice: "Bonne pratique",
};

export const MEMORY_LEVEL_LABELS: Record<string, string> = {
  working: "travail",
  project: "projet",
  user: "utilisateur",
  technical: "technique",
  documentary: "documentaire",
  workflow: "workflow",
  error: "erreurs",
  optimization: "optimisation",
};

const STATUSES: readonly string[] = ["proposed", "validated", "rejected"];

const isRecord = (v: unknown): v is Record<string, unknown> =>
  !!v && typeof v === "object" && !Array.isArray(v);

/** Normalise la liste renvoyée par GET /api/agent/memory (lignes invalides ignorées). */
export function normalizeMemoryRows(raw: unknown): MemoryEntry[] {
  if (!Array.isArray(raw)) return [];
  const out: MemoryEntry[] = [];
  for (const row of raw) {
    if (!isRecord(row) || typeof row.id !== "string" || !row.id) continue;
    if (typeof row.content !== "string" || !row.content.trim()) continue;
    out.push({
      id: row.id,
      type: typeof row.type === "string" ? row.type : "practice",
      level: typeof row.level === "string" ? row.level : "workflow",
      status: typeof row.status === "string" && STATUSES.includes(row.status) ? (row.status as MemoryStatus) : "proposed",
      goal: typeof row.goal === "string" ? row.goal : GENERAL_GOAL,
      content: row.content,
      created_at: typeof row.created_at === "string" ? row.created_at : "",
    });
  }
  return out;
}

/** Entrées de mémoire d'un statut donné (par défaut : celles à valider). */
export async function listMemories(status: MemoryStatus = "proposed"): Promise<MemoryEntry[]> {
  const data = await apiFetch<{ memory?: unknown }>(`/api/agent/memory?status=${encodeURIComponent(status)}`);
  return normalizeMemoryRows(data?.memory);
}

/**
 * Valide ou rejette une entrée (action explicite de l'utilisateur, §9).
 * Renvoie false si l'entrée n'existe plus (404) ; les autres erreurs sont levées.
 */
export async function reviewMemory(id: string, decision: MemoryDecision): Promise<boolean> {
  try {
    await apiFetch(`/api/agent/memory/${encodeURIComponent(id)}`, { method: "PATCH", json: { status: decision } });
    return true;
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) return false;
    throw err;
  }
}

export type SelfImproveOutcome =
  | { kind: "ok"; proposed: number; analyzed: number }
  /** 422 : pas encore assez d'exécutions réelles à analyser. */
  | { kind: "not_enough_history"; message: string };

/** POST /api/agent/self-improve : les optimisations sont PROPOSÉES (à valider ensuite). */
export async function runSelfImprove(): Promise<SelfImproveOutcome> {
  try {
    const data = await apiFetch<{ tasks_analyzed?: unknown; report?: { suggestions?: unknown } }>(
      "/api/agent/self-improve",
      { method: "POST", json: {} },
    );
    const suggestions = data?.report?.suggestions;
    return {
      kind: "ok",
      proposed: Array.isArray(suggestions) ? suggestions.length : 0,
      analyzed: typeof data?.tasks_analyzed === "number" ? data.tasks_analyzed : 0,
    };
  } catch (err) {
    if (err instanceof ApiError && err.status === 422) return { kind: "not_enough_history", message: err.message };
    throw err;
  }
}
