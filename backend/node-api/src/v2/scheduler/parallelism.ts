// Parallélisme effectif (LOT 7, audit §9.6) : minimum de quatre plafonds, relu à chaque tick.
//   SOULBAH_MAX_PARALLEL_AGENTS (global) · user_settings.max_parallel_agents · sessions.max_parallel_agents
//   (surcharge par mission, NULL = aucune) · runtimes.max_slots (capacité du PC).
// Baisser une valeur ne bloque que les NOUVEAUX baux : les tâches en cours continuent.
export const DEFAULT_MAX_PARALLEL_AGENTS = 6;
export const MAX_PARALLEL_HARD_LIMIT = 32;

export interface ParallelismInputs {
  global?: number | null;
  user?: number | null;
  session?: number | null;
  runtime?: number | null;
}

function clampCap(v: number | null | undefined): number | null {
  if (v === null || v === undefined || !Number.isFinite(v)) return null;
  return Math.max(1, Math.min(MAX_PARALLEL_HARD_LIMIT, Math.trunc(v)));
}

/** Plafond effectif (≥ 1). */
export function effectiveMaxParallel(inputs: ParallelismInputs): number {
  const caps = [inputs.global ?? DEFAULT_MAX_PARALLEL_AGENTS, inputs.user, inputs.session, inputs.runtime]
    .map(clampCap)
    .filter((v): v is number => v !== null);
  return caps.length ? Math.min(...caps) : DEFAULT_MAX_PARALLEL_AGENTS;
}

/** Baux attribuables maintenant : plafond − tâches déjà en cours, borné par les slots libres demandés. */
export function grantableSlots(maxParallel: number, running: number, requested: number): number {
  return Math.max(0, Math.min(Math.max(0, Math.trunc(requested)), maxParallel - Math.max(0, running)));
}

/** Lecture tolérante de SOULBAH_MAX_PARALLEL_AGENTS. */
export function parseGlobalMaxParallel(raw: string | undefined): number {
  const n = Number(raw);
  return raw !== undefined && raw.trim() !== "" && Number.isFinite(n) ? (clampCap(n) ?? DEFAULT_MAX_PARALLEL_AGENTS) : DEFAULT_MAX_PARALLEL_AGENTS;
}
