// Logique pure du panneau des tâches de l'agent : statuts, actions permises,
// corrections soumises à approbation (contrat LOT 1 §6), plan affiché, enregistrements.

export interface AgentTaskEvaluation {
  verdict?: string | null;
  reason?: string;
  /**
   * Décision effective de l'évaluateur : none (verdict not_evaluable) | memory_proposed |
   * correction_awaiting_approval | correction_invalid | max_attempts_reached | abandoned |
   * evaluation_failed.
   */
  action_taken?: string | null;
  /** Présent UNIQUEMENT si une tâche corrective a réellement été créée. */
  corrective_task_id?: string | null;
}

export interface AgentTaskStepReport {
  index?: number;
  type?: string;
  ok?: boolean;
  detail?: string;
  data?: { path?: unknown; [key: string]: unknown };
}

export interface AgentTaskResult {
  file?: string;
  summary?: string;
  steps?: AgentTaskStepReport[];
  evaluation?: AgentTaskEvaluation;
  simulated?: boolean;
  empty_plan?: boolean;
  [key: string]: unknown;
}

export interface GoalMeta {
  goal?: string;
  attempt?: number;
  max_attempts?: number;
  understanding?: string;
  awaiting_approval?: boolean;
  parent_task_id?: string;
  root_task_id?: string;
}

export interface AgentTaskPayload {
  goal_meta?: GoalMeta;
  steps?: unknown[];
  [key: string]: unknown;
}

export interface AgentTask {
  id: string;
  task_type: string;
  status: string;
  control?: string | null;
  payload: AgentTaskPayload | null;
  result: AgentTaskResult | null;
  error_message: string | null;
  created_at: string;
  completed_at: string | null;
  target_agent_key_id?: string | null;
  claimed_by_key_id?: string | null;
}

export type TaskStatus = "pending" | "in_progress" | "completed" | "failed" | "cancelled";
export type Tone = "success" | "warning" | "destructive" | "primary" | "muted";

export const TERMINAL_STATUSES: ReadonlySet<string> = new Set(["completed", "failed", "cancelled"]);

export const STATUS_LABELS: Record<TaskStatus, string> = {
  pending: "En attente",
  in_progress: "En cours",
  completed: "Terminé",
  failed: "Échoué",
  cancelled: "Annulée",
};

export const isTerminalStatus = (status: string) => TERMINAL_STATUSES.has(status);

/** Libellé français d'un statut (inconnu → statut brut). */
export function statusLabel(task: Pick<AgentTask, "status" | "control"> & Partial<AgentTask>): string {
  if (task.status === "in_progress" && task.control === "stop") return "Arrêt demandé";
  if (isAwaitingApproval(task)) return "À approuver";
  return STATUS_LABELS[task.status as TaskStatus] ?? task.status;
}

/** Correction créée par l'évaluateur et pas encore approuvée (contrat §6). */
export function isAwaitingApproval(task: Partial<AgentTask>): boolean {
  return task.status === "pending" && task.payload?.goal_meta?.awaiting_approval === true;
}

/** La suppression n'est permise que pour une tâche terminée (S9). */
export const canDeleteTask = (task: Pick<AgentTask, "status">) => isTerminalStatus(task.status);

/** Annulation possible : tâche en attente, ou en cours sans arrêt déjà demandé. */
export function canCancelTask(task: Pick<AgentTask, "status" | "control">): boolean {
  if (task.status === "pending") return true;
  return task.status === "in_progress" && task.control !== "stop";
}

/**
 * Applique localement la réponse de POST /cancel en attendant le temps réel :
 * `{task}` fusionné, sinon `{status}`, sinon le comportement du contrat §2.
 */
export function applyCancelResponse(
  task: AgentTask,
  resp: { status?: string; control?: string; task?: Record<string, unknown> } | undefined,
): AgentTask {
  if (resp?.task && typeof resp.task === "object") return { ...task, ...(resp.task as Partial<AgentTask>) };
  if (typeof resp?.status === "string" && resp.status) {
    return { ...task, status: resp.status, control: resp.control ?? task.control };
  }
  if (task.status === "pending") return { ...task, status: "cancelled" };
  if (task.status === "in_progress") return { ...task, control: "stop" };
  return task;
}

