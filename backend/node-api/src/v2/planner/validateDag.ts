// validateDag (LOT 11, audit §9.3 « Planner », §13 ligne 11) : règles métier d'un plan, au-delà
// de la forme (sessions/dag.ts). Toute violation est listée (pas seulement la première) pour que
// le planificateur — humain ou modèle — puisse corriger en une fois.
//
//  1. forme valide, pas de cycle (validatePlan) ;
//  2. rôle connu ; un rôle exécuté par P1 n'a pas d'étapes ;
//  3. chaque étape : outil du catalogue, autorisé pour le rôle, paramètres valides ;
//  4. niveaux : niveau du nœud ≥ niveau de chacun de ses outils, ≤ plafond du rôle, ≤ plafond de
//     la mission ;
//  5. chemins : absolus, dans les dossiers autorisés, hors deny-list (.env, .git, clés…) ;
//  6. critères : valides ; un nœud à effet (L2+, ou outil à confirmation) en exige au moins un ;
//  7. observer avant d'agir : un nœud qui prend la main sur le bureau commence par une capture
//     ou dépend (directement ou non) d'un nœud qui en fait une ;
//  8. ressource exclusive `desktop.input:<utilisateur>` ajoutée aux nœuds qui pilotent le bureau.
import { TOOL_BY_TYPE, findPathOutsideAllowed, validateSteps } from "../../lib/agentSteps.js";
import type { SecurityLevel } from "../../lib/toolCatalog.js";
import { isPlainObject } from "../../lib/sanitize.js";
import { parseCriteria } from "../evaluation/criteria.js";
import { levelRank, stepPathDenial } from "../security/policy.js";
import { validatePlan, type Plan, type PlanNode } from "../sessions/dag.js";
import { ROLE_BY_NAME } from "./roles.js";

export interface DagContext {
  userId: string;
  /** Dossiers autorisés connus (union des PC de l'utilisateur, ou du PC ciblé). */
  allowedDirs: readonly string[];
  /** Plafond de la mission (sessions.max_security_level). */
  sessionMaxLevel: SecurityLevel;
}

export type DagCheck = { ok: true; plan: Plan } | { ok: false; errors: string[] };

export function desktopResource(userId: string): string {
  return `desktop.input:${userId}`;
}

function stepsOf(node: PlanNode): Record<string, unknown>[] {
  const steps = isPlainObject(node.spec) ? node.spec.steps : undefined;
  return Array.isArray(steps) ? (steps.filter(isPlainObject) as Record<string, unknown>[]) : [];
}

function canonical(type: unknown): string | null {
  const m = TOOL_BY_TYPE.get(String(type ?? ""));
  return m ? m.name : null;
}

export function validateDag(raw: unknown, ctx: DagContext): DagCheck {
  const shape = validatePlan(raw);
  if (!shape.ok) return { ok: false, errors: [shape.error] };
  const plan = shape.value;
  const errors: string[] = [];
  const touchesDesktop = new Map<string, boolean>();
  const observes = new Map<string, boolean>();

  for (const node of plan.nodes) {
    const where = `nœud « ${node.key} »`;
    const role = ROLE_BY_NAME.get(node.role);
    if (!role) {
      errors.push(`${where} : rôle inconnu « ${node.role} »`);
      continue;
    }
    const steps = stepsOf(node);
    if (role.executor === "p1" && steps.length) errors.push(`${where} : le rôle ${role.name} est exécuté par le plan de contrôle, sans étapes d'outil`);
    if (levelRank(node.security_level) > levelRank(role.max_security_level)) {
      errors.push(`${where} : niveau ${node.security_level} au-dessus du plafond du rôle ${role.name} (${role.max_security_level})`);
    }
    if (levelRank(node.security_level) > levelRank(ctx.sessionMaxLevel)) {
      errors.push(`${where} : niveau ${node.security_level} au-dessus du plafond de la mission (${ctx.sessionMaxLevel})`);
    }

    let effect = levelRank(node.security_level) >= levelRank("L2");
    let desktop = false;
    if (steps.length) {
      const shapeOk = validateSteps(steps);
      if (!shapeOk.ok) errors.push(`${where} : ${shapeOk.error}`);
      for (const [i, step] of steps.entries()) {
        const tool = canonical(step.type);
        if (!tool) continue; // déjà signalé par validateSteps
        const m = TOOL_BY_TYPE.get(tool)!;
        if (!role.tools.includes(tool)) errors.push(`${where}, étape ${i + 1} : outil ${tool} non autorisé pour le rôle ${role.name}`);
        if (levelRank(m.security_level) > levelRank(node.security_level)) {
          errors.push(`${where}, étape ${i + 1} : outil ${tool} de niveau ${m.security_level} au-dessus du niveau déclaré du nœud (${node.security_level})`);
        }
        if (m.requires_confirmation || levelRank(m.security_level) >= levelRank("L2")) effect = true;
        if (m.requires_desktop_input) desktop = true;
        const denied = stepPathDenial(step);
        if (denied) errors.push(`${where}, étape ${i + 1} : chemin interdit — ${denied}`);
      }
      const outside = findPathOutsideAllowed(steps, ctx.allowedDirs);
      if (outside) errors.push(`${where} : ${outside}`);
    }
    touchesDesktop.set(node.key, desktop);
    observes.set(node.key, canonical(steps[0]?.type) === "screenshot" || steps.some((s) => canonical(s.type) === "screenshot"));

    const crit = parseCriteria(node.acceptance_criteria);
    if (!crit.ok) errors.push(`${where} : ${crit.error}`);
    else if (role.executor === "runtime" && effect && !crit.value.some((c) => c.required)) {
      errors.push(`${where} : action à effet sans critère d'acceptation requis (ajoutez au moins un critère vérifiable)`);
    }
  }

  // Observer avant d'agir : pour chaque nœud bureau, une capture en tête ou chez un ancêtre (dépendance dure).
  const parents = new Map<string, string[]>();
  for (const e of plan.edges) if (e.kind === "hard") parents.set(e.to, [...(parents.get(e.to) ?? []), e.from]);
  const ancestorObserves = (key: string, seen = new Set<string>()): boolean => {
    for (const p of parents.get(key) ?? []) {
      if (seen.has(p)) continue;
      seen.add(p);
      if (observes.get(p) || ancestorObserves(p, seen)) return true;
    }
    return false;
  };
  for (const node of plan.nodes) {
    if (!touchesDesktop.get(node.key)) continue;
    const first = canonical(stepsOf(node)[0]?.type);
    if (first !== "screenshot" && !ancestorObserves(node.key)) {
      errors.push(`nœud « ${node.key} » : pilote le bureau sans observation préalable (commencez par une capture ou dépendez d'un nœud d'observation)`);
    }
  }
  if (errors.length) return { ok: false, errors };

  // Ressource exclusive du bureau : un seul agent à la fois prend la main (§9.6, §9.7).
  const res = desktopResource(ctx.userId);
  const nodes = plan.nodes.map((n) =>
    touchesDesktop.get(n.key) && !n.resources.some((r) => r.key === res) ? { ...n, resources: [...n.resources, { key: res, mode: "exclusive" as const }] } : n,
  );
  return { ok: true, plan: { nodes, edges: plan.edges } };
}
