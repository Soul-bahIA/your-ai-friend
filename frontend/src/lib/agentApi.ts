// Appels HTTP de l'agent local (contrat LOT 1) : annulation, approbation des
// corrections, capture d'écran, choix du PC cible, déconnexion côté serveur.
// Les fonctions de décodage sont pures et exportées pour les tests.
import { ApiError, apiFetch, errorMessage } from "@/lib/api";
import { toImageDataUrl } from "@/lib/images";

export { toImageDataUrl };

/** Agent (PC) proposé par le serveur ou listé via /api/agent-keys. */
export interface AgentChoice {
  id: string;
  name: string;
}

const isRecord = (v: unknown): v is Record<string, unknown> =>
  !!v && typeof v === "object" && !Array.isArray(v);

/** Normalise une liste d'agents (`{id, name}` ou `{id, label}`), en ignorant les clés révoquées. */
export function normalizeAgents(raw: unknown): AgentChoice[] {
  if (!Array.isArray(raw)) return [];
  const out: AgentChoice[] = [];
  for (const item of raw) {
    if (!isRecord(item) || typeof item.id !== "string" || !item.id) continue;
    if (item.revoked === true || (typeof item.revoked_at === "string" && item.revoked_at)) continue;
    const name =
      (typeof item.name === "string" && item.name.trim()) ||
      (typeof item.label === "string" && item.label.trim()) ||
      `PC ${item.id.slice(0, 8)}`;
    out.push({ id: item.id, name });
  }
  return out;
}

/**
 * Contrat §7 : sans `agent_key_id`, le serveur répond 400 `{error, agents:[{id,name}]}`
 * quand l'utilisateur possède plusieurs agents. Renvoie la liste à proposer, ou null
 * si l'erreur n'est pas une demande de choix d'agent.
 */
export function agentChoiceFromError(err: unknown): AgentChoice[] | null {
  if (!(err instanceof ApiError) || err.status !== 400 || !isRecord(err.body)) return null;
  if (!Array.isArray(err.body.agents)) return null;
  const agents = normalizeAgents(err.body.agents);
  return agents.length > 0 ? agents : null;
}

/** Message d'un refus du planificateur (422) : erreur + raison détaillée si fournie. */
export function goalErrorMessage(err: unknown, fallback = "Échec de la planification"): string {
  const base = errorMessage(err, fallback);
  if (err instanceof ApiError && isRecord(err.body)) {
    const reason = err.body.reason;
    if (typeof reason === "string" && reason.trim() && reason.trim() !== base) {
      return `${base} — ${reason.trim()}`;
    }
  }
  return base;
}

export interface GoalSuccess {
  success?: boolean;
  task_id?: string;
  understanding?: string;
  steps?: unknown[];
  reason?: string;
  error?: string;
}

export type GoalOutcome =
  | { kind: "ok"; data: GoalSuccess }
  | { kind: "choose_agent"; agents: AgentChoice[]; message: string }
  | { kind: "error"; message: string };

/** POST /api/agent/goal (avec PC cible optionnel), décodé en résultat discriminé. */
export async function submitGoal(goal: string, agentKeyId?: string | null): Promise<GoalOutcome> {
  const json: Record<string, unknown> = { goal };
  if (agentKeyId) json.agent_key_id = agentKeyId;
  try {
    const data = await apiFetch<GoalSuccess>("/api/agent/goal", { method: "POST", json });
    if (data?.success) return { kind: "ok", data };
    return { kind: "error", message: data?.reason || data?.error || "Échec de la planification" };
  } catch (err) {
    const agents = agentChoiceFromError(err);
    if (agents) {
      return {
        kind: "choose_agent",
        agents,
        message: errorMessage(err, "Plusieurs agents disponibles : choisissez le PC cible."),
      };
    }
    return { kind: "error", message: goalErrorMessage(err, "Backend injoignable") };
  }
}

/** Réponse de /cancel ou /approve : on accepte `{task}`, `{status}` ou un corps vide. */
export interface TaskMutationResponse {
  success?: boolean;
  status?: string;
  control?: string;
  task?: Record<string, unknown>;
}

const taskPath = (taskId: string, action: string) => `/api/agent-tasks/${encodeURIComponent(taskId)}/${action}`;

/** Annule une tâche (pending → cancelled ; in_progress → arrêt demandé). Sert aussi au rejet d'une correction. */
export async function cancelAgentTask(taskId: string): Promise<TaskMutationResponse> {
  return (await apiFetch<TaskMutationResponse>(taskPath(taskId, "cancel"), { method: "POST", json: {} })) ?? {};
}

/** Approuve une correction proposée par l'évaluateur (awaiting_approval → false). */
export async function approveAgentTask(taskId: string): Promise<TaskMutationResponse> {
  return (await apiFetch<TaskMutationResponse>(taskPath(taskId, "approve"), { method: "POST", json: {} })) ?? {};
}

/** Dernière capture d'une tâche (GET /:id/screenshot) en data URL, ou null (404 / invalide). */
export async function fetchTaskScreenshot(taskId: string, signal?: AbortSignal): Promise<string | null> {
  try {
    const data = await apiFetch<{ image_b64?: string; mime?: string; at?: string }>(taskPath(taskId, "screenshot"), {
      signal,
    });
    return toImageDataUrl(data?.image_b64, data?.mime);
  } catch (err) {
    if (err instanceof ApiError && (err.status === 404 || err.status === 410)) return null;
    throw err;
  }
}

/** Liste des PC (clés d'agent actives) de l'utilisateur. */
export async function listAgents(): Promise<AgentChoice[]> {
  const data = await apiFetch<{ keys?: unknown }>("/api/agent-keys");
  return normalizeAgents(data?.keys);
}

/** Invalide le cache JWT du serveur avant la déconnexion. Les erreurs sont ignorées. */
export async function notifyServerLogout(timeoutMs = 3000): Promise<void> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    await apiFetch("/api/auth/logout", { method: "POST", json: {}, signal: ctrl.signal });
  } catch {
    // Best-effort : la déconnexion locale a lieu quoi qu'il arrive.
  } finally {
    clearTimeout(timer);
  }
}
