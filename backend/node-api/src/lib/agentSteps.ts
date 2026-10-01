// Validation stricte des étapes de tâches agent (côté serveur).
// La liste des actions autorisées reflète le registre des skills de l'agent local
// (agent/skills/__init__.py → step_types de chaque skill). À tenir synchronisée.
import { isPlainObject, unknownKeys } from "./sanitize";

export const AGENT_STEP_TYPES: readonly string[] = [
  // open_app.py
  "open_app", "open_software", "launch",
  // screenshot.py
  "screenshot", "capture",
  // type_text.py
  "type_text", "type", "keyboard",
  // wait.py
  "wait", "sleep",
  // move_file.py
  "move_file", "move",
  // mouse.py
  "mouse", "click", "move_mouse", "drag", "scroll", "double_click", "right_click",
  // hotkey.py
  "hotkey", "press", "key",
  // window.py
  "window", "focus_window", "minimize_window", "maximize_window", "close_window",
  // run_command.py
  "run_command", "run_script", "shell",
  // filesystem.py
  "write_file", "read_file", "list_dir", "make_dir",
  // record_screen.py / record_bg.py
  "record_screen", "start_recording", "start_recording_bg", "stop_recording_bg",
  // edit_video.py / resolve_montage.py
  "edit_video", "montage", "resolve_montage",
  // phone.py
  "phone_list_devices", "phone_tap", "phone_swipe", "phone_type", "phone_key",
  "phone_open_app", "phone_screenshot",
];

export const MAX_STEPS = 50;
export const MAX_STEP_KEYS = 30;
export const MAX_STRING_LEN = 50_000;
export const MAX_ARRAY_LEN = 200;
export const MAX_PAYLOAD_BYTES = 256 * 1024;

const KEY_RE = /^[a-z][a-z0-9_]{0,39}$/;
const TASK_TYPE_RE = /^[a-z][a-z0-9_]{0,49}$/;

export type Result<T> = { ok: true; value: T } | { ok: false; error: string };

function validPrimitive(v: unknown): boolean {
  if (v === null || typeof v === "boolean") return true;
  if (typeof v === "number") return Number.isFinite(v);
  if (typeof v === "string") return v.length <= MAX_STRING_LEN;
  return false;
}

/** Valide une liste d'étapes : type autorisé, clés simples, valeurs scalaires ou tableaux de scalaires. */
export function validateSteps(steps: unknown, maxSteps = MAX_STEPS): Result<Record<string, unknown>[]> {
  if (!Array.isArray(steps)) return { ok: false, error: "steps doit être une liste" };
  if (steps.length === 0) return { ok: false, error: "steps ne peut pas être vide" };
  if (steps.length > maxSteps) return { ok: false, error: `trop d'étapes (max ${maxSteps})` };
  for (const [i, step] of steps.entries()) {
    const where = `étape ${i + 1}`;
    if (!isPlainObject(step)) return { ok: false, error: `${where} : objet attendu` };
    const type = step.type;
    if (typeof type !== "string" || !AGENT_STEP_TYPES.includes(type)) {
      return { ok: false, error: `${where} : action inconnue « ${String(type).slice(0, 40)} »` };
    }
    const keys = Object.keys(step);
    if (keys.length > MAX_STEP_KEYS) return { ok: false, error: `${where} : trop de champs` };
    for (const k of keys) {
      if (!KEY_RE.test(k)) return { ok: false, error: `${where} : nom de champ invalide « ${k.slice(0, 40)} »` };
      const v = step[k];
      if (Array.isArray(v)) {
        if (v.length > MAX_ARRAY_LEN || !v.every(validPrimitive)) {
          return { ok: false, error: `${where} : champ « ${k} » invalide` };
        }
      } else if (!validPrimitive(v)) {
        return { ok: false, error: `${where} : champ « ${k} » invalide` };
      }
    }
  }
  return { ok: true, value: steps as Record<string, unknown>[] };
}

/** Plan généré par le modèle : on borne le nombre d'étapes puis on valide. */
export function clampAndValidatePlanSteps(steps: Record<string, unknown>[]): Result<Record<string, unknown>[]> {
  return validateSteps(steps.slice(0, MAX_STEPS));
}

export interface TaskCreateInput {
  task_type: string;
  payload: Record<string, unknown>;
  priority: number;
}

/** Corps de POST /api/agent-tasks : { task_type, payload: { steps, ... }, priority? }. */
export function validateTaskCreateBody(body: unknown): Result<TaskCreateInput> {
  if (!isPlainObject(body)) return { ok: false, error: "corps JSON objet attendu" };
  const extra = unknownKeys(body, ["task_type", "payload", "priority"]);
  if (extra.length) return { ok: false, error: `champ(s) inconnu(s) : ${extra.join(", ").slice(0, 200)}` };
  if (typeof body.task_type !== "string" || !TASK_TYPE_RE.test(body.task_type)) {
    return { ok: false, error: "task_type requis (minuscules, chiffres, _ ; 50 car. max)" };
  }
  let priority = 5;
  if (body.priority !== undefined) {
    if (typeof body.priority !== "number" || !Number.isInteger(body.priority) || body.priority < 1 || body.priority > 10) {
      return { ok: false, error: "priority doit être un entier entre 1 et 10" };
    }
    priority = body.priority;
  }
  const payload = body.payload;
  if (!isPlainObject(payload)) return { ok: false, error: "payload (objet) requis" };
  if ("goal_meta" in payload) return { ok: false, error: "payload.goal_meta est réservé au serveur" };
  if (Buffer.byteLength(JSON.stringify(payload), "utf8") > MAX_PAYLOAD_BYTES) {
    return { ok: false, error: `payload trop volumineux (max ${MAX_PAYLOAD_BYTES / 1024} Ko)` };
  }
  const steps = validateSteps(payload.steps);
  if (!steps.ok) return { ok: false, error: `payload.steps : ${steps.error}` };
  return { ok: true, value: { task_type: body.task_type, payload, priority } };
}

export const MAX_GOAL_LENGTH = 2000;

/** Corps de POST /api/agent/goal : { goal }. */
export function validateGoalBody(body: unknown): Result<string> {
  if (!isPlainObject(body)) return { ok: false, error: "corps JSON objet attendu" };
  const extra = unknownKeys(body, ["goal"]);
  if (extra.length) return { ok: false, error: `champ(s) inconnu(s) : ${extra.join(", ").slice(0, 200)}` };
  const goal = typeof body.goal === "string" ? body.goal.trim() : "";
  if (!goal) return { ok: false, error: "goal requis" };
  if (goal.length > MAX_GOAL_LENGTH) return { ok: false, error: `goal trop long (max ${MAX_GOAL_LENGTH} caractères)` };
  return { ok: true, value: goal };
}
