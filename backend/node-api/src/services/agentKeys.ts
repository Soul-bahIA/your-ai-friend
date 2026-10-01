import { randomBytes, createHash } from "node:crypto";
import { pool } from "../db";

// Gestion des clés de l'agent local. On ne stocke que le hash SHA-256.
// La clé en clair (préfixe "sbk_") n'existe qu'au moment de la génération.

const KEY_PREFIX = "sbk_";

export function hashKey(rawKey: string): string {
  return createHash("sha256").update(rawKey, "utf8").digest("hex");
}

/** Génère une clé aléatoire (256 bits) et l'enregistre (hash) pour l'utilisateur. */
export async function createAgentKey(userId: string, label?: string): Promise<{ id: string; key: string }> {
  const raw = KEY_PREFIX + randomBytes(32).toString("hex");
  const { rows } = await pool.query(
    "INSERT INTO agent_keys (user_id, key_hash, label) VALUES ($1, $2, $3) RETURNING id",
    [userId, hashKey(raw), label ?? null],
  );
  return { id: rows[0].id, key: raw };
}

/** Liste les clés de l'utilisateur (sans jamais exposer le hash ni la clé). */
export async function listAgentKeys(userId: string) {
  const { rows } = await pool.query(
    `SELECT id, label, created_at, last_used_at FROM agent_keys
     WHERE user_id = $1 ORDER BY created_at DESC`,
    [userId],
  );
  return rows;
}

/** Révoque (supprime) une clé de l'utilisateur. */
export async function revokeAgentKey(userId: string, id: string): Promise<boolean> {
  const { rowCount } = await pool.query(
    "DELETE FROM agent_keys WHERE id = $1 AND user_id = $2",
    [id, userId],
  );
  return (rowCount ?? 0) > 0;
}

/**
 * Valide une clé reçue (en-tête x-agent-key) : retourne { userId, keyId }
 * si le hash correspond, sinon null. Met à jour last_used_at.
 */
export async function resolveAgentKey(
  rawKey: string,
): Promise<{ userId: string; keyId: string } | null> {
  if (!rawKey) return null;
  const { rows } = await pool.query(
    "SELECT id, user_id FROM agent_keys WHERE key_hash = $1 LIMIT 1",
    [hashKey(rawKey)],
  );
  if (rows.length === 0) return null;

  // Best-effort : trace de dernière utilisation
  pool
    .query("UPDATE agent_keys SET last_used_at = now() WHERE id = $1", [rows[0].id])
    .catch(() => {});

  return { userId: rows[0].user_id as string, keyId: rows[0].id as string };
}

/** Enregistre la whitelist de dossiers annoncée par l'agent local (au démarrage). */
export async function setAgentAllowedDirs(keyId: string, dirs: string[]): Promise<void> {
  await pool.query("UPDATE agent_keys SET allowed_dirs = $1::jsonb WHERE id = $2", [
    JSON.stringify(dirs),
    keyId,
  ]);
}

/**
 * Dossiers autorisés connus pour un utilisateur (union des whitelists annoncées
 * par ses agents), injectés dans le contexte du planificateur.
 */
export async function getUserAllowedDirs(userId: string): Promise<string[]> {
  const { rows } = await pool.query(
    "SELECT allowed_dirs FROM agent_keys WHERE user_id = $1",
    [userId],
  );
  const dirs = new Set<string>();
  for (const row of rows) {
    const list = row.allowed_dirs;
    if (Array.isArray(list)) for (const d of list) if (typeof d === "string" && d) dirs.add(d);
  }
  return [...dirs];
}
