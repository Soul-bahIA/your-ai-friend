// Boîte de réception des approbations (LOT 6 — Sécurité et audit).
// Contrat node-api V2 : /api/v2/approvals, /api/v2/audit, /api/v2/audit/verify (JWT via apiFetch).
// - S7  : l'utilisateur voit EXACTEMENT ce qui sera exécuté (payload complet, jamais masqué ici).
// - S22 : l'UI voit qu'une approbation est en attente (liste + compteur), au lieu de la console seule.
// Les fonctions pures sont testées dans approvals.test.ts.
import { ApiError, apiFetch } from "@/lib/api";

export type ApprovalStatus = "pending" | "approved" | "denied" | "expired" | "revoked";
export type ApprovalFilter = ApprovalStatus | "all";
export type SecurityLevel = "L0" | "L1" | "L2" | "L3";
export type ApprovalKind = "request" | "grant";

export interface Approval {
  id: string;
  status: ApprovalStatus;
  security_level: SecurityLevel;
  kind: ApprovalKind;
  tool: string | null;
  summary: string | null;
  task_id: string | null;
  attempt: number | null;
  step_index: number | null;
  payload_presented: Record<string, unknown> | null;
  payload_sha256: string | null;
  reason: string | null;
  created_at: string;
  expires_at: string | null;
  decided_at: string | null;
}

export interface AuditVerifyResult {
  ok: boolean;
  checked: number;
  broken_at: number | null;
}

export interface AuditEntry {
  seq: number;
  action: string;
  actor: string;
  entity: string | null;
  entity_id: string | null;
  data: Record<string, unknown>;
  created_at: string;
}

/** Même palette que les tâches de l'agent (agentTasks.ts). */
export type Tone = "success" | "warning" | "destructive" | "primary" | "muted";

/** Classes Tailwind d'un badge selon la tonalité. */
export const TONE_CLASSES: Record<Tone, string> = {
  success: "border-success/40 bg-success/10 text-success",
  warning: "border-warning/40 bg-warning/10 text-warning",
  destructive: "border-destructive/40 bg-destructive/10 text-destructive",
  primary: "border-primary/40 bg-primary/10 text-primary",
  muted: "border-border bg-secondary text-muted-foreground",
};

/** Mot à saisir pour confirmer une action L3 (irréversible). */
export const L3_CONFIRM_WORD = "AUTORISER";

/** Message affiché lorsque le serveur ne connaît pas les routes V2 (404). */
export const APPROVALS_UNAVAILABLE_MESSAGE =
  "Approbations distantes indisponibles sur ce serveur (API V2 absente). Les confirmations restent demandées à la console de l'agent.";

/** Longueur au-delà de laquelle une valeur texte du payload est tronquée à l'affichage. */
export const PAYLOAD_VALUE_MAX = 2000;

// ───────────────────────── API ─────────────────────────

const q = (v: string | number) => encodeURIComponent(String(v));

/** Liste des approbations (filtre de statut, limite 50 par défaut). */
export async function listApprovals(
  status: ApprovalFilter = "pending",
  signal?: AbortSignal,
  limit = 50,
): Promise<Approval[]> {
  const data = await apiFetch<{ approvals?: Approval[] }>(
    `/api/v2/approvals?status=${q(status)}&limit=${q(limit)}`,
    { signal },
  );
  return Array.isArray(data?.approvals) ? data.approvals : [];
}

/**
 * Approuve une demande. `payloadSha256` est OBLIGATOIRE : c'est l'empreinte de ce qui a été
 * AFFICHÉ, renvoyée telle quelle ; le serveur répond 409 si elle diffère ou si la demande n'est
 * plus en attente.
 */
export async function approveApproval(
  id: string,
  payloadSha256: string,
): Promise<{ id: string; status: "approved"; expires_at: string | null }> {
  if (!payloadSha256) throw new ApiError("Empreinte du contenu absente : approbation impossible.", 0);
  return apiFetch(`/api/v2/approvals/${q(id)}/approve`, {
    method: "POST",
    json: { payload_sha256: payloadSha256 },
  });
}

/** Refuse une demande, avec un motif optionnel. */
export async function denyApproval(id: string, reason?: string): Promise<{ id: string; status: "denied" }> {
  const trimmed = reason?.trim();
  return apiFetch(`/api/v2/approvals/${q(id)}/deny`, {
    method: "POST",
    json: trimmed ? { reason: trimmed } : {},
  });
}

/** Vérifie l'intégrité de la chaîne du journal d'audit. */
export async function verifyAuditChain(): Promise<AuditVerifyResult> {
  const data = await apiFetch<Partial<AuditVerifyResult>>("/api/v2/audit/verify");
  return {
    ok: data?.ok === true,
    checked: typeof data?.checked === "number" ? data.checked : 0,
    broken_at: typeof data?.broken_at === "number" ? data.broken_at : null,
  };
}