/** Applique localement une approbation réussie (le poll peut désormais prendre la tâche). */
export function applyApproveResponse(task: AgentTask, resp?: { task?: Record<string, unknown> }): AgentTask {
  if (resp?.task && typeof resp.task === "object") return { ...task, ...(resp.task as Partial<AgentTask>) };
  const payload = task.payload ?? {};
  return {
    ...task,
    payload: { ...payload, goal_meta: { ...(payload.goal_meta ?? {}), awaiting_approval: false } },
  };
}

/** Issue d'une suppression via DELETE /api/agent-tasks/:id (voir deleteAgentTask). */
export type DeleteOutcome = { kind: "deleted" | "gone" } | { kind: "active"; status: string | null };

/**
 * Applique localement l'issue d'une suppression (S9) : supprimée (204) ou introuvable (404) →
 * retirée ; refusée car active (409) → conservée, avec le statut réel renvoyé par le serveur.
 */
export function applyDeleteOutcome(tasks: AgentTask[], taskId: string, outcome: DeleteOutcome): AgentTask[] {
  if (outcome.kind !== "active") return tasks.filter((t) => t.id !== taskId);
  const status = outcome.status;
  if (!status) return tasks;
  return tasks.map((t) => (t.id === taskId ? { ...t, status } : t));
}

export interface EvaluationView {
  text: string;
  tone: Tone;
}

/** Tâche corrective liée à `task` : désignée par l'évaluation ou par payload.goal_meta.parent_task_id. */
export function findCorrection(task: AgentTask, tasks: readonly AgentTask[]): AgentTask | null {
  const id = task.result?.evaluation?.corrective_task_id;
  return (
    (typeof id === "string" && id ? tasks.find((t) => t.id === id) : undefined) ??
    tasks.find((t) => t.payload?.goal_meta?.parent_task_id === task.id) ??
    null
  );
}

const ABORT_LABELS: Record<string, string> = {
  max_attempts_reached: "Abandonné (nombre maximal de tentatives atteint)",
  correction_invalid: "Aucune correction créée (plan correctif invalide)",
  abandoned: "Abandonné",
};

/**
 * Texte du verdict de l'évaluateur (T17). « Correction lancée » n'est affiché que si une
 * tâche corrective existe réellement (corrective_task_id de l'évaluation, ou tâche liée
 * dans la liste) ET a été approuvée ; sinon on dit la vérité (proposée, rejetée, aucune).
 */
export function evaluationView(task: AgentTask, tasks: readonly AgentTask[]): EvaluationView | null {
  const ev = task.result?.evaluation;
  if (!ev || typeof ev !== "object") return null;
  const reason = typeof ev.reason === "string" && ev.reason ? ` — ${ev.reason}` : "";
  if (ev.action_taken === "evaluation_failed") return { text: `Évaluation impossible${reason}`, tone: "muted" };
  // Non évaluable (python-ia not_evaluable → action_taken 'none') : ni correction, ni mémoire.
  if (ev.verdict === "not_evaluable" || ev.action_taken === "none") {
    return { text: `Non évaluable${reason}`, tone: "muted" };
  }
  if (ev.verdict === "success") return { text: `Objectif atteint${reason}`, tone: "success" };

  const correction = findCorrection(task, tasks);
  const created = !!correction || (typeof ev.corrective_task_id === "string" && ev.corrective_task_id !== "");
  if (created) {
    if (!correction || isAwaitingApproval(correction)) {
      return { text: `Correction proposée — en attente de votre approbation${reason}`, tone: "warning" };
    }
    if (correction.status === "cancelled") return { text: `Correction rejetée${reason}`, tone: "muted" };
    return { text: `Correction lancée${reason}`, tone: "warning" };
  }
  const abortLabel = typeof ev.action_taken === "string" ? ABORT_LABELS[ev.action_taken] : undefined;
  if (abortLabel) return { text: `${abortLabel}${reason}`, tone: "destructive" };
  if (ev.verdict === "retry") {
    return { text: `Nouvelle tentative conseillée — aucune correction créée${reason}`, tone: "muted" };
  }
  return { text: `Abandonné${reason}`, tone: "destructive" };
}

