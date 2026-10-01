// Dernière capture d'écran par tâche, EN MÉMOIRE uniquement (contrat LOT 1 §8) :
// plus aucun base64 dans agent_events ni dans agent_tasks.result. La capture est servie
// par GET /api/agent-tasks/:id/screenshot (JWT, propriétaire) pendant 10 minutes.
import { TtlCache } from "../lib/ttlCache.js";
import { isPlainObject } from "../lib/sanitize.js";

export const SCREENSHOT_TTL_MS = 10 * 60 * 1000;
const MAX_TASKS = 200;

export interface StoredScreenshot {
  userId: string;
  image_b64: string;
  mime: string;
  at: string;
}

const store = new TtlCache<StoredScreenshot>(MAX_TASKS, SCREENSHOT_TTL_MS);

const MIME_RE = /^image\/(jpeg|png|webp)$/;

export function normalizeMime(v: unknown): string {
  return typeof v === "string" && MIME_RE.test(v) ? v : "image/jpeg";
}

export function rememberScreenshot(taskId: string, userId: string, image_b64: string, mime: unknown): void {
  store.set(taskId, { userId, image_b64, mime: normalizeMime(mime), at: new Date().toISOString() });
}

/** Capture d'une tâche, uniquement pour son propriétaire (sinon undefined → 404). */
export function getScreenshot(taskId: string, userId: string): StoredScreenshot | undefined {
  const s = store.get(taskId);
  return s && s.userId === userId ? s : undefined;
}

export function forgetScreenshot(taskId: string): void {
  store.delete(taskId);
}

/**
 * Retire la capture d'un `data` d'évènement : renvoie les données sans `image_b64`
 * (avec has_image=true si une image était présente) et l'image extraite éventuelle.
 */
export function extractEventImage(data: unknown): {
  data: Record<string, unknown>;
  image?: { b64: string; mime: string };
} {
  if (!isPlainObject(data)) return { data: {} };
  const { image_b64, ...rest } = data;
  if (typeof image_b64 === "string" && image_b64.length > 0) {
    return {
      data: { ...rest, has_image: true },
      image: { b64: image_b64, mime: normalizeMime(rest.media_type ?? rest.mime) },
    };
  }
  return { data: image_b64 === undefined ? data : { ...rest } };
}

/**
 * Captures d'un rapport final de l'agent (result.steps[].data.image_b64), les N
 * DERNIÈRES dans l'ordre d'exécution — ce que l'évaluateur doit « voir » (état final).
 */
export function extractResultScreenshots(result: unknown, max = 3): string[] {
  const steps = isPlainObject(result) ? result.steps : undefined;
  if (!Array.isArray(steps)) return [];
  const shots: string[] = [];
  for (const s of steps) {
    const img = isPlainObject(s) && isPlainObject(s.data) ? s.data.image_b64 : undefined;
    if (typeof img === "string" && img.length > 0) shots.push(img);
  }
  return shots.slice(-max);
}
