// Approbations HMAC liées au payload (LOT 6, audit §9.1 point 2) : le plan de contrôle émet
// un jeton `sbap_<corps>.<signature>` pour une demande approuvée ; le corps porte l'id de la
// demande, l'empreinte SHA-256 du payload présenté, l'expiration et le niveau. Le runtime
// ne détient pas le secret : il présente le jeton, P1 le vérifie (signature, expiration,
// empreinte du payload RÉELLEMENT exécuté, statut en base). Seul le hash du jeton est stocké.
import { createHmac, createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { config } from "../../config.js";
import { logger } from "../../lib/logger.js";
import type { SecurityLevel } from "../../lib/toolCatalog.js";
import { isSecurityLevel } from "./policy.js";

export const TOKEN_PREFIX = "sbap_";

/**
 * JSON canonique : clés triées récursivement, sans espace — identique à
 * `json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)` côté agent
 * (pour des nombres entiers ; un flottant « 1.0 » diffère : les payloads d'étapes n'en portent pas).
 */
export function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value) ?? "null";
  if (Array.isArray(value)) return `[${value.map((v) => canonicalJson(v)).join(",")}]`;
  const keys = Object.keys(value as Record<string, unknown>).sort();
  return `{${keys
    .filter((k) => (value as Record<string, unknown>)[k] !== undefined)
    .map((k) => `${JSON.stringify(k)}:${canonicalJson((value as Record<string, unknown>)[k])}`)
    .join(",")}}`;
}

/** Empreinte SHA-256 (hex) du JSON canonique d'un payload. */
export function payloadSha256(payload: unknown): string {
  return createHash("sha256").update(canonicalJson(payload), "utf8").digest("hex");
}

/** Hash stocké en base pour un jeton (jamais le jeton). */
export function tokenHash(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

let ephemeralSecret: string | undefined;
/** Secret HMAC : SOULBAH_APPROVAL_SECRET, sinon (dev/test) un secret éphémère par processus. */
export function approvalSecret(): string {
  if (config.approvalSecret) return config.approvalSecret;
  if (!ephemeralSecret) {
    ephemeralSecret = randomBytes(32).toString("hex");
    logger.warn({}, "SOULBAH_APPROVAL_SECRET absent : secret d'approbation ÉPHÉMÈRE (les jetons ne survivent pas au redémarrage)");
  }
  return ephemeralSecret;
}

export interface TokenBody {
  v: 1;
  id: string;
  sha: string;
  /** Expiration (secondes epoch). */
  exp: number;
  lvl: SecurityLevel;
}

function b64url(s: string): string {
  return Buffer.from(s, "utf8").toString("base64url");
}
function sign(body: string, secret: string): string {
  return createHmac("sha256", secret).update(body, "utf8").digest("hex");
}

export function createApprovalToken(input: { id: string; payloadSha256: string; expiresAt: Date; level: SecurityLevel }, secret = approvalSecret()): string {
  const body: TokenBody = { v: 1, id: input.id, sha: input.payloadSha256, exp: Math.floor(input.expiresAt.getTime() / 1000), lvl: input.level };
  const encoded = b64url(canonicalJson(body));
  return `${TOKEN_PREFIX}${encoded}.${sign(encoded, secret)}`;
}

export type VerifyReason = "malformed" | "signature" | "expired" | "payload_mismatch";
export type TokenVerification = { ok: true; body: TokenBody } | { ok: false; reason: VerifyReason };

/** Vérifie signature, expiration et (si fournie) l'empreinte du payload exécuté. */
export function verifyApprovalToken(
  token: unknown,
  opts: { payloadSha256?: string; now?: Date; secret?: string } = {},
): TokenVerification {
  if (typeof token !== "string" || !token.startsWith(TOKEN_PREFIX)) return { ok: false, reason: "malformed" };
  const rest = token.slice(TOKEN_PREFIX.length);
  const dot = rest.lastIndexOf(".");
  if (dot <= 0) return { ok: false, reason: "malformed" };
  const encoded = rest.slice(0, dot);
  const sig = rest.slice(dot + 1);
  if (!/^[0-9a-f]{64}$/.test(sig)) return { ok: false, reason: "malformed" };
  const expected = sign(encoded, opts.secret ?? approvalSecret());
  if (!timingSafeEqual(Buffer.from(sig, "hex"), Buffer.from(expected, "hex"))) return { ok: false, reason: "signature" };
  let body: TokenBody;
  try {
    body = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")) as TokenBody;
  } catch {
    return { ok: false, reason: "malformed" };
  }
  if (
    !body ||
    body.v !== 1 ||
    typeof body.id !== "string" ||
    !/^[0-9a-f]{64}$/.test(String(body.sha)) ||
    typeof body.exp !== "number" ||
    !isSecurityLevel(body.lvl)
  ) {
    return { ok: false, reason: "malformed" };
  }
  const now = opts.now ?? new Date();
  if (body.exp * 1000 <= now.getTime()) return { ok: false, reason: "expired" };
  if (opts.payloadSha256 !== undefined && opts.payloadSha256 !== body.sha) return { ok: false, reason: "payload_mismatch" };
  return { ok: true, body };
}
