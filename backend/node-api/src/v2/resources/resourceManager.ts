// Resource Manager V3 (LOT 6) — côté plan de contrôle.
//
// Les runtimes (PC) envoient leur état mémoire avec lease et keepalive (agent/runtime/supervisor.py,
// politique commune shared/config/soulbah_resources.py) : il est rangé dans
// soulbah.runtimes.capabilities.live. Le PC limite lui-même ses nouveaux workers ; ici, garde-fou :
// aucun nouveau bail pour un runtime dont la mémoire est critique (état reçu depuis moins de
// LIVE_FRESH_MS). La vue d'ensemble (GET /api/v2/resources) réunit agents logiques, files, PC et
// files d'inférence du modèle local (python-ia /v2/resources).
import { pool } from "../../db.js";
import { isPlainObject } from "../../lib/sanitize.js";

export const LIVE_FRESH_MS = 90_000;
export const PRESSURES = ["ok", "high", "critical", "unknown"] as const;
export type Pressure = (typeof PRESSURES)[number];

export interface LiveResources {
  free_mb: number | null;
  total_mb: number | null;
  load_percent: number | null;
  pressure: Pressure;
  held: number | null;
  max_slots: number | null;
  allowed_new: number | null;
  throttled: boolean;
  at: string;
}

function num(v: unknown, max = 10_000_000): number | null {
  return typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= max ? Math.round(v) : null;
}

/** Ne garde que des nombres bornés et un niveau de pression connu (jamais de texte libre). */
export function sanitizeLiveResources(raw: unknown, now: Date = new Date()): LiveResources | null {
  if (!isPlainObject(raw)) return null;
  const pressure = PRESSURES.includes(raw.pressure as Pressure) ? (raw.pressure as Pressure) : "unknown";
  return {
    free_mb: num(raw.free_mb),
    total_mb: num(raw.total_mb),
    load_percent: num(raw.load_percent, 100),
    pressure,
    held: num(raw.held, 64),
    max_slots: num(raw.max_slots, 64),
    allowed_new: num(raw.allowed_new, 64),
    throttled: raw.throttled === true,
    at: now.toISOString(),
  };
}

export async function recordRuntimeResources(runtimeId: string, live: LiveResources): Promise<void> {
  await pool.query(
    "UPDATE soulbah.runtimes SET capabilities = capabilities || jsonb_build_object('live', $2::jsonb) WHERE id = $1",
    [runtimeId, JSON.stringify(live)],
  );
}

/** Plafond de baux imposé par la mémoire : 0 si l'état est critique et récent, sinon null (aucun). */
export function memoryCap(live: unknown, now: Date = new Date()): number | null {
  if (!isPlainObject(live) || live.pressure !== "critical" || typeof live.at !== "string") return null;
  const at = Date.parse(live.at);
  if (!Number.isFinite(at) || now.getTime() - at > LIVE_FRESH_MS) return null;
  return 0;
}

export interface AgentsOverview {
  running: number;
  waiting: number;
  validating: number;
  ready: number;
  by_role: Record<string, number>;
}

/** Agents logiques de l'utilisateur : tâches tenues (RUNNING, WAITING, VALIDATING) et file READY. */
export async function agentsOverview(userId: string): Promise<AgentsOverview> {
  const { rows } = await pool.query(
    `SELECT t.status, t.role, count(*)::int AS n
       FROM soulbah.tasks t JOIN soulbah.sessions s ON s.id = t.session_id
      WHERE t.user_id = $1 AND s.status = 'RUNNING' AND t.status IN ('READY', 'RUNNING', 'WAITING', 'VALIDATING')
      GROUP BY t.status, t.role`,
    [userId],
  );
  const out: AgentsOverview = { running: 0, waiting: 0, validating: 0, ready: 0, by_role: {} };
  for (const r of rows as { status: string; role: string; n: number }[]) {
    if (r.status === "READY") {
      out.ready += r.n;
      continue;
    }
    if (r.status === "RUNNING") out.running += r.n;
    if (r.status === "WAITING") out.waiting += r.n;
    if (r.status === "VALIDATING") out.validating += r.n;
    out.by_role[r.role] = (out.by_role[r.role] ?? 0) + r.n;
  }
  return out;
}

export interface RuntimeOverview {
  id: string;
  hostname: string | null;
  status: string;
  max_slots: number;
  last_seen_at: string | null;
  live: LiveResources | null;
}

export async function runtimesOverview(userId: string): Promise<RuntimeOverview[]> {
  const { rows } = await pool.query(
    `SELECT id, hostname, status, max_slots, last_seen_at, capabilities->'live' AS live
       FROM soulbah.runtimes WHERE user_id = $1 ORDER BY last_seen_at DESC NULLS LAST LIMIT 20`,
    [userId],
  );
  return (rows as RuntimeOverview[]).map((r) => ({ ...r, live: isPlainObject(r.live) ? (r.live as unknown as LiveResources) : null }));
}
