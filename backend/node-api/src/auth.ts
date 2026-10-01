import { createHash } from "node:crypto";
import type { FastifyRequest, FastifyReply } from "fastify";
import { config } from "./config.js";
import { resolveAgentKey, hashKey } from "./services/agentKeys.js";
import { TtlCache } from "./lib/ttlCache.js";
import { logger } from "./lib/logger.js";

export interface AuthUser {
  id: string;
  email?: string;
}

declare module "fastify" {
  interface FastifyRequest {
    user?: AuthUser;
    agentUserId?: string;
    agentKeyId?: string;
  }
}

const SUPABASE_AUTH_TIMEOUT_MS = 10_000;
// Un JWT révoqué (déconnexion) reste accepté au plus ce délai sur une AUTRE instance ;
// sur celle qui reçoit POST /api/auth/logout, il est oublié immédiatement (S26).
export const TOKEN_CACHE_TTL_MS = 15_000;

// Cache des JWT déjà vérifiés (clé = SHA-256 du jeton, jamais le jeton en clair).
const tokenCache = new TtlCache<AuthUser>(5_000, TOKEN_CACHE_TTL_MS);

// Jetons déconnectés (S26) : refusés par CETTE instance sans consulter Supabase ni les remettre
// en cache, jusqu'à leur expiration (exp du JWT, bornée à REVOKED_MAX_TTL_MS, au moins
// TOKEN_CACHE_TTL_MS). Ferme la fenêtre entre POST /api/auth/logout et supabase.auth.signOut()
// où une requête (poll du cockpit, rejeu) re-vérifiait le jeton, encore valide chez Supabase,
// et le remettait en cache 15 s.
export const REVOKED_MAX_TTL_MS = 60 * 60 * 1000;
const revokedTokens = new TtlCache<true>(10_000, TOKEN_CACHE_TTL_MS);

