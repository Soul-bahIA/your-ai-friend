// État du poste de pilotage (cockpit) : réducteur pur, testable sans React.
//  - ignore les évènements de progression des formations (data.source='formation', T29) ;
//  - les captures ne transitent plus en base64 : data.has_image ⇒ requête vers
//    GET /api/agent-tasks/:id/screenshot (contrat §8) ; l'ancien image_b64 reste lu ;
//  - approval_required / approval_result ⇒ « En attente de confirmation sur le PC » (§13).
import { toImageDataUrl } from "@/lib/images";

export interface AgentEventData {
  index?: number;
  step_index?: number;
  step_type?: string;
  image_b64?: string;
  media_type?: string;
  has_image?: boolean;
  duration_s?: number;
  total?: number;
  source?: string;
  action?: unknown;
  summary?: string;
  approved?: boolean;
  [key: string]: unknown;
}

export interface AgentEvent {
  id: string;
  /** Absent des lignes renvoyées par GET /:id/events (la tâche est implicite). */
  task_id?: string;
  type: string;
  message: string | null;
  data: AgentEventData | null;
  created_at: string;
}

export interface PendingApproval {
  stepIndex: number | null;
  action: string;
  summary: string;
}

export interface ScreenshotRequest {
  taskId: string;
  /** Identifiant de l'évènement déclencheur : change à chaque nouvelle capture. */
  eventId: string;
}

export interface CockpitState {
  events: AgentEvent[];
  taskId: string | null;
  running: boolean;
  liveImage: string | null;
  pendingApproval: PendingApproval | null;
  screenshotRequest: ScreenshotRequest | null;
}

export type CockpitAction =
  | { type: "event"; event: AgentEvent }
  | { type: "hydrate"; taskId: string; events: AgentEvent[] }
  | { type: "screenshot"; taskId: string; image: string | null }
  | { type: "stopped" };

/** Nombre maximal d'évènements conservés en mémoire (timeline). */
export const MAX_EVENTS = 500;

export const TERMINAL_EVENT_TYPES: ReadonlySet<string> = new Set([
  "task_completed",
  "task_failed",
  "task_cancelled",
]);

/**
 * Évènements de cycle de vie émis par le serveur (évaluation, approbation, annulation,
 * remise en file…) : ils ne signalent pas une exécution en cours, donc n'attirent pas
 * le cockpit vers une autre tâche.
 */
export const LIFECYCLE_EVENT_TYPES: ReadonlySet<string> = new Set([
  ...TERMINAL_EVENT_TYPES,
  "evaluation",
  "task_approved",
  "task_requeued",
]);

export const initialCockpitState: CockpitState = {
  events: [],
  taskId: null,
  running: false,
  liveImage: null,
  pendingApproval: null,
  screenshotRequest: null,
};

/** Le cockpit n'affiche que les évènements de l'agent (pas ceux des formations). */
export function isCockpitEvent(ev: Pick<AgentEvent, "data"> | null | undefined): boolean {
  if (!ev) return false;
  const source = ev.data?.source;
  return source === undefined || source === null || source === "agent";
}

const capEvents = (list: AgentEvent[]) => (list.length > MAX_EVENTS ? list.slice(-MAX_EVENTS) : list);

/** Retire la capture base64 (lourde) de l'évènement stocké. */
export function stripImage(ev: AgentEvent): AgentEvent {
  if (!ev.data?.image_b64) return ev;
  const { image_b64: _omit, ...rest } = ev.data;
  return { ...ev, data: rest };
}

function actionLabel(action: unknown): string {
  if (typeof action === "string") return action;
  if (action && typeof action === "object") {
    const a = action as Record<string, unknown>;
    if (typeof a.type === "string") return a.type;
  }
  return "";
}

