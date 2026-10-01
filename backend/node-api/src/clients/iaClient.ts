import { Agent, fetch as undiciFetch } from "undici";
import { config } from "../config";
import { mapUpstreamStatus } from "../lib/upstream";
import { logger } from "../lib/logger";

/** Erreur portant un code HTTP à propager (429/402/502…). */
export class ServiceError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

// Délais par appel (AbortSignal.timeout) — plus de timeout global de 900 s.
const DEFAULT_TIMEOUT_MS = 120_000; // planification, évaluation, routage, synthèse…
const LONG_TIMEOUT_MS = 900_000; // génération de contenu / vidéo / PDF (plusieurs minutes)

// Dispatcher dédié aux appels longs : le dispatcher par défaut coupe à 300 s
// (headersTimeout/bodyTimeout), insuffisant pour la production vidéo.
const longDispatcher = new Agent({ headersTimeout: LONG_TIMEOUT_MS, bodyTimeout: LONG_TIMEOUT_MS });

/** En-têtes communs vers python-ia (jeton inter-services si IA_SERVICE_TOKEN est défini). */
export function iaHeaders(extra: Record<string, string> = {}): Record<string, string> {
  const h: Record<string, string> = { ...extra };
  if (config.iaServiceToken) h["x-ia-token"] = config.iaServiceToken;
  return h;
}

async function postIa<T>(path: string, body: unknown, opts: { long?: boolean } = {}): Promise<T> {
  const timeoutMs = opts.long ? LONG_TIMEOUT_MS : DEFAULT_TIMEOUT_MS;
  let res: Awaited<ReturnType<typeof undiciFetch>>;
  try {
    res = await undiciFetch(`${config.iaServiceUrl}${path}`, {
      method: "POST",
      headers: iaHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
      ...(opts.long ? { dispatcher: longDispatcher } : {}),
    });
  } catch (e) {
    const err = e as Error;
    if (err.name === "TimeoutError" || err.name === "AbortError") {
      throw new ServiceError(504, "Le service IA n'a pas répondu à temps");
    }
    logger.warn({ path, err: err.message }, "python-ia injoignable");
    throw new ServiceError(502, "Service IA injoignable");
  }
  if (!res.ok) {
    const data = (await res.json().catch(() => ({}))) as { detail?: unknown; error?: unknown };
    const detail = typeof data.detail === "string" ? data.detail : typeof data.error === "string" ? data.error : "";
    const mapped = mapUpstreamStatus(res.status);
    logger.warn({ path, upstreamStatus: res.status, detail: detail.slice(0, 500) }, "python-ia a répondu en erreur");
    throw new ServiceError(
      mapped.status,
      mapped.exposeDetail && detail ? `${mapped.message} : ${detail.slice(0, 300)}` : mapped.message,
    );
  }
  return (await res.json()) as T;
}

// --- Démo (Node → Python → Rust) ---
export interface InferenceResult {
  label: string;
  score: number;
  compute: Record<string, unknown>;
}
export async function requestInference(payload: { text: string }): Promise<InferenceResult> {
  return postIa<InferenceResult>("/infer", payload);
}

// --- Génération de formation ---
export interface FormationContent {
  title?: string;
  description?: string;
  duration?: string;
  lessons?: unknown[];
  [k: string]: unknown;
}
export async function generateFormation(input: {
  topic: string;
  details?: string | null;
}): Promise<FormationContent> {
  const data = await postIa<{ formation: FormationContent }>("/generate/formation", input, { long: true });
  return data.formation;
}

// --- Génération d'application ---
export interface ApplicationContent {
  title?: string;
  description?: string;
  app_type?: string;
  tech_stack?: string;
  architecture?: unknown;
  [k: string]: unknown;
}
export async function generateApplication(input: {
  appName: string;
  appDesc?: string | null;
  conversationHistory?: unknown[] | null;
  existingArchitecture?: unknown;
}): Promise<ApplicationContent> {
  const data = await postIa<{ application: ApplicationContent }>("/generate/application", input, { long: true });
  return data.application;
}

// --- Production vidéo d'une formation ---
export interface FormationVideoResult {
  filename: string;
  slides: number;
  duration_s: number;
}
export async function generateFormationVideo(input: {
  formationId: string;
  title: string;
  lessons: unknown[];
  max_slides?: number | null;
}): Promise<FormationVideoResult> {
  return postIa<FormationVideoResult>("/generate/formation-video", input, { long: true });
}