/** Dernières entrées du journal d'audit (les plus récentes en premier côté serveur). */
export async function listAudit(limit = 100): Promise<AuditEntry[]> {
  const data = await apiFetch<{ entries?: AuditEntry[] }>(`/api/v2/audit?limit=${q(limit)}`);
  return Array.isArray(data?.entries) ? data.entries : [];
}

/** Vrai si l'erreur signifie « routes V2 absentes » (serveur V1) : on arrête alors le polling. */
export const isApprovalsUnavailable = (err: unknown): boolean =>
  err instanceof ApiError && err.status === 404;

/** Vrai si le serveur a refusé la décision parce que la demande a changé ou n'est plus en attente. */
export const isStaleApproval = (err: unknown): boolean =>
  err instanceof ApiError && err.status === 409;

// ───────────────────────── Fonctions pures ─────────────────────────

const LEVEL_LABELS: Record<SecurityLevel, string> = {
  L0: "lecture",
  L1: "réversible",
  L2: "effet réel",
  L3: "irréversible",
};

const LEVEL_TONES: Record<SecurityLevel, Tone> = {
  L0: "muted",
  L1: "primary",
  L2: "warning",
  L3: "destructive",
};

const LEVEL_RANK: Record<SecurityLevel, number> = { L0: 0, L1: 1, L2: 2, L3: 3 };

/** Libellé français d'un niveau (inconnu → le niveau brut). */
export const levelLabel = (level: string): string => LEVEL_LABELS[level as SecurityLevel] ?? level;

/** Tonalité (couleur) d'un niveau ; inconnu → muted. */
export const levelTone = (level: string): Tone => LEVEL_TONES[level as SecurityLevel] ?? "muted";

/** Rang numérique d'un niveau pour le tri ; inconnu → -1. */
export const levelRank = (level: string): number => LEVEL_RANK[level as SecurityLevel] ?? -1;

/** Un niveau L3 exige une confirmation supplémentaire (saisie du mot AUTORISER). */
export const requiresTypedConfirmation = (level: string): boolean => level === "L3";

const STATUS_LABELS: Record<ApprovalStatus, string> = {
  pending: "En attente",
  approved: "Approuvée",
  denied: "Refusée",
  expired: "Expirée",
  revoked: "Révoquée",
};

/** Libellé français d'un statut (inconnu → statut brut). */
export const statusLabel = (status: string): string => STATUS_LABELS[status as ApprovalStatus] ?? status;

/** Tonalité d'un statut. */
export const statusTone = (status: string): Tone => {
  switch (status) {
    case "approved":
      return "success";
    case "denied":
    case "revoked":
      return "destructive";
    case "pending":
      return "warning";
    default:
      return "muted";
  }
};

/** Libellé d'un type de demande. */
export const kindLabel = (kind: string): string =>
  kind === "grant" ? "autorisation de session" : kind === "request" ? "action unique" : kind;

const parseTime = (iso: string | null): number | null => {
  if (!iso) return null;
  const t = Date.parse(iso);
  return Number.isNaN(t) ? null : t;
};

/** Vrai si la demande est expirée (statut expired, ou expires_at dépassé). */
export function isExpired(approval: Pick<Approval, "status" | "expires_at">, now: number = Date.now()): boolean {
  if (approval.status === "expired") return true;
  const t = parseTime(approval.expires_at);
  return t !== null && t <= now;
}

/** Secondes restantes avant expiration (0 si dépassée) ; null si pas d'échéance. */
export function remainingSeconds(
  approval: Pick<Approval, "expires_at">,
  now: number = Date.now(),
): number | null {
  const t = parseTime(approval.expires_at);
  if (t === null) return null;
  return Math.max(0, Math.ceil((t - now) / 1000));
}

/** Texte du compte à rebours : « expirée », « 45 s », « 2 min 05 s », « 1 h 02 min », ou « sans échéance ». */
export function formatRemaining(seconds: number | null): string {
  if (seconds === null) return "sans échéance";
  if (seconds <= 0) return "expirée";
  if (seconds < 60) return `${seconds} s`;
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (h > 0) return `${h} h ${String(m).padStart(2, "0")} min`;
  return `${m} min ${String(s).padStart(2, "0")} s`;
}

/** Clés du payload susceptibles de désigner la cible de l'action, par ordre de préférence. */
const TARGET_KEYS = ["target", "path", "file", "url", "command", "cmd", "app", "selector", "query", "text"];

const TARGET_MAX = 120;

/** Cible lisible extraite du payload (chaîne), ou null. */
export function targetOf(payload: Record<string, unknown> | null): string | null {
  if (!payload) return null;
  for (const key of TARGET_KEYS) {
    const v = payload[key];
    if (typeof v === "string" && v.trim()) {
      const s = v.trim();
      return s.length > TARGET_MAX ? `${s.slice(0, TARGET_MAX)}…` : s;
    }
  }
  return null;
}

/** Texte court : outil, résumé et cible. Ex. « write_file — Écrire le rapport → C:\…\rapport.md ». */
export function summarizeApproval(
  approval: Pick<Approval, "tool" | "summary" | "payload_presented">,
): string {
  const tool = approval.tool?.trim() || "action inconnue";
  const summary = approval.summary?.trim();
  const target = targetOf(approval.payload_presented);
  let text = tool;
  if (summary) text += ` — ${summary}`;
  if (target && (!summary || !summary.includes(target))) text += ` → ${target}`;
  return text;
}