const STEP_LABELS: Record<string, string> = {
  open_app: "Ouvrir",
  type_text: "Taper",
  hotkey: "Raccourci",
  wait: "Attendre",
  screenshot: "Capture",
  click: "Clic",
  double_click: "Double-clic",
  right_click: "Clic droit",
  move_mouse: "Déplacer la souris",
  drag: "Glisser",
  scroll: "Défiler",
  window: "Fenêtre",
  move_file: "Déplacer le fichier",
  write_file: "Écrire le fichier",
  read_file: "Lire le fichier",
  list_dir: "Lister le dossier",
  make_dir: "Créer le dossier",
  run_command: "Commande",
  record_screen: "Enregistrer l'écran",
  start_recording: "Démarrer l'enregistrement",
  start_recording_bg: "Démarrer l'enregistrement",
  stop_recording_bg: "Arrêter l'enregistrement",
  edit_video: "Monter la vidéo",
  resolve_montage: "Montage Resolve",
  open_software: "Ouvrir",
};

const str = (v: unknown) => (typeof v === "string" ? v : typeof v === "number" ? String(v) : "");

/**
 * Types d'étapes sensibles (même liste que node-api `SENSITIVE_STEP_TYPES`) : une étape de ce
 * type exige la confirmation sur le PC ; dans une correction à approuver, son contenu complet
 * (texte saisi, commande, contenu de fichier) est affiché avant le bouton Approuver (S10).
 */
export const SENSITIVE_STEP_TYPES: ReadonlySet<string> = new Set([
  "run_command", "run_script", "shell",
  "write_file", "move_file", "move",
  "type_text", "type", "keyboard",
  "hotkey", "press", "key",
  "phone_tap", "phone_swipe", "phone_type", "phone_key", "phone_open_app",
]);

export const isSensitiveStep = (step: unknown): boolean =>
  !!step && typeof step === "object" && SENSITIVE_STEP_TYPES.has(str((step as Record<string, unknown>).type));

export interface DescribeStepOptions {
  /** Aucun texte tronqué (carte d'approbation d'une correction, S10). */
  full?: boolean;
}

/** Résumé lisible d'une étape planifiée (C36) ; tronqué sauf `{ full: true }`. */
export function describeStep(step: unknown, { full = false }: DescribeStepOptions = {}): string {
  if (!step || typeof step !== "object") return "Étape invalide";
  const clip = (v: string, max = 80) => (!full && v.length > max ? `${v.slice(0, max - 1)}…` : v);
  const s = step as Record<string, unknown>;
  const type = str(s.type) || "?";
  const label = STEP_LABELS[type] ?? type;
  let detail = "";
  switch (type) {
    case "open_app":
      detail = str(s.app);
      break;
    case "open_software":
      detail = str(s.software);
      break;
    case "type_text": {
      const text = str(s.text);
      detail = text ? `« ${clip(text, 60)} »` : "";
      break;
    }
    case "hotkey":
      detail = Array.isArray(s.keys) ? s.keys.map(str).filter(Boolean).join("+") : "";
      break;
    case "wait":
      detail = s.seconds !== undefined ? `${str(s.seconds)} s` : "";
      break;
    case "click":
    case "double_click":
    case "right_click":
    case "move_mouse":
    case "drag":
      detail = s.x !== undefined && s.y !== undefined ? `(${str(s.x)}, ${str(s.y)})` : "";
      break;
    case "window":
      detail = [str(s.action), str(s.window_title)].filter(Boolean).join(" ");
      break;
    case "move_file":
      detail = `${str(s.src)} → ${str(s.dest)}`;
      break;
    case "run_command":
      detail = [str(s.program), ...(Array.isArray(s.args) ? s.args.map(str) : [])].filter(Boolean).join(" ");
      break;
    case "edit_video":
    case "resolve_montage":
      detail = str(s.output);
      break;
    default:
      detail = str(s.path) || str(s.description);
  }
  const note = str(s.note) || str(s.description);
  const main = detail ? `${label} : ${clip(detail)}` : label;
  return note && note !== detail ? `${main} (${clip(note, 60)})` : main;
}

