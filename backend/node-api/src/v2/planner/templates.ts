// Gabarits de plans (LOT 11, audit §9.3 « Planner : gabarits + proposition LLM → validateDag »).
// Un gabarit transforme des paramètres simples en DAG complet — rôles, niveaux, dépendances,
// critères d'acceptation vérifiables — que validateDag contrôle ensuite comme n'importe quel plan.
//
//   desktop_goal : objectif sur le PC (étapes du planificateur V1) → [observer] → agir
//   formation    : N modules rédigés EN PARALLÈLE par P1 (content_writer) → assemblage
//   demo_video   : observer → enregistrer + actions → montage (vidéo vérifiée par probe)
//   code_parallel: N codeurs en worktrees git → relecture QA bloquante → fusion testée (LOT 12)
import { TOOL_BY_TYPE } from "../../lib/agentSteps.js";
import type { SecurityLevel } from "../../lib/toolCatalog.js";
import { isPlainObject } from "../../lib/sanitize.js";
import { levelRank } from "../security/policy.js";
import { ROLES } from "./roles.js";

export const TEMPLATE_NAMES = ["desktop_goal", "formation", "demo_video", "code_parallel"] as const;
export type TemplateName = (typeof TEMPLATE_NAMES)[number];

type RawNode = Record<string, unknown>;
export interface RawPlan {
  nodes: RawNode[];
  edges: { from: string; to: string; kind?: "hard" | "soft" }[];
}
export type TemplateResult = { ok: true; plan: RawPlan } | { ok: false; error: string };

const RUNTIME_ROLES = ["desktop_operator", "coder", "video_editor", "phone_operator", "researcher"];

function tool(step: Record<string, unknown>) {
  return TOOL_BY_TYPE.get(String(step.type ?? ""));
}

/** Premier rôle runtime dont les outils couvrent toutes les étapes (null sinon). */
export function roleFor(steps: Record<string, unknown>[]): string | null {
  const names = steps.map((s) => tool(s)?.name);
  if (names.some((n) => !n)) return null;
  for (const r of RUNTIME_ROLES) {
    const role = ROLES.find((x) => x.name === r)!;
    if (names.every((n) => role.tools.includes(n!))) return r;
  }
  return null;
}

/** Niveau minimal couvrant toutes les étapes (au moins L1 pour une action). */
export function levelFor(steps: Record<string, unknown>[]): SecurityLevel {
  let lvl: SecurityLevel = "L1";
  for (const s of steps) {
    const m = tool(s);
    if (m && levelRank(m.security_level) > levelRank(lvl)) lvl = m.security_level;
  }
  return lvl;
}

/** Critères vérifiables déduits des étapes (fichiers produits, commandes). */
export function criteriaFromSteps(steps: Record<string, unknown>[]): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  for (const s of steps) {
    const name = tool(s)?.name;
    if ((name === "write_file" || name === "stop_recording_bg") && typeof s.path === "string") out.push({ type: "file_exists", path: s.path });
    if (name === "move_file" && typeof s.dest === "string") out.push({ type: "file_exists", path: s.dest });
    if (name === "edit_video" && typeof s.output === "string") out.push({ type: "video_valid", path: s.output });
    if (name === "run_command" && typeof s.program === "string") out.push({ type: "command_succeeds", command: s.program });
  }
  return out;
}

function str(v: unknown, max = 500): string | null {
  return typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null;
}

function joinPath(dir: string, name: string): string {
  return /[\\/]$/.test(dir) ? `${dir}${name}` : `${dir}${dir.includes("/") && !dir.includes("\\") ? "/" : "\\"}${name}`;
}

