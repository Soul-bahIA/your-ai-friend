import type { FastifyRequest, FastifyReply } from "fastify";
import { config } from "./config";
import { resolveAgentKey } from "./services/agentKeys";

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

/**
 * Vérifie un JWT Supabase en interrogeant l'endpoint /auth/v1/user
 * (équivalent de `supabase.auth.getUser(token)` utilisé par les edge functions).
 */
export async function verifySupabaseToken(token: string): Promise<AuthUser | null> {
  if (!config.supabaseUrl || !config.supabaseAnonKey) return null;
  try {
    const res = await fetch(`${config.supabaseUrl}/auth/v1/user`, {
      headers: {
        apikey: config.supabaseAnonKey,
        Authorization: `Bearer ${token}`,
      },
    });
    if (!res.ok) return null;
    const user = (await res.json()) as { id?: string; email?: string };
    return user?.id ? { id: user.id, email: user.email } : null;
  } catch {
    return null;
  }
}

/** preHandler Fastify : exige un utilisateur authentifié (JWT Supabase). */
export async function requireUser(request: FastifyRequest, reply: FastifyReply): Promise<void> {
  const header = request.headers["authorization"];
  const token = typeof header === "string" ? header.replace(/^Bearer\s+/i, "") : "";
  if (!token) {
    await reply.status(401).send({ error: "Non authentifié" });
    return;
  }
  const user = await verifySupabaseToken(token);
  if (!user) {
    await reply.status(401).send({ error: "Non autorisé" });
    return;
  }
  request.user = user;
}

/**
 * preHandler pour le worker local : valide l'en-tête x-agent-key contre le hash
 * stocké en base et déduit le user_id propriétaire (`request.agentUserId`).
 * Le user_id n'est donc plus transmis en clair par l'agent.
 */
export async function requireAgentKey(request: FastifyRequest, reply: FastifyReply): Promise<void> {
  const header = request.headers["x-agent-key"];
  const key = typeof header === "string" ? header : "";
  if (!key) {
    await reply.status(401).send({ error: "x-agent-key requis" });
    return;
  }
  const resolved = await resolveAgentKey(key);
  if (!resolved) {
    await reply.status(401).send({ error: "Clé agent invalide" });
    return;
  }
  request.agentUserId = resolved.userId;
  request.agentKeyId = resolved.keyId;
}
