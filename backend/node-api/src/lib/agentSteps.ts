// Validation stricte des étapes de tâches agent (côté serveur).
//
// TABLE UNIQUE des skills de l'agent local (agent/skills/*.py) : types d'étapes et
// paramètres lus par chaque skill. Elle alimente :
//  - AGENT_STEP_TYPES (actions autorisées),
//  - compactStep (nettoyage des plans générés : ne garde QUE les paramètres connus),
//  - REQUIRED_FIELDS / findInvalidStep (plan incomplet refusé avant la mise en file).
// test/agentSteps.test.ts relit agent/skills/*.py et ÉCHOUE si un skill lit un paramètre
// absent de cette table (dérive planner → agent, cf. audit T3) ou si un type manque.
import { isPlainObject, unknownKeys, isUuid } from "./sanitize.js";
import { isAbsoluteAnyOs, isPathAllowed } from "./paths.js";

export interface SkillSpec {
  /** Fichier du skill dans agent/skills/. */
  file: string;
  /** Types d'étapes (step_types) du skill. */
  types: readonly string[];
  /** Paramètres lus par le skill (step.get(...)), hors `type`. */
  params: readonly string[];
}

export const AGENT_SKILLS: readonly SkillSpec[] = [
  { file: "open_app.py", types: ["open_app", "open_software", "launch"], params: ["app", "software", "name"] },
  { file: "screenshot.py", types: ["screenshot", "capture"], params: ["path"] },
  { file: "type_text.py", types: ["type_text", "type", "keyboard"], params: ["text", "method", "interval", "window_title"] },
  { file: "wait.py", types: ["wait", "sleep"], params: ["seconds"] },
  { file: "move_file.py", types: ["move_file", "move"], params: ["src", "dest"] },
  {
    file: "mouse.py",
    types: ["mouse", "click", "move_mouse", "drag", "scroll", "double_click", "right_click"],
    params: ["x", "y", "dy", "button", "clicks"],
  },
  { file: "hotkey.py", types: ["hotkey", "press", "key"], params: ["keys"] },
  {
    file: "window.py",
    types: ["window", "focus_window", "minimize_window", "maximize_window", "close_window"],
    params: ["action", "window_title", "title", "match"],
  },
  { file: "run_command.py", types: ["run_command", "run_script", "shell"], params: ["program", "args", "cwd", "timeout", "allow_scripts"] },
  { file: "filesystem.py", types: ["write_file", "read_file", "list_dir", "make_dir"], params: ["path", "content"] },
  { file: "record_screen.py", types: ["record_screen", "start_recording"], params: ["path", "duration", "fps", "monitor"] },
  { file: "record_bg.py", types: ["start_recording_bg", "stop_recording_bg"], params: ["path", "fps", "monitor"] },
  { file: "edit_video.py", types: ["edit_video", "montage"], params: ["clips", "output", "title"] },
  { file: "resolve_montage.py", types: ["resolve_montage"], params: ["clips", "audio", "output", "project"] },
  {
    file: "phone.py",
    types: [
      "phone_list_devices", "phone_tap", "phone_swipe", "phone_type", "phone_key",
      "phone_open_app", "phone_screenshot",
    ],
    params: ["device_id", "x", "y", "x1", "y1", "x2", "y2", "duration_ms", "text", "keycode", "package", "path"],
  },
];

/** Champs descriptifs conservés sur toute étape (ignorés par l'agent, affichés à l'utilisateur). */
export const COMMON_STEP_FIELDS: readonly string[] = ["type", "note", "description"];

export const AGENT_STEP_TYPES: readonly string[] = AGENT_SKILLS.flatMap((s) => s.types);

/** Paramètres autorisés par type d'étape (dérivés de AGENT_SKILLS). */
export const STEP_PARAMS: Readonly<Record<string, readonly string[]>> = Object.fromEntries(
  AGENT_SKILLS.flatMap((s) => s.types.map((t) => [t, s.params] as const)),
);

/**
 * Champs obligatoires par type (« a|b » = au moins l'un des deux). Un plan qui en omet
 * un échouerait forcément côté agent : on le rejette AVANT de le mettre en file.
 * run_command exige `cwd` (l'agent refuse une commande sans répertoire de travail).
 */
