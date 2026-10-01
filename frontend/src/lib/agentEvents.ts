// État du poste de pilotage (cockpit) : réducteur pur, testable sans React.
//  - ignore les évènements de progression des formations (data.source='formation', T29) ;
//  - les captures ne transitent plus en base64 : data.has_image ⇒ requête vers
//    GET /api/agent-tasks/:id/screenshot (contrat §8) ; l'ancien image_b64 reste lu ;
//  - approval_required / approval_result ⇒ « En attente de confirmation sur le PC » (§13),
//    y compris pour une tâche exécutée en parallèle sur un autre PC (otherApprovals).
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

/** Confirmation attendue sur le PC d'une tâche AUTRE que celle suivie (plusieurs PC, contrat §7/§13). */
export interface TaskApproval extends PendingApproval {
  taskId: string;
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
  /** Confirmation attendue pour la tâche suivie. */
  pendingApproval: PendingApproval | null;
  /** Confirmations attendues pour les autres tâches (un autre PC exécute en parallèle). */
  otherApprovals: TaskApproval[];
  screenshotRequest: ScreenshotRequest | null;
}

export type CockpitAction =
  | { type: "event"; event: AgentEvent }
  | { type: "hydrate"; taskId: string; events: AgentEvent[] }
  /** Historique d'une autre tâche en cours : n'en retient que la confirmation attendue. */
  | { type: "approvals"; taskId: string; events: AgentEvent[] }
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
  otherApprovals: [],
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

/** Confirmation décrite par un évènement approval_required (`data: {step_index, action, summary}`). */
function approvalFromEvent(ev: AgentEvent): PendingApproval {
  const idx = ev.data?.step_index ?? ev.data?.index;
  return {
    stepIndex: typeof idx === "number" ? idx : null,
    action: actionLabel(ev.data?.action),
    summary: typeof ev.data?.summary === "string" ? ev.data.summary : ev.message ?? "",
  };
}

const toPending = ({ stepIndex, action, summary }: TaskApproval): PendingApproval => ({ stepIndex, action, summary });

const withoutApproval = (list: TaskApproval[], taskId: string): TaskApproval[] =>
  list.some((a) => a.taskId === taskId) ? list.filter((a) => a.taskId !== taskId) : list;

const withApproval = (list: TaskApproval[], taskId: string, approval: PendingApproval): TaskApproval[] => [
  ...withoutApproval(list, taskId),
  { taskId, ...approval },
];

/** Confirmations d'une tâche NON suivie : approval_required l'ajoute ; approval_result ou la fin la retire. */
function trackApproval(list: TaskApproval[], taskId: string, ev: AgentEvent): TaskApproval[] {
  if (ev.type === "approval_required") return withApproval(list, taskId, approvalFromEvent(ev));
  if (ev.type === "approval_result" || TERMINAL_EVENT_TYPES.has(ev.type)) return withoutApproval(list, taskId);
  return list;
}

/**
 * Confirmations à conserver quand le cockpit se met à suivre `nextTaskId` : celles des autres
 * tâches, plus celle de la tâche suivie jusque-là si elle tourne encore (autre PC).
 */
function carriedApprovals(state: CockpitState, nextTaskId: string): TaskApproval[] {
  const others = withoutApproval(state.otherApprovals, nextTaskId);
  if (state.taskId && state.taskId !== nextTaskId && state.running && state.pendingApproval) {
    return withApproval(others, state.taskId, state.pendingApproval);
  }
  return others;
}

/** Confirmation encore attendue d'après l'historique d'une tâche (null si aucune). */
export function pendingApprovalFromHistory(events: readonly AgentEvent[]): PendingApproval | null {
  let pending: PendingApproval | null = null;
  for (const ev of events) {
    if (!isCockpitEvent(ev)) continue;
    if (ev.type === "approval_required") pending = approvalFromEvent(ev);
    else if (ev.type === "approval_result" || ev.type === "task_started" || TERMINAL_EVENT_TYPES.has(ev.type)) {
      pending = null;
    }
  }
  return pending;
}

function applyEvent(state: CockpitState, raw: AgentEvent): CockpitState {
  if (!isCockpitEvent(raw)) return state;
  const evTask = raw.task_id ?? state.taskId;
  const image = toImageDataUrl(raw.data?.image_b64, raw.data?.media_type);
  const ev = stripImage(raw);

  let next: CockpitState;
  if (ev.type === "task_started" && evTask) {
    next = { ...initialCockpitState, otherApprovals: carriedApprovals(state, evTask), events: [ev], taskId: evTask, running: true };
  } else if (evTask && state.taskId && evTask !== state.taskId) {
    // Évènement d'une autre tâche (autre PC, contrat §7) : ses confirmations sont toujours
    // suivies (§13) ; pour la timeline, il est ignoré tant que la tâche suivie tourne (ou s'il
    // ne s'agit que de cycle de vie) ; sinon (début manqué), le cockpit bascule dessus.
    const others = trackApproval(state.otherApprovals, evTask, ev);
    if (state.running || LIFECYCLE_EVENT_TYPES.has(ev.type)) {
      return others === state.otherApprovals ? state : { ...state, otherApprovals: others };
    }
    const own = others.find((a) => a.taskId === evTask);
    next = {
      ...initialCockpitState,
      otherApprovals: withoutApproval(others, evTask),
      pendingApproval: own ? toPending(own) : null,
      events: [ev],
      taskId: evTask,
      running: true,
    };
  } else if (!state.taskId && LIFECYCLE_EVENT_TYPES.has(ev.type)) {
    // Cockpit vide : un évènement de cycle de vie isolé n'ouvre pas de timeline.
    return state;
  } else {
    next = { ...state, taskId: evTask ?? null, events: capEvents([...state.events, ev]) };
    if (!state.taskId && evTask) next.running = true;
    if (evTask) next.otherApprovals = withoutApproval(next.otherApprovals, evTask);
  }

  if (ev.type === "approval_required") {
    next.pendingApproval = approvalFromEvent(ev);
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
  none: "tâche non évaluable (ni correction, ni mémoire)",
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
    const action =
      typeof d.action_taken === "string"
        ? EVALUATION_ACTION_TEXT[d.action_taken]
        : d.verdict === "not_evaluable"
          ? EVALUATION_ACTION_TEXT.none
          : undefined;
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
      let next: CockpitState = {
        ...initialCockpitState,
        otherApprovals: carriedApprovals(state, action.taskId),
        taskId: action.taskId,
        running: true,
      };
      for (const ev of action.events) next = applyEvent(next, { ...ev, task_id: ev.task_id ?? action.taskId });
      return next;
    }
    case "approvals": {
      // Autre tâche en cours (autre PC) : seule sa confirmation attendue est retenue (§13).
      if (action.taskId === state.taskId) return state;
      const pending = pendingApprovalFromHistory(action.events);
      const others = pending
        ? withApproval(state.otherApprovals, action.taskId, pending)
        : withoutApproval(state.otherApprovals, action.taskId);
      return others === state.otherApprovals ? state : { ...state, otherApprovals: others };
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
