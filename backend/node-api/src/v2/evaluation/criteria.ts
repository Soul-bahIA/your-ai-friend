// DSL de critères d'acceptation (LOT 10, audit §9.8) — évaluation PURE sur les preuves des
// actions d'une tentative (soulbah.actions : outil, paramètres masqués, preuves typées).
// P1 ne voit jamais le PC : un critère passe parce qu'une PREUVE le démontre, avec un niveau
// de confiance au moins égal à celui exigé (`min_confidence`).
//
//   file_exists         {path}                     preuve file_path = path
//   file_contains       {path, sha256} | {text}    sha256 du fichier produit à ce chemin, ou texte vu
//                                                  dans une sortie (command_output / ui_state / window_title)
//   command_succeeds    {command?}                 run_command (de cette commande) avec exit_code 0
//   tests_pass          {command?}                 test_report réussi, ou commande de tests avec exit_code 0
//   http_status         {status, url?}             preuve http_status
//   git_branch_contains {branch, text}             sortie de git_commit / git_merge ou d'une commande git, mentionnant la branche et le texte
//   video_valid         {path?}                    video_probe sans erreur (durée > 0 si connue)
//   ui_element_state    {name?, state?, window_title?}  preuve ui_state ou window_title
//   artifact_hash       {sha256}                   une preuve porte exactement cette empreinte
//   llm_rubric          {rubric}                   jugement d'un modèle (confiance faible), hors de ce module
import { isPlainObject } from "../../lib/sanitize.js";
import type { Confidence, Evidence } from "../evidence.js";

export const CRITERION_TYPES = [
  "file_exists",
  "file_contains",
  "command_succeeds",
  "tests_pass",
  "http_status",
  "git_branch_contains",
  "video_valid",
  "ui_element_state",
  "artifact_hash",
  "llm_rubric",
] as const;
export type CriterionType = (typeof CRITERION_TYPES)[number];

const CONF_RANK: Record<Confidence, number> = { none: 0, low: 1, medium: 2, high: 3 };
const CONFIDENCES = Object.keys(CONF_RANK) as Confidence[];
const SHA_RE = /^[0-9a-f]{64}$/;

export interface Criterion {
  type: CriterionType;
  required: boolean;
  min_confidence: Confidence;
  params: Record<string, unknown>;
}

export interface ActionEvidence {
  step_index: number;
  tool: string;
  status: string;
  params: Record<string, unknown>;
  evidence: Evidence[];
}

export interface CriterionResult {
  type: CriterionType;
  required: boolean;
  passed: boolean;
  confidence: Confidence;
  min_confidence: Confidence;
  reason: string;
  /** Étapes dont une preuve a servi. */
  steps: number[];
  /** llm_rubric : à juger par un modèle (hors de ce module). */
  pending_llm?: boolean;
}

const PARAMS: Record<CriterionType, { required: string[]; optional: string[] }> = {
  file_exists: { required: ["path"], optional: [] },
  file_contains: { required: [], optional: ["path", "sha256", "text"] },
  command_succeeds: { required: [], optional: ["command"] },
  tests_pass: { required: [], optional: ["command"] },
  http_status: { required: ["status"], optional: ["url"] },
  git_branch_contains: { required: ["branch", "text"], optional: [] },
  video_valid: { required: [], optional: ["path"] },
  ui_element_state: { required: [], optional: ["name", "state", "window_title"] },
  artifact_hash: { required: ["sha256"], optional: [] },
  llm_rubric: { required: ["rubric"], optional: [] },
};

/** Confiance minimale par défaut : un jugement de modèle est « low » par nature. */
export function defaultMinConfidence(type: CriterionType): Confidence {
  return type === "llm_rubric" ? "low" : "medium";
}