const REQUIRED_BY_SKILL: Record<string, Record<string, readonly string[]>> = {
  "open_app.py": { "*": ["app|software|name"] },
  "type_text.py": { "*": ["text"] },
  "move_file.py": { "*": ["src", "dest"] },
  "hotkey.py": { "*": ["keys"] },
  "window.py": { "*": ["window_title|title"] },
  "run_command.py": { "*": ["program", "cwd"] },
  "filesystem.py": { "*": ["path"] },
  "record_screen.py": { "*": ["path"] },
  "record_bg.py": { "*": ["path"] },
  "edit_video.py": { "*": ["clips", "output"] },
  "resolve_montage.py": { "*": ["clips", "output"] },
  "phone.py": {
    phone_tap: ["x", "y"],
    phone_swipe: ["x1", "y1", "x2", "y2"],
    phone_type: ["text"],
    phone_key: ["keycode"],
    phone_open_app: ["package"],
    phone_screenshot: ["path"],
  },
};

export const REQUIRED_FIELDS: Readonly<Record<string, readonly string[]>> = Object.fromEntries(
  AGENT_SKILLS.flatMap((s) =>
    s.types.map((t) => {
      const spec = REQUIRED_BY_SKILL[s.file] ?? {};
      return [t, spec[t] ?? spec["*"] ?? []] as const;
    }),
  ),
);

/** Clés de chemin contrôlées (miroir de agent/permissions.py _PATH_KEYS) + `clips`. */
export const PATH_KEYS: readonly string[] = ["src", "dest", "path", "cwd", "output", "audio"];

