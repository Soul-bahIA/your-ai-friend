// Planificateur V2 (LOT 11, audit §9.3) : gabarit OU proposition d'un modèle → validateDag →
// plan posé sur la session (AWAITING_APPROVAL) → approbation de l'utilisateur → RUNNING. Le
// modèle ne décide de rien : un plan refusé par validateDag n'est jamais posé (422 + erreurs).
import { proposePlan, ServiceError } from "../../clients/iaClient.js";
import type { Queryable } from "../../db.js";
import { getUserAllowedDirs } from "../../services/agentKeys.js";
import { userActor } from "../audit.js";
import { setPlan, type SessionRow } from "../sessions/repo.js";
import type { TaskRow } from "../tasks/repo.js";
import { ROLES } from "./roles.js";
import { buildFromTemplate } from "./templates.js";
import { validateDag } from "./validateDag.js";

export interface ProposeInput {
  template?: string;
  params?: Record<string, unknown>;
  /** Sans gabarit : objectif proposé à python-ia (/v2/planner/propose). */
  goal?: string;
  context?: string;
  /** Dossiers autorisés (sinon : union des PC de l'utilisateur). */
  allowedDirs?: string[];
}

export type ProposeOutcome =
  | { ok: true; session: SessionRow; tasks: TaskRow[]; source: "template" | "llm"; understanding?: string }
  | { ok: false; status: number; error: string; errors?: string[]; plan?: unknown; reason?: string };

/** Plan brut depuis un gabarit ou le modèle (sans validation métier). */
export async function draftPlan(
  session: SessionRow,
  input: ProposeInput,
  allowedDirs: string[],
): Promise<{ ok: true; plan: unknown; source: "template" | "llm"; understanding?: string } | { ok: false; status: number; error: string; reason?: string }> {
  if (input.template) {
    const t = buildFromTemplate(input.template, input.params ?? {});
    return t.ok ? { ok: true, plan: t.plan, source: "template" } : { ok: false, status: 400, error: t.error };
  }
  const goal = (input.goal ?? session.goal).trim();
  try {
    const proposal = await proposePlan({
      goal,
      roles: ROLES.map((r) => ({ name: r.name, description: r.description, executor: r.executor, max_security_level: r.max_security_level, tools: [...r.tools] })),
      allowed_dirs: allowedDirs,
      max_security_level: session.max_security_level,
      context: input.context,
    });
    if (!proposal.feasible) return { ok: false, status: 422, error: "Objectif jugé irréalisable par le planificateur", reason: proposal.reason };
    return { ok: true, plan: proposal.plan, source: "llm", understanding: proposal.understanding };
  } catch (e) {
    if (e instanceof ServiceError) return { ok: false, status: e.status, error: e.message };
    throw e;
  }
}

/** Valide un plan brut et le pose sur la session (dans la transaction de l'appelant). */
export async function applyPlan(
  q: Queryable,
  session: SessionRow,
  rawPlan: unknown,
  userId: string,
  allowedDirs: string[],
): Promise<{ ok: true; session: SessionRow; tasks: TaskRow[] } | { ok: false; status: number; error: string; errors: string[] }> {
  const check = validateDag(rawPlan, { userId, allowedDirs, sessionMaxLevel: session.max_security_level });
  if (!check.ok) return { ok: false, status: 422, error: "Plan refusé par la validation", errors: check.errors };
  const out = await setPlan(q, session, check.plan, userActor(userId));
  return { ok: true, ...out };
}

export async function allowedDirsFor(userId: string, explicit?: string[]): Promise<string[]> {
  if (explicit && explicit.length) return explicit;
  return getUserAllowedDirs(userId);
}