/**
 * Contenu INTÉGRAL d'une étape (JSON indenté, rien de tronqué ni d'omis) : c'est exactement ce
 * que l'agent recevra. Affiché pour chaque étape d'une correction en attente d'approbation (S10).
 */
export function stepFullDetail(step: unknown): string {
  try {
    return JSON.stringify(step, null, 2) ?? String(step);
  } catch {
    return String(step);
  }
}

export interface ApprovalStepView {
  /** Résumé non tronqué. */
  summary: string;
  /** Étape complète (JSON). */
  detail: string;
  sensitive: boolean;
}

/** Vue d'une étape dans la carte d'approbation d'une correction : rien n'est masqué (S10). */
export function approvalStepView(step: unknown): ApprovalStepView {
  return { summary: describeStep(step, { full: true }), detail: stepFullDetail(step), sensitive: isSensitiveStep(step) };
}

/** Étapes planifiées d'une tâche (payload.steps), [] si absent. */
export function plannedSteps(task: Pick<AgentTask, "payload">): unknown[] {
  const steps = task.payload?.steps;
  return Array.isArray(steps) ? steps : [];
}

// start_recording_bg est exclu : le fichier n'est finalisé (lisible) qu'à l'arrêt.
const RECORDING_TYPES = new Set(["record_screen", "start_recording", "stop_recording_bg"]);

/** Chemins des enregistrements produits par la tâche (C18), sans doublon. */
export function recordingPaths(task: Pick<AgentTask, "result">): string[] {
  const steps = task.result?.steps;
  if (!Array.isArray(steps)) return [];
  const out: string[] = [];
  for (const step of steps) {
    if (!step || typeof step !== "object" || !RECORDING_TYPES.has(String(step.type))) continue;
    const path = step.data?.path;
    if (step.ok !== false && typeof path === "string" && path && !out.includes(path)) out.push(path);
  }
  return out;
}

const isRecord = (v: unknown): v is Record<string, unknown> =>
  !!v && typeof v === "object" && !Array.isArray(v);
const optStr = (v: unknown): string | null => (typeof v === "string" ? v : null);

/** Normalise une ligne agent_tasks (API ou temps réel) ; null si elle est inexploitable. */
export function normalizeTaskRow(row: unknown): AgentTask | null {
  if (!isRecord(row) || typeof row.id !== "string" || !row.id) return null;
  return {
    id: row.id,
    task_type: typeof row.task_type === "string" ? row.task_type : "",
    status: typeof row.status === "string" && row.status ? row.status : "pending",
    control: optStr(row.control),
    payload: isRecord(row.payload) ? (row.payload as AgentTaskPayload) : null,
    result: isRecord(row.result) ? (row.result as AgentTaskResult) : null,
    error_message: optStr(row.error_message),
    created_at: typeof row.created_at === "string" ? row.created_at : new Date(0).toISOString(),
    completed_at: optStr(row.completed_at),
    target_agent_key_id: optStr(row.target_agent_key_id),
    claimed_by_key_id: optStr(row.claimed_by_key_id),
  };
}

/** Changement temps réel (sous-ensemble de RealtimePostgresChangesPayload). */
export type TaskChange =
  | { eventType: "DELETE"; old: { id?: unknown } }
  | { eventType: "INSERT" | "UPDATE"; new: Record<string, unknown> };

export const MAX_TASKS = 200;

/** Applique un évènement temps réel à la liste (sans refetch complet). */
export function applyTaskChange(prev: AgentTask[], change: TaskChange): AgentTask[] {
  if (change.eventType === "DELETE") {
    const id = change.old?.id;
    return typeof id === "string" && id ? prev.filter((t) => t.id !== id) : prev;
  }
  const id = change.new?.id;
  if (typeof id !== "string" || !id) return prev;
  const idx = prev.findIndex((t) => t.id === id);
  // Les colonnes absentes du message (ex. JSON volumineux inchangé) gardent leur valeur.
  const row = normalizeTaskRow(idx === -1 ? change.new : { ...prev[idx], ...change.new });
  if (!row) return prev;
  if (idx === -1) return [row, ...prev].slice(0, MAX_TASKS);
  const next = prev.slice();
  next[idx] = row;
  return next;
}