/** Actions à effet réel (commande, écriture, saisie, touches, téléphone) : confirmation requise. */
export const SENSITIVE_STEP_TYPES: readonly string[] = [
  "run_command", "run_script", "shell",
  "write_file", "move_file", "move",
  "type_text", "type", "keyboard",
  "hotkey", "press", "key",
  "phone_tap", "phone_swipe", "phone_type", "phone_key", "phone_open_app",
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

/**
 * Nettoie une étape générée par le planificateur : ne garde que `type`, les champs
 * descriptifs et les paramètres RÉELLEMENT lus par le skill (table AGENT_SKILLS).
 * Les valeurs absentes (undefined/null) sont omises. Type inconnu → seulement {type}
 * (validateSteps le refusera ensuite).
 */
export function compactStep(s: Record<string, unknown>): Record<string, unknown> {
  const type = typeof s.type === "string" ? s.type : String(s.type);
  const out: Record<string, unknown> = { type };
  const allowed = ["note", "description", ...(STEP_PARAMS[type] ?? [])];
  for (const k of allowed) {
    const v = s[k];
    if (v === undefined || v === null) continue;
    if (k === "note" || k === "description") {
      if (typeof v === "string" && v.trim()) out[k] = v.slice(0, 500);
      continue;
    }
    out[k] = v;
  }
  return out;
}

function isMissing(v: unknown): boolean {
  return v === undefined || v === null || v === "" || (Array.isArray(v) && v.length === 0);
}

/** Retourne null si toutes les étapes sont complètes, sinon un message d'erreur lisible. */
export function findInvalidStep(steps: Record<string, unknown>[]): string | null {
  for (const [i, step] of steps.entries()) {
    for (const field of REQUIRED_FIELDS[step.type as string] ?? []) {
      const alternatives = field.split("|");
      if (alternatives.every((f) => isMissing(step[f]))) {
        return `étape ${i + 1} (${String(step.type)}) : champ obligatoire manquant « ${alternatives.join(" » ou « ")} »`;
      }
    }
  }
  return null;
}

/** Chemins portés par une étape (clés de chemin + clips). */
export function stepPaths(step: Record<string, unknown>): string[] {
  const out: string[] = [];
  for (const k of PATH_KEYS) {
    const v = step[k];
    if (typeof v === "string" && v !== "") out.push(v);
  }
  if (Array.isArray(step.clips)) for (const c of step.clips) if (typeof c === "string" && c) out.push(c);
  return out;
}

/**
 * Vérifie que chaque chemin des étapes est absolu ET dans les dossiers autorisés de
 * l'agent ciblé (S21). Retourne null si tout est conforme, sinon un message.
 */
export function findPathOutsideAllowed(
  steps: Record<string, unknown>[],
  allowedDirs: readonly string[],
): string | null {
  for (const [i, step] of steps.entries()) {
    for (const p of stepPaths(step)) {
      if (!isAbsoluteAnyOs(p)) return `étape ${i + 1} (${String(step.type)}) : chemin relatif refusé « ${p.slice(0, 200)} »`;
      if (!isPathAllowed(p, allowedDirs)) {
        return allowedDirs.length === 0
          ? `étape ${i + 1} (${String(step.type)}) : aucun dossier autorisé connu pour l'agent ciblé — chemin « ${p.slice(0, 200)} » refusé`
          : `étape ${i + 1} (${String(step.type)}) : chemin hors des dossiers autorisés de l'agent « ${p.slice(0, 200)} »`;
      }
    }
  }
  return null;
}

/** Vrai si au moins une étape a un effet réel (commande, écriture, saisie, touches…). */
export function requiresConfirmation(steps: Record<string, unknown>[]): boolean {
  return steps.some((s) => SENSITIVE_STEP_TYPES.includes(String(s.type)));
}

/** agent_key_id optionnel : undefined si absent, null si invalide, sinon l'uuid. */
export function parseAgentKeyId(v: unknown): string | undefined | null {
  if (v === undefined || v === null || v === "") return undefined;
  return isUuid(v) ? v : null;
}

export interface TaskCreateInput {
  task_type: string;
  payload: Record<string, unknown>;
  priority: number;
  agent_key_id?: string;
}

/** Corps de POST /api/agent-tasks : { task_type, payload: { steps, ... }, priority?, agent_key_id? }. */
export function validateTaskCreateBody(body: unknown): Result<TaskCreateInput> {
  if (!isPlainObject(body)) return { ok: false, error: "corps JSON objet attendu" };
  const extra = unknownKeys(body, ["task_type", "payload", "priority", "agent_key_id"]);
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
  const agentKeyId = parseAgentKeyId(body.agent_key_id);
  if (agentKeyId === null) return { ok: false, error: "agent_key_id doit être un uuid" };
  const payload = body.payload;
  if (!isPlainObject(payload)) return { ok: false, error: "payload (objet) requis" };
  if ("goal_meta" in payload) return { ok: false, error: "payload.goal_meta est réservé au serveur" };
  if (Buffer.byteLength(JSON.stringify(payload), "utf8") > MAX_PAYLOAD_BYTES) {
    return { ok: false, error: `payload trop volumineux (max ${MAX_PAYLOAD_BYTES / 1024} Ko)` };
  }
  const steps = validateSteps(payload.steps);
  if (!steps.ok) return { ok: false, error: `payload.steps : ${steps.error}` };
  const value: TaskCreateInput = { task_type: body.task_type, payload, priority };
  if (agentKeyId) value.agent_key_id = agentKeyId;
  return { ok: true, value };
}

export const MAX_GOAL_LENGTH = 2000;

/** Corps de POST /api/agent/goal : { goal, agent_key_id? } → l'objectif nettoyé. */
export function validateGoalBody(body: unknown): Result<string> {
  if (!isPlainObject(body)) return { ok: false, error: "corps JSON objet attendu" };
  const extra = unknownKeys(body, ["goal", "agent_key_id"]);
  if (extra.length) return { ok: false, error: `champ(s) inconnu(s) : ${extra.join(", ").slice(0, 200)}` };
  if (parseAgentKeyId(body.agent_key_id) === null) return { ok: false, error: "agent_key_id doit être un uuid" };
  const goal = typeof body.goal === "string" ? body.goal.trim() : "";
  if (!goal) return { ok: false, error: "goal requis" };
  if (goal.length > MAX_GOAL_LENGTH) return { ok: false, error: `goal trop long (max ${MAX_GOAL_LENGTH} caractères)` };
  return { ok: true, value: goal };
}
