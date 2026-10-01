// Preuves typées (LOT 9, audit §9.8) : validation de forme alignée sur
// shared/schemas/evidence.schema.json (bibliothèque standard, pas d'ajv). Aucun contenu
// binaire ne passe : image_b64 et longues chaînes base64 sont refusées — un fichier est un
// ARTEFACT (sha256) référencé, jamais embarqué (« 0 base64 en base »).
import { isPlainObject } from "../lib/sanitize.js";

export const EVIDENCE_KINDS = [
  "command_output",
  "device_list",
  "dir_listing",
  "exit_code",
  "file_content",
  "file_path",
  "process",
  "screenshot",
  "self_report",
  "video_probe",
  "video_stats",
  "window_title",
  "http_status",
  "sha256",
  "test_report",
  "ui_state",
] as const;
export type EvidenceKind = (typeof EVIDENCE_KINDS)[number];
export const CONFIDENCES = ["high", "medium", "low", "none"] as const;
export type Confidence = (typeof CONFIDENCES)[number];

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SHA_RE = /^[0-9a-f]{64}$/;
const ALLOWED_KEYS = new Set(["kind", "confidence", "description", "value", "artifact_id", "sha256", "step_index", "at"]);
export const MAX_VALUE_CHARS = 4000;
/** Une chaîne base64 « longue » (≥ 256 caractères, alphabet base64 seul) est un contenu binaire déguisé. */
const BASE64_BLOB = /^[A-Za-z0-9+/=\r\n]{256,}$/;

export interface Evidence {
  kind: EvidenceKind;
  confidence: Confidence;
  description?: string;
  value?: unknown;
  artifact_id?: string;
  sha256?: string;
  step_index?: number;
  at?: string;
}

export type EvidenceCheck = { ok: true; value: Evidence } | { ok: false; error: string };

/** Vrai si une valeur (profonde) contient un blob base64 ou une clé image_b64. */
export function containsBinaryBlob(value: unknown, depth = 0): boolean {
  if (depth > 16) return false;
  if (typeof value === "string") return BASE64_BLOB.test(value) || value.startsWith("data:image/") || value.startsWith("data:video/");
  if (Array.isArray(value)) return value.some((v) => containsBinaryBlob(v, depth + 1));
  if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (/^(image_b64|b64|base64|data_uri)$/i.test(k)) return true;
      if (containsBinaryBlob(v, depth + 1)) return true;
    }
  }
  return false;
}

export function validateEvidence(raw: unknown): EvidenceCheck {
  if (!isPlainObject(raw)) return { ok: false, error: "preuve : objet attendu" };
  const extra = Object.keys(raw).filter((k) => !ALLOWED_KEYS.has(k));
  if (extra.length) return { ok: false, error: `preuve : champ(s) inconnu(s) : ${extra.join(", ").slice(0, 200)}` };
  if (!(EVIDENCE_KINDS as readonly string[]).includes(raw.kind as string)) return { ok: false, error: `preuve : kind inconnu « ${String(raw.kind).slice(0, 40)} »` };
  if (!(CONFIDENCES as readonly string[]).includes(raw.confidence as string)) return { ok: false, error: "preuve : confidence high | medium | low | none attendue" };
  if (raw.description !== undefined && (typeof raw.description !== "string" || raw.description.length > 2000)) return { ok: false, error: "preuve : description (≤ 2000 car.) attendue" };
  if (raw.value !== undefined) {
    const text = typeof raw.value === "string" ? raw.value : JSON.stringify(raw.value) ?? "";
    if (text.length > MAX_VALUE_CHARS) return { ok: false, error: `preuve : value trop longue (${MAX_VALUE_CHARS} car. max) — téléversez un artefact` };
    if (containsBinaryBlob(raw.value)) return { ok: false, error: "preuve : contenu binaire/base64 interdit — téléversez un artefact (PUT /api/v2/artifacts/:sha256)" };
  }
  if (raw.artifact_id !== undefined && (typeof raw.artifact_id !== "string" || !UUID_RE.test(raw.artifact_id))) return { ok: false, error: "preuve : artifact_id (uuid) invalide" };
  if (raw.sha256 !== undefined && (typeof raw.sha256 !== "string" || !SHA_RE.test(raw.sha256))) return { ok: false, error: "preuve : sha256 (64 hex) invalide" };
  if (raw.step_index !== undefined && !(typeof raw.step_index === "number" && Number.isInteger(raw.step_index) && raw.step_index >= 0)) return { ok: false, error: "preuve : step_index entier ≥ 0" };
  if (raw.at !== undefined && (typeof raw.at !== "string" || Number.isNaN(Date.parse(raw.at)))) return { ok: false, error: "preuve : at (date ISO) invalide" };
  // Une capture / vidéo doit référencer un artefact (jamais le contenu).
  if ((raw.kind === "screenshot" || raw.kind === "video_probe" || raw.kind === "video_stats") && !raw.artifact_id && !raw.sha256 && raw.value === undefined) {
    return { ok: false, error: `preuve ${String(raw.kind)} : artifact_id ou sha256 requis` };
  }
  return { ok: true, value: raw as unknown as Evidence };
}

/** Valide une liste de preuves ; première erreur rencontrée. */
export function validateEvidenceList(raw: unknown): { ok: true; value: Evidence[] } | { ok: false; error: string } {
  if (raw === undefined) return { ok: true, value: [] };
  if (!Array.isArray(raw)) return { ok: false, error: "evidence : liste attendue" };
  if (raw.length > 50) return { ok: false, error: "evidence : 50 éléments max" };
  const out: Evidence[] = [];
  for (const [i, e] of raw.entries()) {
    const r = validateEvidence(e);
    if (!r.ok) return { ok: false, error: `evidence[${i}] : ${r.error}` };
    out.push(r.value);
  }
  return { ok: true, value: out };
}

const CONF_RANK: Record<Confidence, number> = { high: 3, medium: 2, low: 1, none: 0 };
/** Meilleure confiance d'une liste (null si vide). */
export function bestConfidence(list: readonly Evidence[]): Confidence | null {
  let best: Confidence | null = null;
  for (const e of list) if (best === null || CONF_RANK[e.confidence] > CONF_RANK[best]) best = e.confidence;
  return best;
}

/** Règle §9.8 : une tâche L2+ exige au moins une preuve de confiance moyenne. */
export function meetsLevelRequirement(level: string, list: readonly Evidence[]): boolean {
  if (level !== "L2" && level !== "L3") return true;
  const best = bestConfidence(list);
  return best !== null && CONF_RANK[best] >= CONF_RANK.medium;
}
