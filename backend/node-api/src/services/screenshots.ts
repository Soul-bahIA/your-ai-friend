// Dernière capture d'écran par tâche, EN MÉMOIRE uniquement (contrat LOT 1 §8) :
// plus aucun base64 dans agent_events ni dans agent_tasks.result. La capture est servie
// par GET /api/agent-tasks/:id/screenshot (JWT, propriétaire) pendant 10 minutes.
//
// Mémoire bornée (C§8 / T37) : une capture est validée (base64 strict, ≤ 2 Mo de texte),
// le magasin a un budget GLOBAL en octets et en entrées, plus un plafond PAR UTILISATEUR
// (un compte ne peut pas évincer les captures des autres), et les entrées expirées sont
// balayées (à chaque écriture et par un minuteur), pas seulement évincées en FIFO.
import { isPlainObject, stripImageB64 } from "../lib/sanitize.js";

export const SCREENSHOT_TTL_MS = 10 * 60 * 1000;
/**
 * Taille max d'une capture, en caractères base64 (≈ 1,5 Mo binaire). L'agent envoie un
 * JPEG ≤ 1280 px de côté, qualité 80 : quelques centaines de Ko en pratique.
 */
export const MAX_SCREENSHOT_B64_CHARS = 2 * 1024 * 1024;

export interface ScreenshotStoreLimits {
  /** Budget global (somme des longueurs base64). */
  maxBytes: number;
  /** Budget par utilisateur. */
  maxBytesPerUser: number;
  /** Nombre max de tâches retenues, tous utilisateurs confondus. */
  maxEntries: number;
  /** Nombre max de tâches retenues par utilisateur. */
  maxEntriesPerUser: number;
  ttlMs: number;
}

export const DEFAULT_SCREENSHOT_LIMITS: ScreenshotStoreLimits = {
  maxBytes: 128 * 1024 * 1024,
  maxBytesPerUser: 24 * 1024 * 1024,
  maxEntries: 500,
  maxEntriesPerUser: 50,
  ttlMs: SCREENSHOT_TTL_MS,
};

export interface StoredScreenshot {
  userId: string;
  image_b64: string;
  mime: string;
  at: string;
}

interface Entry extends StoredScreenshot {
  expires: number;
  bytes: number;
}

const B64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

/** null si `v` est une capture base64 acceptable, sinon la raison du refus. */
export function screenshotB64Error(v: unknown, maxChars = MAX_SCREENSHOT_B64_CHARS): string | null {
  if (typeof v !== "string" || v.length === 0) return "image_b64 doit être un texte base64 non vide";
  if (v.length > maxChars) return `image_b64 trop volumineuse (${Math.floor(maxChars / (1024 * 1024))} Mo de base64 max)`;
  if (v.length % 4 !== 0 || !B64_RE.test(v)) return "image_b64 n'est pas du base64 valide";
  return null;
}

/**
 * Magasin borné des dernières captures (une par tâche). Ordre d'insertion = ancienneté :
 * l'éviction retire d'abord les plus anciennes captures DU MÊME utilisateur (plafond par
 * compte), puis, si le budget global est dépassé, les plus anciennes du compte qui en
 * consomme le plus — un compte ne peut pas vider le magasin des autres.
 */
export class ScreenshotStore {
  private map = new Map<string, Entry>();
  private totalBytes = 0;
  private users = new Map<string, { bytes: number; count: number }>();

  constructor(
    private limits: ScreenshotStoreLimits = DEFAULT_SCREENSHOT_LIMITS,
    private now: () => number = () => Date.now(),
  ) {}

  /** Retient la capture ; false si elle dépasse à elle seule un budget (non retenue). */
  set(taskId: string, shot: StoredScreenshot): boolean {
    const bytes = shot.image_b64.length;
    this.delete(taskId);
    if (bytes > this.limits.maxBytesPerUser || bytes > this.limits.maxBytes) return false;
    this.sweep();
    const u = () => this.users.get(shot.userId) ?? { bytes: 0, count: 0 };
    while (u().count > 0 && (u().count >= this.limits.maxEntriesPerUser || u().bytes + bytes > this.limits.maxBytesPerUser)) {
      if (!this.evictOldest((e) => e.userId === shot.userId)) break;
    }
    // Budget global dépassé : on prend chez le plus GROS consommateur (équité entre comptes).
    while (this.map.size > 0 && (this.map.size >= this.limits.maxEntries || this.totalBytes + bytes > this.limits.maxBytes)) {
      const heaviest = this.heaviestUser();
      if (heaviest === undefined || !this.evictOldest((e) => e.userId === heaviest)) break;
    }
    this.map.set(taskId, { ...shot, bytes, expires: this.now() + this.limits.ttlMs });
    this.account(shot.userId, bytes, 1);
    return true;
  }

