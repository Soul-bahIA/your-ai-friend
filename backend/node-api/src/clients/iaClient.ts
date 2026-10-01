import { config } from "../config";

/** Erreur portant un code HTTP à propager (429/402/502…). */
export class ServiceError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

async function postIa<T>(path: string, body: unknown): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${config.iaServiceUrl}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch {
    throw new ServiceError(502, "Service IA injoignable");
  }
  if (!res.ok) {
    const data = (await res.json().catch(() => ({}))) as { detail?: string; error?: string };
    throw new ServiceError(res.status, data.detail ?? data.error ?? `Service IA ${res.status}`);
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
  const data = await postIa<{ formation: FormationContent }>("/generate/formation", input);
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
  const data = await postIa<{ application: ApplicationContent }>("/generate/application", input);
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
  return postIa<FormationVideoResult>("/generate/formation-video", input);
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
  return postIa<{ filename: string; pages: number }>("/formation/pdf", input);
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
  const data = await postIa<{ program: Record<string, unknown> }>("/formation/program", input);
  return data.program;
}

export async function buildModule(input: {
  program_title: string;
  module: Record<string, unknown>;
  research_notes: unknown[];
  provider?: string | null;
}): Promise<Record<string, unknown>> {
  const data = await postIa<{ module: Record<string, unknown> }>("/formation/module", input);
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
