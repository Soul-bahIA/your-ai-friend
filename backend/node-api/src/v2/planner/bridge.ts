// Ponts V1 → V2 (LOT 11) :
//  - `/api/agent/goal` (derrière SOULBAH_V2_GOAL_BRIDGE=1) : l'objectif est planifié comme en V1
//    (planificateur python-ia, dossiers du PC ciblé, mémoire), puis transformé par le gabarit
//    desktop_goal en mission V2 en attente d'approbation — au lieu d'une agent_task directe ;
//  - `/api/formations/:id/demos` : une démonstration décrite en langage naturel devient une
//    mission V2 via le gabarit demo_video (observer → filmer + agir → monter, vidéo vérifiée).
import { planGoal, ServiceError } from "../../clients/iaClient.js";
import { withTransaction } from "../../db.js";
import { clampAndValidatePlanSteps, compactStep } from "../../lib/agentSteps.js";
import { resolveTargetKey } from "../../services/agentKeys.js";
import { createSession, type SessionRow } from "../sessions/repo.js";
import type { TaskRow } from "../tasks/repo.js";
import { applyPlan } from "./planner.js";
import { buildFromTemplate } from "./templates.js";

export type BridgeOutcome =
  | { ok: true; session: SessionRow; tasks: TaskRow[]; understanding: string; steps: Record<string, unknown>[] }
  | { ok: false; status: number; error: string; errors?: string[]; reason?: string; agents?: { id: string; name: string }[] };

function dirsContext(dirs: readonly string[]): string {
  return dirs.length
    ? `DOSSIERS AUTORISÉS (whitelist de l'agent ciblé) — tout chemin de fichier/dossier/cwd DOIT être absolu et strictement à l'intérieur de l'un d'eux :\n${dirs.map((d) => `- ${d}`).join("\n")}`
    : "ATTENTION : aucun dossier autorisé connu pour l'agent ciblé. Toute étape fichier/commande/vidéo sera refusée — si l'objectif en nécessite, réponds feasible=false en l'expliquant.";
}

async function stepsFor(description: string, dirs: string[]): Promise<{ ok: true; steps: Record<string, unknown>[]; understanding: string } | { ok: false; status: number; error: string; reason?: string }> {
  let plan;
  try {
    plan = await planGoal(description, dirsContext(dirs));
  } catch (e) {
    if (e instanceof ServiceError) return { ok: false, status: e.status, error: e.message };
    throw e;
  }
  const raw = Array.isArray(plan.steps) ? plan.steps : [];
  if (!plan.feasible || raw.length === 0) return { ok: false, status: 422, error: "Objectif non réalisable avec les capacités actuelles de l'agent", reason: plan.reason };
  const checked = clampAndValidatePlanSteps(raw.map((s) => compactStep(s as unknown as Record<string, unknown>)));
  if (!checked.ok) return { ok: false, status: 422, error: `Plan invalide : ${checked.error}` };
  return { ok: true, steps: checked.value, understanding: plan.understanding };
}

async function sessionFromTemplate(
  userId: string,
  goal: string,
  template: "desktop_goal" | "demo_video",
  params: Record<string, unknown>,
  dirs: string[],
  environment: Record<string, unknown>,
): Promise<{ ok: true; session: SessionRow; tasks: TaskRow[] } | { ok: false; status: number; error: string; errors?: string[] }> {
  const t = buildFromTemplate(template, params);
  if (!t.ok) return { ok: false, status: 422, error: t.error };
  return withTransaction(async (client) => {
    const session = await createSession(client, userId, { goal, environment });
    const out = await applyPlan(client, session, t.plan, userId, dirs);
    if (!out.ok) throw Object.assign(new Error(out.error), { planErrors: out.errors, statusCode: out.status });
    return { ok: true as const, session: out.session, tasks: out.tasks };
  }).catch((e: Error & { planErrors?: string[]; statusCode?: number }) => {
    if (e.planErrors) return { ok: false as const, status: e.statusCode ?? 422, error: e.message, errors: e.planErrors };
    throw e;
  });
}

/** Pont /api/agent/goal → mission V2 (gabarit desktop_goal), en attente d'approbation. */
export async function goalToSession(userId: string, goal: string, opts: { agentKeyId?: string } = {}): Promise<BridgeOutcome> {
  const target = await resolveTargetKey(userId, opts.agentKeyId);
  if (!target.ok) return { ok: false, status: target.status, error: target.error, agents: target.agents };
  const dirs = target.key?.allowed_dirs ?? [];
  const s = await stepsFor(goal, dirs);
  if (!s.ok) return s;
  const out = await sessionFromTemplate(userId, goal, "desktop_goal", { goal, steps: s.steps }, dirs, { source: "api/agent/goal", agent_key_id: target.key?.id ?? null });
  return out.ok ? { ...out, understanding: s.understanding, steps: s.steps } : out;
}

/** /api/formations/:id/demos → mission V2 (gabarit demo_video). */
export async function demoToSession(
  userId: string,
  input: { formationId: string; title: string; description: string; outputDir?: string; agentKeyId?: string },
): Promise<BridgeOutcome> {
  const target = await resolveTargetKey(userId, input.agentKeyId);
  if (!target.ok) return { ok: false, status: target.status, error: target.error, agents: target.agents };
  const dirs = target.key?.allowed_dirs ?? [];
  const outputDir = input.outputDir ?? dirs[0];
  if (!outputDir) return { ok: false, status: 422, error: "Aucun dossier autorisé connu pour enregistrer la vidéo : configurez le workspace de l'agent" };
  const s = await stepsFor(input.description, dirs);
  if (!s.ok) return s;
  const out = await sessionFromTemplate(
    userId,
    `Démonstration : ${input.title}`,
    "demo_video",
    { title: input.title, steps: s.steps, output_dir: outputDir },
    dirs,
    { source: "api/formations/demos", formation_id: input.formationId, agent_key_id: target.key?.id ?? null },
  );
  return out.ok ? { ...out, understanding: s.understanding, steps: s.steps } : out;
}
