// Rédaction des secrets (LOT 6) avant toute écriture en base, tout journal et tout prompt :
// motifs de jetons/clefs connus, clés de champs sensibles, et valeurs déclarées
// (SOULBAH_REDACT_VALUES, p. ex. un canari de test). Complète lib/redact.ts (masquage du
// texte saisi « [texte masqué : N car.] », contrat LOT 1 §12), qui reste intact.
import { config } from "../../config.js";
import { MAX_SANITIZE_DEPTH, TOO_DEEP_PLACEHOLDER } from "../../lib/sanitize.js";

export const SECRET_LABEL = "[secret masqué]";

/** Motifs de secrets « reconnaissables » (clés d'API, jetons, clés privées). */
const PATTERNS: { re: RegExp; repl: string }[] = [
  { re: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, repl: SECRET_LABEL },
  { re: /\bsk-(?:ant-)?[A-Za-z0-9_-]{16,}\b/g, repl: SECRET_LABEL }, // OpenAI / Anthropic
  { re: /\bsbk_[0-9a-f]{32,}\b/gi, repl: SECRET_LABEL }, // clé agent SoulBah
  { re: /\bsbap_[A-Za-z0-9_-]+\.[0-9a-f]{64}\b/g, repl: SECRET_LABEL }, // jeton d'approbation
  { re: /\bAKIA[0-9A-Z]{16}\b/g, repl: SECRET_LABEL }, // AWS
  { re: /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g, repl: SECRET_LABEL }, // GitHub
  { re: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/g, repl: SECRET_LABEL }, // Slack
  { re: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g, repl: SECRET_LABEL }, // JWT
  { re: /\b(Bearer)\s+[A-Za-z0-9._~+/=-]{16,}/gi, repl: `$1 ${SECRET_LABEL}` },
  {
    re: /\b(password|passwd|pwd|mot_de_passe|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret)(\s*[=:]\s*)["']?([^\s"'&,;]{6,})["']?/gi,
    repl: `$1$2${SECRET_LABEL}`,
  },
];

/** Clés de champs dont la valeur entière est un secret, quel que soit son contenu. */
const SENSITIVE_KEYS =
  /^(password|passwd|mot_de_passe|secret|token|api_?key|authorization|key_hash|private_key|access_token|refresh_token|x-agent-key|x-ia-token|approval_token|dev_local_token|approval_secret)$/i;

/** Libellés déjà posés par lib/redact.ts : jamais retouchés. */
const ALREADY_MASKED = /^\[(texte|secret) masqué(?: : \d+ car\.)?\]$/;

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Valeurs explicitement interdites dans toute sortie (config + canari), les plus longues d'abord. */
export function forbiddenValues(extra: readonly string[] = []): string[] {
  const values = new Set<string>();
  for (const v of [...config.redactValues, ...extra]) {
    const t = v.trim();
    if (t.length >= 4) values.add(t);
  }
  return [...values].sort((a, b) => b.length - a.length);
}

/** Rédige une chaîne : valeurs interdites puis motifs. */
export function redactText(s: string, extra: readonly string[] = []): string {
  if (!s) return s;
  let out = s;
  for (const v of forbiddenValues(extra)) {
    out = out.replace(new RegExp(escapeRegExp(v), "g"), SECRET_LABEL);
  }
  for (const { re, repl } of PATTERNS) {
    re.lastIndex = 0;
    out = out.replace(re, repl);
  }
  return out;
}

/** True si la valeur contient encore un secret déclaré (test du canari). */
export function containsForbiddenValue(value: unknown, extra: readonly string[] = []): boolean {
  const text = typeof value === "string" ? value : JSON.stringify(value) ?? "";
  return forbiddenValues(extra).some((v) => text.includes(v));
}

/**
 * Copie profonde rédigée : clés sensibles → libellé, chaînes → redactText. Au-delà de
 * MAX_SANITIZE_DEPTH le sous-arbre est remplacé (jamais transmis non inspecté).
 */
export function redactSecrets<T>(value: T, extra: readonly string[] = [], depth = 0): T {
  if (depth > MAX_SANITIZE_DEPTH) return (value !== null && typeof value === "object" ? TOO_DEEP_PLACEHOLDER : value) as T;
  if (typeof value === "string") return (ALREADY_MASKED.test(value) ? value : redactText(value, extra)) as T;
  if (Array.isArray(value)) return value.map((v) => redactSecrets(v, extra, depth + 1)) as unknown as T;
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (SENSITIVE_KEYS.test(k) && v !== null && v !== undefined && v !== "") out[k] = SECRET_LABEL;
      else out[k] = redactSecrets(v, extra, depth + 1);
    }
    return out as T;
  }
  return value;
}

type LogFn = (obj: unknown, msg?: string) => void;
/** Enveloppe un logger : objets et messages passent par redactSecrets avant écriture. */
export function redactingLogger<L extends { info: LogFn; warn: LogFn; error: LogFn }>(base: L): L {
  const wrap =
    (fn: LogFn): LogFn =>
    (obj, msg) =>
      fn.call(base, typeof obj === "string" ? redactText(obj) : redactSecrets(obj), msg === undefined ? undefined : redactText(msg));
  return { ...base, info: wrap(base.info), warn: wrap(base.warn), error: wrap(base.error) } as L;
}