/** Objectif sur le PC : étapes d'outil (ex. issues du planificateur V1) → [observer] → agir. */
export function desktopGoal(params: Record<string, unknown>): TemplateResult {
  const goal = str(params.goal, 2000);
  if (!goal) return { ok: false, error: "desktop_goal : goal requis" };
  const steps = Array.isArray(params.steps) ? (params.steps.filter(isPlainObject) as Record<string, unknown>[]) : [];
  if (!steps.length) return { ok: false, error: "desktop_goal : steps (liste non vide) requis" };
  const role = roleFor(steps);
  if (!role) return { ok: false, error: "desktop_goal : aucune étape ne doit mélanger des outils de rôles différents (bureau, code, vidéo, téléphone)" };
  const touches = steps.some((s) => tool(s)?.requires_desktop_input);
  const level = levelFor(steps);
  const criteria = criteriaFromSteps(steps);
  const effect = levelRank(level) >= levelRank("L2") || steps.some((s) => tool(s)?.requires_confirmation);
  if (effect && !criteria.length) criteria.push({ type: "llm_rubric", rubric: `L'objectif est atteint d'après les preuves : ${goal}` });
  const act: RawNode = { key: "act", title: goal.slice(0, 200), role, security_level: level, spec: { steps, goal }, acceptance_criteria: criteria };
  if (!touches || tool(steps[0])?.name === "screenshot") return { ok: true, plan: { nodes: [act], edges: [] } };
  const observe: RawNode = { key: "observe", title: "Observer l'écran avant d'agir", role: "desktop_operator", security_level: "L1", spec: { steps: [{ type: "screenshot" }] }, acceptance_criteria: [] };
  return { ok: true, plan: { nodes: [observe, act], edges: [{ from: "observe", to: "act", kind: "hard" }] } };
}

/** Formation : modules rédigés en parallèle par P1, puis assemblage. */
export function formation(params: Record<string, unknown>): TemplateResult {
  const topic = str(params.topic);
  if (!topic) return { ok: false, error: "formation : topic requis" };
  const modules = Array.isArray(params.modules) ? params.modules : [];
  if (modules.length < 1 || modules.length > 20) return { ok: false, error: "formation : 1 à 20 modules attendus" };
  const nodes: RawNode[] = modules.map((m, i) => {
    const module = isPlainObject(m) ? m : { title: String(m) };
    return {
      key: `module_${i + 1}`,
      title: `Module ${i + 1} : ${String(module.title ?? "").slice(0, 150)}`,
      role: "content_writer",
      security_level: "L0",
      spec: { kind: "formation_module", topic, program_title: str(params.program_title) ?? topic, module },
      acceptance_criteria: [],
    };
  });
  nodes.push({ key: "assemble", title: `Assemblage : ${topic.slice(0, 150)}`, role: "content_writer", security_level: "L0", spec: { kind: "formation_assemble", topic }, acceptance_criteria: [] });
  return { ok: true, plan: { nodes, edges: nodes.slice(0, -1).map((n) => ({ from: n.key as string, to: "assemble", kind: "hard" as const })) } };
}

/** Démonstration vidéo : observer → enregistrer pendant les actions → monter (vidéo vérifiée). */
export function demoVideo(params: Record<string, unknown>): TemplateResult {
  const title = str(params.title, 200);
  const outputDir = str(params.output_dir, 1000);
  if (!title || !outputDir) return { ok: false, error: "demo_video : title et output_dir requis" };
  const steps = Array.isArray(params.steps) ? (params.steps.filter(isPlainObject) as Record<string, unknown>[]) : [];
  if (!steps.length) return { ok: false, error: "demo_video : steps (actions à filmer) requis" };
  const slug = title.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "").slice(0, 40) || "demo";
  const raw = joinPath(outputDir, `${slug}_brut.mp4`);
  const final = joinPath(outputDir, `${slug}.mp4`);
  const recordSteps = [{ type: "start_recording_bg", path: raw, fps: 15 }, ...steps, { type: "stop_recording_bg", path: raw }];
  return {
    ok: true,
    plan: {
      nodes: [
        { key: "observe", title: "Observer l'écran avant la démonstration", role: "desktop_operator", security_level: "L1", spec: { steps: [{ type: "screenshot" }] }, acceptance_criteria: [] },
        { key: "record", title: `Filmer : ${title}`, role: "desktop_operator", security_level: levelFor(recordSteps), spec: { steps: recordSteps }, acceptance_criteria: [{ type: "file_exists", path: raw }] },
        {
          key: "montage",
          title: `Monter : ${title}`,
          role: "video_editor",
          security_level: "L1",
          spec: { steps: [{ type: "edit_video", clips: [raw], output: final, title }] },
          acceptance_criteria: [{ type: "video_valid", path: final }],
        },
      ],
      edges: [
        { from: "observe", to: "record", kind: "hard" },
        { from: "record", to: "montage", kind: "hard" },
      ],
    },
  };
}

const SLUG_RE = /^[a-z0-9][a-z0-9_-]{0,40}$/;
const RESERVED_KEYS = new Set(["merge", "integration"]);

/**
 * Code en parallèle (LOT 12, audit §9.7) : N codeurs, chacun dans SA worktree et sa branche
 * soulbah/<session>/<tâche> (git_worktree → étapes → git_commit) → une relecture QA bloquante par
 * codeur → fusion dans soulbah/<session>/integration avec tests verts (git_merge), sur une
 * ressource exclusive : une seule fusion à la fois.
 */