// --- Cerveau central (Chief Agent) : routage vers l'agent spécialisé ---
export interface RouteDecision {
  agent: string;
  agent_label: string;
  capability: string;
  task_type: string;
  reason: string;
  complexity: string;
  subtasks: string[];
  needs_memory_check: boolean;
}
export async function routeRequest(input: {
  request: string;
  provider?: string | null;
}): Promise<RouteDecision> {
  const data = await postIa<{ decision: RouteDecision }>("/orchestrator/route", input);
  return data.decision;
}

// --- Support PDF d'une formation ---
export async function generateFormationPdf(input: {
  formationId: string;
  curriculum: unknown;
}): Promise<{ filename: string; pages: number }> {
  return postIa<{ filename: string; pages: number }>("/formation/pdf", input, { long: true });
}

// --- Moteur de raisonnement (objectif → plan ; rapport → verdict) ---
export interface AgentStep {
  type: string;
  note?: string;
  app?: string;
  text?: string;
  keys?: string[];
  seconds?: number;
  x?: number;
  y?: number;
  dy?: number;
  action?: string;
  window_title?: string;
  path?: string;
  content?: string;
  src?: string;
  dest?: string;
  program?: string;
  args?: string[];
  cwd?: number | string;
  duration?: number;
  fps?: number;
  clips?: string[];
  title?: string;
  output?: string;
  audio?: string;
  project?: string;
  x1?: number;
  y1?: number;
  x2?: number;
  y2?: number;
  duration_ms?: number;
  keycode?: string;
  package?: string;
  device_id?: string;
}
export interface GoalPlan {
  understanding: string;
  feasible: boolean;
  reason: string;
  steps: AgentStep[];
}
export interface GoalEvaluation {
  verdict: "success" | "retry" | "abort";
  reason: string;
  corrective_steps: AgentStep[];
}

export async function planGoal(goal: string, context?: string): Promise<GoalPlan> {
  const data = await postIa<{ plan: GoalPlan }>("/agent/plan", { goal, context });
  return data.plan;
}

// --- Auto-amélioration (analyse de performance) ---
export interface PerformanceReport {
  slow_steps: string[];
  recurring_errors: string[];
  suggestions: string[];
}
export async function analyzePerformance(summary: string): Promise<PerformanceReport> {
  const data = await postIa<{ report: PerformanceReport }>("/agent/self-improve", { summary });
  return data.report;
}

// --- Moteur de contenu de formation (multi-étapes) ---
export interface FormationAnalysis {
  subject: string;
  level: string;
  audience: string;
  objectives: string[];
  skills: string[];
  prerequisites: string[];
  research_queries: string[];
}
export async function analyzeFormation(input: {
  topic: string;
  details?: string | null;
  provider?: string | null;
}): Promise<FormationAnalysis> {
  const data = await postIa<{ analysis: FormationAnalysis }>("/formation/analyze", input);
  return data.analysis;
}

export async function buildProgram(input: {
  analysis: FormationAnalysis;
  research_notes: unknown[];
  provider?: string | null;
}): Promise<Record<string, unknown>> {
  const data = await postIa<{ program: Record<string, unknown> }>("/formation/program", input, { long: true });
  return data.program;
}

export async function buildModule(input: {
  program_title: string;
  module: Record<string, unknown>;
  research_notes: unknown[];
  provider?: string | null;
}): Promise<Record<string, unknown>> {
  const data = await postIa<{ module: Record<string, unknown> }>("/formation/module", input, { long: true });
  return data.module;
}

// --- Synthèse documentaire (moteur de recherche KB-first) ---
export interface SynthesisResult {
  title: string;
  summary: string;
  content: string;
  keywords: string[];
  domain: string;
  confidence: number;
  sources: { title: string; url: string }[];
}
export async function synthesizeKnowledge(input: {
  query: string;
  sources?: { title: string; url: string; snippet: string }[];
  known?: { title: string; summary: string }[];
  domain?: string | null;
  provider?: string | null;
}): Promise<SynthesisResult> {
  const data = await postIa<{ synthesis: SynthesisResult }>("/synthesize", input);
  return data.synthesis;
}

export async function evaluateGoal(
  goal: string,
  steps: unknown[],
  result: unknown,
  screenshots?: string[],
): Promise<GoalEvaluation> {
  const data = await postIa<{ evaluation: GoalEvaluation }>("/agent/evaluate", {
    goal,
    steps,
    result,
    screenshots,
  });
  return data.evaluation;
}