  get(taskId: string): StoredScreenshot | undefined {
    const e = this.map.get(taskId);
    if (!e) return undefined;
    if (e.expires <= this.now()) {
      this.delete(taskId);
      return undefined;
    }
    return { userId: e.userId, image_b64: e.image_b64, mime: e.mime, at: e.at };
  }

  delete(taskId: string): void {
    const e = this.map.get(taskId);
    if (!e) return;
    this.map.delete(taskId);
    this.account(e.userId, -e.bytes, -1);
  }

  /** Retire toutes les entrées expirées ; renvoie leur nombre. */
  sweep(): number {
    const now = this.now();
    let n = 0;
    for (const [id, e] of this.map) {
      if (e.expires <= now) {
        this.delete(id);
        n++;
      }
    }
    return n;
  }

  stats(): { entries: number; bytes: number; users: number } {
    return { entries: this.map.size, bytes: this.totalBytes, users: this.users.size };
  }

  userStats(userId: string): { bytes: number; count: number } {
    return { ...(this.users.get(userId) ?? { bytes: 0, count: 0 }) };
  }

  private heaviestUser(): string | undefined {
    let best: string | undefined;
    let max = -1;
    for (const [u, s] of this.users) {
      const weight = s.bytes * 1_000 + s.count; // octets d'abord, puis nombre d'entrées
      if (weight > max) {
        max = weight;
        best = u;
      }
    }
    return best;
  }

  private evictOldest(match: (e: Entry) => boolean): boolean {
    for (const [id, e] of this.map) {
      if (match(e)) {
        this.delete(id);
        return true;
      }
    }
    return false;
  }

  private account(userId: string, bytes: number, count: number): void {
    this.totalBytes += bytes;
    const cur = this.users.get(userId) ?? { bytes: 0, count: 0 };
    const next = { bytes: cur.bytes + bytes, count: cur.count + count };
    if (next.count <= 0) this.users.delete(userId);
    else this.users.set(userId, next);
  }
}

const store = new ScreenshotStore();
// Balayage périodique : la mémoire des captures expirées est libérée même sans nouvelle écriture.
const sweeper = setInterval(() => store.sweep(), 60_000);
sweeper.unref?.();

const MIME_RE = /^image\/(jpeg|png|webp)$/;

export function normalizeMime(v: unknown): string {
  return typeof v === "string" && MIME_RE.test(v) ? v : "image/jpeg";
}

/** Retient la dernière capture d'une tâche (déjà validée par screenshotB64Error). */
export function rememberScreenshot(taskId: string, userId: string, image_b64: string, mime: unknown): boolean {
  return store.set(taskId, { userId, image_b64, mime: normalizeMime(mime), at: new Date().toISOString() });
}

/** Capture d'une tâche, uniquement pour son propriétaire (sinon undefined → 404). */
export function getScreenshot(taskId: string, userId: string): StoredScreenshot | undefined {
  const s = store.get(taskId);
  return s && s.userId === userId ? s : undefined;
}

export function forgetScreenshot(taskId: string): void {
  store.delete(taskId);
}

export function screenshotStoreStats(): { entries: number; bytes: number; users: number } {
  return store.stats();
}

/**
 * Retire la capture d'un `data` d'évènement : renvoie les données sans AUCUN `image_b64`
 * (niveau racine : extraite, has_image=true ; niveaux imbriqués : retirée en profondeur,
 * jamais insérée en base ni diffusée par Realtime) et l'image extraite éventuelle.
 */
export function extractEventImage(data: unknown): {
  data: Record<string, unknown>;
  image?: { b64: unknown; mime: string };
} {
  if (!isPlainObject(data)) return { data: {} };
  const { image_b64, ...rest } = data;
  const clean = stripImageB64(rest);
  if (image_b64 !== undefined && image_b64 !== null && image_b64 !== "") {
    return {
      data: { ...clean, has_image: true },
      image: { b64: image_b64, mime: normalizeMime(rest.media_type ?? rest.mime) },
    };
  }
  return { data: clean };
}

/**
 * Captures d'un rapport final de l'agent (result.steps[].data.image_b64), les N
 * DERNIÈRES dans l'ordre d'exécution — ce que l'évaluateur doit « voir » (état final).
 * Une capture invalide (pas du base64, trop volumineuse) est ignorée : jamais retenue en mémoire.
 */
export function extractResultScreenshots(result: unknown, max = 3): string[] {
  const steps = isPlainObject(result) ? result.steps : undefined;
  if (!Array.isArray(steps)) return [];
  const shots: string[] = [];
  for (const s of steps) {
    const img = isPlainObject(s) && isPlainObject(s.data) ? s.data.image_b64 : undefined;
    if (typeof img === "string" && screenshotB64Error(img) === null) shots.push(img);
  }
  return shots.slice(-max);
}