export function tokenHash(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

/** Bearer token de l'en-tête Authorization ("" si absent). */
export function bearerToken(request: FastifyRequest): string {
  const header = request.headers["authorization"];
  return typeof header === "string" ? header.replace(/^Bearer\s+/i, "").trim() : "";
}

/** Utilisateur déjà vérifié pour ce jeton (sans appel réseau) — utilisé par le rate-limit. */
export function cachedUserForToken(token: string): AuthUser | undefined {
  return token ? tokenCache.get(tokenHash(token)) : undefined;
}

/**
 * Déconnexion : oublie le jeton du cache ET le marque révoqué sur cette instance — tout usage
 * ultérieur est refusé (401) sans appel à Supabase, même avant supabase.auth.signOut().
 */
export function forgetToken(token: string): void {
  if (!token) return;
  const key = tokenHash(token);
  tokenCache.delete(key);
  const exp = jwtExpiry(token);
  const untilExp = exp ? exp * 1000 - Date.now() : 0;
  revokedTokens.set(key, true, Math.min(REVOKED_MAX_TTL_MS, Math.max(TOKEN_CACHE_TTL_MS, untilExp)));
}

/** Jeton déconnecté sur cette instance (S26). */
export function isTokenRevoked(token: string): boolean {
  return !!token && revokedTokens.get(tokenHash(token)) === true;
}

/** exp (secondes epoch) lu dans la charge utile du JWT, sans vérification (sert à borner le cache). */
function jwtExpiry(token: string): number | undefined {
  try {
    const payload = JSON.parse(Buffer.from(token.split(".")[1] ?? "", "base64url").toString("utf8"));
    return typeof payload.exp === "number" ? payload.exp : undefined;
  } catch {
    return undefined;
  }
}

export type VerifyResult = { ok: true; user: AuthUser } | { ok: false; reason: "invalid" | "unavailable" };

/**
 * Vérifie un JWT Supabase via /auth/v1/user (équivalent de `supabase.auth.getUser`).
 * Distingue « jeton invalide » (401) de « Supabase injoignable » (503) pour que le
 * frontend ne déconnecte pas l'utilisateur sur une panne réseau.
 */
export async function verifySupabaseToken(token: string): Promise<VerifyResult> {
  const key = tokenHash(token);
  // Déconnecté : refusé avant toute consultation du cache ou de Supabase (S26).
  if (revokedTokens.get(key)) return { ok: false, reason: "invalid" };
  if (!config.supabaseUrl || !config.supabaseAnonKey) return { ok: false, reason: "unavailable" };
  const cached = tokenCache.get(key);
  if (cached) return { ok: true, user: cached };

  let res: Response;
  try {
    res = await fetch(`${config.supabaseUrl}/auth/v1/user`, {
      headers: { apikey: config.supabaseAnonKey, Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(SUPABASE_AUTH_TIMEOUT_MS),
    });
  } catch (e) {
    logger.warn({ err: (e as Error).message }, "vérification Supabase injoignable");
    return { ok: false, reason: "unavailable" };
  }
  if (res.status >= 500) return { ok: false, reason: "unavailable" };
  if (!res.ok) return { ok: false, reason: "invalid" };
  const user = (await res.json().catch(() => null)) as { id?: string; email?: string } | null;
  if (!user?.id) return { ok: false, reason: "invalid" };

  const authUser = { id: user.id, email: user.email };
  // Déconnexion survenue PENDANT la vérification : ni acceptée ni remise en cache.
  if (revokedTokens.get(key)) return { ok: false, reason: "invalid" };
  const exp = jwtExpiry(token);
  const ttl = exp ? Math.min(TOKEN_CACHE_TTL_MS, exp * 1000 - Date.now()) : TOKEN_CACHE_TTL_MS;
  tokenCache.set(key, authUser, ttl);
  return { ok: true, user: authUser };
}

/** preHandler Fastify : exige un utilisateur authentifié (JWT Supabase). */
export async function requireUser(request: FastifyRequest, reply: FastifyReply): Promise<void> {
  const token = bearerToken(request);
  if (!token) {
    await reply.status(401).send({ error: "Non authentifié" });
    return;
  }
  const result = await verifySupabaseToken(token);
  if (!result.ok) {
    if (result.reason === "unavailable") {
      await reply.status(503).send({ error: "Service d'authentification indisponible, réessayez" });
    } else {
      await reply.status(401).send({ error: "Non autorisé" });
    }
    return;
  }
  request.user = result.user;
}

// Clés agent déjà résolues (clé = hash) — évite une requête DB par heartbeat.
// Une clé révoquée reste donc valide au plus AGENT_KEY_CACHE_TTL_MS.
const AGENT_KEY_CACHE_TTL_MS = 30_000;
const agentKeyCache = new TtlCache<{ userId: string; keyId: string }>(1_000, AGENT_KEY_CACHE_TTL_MS);

/** Propriétaire déjà vérifié d'une clé agent (sans appel DB) — utilisé par le rate-limit. */
export function cachedAgentForKey(rawKey: string): { userId: string; keyId: string } | undefined {
  return rawKey ? agentKeyCache.get(hashKey(rawKey)) : undefined;
}

const agentKeyIndex = new Map<string, string>(); // keyId → hash (pour la révocation)

/** Oublie une clé du cache (après révocation) : effet immédiat sur cette instance. */
export function forgetAgentKey(keyId: string): void {
  const h = agentKeyIndex.get(keyId);
  if (h) agentKeyCache.delete(h);
  agentKeyIndex.delete(keyId);
}

/**
 * preHandler pour le worker local : valide l'en-tête x-agent-key contre le hash
 * stocké en base et déduit le user_id propriétaire (`request.agentUserId`).
 */
export async function requireAgentKey(request: FastifyRequest, reply: FastifyReply): Promise<void> {
  const header = request.headers["x-agent-key"];
  const key = typeof header === "string" ? header : "";
  if (!key) {
    await reply.status(401).send({ error: "x-agent-key requis" });
    return;
  }
  const h = hashKey(key);
  let resolved = agentKeyCache.get(h);
  if (!resolved) {
    resolved = (await resolveAgentKey(key)) ?? undefined;
    if (resolved) {
      agentKeyCache.set(h, resolved);
      agentKeyIndex.set(resolved.keyId, h);
    }
  }
  if (!resolved) {
    await reply.status(401).send({ error: "Clé agent invalide" });
    return;
  }
  request.agentUserId = resolved.userId;
  request.agentKeyId = resolved.keyId;
}