/** Trie récursivement les clés d'un objet ; tronque les chaînes trop longues (longueur indiquée). */
function normalizeForDisplay(value: unknown, maxLength: number): unknown {
  if (typeof value === "string") {
    return value.length > maxLength ? `${value.slice(0, maxLength)}… (${value.length} car.)` : value;
  }
  if (Array.isArray(value)) return value.map((v) => normalizeForDisplay(v, maxLength));
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      out[key] = normalizeForDisplay((value as Record<string, unknown>)[key], maxLength);
    }
    return out;
  }
  if (typeof value === "bigint") return value.toString();
  if (value === undefined) return null;
  return value;
}

/**
 * Payload en JSON indenté, clés triées. Les valeurs texte au-delà de `maxLength` caractères sont
 * tronquées avec « … (N car.) » (N = longueur réelle) ; passer Infinity pour tout afficher.
 * AUCUN masquage côté client : l'utilisateur doit voir exactement ce qui sera exécuté (S7).
 */
export function formatPayload(
  payload: Record<string, unknown> | null | undefined,
  maxLength: number = PAYLOAD_VALUE_MAX,
): string {
  if (payload === null || payload === undefined) return "(aucun contenu présenté)";
  if (typeof payload !== "object" || Object.keys(payload).length === 0) return "{}";
  return JSON.stringify(normalizeForDisplay(payload, maxLength), null, 2);
}

/** Vrai si au moins une valeur texte du payload dépasse `maxLength` (donc serait tronquée). */
export function payloadHasLongValues(
  payload: Record<string, unknown> | null | undefined,
  maxLength: number = PAYLOAD_VALUE_MAX,
): boolean {
  const walk = (v: unknown): boolean => {
    if (typeof v === "string") return v.length > maxLength;
    if (Array.isArray(v)) return v.some(walk);
    if (v && typeof v === "object") return Object.values(v as Record<string, unknown>).some(walk);
    return false;
  };
  return !!payload && walk(payload);
}

/** Empreinte abrégée : 8 premiers + 4 derniers caractères ; « — » si absente. */
export function shortSha(sha: string | null | undefined): string {
  if (!sha) return "—";
  if (sha.length <= 16) return sha;
  return `${sha.slice(0, 8)}…${sha.slice(-4)}`;
}

/** Tri : en attente d'abord, puis niveau décroissant (L3 avant L2), puis plus ancien d'abord. */
export function sortApprovals<T extends Pick<Approval, "status" | "security_level" | "created_at">>(
  approvals: readonly T[],
): T[] {
  return [...approvals].sort((a, b) => {
    const pa = a.status === "pending" ? 0 : 1;
    const pb = b.status === "pending" ? 0 : 1;
    if (pa !== pb) return pa - pb;
    const ra = levelRank(a.security_level);
    const rb = levelRank(b.security_level);
    if (ra !== rb) return rb - ra;
    const ta = parseTime(a.created_at) ?? 0;
    const tb = parseTime(b.created_at) ?? 0;
    return ta - tb;
  });
}

/** Ne garde que les demandes réellement actionnables (en attente et non expirées). */
export const pendingActionable = (approvals: readonly Approval[], now: number = Date.now()): Approval[] =>
  sortApprovals(approvals.filter((a) => a.status === "pending" && !isExpired(a, now)));

/** Historique : tout ce qui n'est plus en attente (une demande dépassée est présentée comme expirée). */
export function historyOf(approvals: readonly Approval[], now: number = Date.now()): Approval[] {
  return sortApprovals(
    approvals
      .filter((a) => a.status !== "pending" || isExpired(a, now))
      .map((a) => (a.status === "pending" ? { ...a, status: "expired" as const } : a)),
  );
}

/** Texte du résultat de vérification de la chaîne d'audit. */
export function auditVerifyText(result: AuditVerifyResult): string {
  if (result.ok) {
    return result.checked === 0
      ? "Chaîne intègre (journal vide)."
      : `Chaîne intègre : ${result.checked} entrée${result.checked > 1 ? "s" : ""} vérifiée${result.checked > 1 ? "s" : ""}.`;
  }
  const where = result.broken_at !== null ? ` à la ligne ${result.broken_at}` : "";
  return `Chaîne ROMPUE${where} (${result.checked} entrée${result.checked > 1 ? "s" : ""} vérifiée${result.checked > 1 ? "s" : ""}).`;
}

/** Résumé d'une entrée d'audit : « action · entité#id » (sans id → entité seule). */
export function auditEntryText(entry: Pick<AuditEntry, "action" | "entity" | "entity_id">): string {
  const target = entry.entity
    ? entry.entity_id
      ? `${entry.entity}#${entry.entity_id.slice(0, 8)}`
      : entry.entity
    : null;
  return target ? `${entry.action} · ${target}` : entry.action;
}