function applyEvent(state: CockpitState, raw: AgentEvent): CockpitState {
  if (!isCockpitEvent(raw)) return state;
  const evTask = raw.task_id ?? state.taskId;
  const image = toImageDataUrl(raw.data?.image_b64, raw.data?.media_type);
  const ev = stripImage(raw);

  let next: CockpitState;
  if (ev.type === "task_started" && evTask) {
    next = { ...initialCockpitState, events: [ev], taskId: evTask, running: true };
  } else if (evTask && state.taskId && evTask !== state.taskId) {
    // Évènement d'une autre tâche : ignoré tant que la tâche suivie tourne (ou s'il ne
    // s'agit que de cycle de vie) ; sinon (début manqué), le cockpit bascule dessus.
    if (state.running || LIFECYCLE_EVENT_TYPES.has(ev.type)) return state;
    next = { ...initialCockpitState, events: [ev], taskId: evTask, running: true };
  } else if (!state.taskId && LIFECYCLE_EVENT_TYPES.has(ev.type)) {
    // Cockpit vide : un évènement de cycle de vie isolé n'ouvre pas de timeline.
    return state;
  } else {
    next = { ...state, taskId: evTask ?? null, events: capEvents([...state.events, ev]) };
    if (!state.taskId && evTask) next.running = true;
  }

  if (ev.type === "approval_required") {
    const idx = ev.data?.step_index ?? ev.data?.index;
    next.pendingApproval = {
      stepIndex: typeof idx === "number" ? idx : null,
      action: actionLabel(ev.data?.action),
      summary: typeof ev.data?.summary === "string" ? ev.data.summary : ev.message ?? "",
    };
  } else if (ev.type === "approval_result") {
    next.pendingApproval = null;
  }

  if (TERMINAL_EVENT_TYPES.has(ev.type)) {
    next.running = false;
    next.pendingApproval = null;
  }

  if (image) next.liveImage = image;
  else if (ev.data?.has_image === true && next.taskId) {
    next.screenshotRequest = { taskId: next.taskId, eventId: ev.id };
  }
  return next;
}

const EVALUATION_ACTION_TEXT: Record<string, string> = {
  memory_proposed: "objectif atteint",
  correction_awaiting_approval: "correction proposée, en attente de votre approbation",
  correction_invalid: "aucune correction créée (plan correctif invalide)",
  max_attempts_reached: "abandon (nombre maximal de tentatives atteint)",
  abandoned: "abandon",
  evaluation_failed: "évaluation impossible",
};

/** Texte lisible d'un évènement de la timeline. */
export function eventText(ev: AgentEvent): string {
  const d = ev.data ?? {};
  if (ev.type === "evaluation") {
    const action = typeof d.action_taken === "string" ? EVALUATION_ACTION_TEXT[d.action_taken] : undefined;
    // « Correction » uniquement si une tâche corrective a réellement été créée (T17).
    if (d.action_taken === "correction_awaiting_approval" && typeof d.corrective_task_id !== "string") {
      return "Évaluation : nouvelle tentative conseillée, aucune correction créée";
    }
    if (action) return `Évaluation : ${action}`;
  }
  if (ev.message) return ev.message;
  if (ev.type === "approval_result") return d.approved ? "Action confirmée sur le PC" : "Action refusée sur le PC";
  if (ev.type === "approval_required") return "Confirmation demandée sur le PC";
  return ev.type;
}

export function cockpitReducer(state: CockpitState, action: CockpitAction): CockpitState {
  switch (action.type) {
    case "event":
      return applyEvent(state, action.event);
    case "hydrate": {
      // Reprise après rafraîchissement : la tâche en cours et sa timeline.
      let next: CockpitState = { ...initialCockpitState, taskId: action.taskId, running: true };
      for (const ev of action.events) next = applyEvent(next, { ...ev, task_id: ev.task_id ?? action.taskId });
      return next;
    }
    case "screenshot":
      if (action.taskId !== state.taskId || !action.image) return state;
      return { ...state, liveImage: action.image };
    case "stopped":
      return { ...state, running: false, pendingApproval: null };
    default:
      return state;
  }
}