/** Valide et normalise une liste de critères bruts (plan / tâche). */
export function parseCriteria(raw: unknown): { ok: true; value: Criterion[] } | { ok: false; error: string } {
  if (raw === undefined || raw === null) return { ok: true, value: [] };
  if (!Array.isArray(raw)) return { ok: false, error: "acceptance_criteria : liste attendue" };
  if (raw.length > 30) return { ok: false, error: "acceptance_criteria : 30 critères max" };
  const out: Criterion[] = [];
  for (const [i, c] of raw.entries()) {
    const where = `acceptance_criteria[${i}]`;
    if (!isPlainObject(c)) return { ok: false, error: `${where} : objet attendu` };
    const type = c.type as CriterionType;
    if (!(CRITERION_TYPES as readonly string[]).includes(type)) return { ok: false, error: `${where}.type inconnu « ${String(c.type).slice(0, 40)} »` };
    const spec = PARAMS[type];
    const allowed = new Set(["type", "required", "min_confidence", ...spec.required, ...spec.optional]);
    const extra = Object.keys(c).filter((k) => !allowed.has(k));
    if (extra.length) return { ok: false, error: `${where} : champ(s) inconnu(s) : ${extra.join(", ")}` };
    for (const k of spec.required) if (c[k] === undefined || c[k] === null || c[k] === "") return { ok: false, error: `${where}.${k} requis` };
    if (type === "file_contains" && !((c.path && c.sha256) || c.text)) return { ok: false, error: `${where} : {path, sha256} ou {text} requis` };
    for (const k of ["sha256"]) if (c[k] !== undefined && (typeof c[k] !== "string" || !SHA_RE.test(c[k] as string))) return { ok: false, error: `${where}.${k} : 64 hex attendus` };
    if (type === "http_status" && !(Number.isInteger(c.status) && (c.status as number) >= 100 && (c.status as number) <= 599)) return { ok: false, error: `${where}.status : code HTTP attendu` };
    if (c.required !== undefined && typeof c.required !== "boolean") return { ok: false, error: `${where}.required : booléen attendu` };
    const minConf = (c.min_confidence ?? defaultMinConfidence(type)) as Confidence;
    if (!CONFIDENCES.includes(minConf)) return { ok: false, error: `${where}.min_confidence : high | medium | low | none` };
    const params: Record<string, unknown> = {};
    for (const k of [...spec.required, ...spec.optional]) if (c[k] !== undefined) params[k] = c[k];
    out.push({ type, required: c.required !== false, min_confidence: minConf, params });
  }
  return { ok: true, value: out };
}