export function codeParallel(params: Record<string, unknown>): TemplateResult {
  const repo = str(params.repo, 1000);
  const wtDir = str(params.worktrees_dir, 1000);
  const session = str(params.session_slug, 41)?.toLowerCase() ?? null;
  if (!repo || !wtDir) return { ok: false, error: "code_parallel : repo et worktrees_dir requis" };
  if (!session || !SLUG_RE.test(session)) return { ok: false, error: "code_parallel : session_slug requis ([a-z0-9][a-z0-9_-]*)" };
  const tasks = Array.isArray(params.tasks) ? params.tasks.filter(isPlainObject) : [];
  if (tasks.length < 1 || tasks.length > 8) return { ok: false, error: "code_parallel : 1 à 8 tâches attendues" };
  const test = isPlainObject(params.test) ? params.test : null;
  const testProgram = test ? str(test.program, 20) : null;
  const testArgs = test && Array.isArray(test.args) ? test.args.map(String).slice(0, 64) : [];
  const base = str(params.base, 200) ?? "HEAD";
  const target = `soulbah/${session}/integration`;
  const integrationPath = joinPath(wtDir, "integration");

  const nodes: RawNode[] = [];
  const edges: RawPlan["edges"] = [];
  const merges: Record<string, unknown>[] = [];
  const mergeCriteria: Record<string, unknown>[] = [];
  const seen = new Set<string>();
  for (const t of tasks) {
    const key = str(t.key, 41)?.toLowerCase() ?? "";
    if (!SLUG_RE.test(key) || RESERVED_KEYS.has(key) || key.startsWith("review_")) return { ok: false, error: `code_parallel : clé de tâche invalide « ${key.slice(0, 40)} »` };
    if (seen.has(key)) return { ok: false, error: `code_parallel : clé de tâche en double « ${key} »` };
    seen.add(key);
    const title = str(t.title, 200) ?? key;
    const userSteps = Array.isArray(t.steps) ? (t.steps.filter(isPlainObject) as Record<string, unknown>[]) : [];
    const branch = `soulbah/${session}/${key}`;
    const path = joinPath(wtDir, key);
    const marker = `soulbah:${key}`;
    const steps = [
      { type: "git_worktree", repo, path, branch, base },
      ...userSteps,
      { type: "git_commit", cwd: path, message: `${marker} ${title}`.slice(0, 500) },
    ];
    nodes.push({
      key,
      title: `Coder : ${title}`,
      role: "coder",
      security_level: levelFor(steps),
      spec: { steps, worktree: path, branch },
      acceptance_criteria: [{ type: "git_branch_contains", branch, text: marker }, ...criteriaFromSteps(userSteps)],
    });
    nodes.push({ key: `review_${key}`, title: `Relecture : ${title}`, role: "qa_reviewer", security_level: "L0", spec: { review_of_key: key }, acceptance_criteria: [] });
    edges.push({ from: key, to: `review_${key}`, kind: "hard" }, { from: `review_${key}`, to: "merge", kind: "hard" });
    merges.push({ type: "git_merge", repo, path: integrationPath, source: branch, target, base, ...(testProgram ? { test_program: testProgram, test_args: testArgs } : {}) });
    mergeCriteria.push({ type: "git_branch_contains", branch: target, text: branch });
  }
  if (testProgram) mergeCriteria.unshift({ type: "tests_pass" });
  nodes.push({
    key: "merge",
    title: `Fusionner dans ${target}${testProgram ? " (tests verts)" : ""}`,
    role: "coder",
    security_level: "L2",
    spec: { steps: merges },
    acceptance_criteria: mergeCriteria,
    resources: [{ key: `git.merge:${session}`, mode: "exclusive" }],
  });
  return { ok: true, plan: { nodes, edges } };
}

export function buildFromTemplate(name: unknown, params: unknown): TemplateResult {
  const p = isPlainObject(params) ? params : {};
  switch (name) {
    case "code_parallel":
      return codeParallel(p);
    case "desktop_goal":
      return desktopGoal(p);
    case "formation":
      return formation(p);
    case "demo_video":
      return demoVideo(p);
    default:
      return { ok: false, error: `gabarit inconnu « ${String(name).slice(0, 40)} » (${TEMPLATE_NAMES.join(", ")})` };
  }
}
