// Machine à états des tâches V2 (LOT 7, audit §9.4) — PURE. La même table est appliquée en
// base par le trigger soulbah.tasks_check_transition (LOT 4) : node-api décide, la base refuse
// tout ce que le code laisserait passer. Toute transition absente de la table est interdite.
export const TASK_STATUSES = [
  "PENDING",
  "READY",
  "RUNNING",
  "WAITING",
  "BLOCKED",
  "VALIDATING",
  "RETRYING",
  "COMPLETED",
  "FAILED",
  "CANCELLED",
] as const;
export type TaskStatus = (typeof TASK_STATUSES)[number];

export const TERMINAL_TASK_STATUSES: readonly TaskStatus[] = ["COMPLETED", "FAILED", "CANCELLED"];
/** États qui détiennent un bail (le reaper les surveille). */
export const LEASED_STATUSES: readonly TaskStatus[] = ["RUNNING", "WAITING", "VALIDATING"];

/** Transitions nominales (§9.4) : de → vers. CANCELLED est traité à part (tout état non terminal). */
export const TRANSITIONS: Readonly<Record<TaskStatus, readonly TaskStatus[]>> = {
  PENDING: ["READY", "BLOCKED"],
  READY: ["RUNNING"],
  RUNNING: ["WAITING", "BLOCKED", "VALIDATING", "RETRYING", "FAILED"],
  WAITING: ["RUNNING", "BLOCKED", "RETRYING", "FAILED"],
  BLOCKED: ["READY", "PENDING", "FAILED"],
  VALIDATING: ["COMPLETED", "RETRYING", "FAILED"],
  RETRYING: ["READY"],
  COMPLETED: [],
  // Relance manuelle par l'utilisateur, auditée ; sinon FAILED est terminal.
  FAILED: ["READY"],
  CANCELLED: [],
};

export function isTaskStatus(v: unknown): v is TaskStatus {
  return typeof v === "string" && (TASK_STATUSES as readonly string[]).includes(v);
}

export function isTerminal(status: TaskStatus): boolean {
  return TERMINAL_TASK_STATUSES.includes(status);
}

/** Vrai si `from → to` figure dans la table (ou annulation depuis un état non terminal). */
export function canTransition(from: TaskStatus, to: TaskStatus): boolean {
  if (from === to) return false;
  if (to === "CANCELLED") return !isTerminal(from);
  return TRANSITIONS[from].includes(to);
}

export class IllegalTransition extends Error {
  constructor(
    public readonly from: TaskStatus,
    public readonly to: TaskStatus,
  ) {
    super(`transition ${from} → ${to} interdite (audit §9.4)`);
  }
}

export function assertTransition(from: TaskStatus, to: TaskStatus): void {
  if (!canTransition(from, to)) throw new IllegalTransition(from, to);
}

/** Toutes les paires autorisées (pour les tests exhaustifs et la documentation). */
export function allowedPairs(): [TaskStatus, TaskStatus][] {
  const out: [TaskStatus, TaskStatus][] = [];
  for (const from of TASK_STATUSES) for (const to of TASK_STATUSES) if (canTransition(from, to)) out.push([from, to]);
  return out;
}

/** Backoff des reprises (§9.4) : 30 s, 2 min, 8 min, puis 8 min. */
export const RETRY_BACKOFF_MS: readonly number[] = [30_000, 120_000, 480_000];
export function retryBackoffMs(retryCount: number): number {
  const i = Math.max(0, Math.min(RETRY_BACKOFF_MS.length - 1, Math.trunc(retryCount)));
  return RETRY_BACKOFF_MS[i];
}

/** Délai d'escalade d'un blocage avant FAILED (24 h par défaut). */
export const DEFAULT_ESCALATION_MS = 24 * 60 * 60 * 1000;

/** Erreurs non rejouables (§9.4) : refus de politique, run simulé. */
export const NON_RETRYABLE_REASONS = ["policy_refused", "simulated", "cancelled_by_user"] as const;
export type FailureReason = (typeof NON_RETRYABLE_REASONS)[number] | "crash" | "timeout" | "lease_expired" | "criteria_failed" | "error";

/** Décision après un échec : RETRYING si des reprises restent et que la cause est rejouable, sinon FAILED. */
export function afterFailure(retryCount: number, maxRetries: number, reason: FailureReason): "RETRYING" | "FAILED" {
  if ((NON_RETRYABLE_REASONS as readonly string[]).includes(reason)) return "FAILED";
  return retryCount < maxRetries ? "RETRYING" : "FAILED";
}