// --- appariement des preuves -----------------------------------------------------------------
export function normalizePath(p: unknown): string {
  return String(p ?? "")
    .trim()
    .replace(/^\\\\\?\\/, "")
    .replace(/\//g, "\\")
    .replace(/\\+$/, "")
    .toLowerCase();
}

function text(v: unknown): string {
  if (v === undefined || v === null) return "";
  return typeof v === "string" ? v : JSON.stringify(v);
}

interface Hit {
  confidence: Confidence;
  step: number;
}

function best(hits: Hit[]): Hit | null {
  let top: Hit | null = null;
  for (const h of hits) if (!top || CONF_RANK[h.confidence] > CONF_RANK[top.confidence]) top = h;
  return top;
}

const TEST_COMMAND = /\b(pytest|vitest|jest|mocha|npm\s+(run\s+)?test|yarn\s+test|pnpm\s+test|go\s+test|cargo\s+test|dotnet\s+test)\b/i;

function commandOf(a: ActionEvidence): string {
  // run_command : `program` + `args` (catalogue) ; `command` accepté pour les plans écrits à la main.
  const cmd = a.params.program ?? a.params.command;
  const args = Array.isArray(a.params.args) ? a.params.args.map(String).join(" ") : "";
  return `${typeof cmd === "string" ? cmd : ""} ${args}`.trim();
}

function exitZero(a: ActionEvidence): Hit[] {
  return a.evidence.filter((e) => e.kind === "exit_code" && Number(e.value) === 0).map((e) => ({ confidence: e.confidence, step: a.step_index }));
}

/** Évalue un critère « règles » ; llm_rubric est renvoyé en attente de jugement. */
export function evaluateCriterion(c: Criterion, actions: readonly ActionEvidence[]): CriterionResult {
  const base = { type: c.type, required: c.required, min_confidence: c.min_confidence };
  const done = actions.filter((a) => a.status === "executed" || a.status === "verified");
  let hits: Hit[] = [];
  let reason = "";
  switch (c.type) {
    case "file_exists": {
      const want = normalizePath(c.params.path);
      for (const a of done) for (const e of a.evidence) if (e.kind === "file_path" && normalizePath(e.value) === want) hits.push({ confidence: e.confidence, step: a.step_index });
      reason = hits.length ? `fichier attesté : ${String(c.params.path)}` : `aucune preuve du fichier ${String(c.params.path)}`;
      break;
    }
    case "file_contains": {
      if (c.params.sha256) {
        const want = normalizePath(c.params.path);
        for (const a of done) {
          const atPath = a.evidence.some((e) => e.kind === "file_path" && normalizePath(e.value) === want) || normalizePath(a.params.path ?? a.params.dest ?? a.params.output) === want;
          if (!atPath) continue;
          for (const e of a.evidence) if ((e.kind === "sha256" || e.kind === "file_content") && e.sha256 === c.params.sha256) hits.push({ confidence: "high", step: a.step_index });
        }
        reason = hits.length ? "empreinte du fichier conforme" : "empreinte du fichier absente ou différente";
      } else {
        const needle = String(c.params.text);
        for (const a of done)
          for (const e of a.evidence)
            if (["command_output", "ui_state", "window_title", "file_path"].includes(e.kind) && (text(e.value).includes(needle) || text(e.description).includes(needle)))
              hits.push({ confidence: e.confidence, step: a.step_index });
        reason = hits.length ? `texte « ${needle.slice(0, 60)} » observé` : `texte « ${needle.slice(0, 60)} » jamais observé`;
      }
      break;
    }
    case "command_succeeds": {
      const want = typeof c.params.command === "string" ? c.params.command.trim().toLowerCase() : null;
      for (const a of done) {
        if (a.tool !== "run_command") continue;
        if (want && !commandOf(a).toLowerCase().includes(want)) continue;
        hits.push(...exitZero(a));
      }
      reason = hits.length ? "commande terminée avec le code 0" : "aucune commande réussie attestée";
      break;
    }
    case "tests_pass": {
      const want = typeof c.params.command === "string" ? c.params.command.trim().toLowerCase() : null;
      for (const a of done) {
        for (const e of a.evidence) {
          if (e.kind !== "test_report") continue;
          const v = isPlainObject(e.value) ? e.value : {};
          if (v.passed === true || (Number(v.failed ?? 1) === 0 && Number(v.total ?? 0) > 0)) hits.push({ confidence: e.confidence, step: a.step_index });
        }
        if (a.tool === "run_command") {
          const cmd = commandOf(a);
          if (want ? cmd.toLowerCase().includes(want) : TEST_COMMAND.test(cmd)) hits.push(...exitZero(a));
        }
      }
      reason = hits.length ? "tests réussis" : "aucun rapport ni commande de tests réussie";
      break;
    }
    case "http_status": {
      const want = Number(c.params.status);
      for (const a of done)
        for (const e of a.evidence) {
          if (e.kind !== "http_status") continue;
          const v = isPlainObject(e.value) ? e.value : { status: e.value };
          if (Number(v.status) === want && (!c.params.url || String(v.url ?? "") === String(c.params.url))) hits.push({ confidence: e.confidence, step: a.step_index });
        }
      reason = hits.length ? `statut HTTP ${want} observé` : `statut HTTP ${want} jamais observé`;
      break;
    }
    case "git_branch_contains": {
      const branch = String(c.params.branch);
      const needle = String(c.params.text);
      for (const a of done) {
        // LOT 12 : outils git dédiés (git_commit, git_merge : sortie structurée, confiance haute) ou run_command git.
        const gitTool = a.tool === "git_commit" || a.tool === "git_merge";
        if (!gitTool && (a.tool !== "run_command" || !/\bgit\b/i.test(commandOf(a)))) continue;
        const out = a.evidence.filter((e) => e.kind === "command_output").map((e) => text(e.value)).join("\n");
        if ((out.includes(branch) || commandOf(a).includes(branch)) && out.includes(needle) && exitZero(a).length) hits.push({ confidence: gitTool ? "high" : "medium", step: a.step_index });
      }
      reason = hits.length ? `branche ${branch} : « ${needle.slice(0, 40)} » trouvé` : `branche ${branch} : « ${needle.slice(0, 40)} » non attesté`;
      break;
    }
    case "video_valid": {
      const want = c.params.path ? normalizePath(c.params.path) : null;
      for (const a of done) {
        if (want && !a.evidence.some((e) => e.kind === "file_path" && normalizePath(e.value) === want) && normalizePath(a.params.output ?? a.params.path) !== want) continue;
        for (const e of a.evidence) {
          if (e.kind !== "video_probe") continue;
          const v = isPlainObject(e.value) ? e.value : {};
          const dur = Number(v.duration ?? v.duration_s ?? 1);
          if (v.ok !== false && !v.error && dur > 0) hits.push({ confidence: e.confidence, step: a.step_index });
        }
      }
      reason = hits.length ? "vidéo valide (probe)" : "aucune probe vidéo valide";
      break;
    }
    case "ui_element_state": {
      for (const a of done)
        for (const e of a.evidence) {
          if (e.kind === "ui_state") {
            const v = isPlainObject(e.value) ? e.value : {};
            if ((!c.params.name || v.name === c.params.name) && (!c.params.state || v.state === c.params.state)) hits.push({ confidence: e.confidence, step: a.step_index });
          }
          if (e.kind === "window_title" && c.params.window_title && (text(e.value) + text(e.description)).includes(String(c.params.window_title)))
            hits.push({ confidence: e.confidence, step: a.step_index });
        }
      reason = hits.length ? "état d'interface attesté" : "état d'interface non attesté";
      break;
    }
    case "artifact_hash": {
      for (const a of done) for (const e of a.evidence) if (e.sha256 === c.params.sha256) hits.push({ confidence: e.confidence === "none" ? "high" : e.confidence, step: a.step_index });
      reason = hits.length ? "empreinte attestée" : "empreinte jamais observée";
      break;
    }
    case "llm_rubric":
      return { ...base, passed: false, confidence: "none", reason: "jugement du modèle en attente", steps: [], pending_llm: true };
  }
  hits = hits.filter((h) => h.confidence !== undefined);
  const top = best(hits);
  if (!top) return { ...base, passed: false, confidence: "none", reason, steps: [] };
  const enough = CONF_RANK[top.confidence] >= CONF_RANK[c.min_confidence];
  return {
    ...base,
    passed: enough,
    confidence: top.confidence,
    reason: enough ? reason : `${reason} — confiance ${top.confidence} < ${c.min_confidence} exigée`,
    steps: [...new Set(hits.map((h) => h.step))].sort((x, y) => x - y),
  };
}

export type Verdict = "success" | "partial" | "failure" | "not_evaluable";

export interface RunFacts {
  simulated: boolean;
  /** Le plan de la tâche contenait des étapes (spec.steps non vide). */
  hasSteps: boolean;
  /** Résultat déclaré par le runtime (ok === false = échec annoncé). */
  resultOk: boolean | null;
  securityLevel: "L0" | "L1" | "L2" | "L3";
}

export interface Assessment {
  verdict: Verdict;
  confidence: Confidence;
  results: CriterionResult[];
  reasons: string[];
}

/**
 * Verdict d'une tentative (§9.8) :
 *  - simulé → not_evaluable (jamais COMPLETED) ; plan avec étapes mais aucune étape exécutée → failure ;
 *  - résultat annoncé en échec → failure ;
 *  - tâche L2+ : au moins une preuve de confiance ≥ medium, sinon failure ;
 *  - tous les critères requis passent → success (partial si un critère facultatif échoue).
 * Les critères llm_rubric doivent avoir été jugés avant (résultats fournis dans `judged`).
 */
export function assess(criteria: readonly Criterion[], actions: readonly ActionEvidence[], facts: RunFacts, judged: Map<number, CriterionResult> = new Map()): Assessment {
  if (facts.simulated) return { verdict: "not_evaluable", confidence: "none", results: [], reasons: ["run simulé (dry-run) : jamais COMPLETED"] };
  const executed = actions.filter((a) => a.status === "executed" || a.status === "verified");
  if (facts.hasSteps && executed.length === 0) return { verdict: "failure", confidence: "none", results: [], reasons: ["aucune étape exécutée (plan vide ou non joué)"] };
  const reasons: string[] = [];
  if (facts.resultOk === false) reasons.push("le runtime a annoncé un échec");
  const results = criteria.map((c, i) => judged.get(i) ?? evaluateCriterion(c, actions));
  const pending = results.filter((r) => r.pending_llm);
  if (pending.length) reasons.push(`${pending.length} critère(s) en attente d'un jugement de modèle`);
  if (facts.securityLevel === "L2" || facts.securityLevel === "L3") {
    const strongest = executed.flatMap((a) => a.evidence).reduce<Confidence>((acc, e) => (CONF_RANK[e.confidence] > CONF_RANK[acc] ? e.confidence : acc), "none");
    if (CONF_RANK[strongest] < CONF_RANK.medium) reasons.push(`tâche ${facts.securityLevel} sans preuve de confiance ≥ medium (meilleure : ${strongest})`);
  }
  const requiredFailed = results.filter((r) => r.required && !r.passed);
  for (const r of requiredFailed) reasons.push(`${r.type} : ${r.reason}`);
  const optionalFailed = results.filter((r) => !r.required && !r.passed);
  const confidence = results.length
    ? results.filter((r) => r.required).reduce<Confidence>((acc, r) => (CONF_RANK[r.confidence] < CONF_RANK[acc] ? r.confidence : acc), "high")
    : "none";
  if (reasons.length) return { verdict: "failure", confidence, results, reasons };
  return { verdict: optionalFailed.length ? "partial" : "success", confidence, results, reasons: optionalFailed.map((r) => `${r.type} (facultatif) : ${r.reason}`) };
}
