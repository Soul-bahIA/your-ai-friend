// Politique de sécurité L0–L3 du plan de contrôle (LOT 6, audit §9.10), dérivée du
// catalogue d'outils (LOT 2) : niveau, confirmation obligatoire, contrôle d'entrée. La
// décision est PURE (testable pour chaque outil du catalogue) ; les grants et plafonds
// viennent de soulbah.permissions / user_settings / sessions.
//
//   L0  lecture sans effet                      → allow
//   L1  réversible, confiné au workspace        → allow si la session est approuvée, sinon session_grant
//   L2  effet réel                              → allow si un grant de session couvre l'outil et que le
//                                                 catalogue n'exige pas de confirmation ; sinon approve_each
//   L3  irréversible                            → approve_each, payload complet, jamais en lot
//   DENY chemins interdits (deny-list), outil inconnu, niveau au-dessus du plafond
import { PATH_KEYS, PATH_LIST_KEYS, TOOL_BY_TYPE } from "../../lib/agentSteps.js";
import type { SecurityLevel } from "../../lib/toolCatalog.js";

export type Decision = "allow" | "session_grant" | "approve_each" | "deny";

export interface Grant {
  level: SecurityLevel;
  /** Outils couverts ("*" = tous) ; vide = aucun. */
  tools?: readonly string[];
  /** Ressources couvertes (clés normalisées §9.7, "*" = toutes). */
  resources?: readonly string[];
  expiresAt?: Date | string | null;
}

export interface PolicyInput {
  tool: string;
  step?: Record<string, unknown>;
  /** Plafond utilisateur (user_settings.max_security_level ; défaut L2). */
  userMaxLevel?: SecurityLevel;
  /** Plafond de la mission (sessions.max_security_level). */
  sessionMaxLevel?: SecurityLevel | null;
  /** La session a reçu l'approbation initiale (couvre L1). */
  sessionApproved?: boolean;
  grants?: readonly Grant[];
  now?: Date;
}

export interface PolicyResult {
  decision: Decision;
  level: SecurityLevel | "DENY";
  reason: string;
  requiresDesktopInput: boolean;
  /** L3 : la demande d'approbation doit porter le payload complet. */
  requiresPayload: boolean;
}

const LEVELS: readonly SecurityLevel[] = ["L0", "L1", "L2", "L3"];
export function levelRank(level: SecurityLevel): number {
  return LEVELS.indexOf(level);
}
export function isSecurityLevel(v: unknown): v is SecurityLevel {
  return typeof v === "string" && (LEVELS as readonly string[]).includes(v);
}
export function minLevel(a: SecurityLevel, b: SecurityLevel | null | undefined): SecurityLevel {
  if (!b) return a;
  return levelRank(a) <= levelRank(b) ? a : b;
}

// --- Deny-list par NOM (miroir de agent/skills/safety.py : denied_name) -------------------
const KEY_PATTERNS = [/^id_(rsa|dsa|ecdsa|ed25519)(\..*)?$/i, /\.(pem|key|ppk|p12|pfx)$/i];
const SECRET_DIRS = new Set([".ssh", ".gnupg"]);

function components(path: string): string[] {
  return path
    .replace(/^\\\\\?\\(UNC\\)?/i, "")
    .split(/[\\/]+/)
    .map((c) => c.replace(/::\$[A-Za-z_]+$/, "").replace(/[. ]+$/, "").toLowerCase())
    .filter(Boolean);
}

/** Raison du refus permanent d'un chemin (sans accès disque), ou null. */
export function denyPathReason(path: unknown): string | null {
  if (typeof path !== "string" || !path.trim() || path.includes("\0")) return "chemin invalide";
  const parts = components(path);
  if (parts.length === 0) return null;
  if (parts.includes(".git")) return "dossier .git";
  if (parts.some((p) => SECRET_DIRS.has(p))) return "dossier de clés (.ssh/.gnupg)";
  const last = parts[parts.length - 1];
  if (last === ".env" || last.endsWith(".env") || last.startsWith(".env.")) return "fichier .env (secrets)";
  if (KEY_PATTERNS.some((re) => re.test(last))) return "clé privée";
  return null;
}

/** Premier chemin interdit d'une étape (champs is_path du catalogue), ou null. */
export function stepPathDenial(step: Record<string, unknown> | undefined): string | null {
  if (!step) return null;
  for (const key of PATH_KEYS) {
    const v = step[key];
    if (typeof v === "string") {
      const r = denyPathReason(v);
      if (r) return `${key} : ${r}`;
    }
  }
  for (const key of PATH_LIST_KEYS) {
    const list = step[key];
    if (Array.isArray(list)) {
      for (const v of list) {
        const r = denyPathReason(v);
        if (r) return `${key} : ${r}`;
      }
    }
  }
  return null;
}

function grantCovers(grants: readonly Grant[] | undefined, tool: string, level: SecurityLevel, now: Date): boolean {
  if (!grants) return false;
  return grants.some((g) => {
    if (levelRank(g.level) < levelRank(level)) return false;
    if (g.expiresAt && new Date(g.expiresAt).getTime() <= now.getTime()) return false;
    const tools = g.tools ?? [];
    return tools.includes("*") || tools.includes(tool);
  });
}

/** Décision de politique pour une étape (pure). */
export function decide(input: PolicyInput): PolicyResult {
  const now = input.now ?? new Date();
  const manifest = TOOL_BY_TYPE.get(input.tool);
  if (!manifest) {
    return { decision: "deny", level: "DENY", reason: `outil inconnu du catalogue : ${input.tool.slice(0, 60)}`, requiresDesktopInput: false, requiresPayload: false };
  }
  const requiresDesktopInput = manifest.requires_desktop_input;
  const denial = stepPathDenial(input.step);
  if (denial) {
    return { decision: "deny", level: "DENY", reason: `chemin interdit — ${denial}`, requiresDesktopInput, requiresPayload: false };
  }
  const level = manifest.security_level;
  const cap = minLevel(input.userMaxLevel ?? "L2", input.sessionMaxLevel);
  if (levelRank(level) > levelRank(cap)) {
    return {
      decision: "deny",
      level,
      reason: `niveau ${level} au-dessus du plafond ${cap} (réglage utilisateur / mission)`,
      requiresDesktopInput,
      requiresPayload: level === "L3",
    };
  }
  if (level === "L0") {
    return { decision: "allow", level, reason: "lecture sans effet (L0)", requiresDesktopInput, requiresPayload: false };
  }
  if (level === "L1") {
    return input.sessionApproved
      ? { decision: "allow", level, reason: "réversible et confiné, session approuvée (L1)", requiresDesktopInput, requiresPayload: false }
      : { decision: "session_grant", level, reason: "réversible et confiné : approbation de la session requise (L1)", requiresDesktopInput, requiresPayload: false };
  }
  if (level === "L2") {
    if (manifest.requires_confirmation) {
      return {
        decision: "approve_each",
        level,
        reason: "effet réel, confirmation exigée par le catalogue (L2)",
        requiresDesktopInput,
        requiresPayload: false,
      };
    }
    return grantCovers(input.grants, input.tool, "L2", now)
      ? { decision: "allow", level, reason: "effet réel couvert par un grant de session (L2)", requiresDesktopInput, requiresPayload: false }
      : { decision: "approve_each", level, reason: "effet réel sans grant : approbation par action (L2)", requiresDesktopInput, requiresPayload: false };
  }
  return { decision: "approve_each", level, reason: "irréversible : approbation par action, payload complet, jamais en lot (L3)", requiresDesktopInput, requiresPayload: true };
}
