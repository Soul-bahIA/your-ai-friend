import { randomBytes, createHash } from "node:crypto";
import { pool, withTransaction } from "../db.js";
import { buildRevokeKeyQueries } from "../lib/agentTaskSql.js";

// Gestion des clés de l'agent local. On ne stocke que le hash SHA-256.
// La clé en clair (préfixe "sbk_") n'existe qu'au moment de la génération.
// Une clé révoquée est SUPPRIMÉE : toute clé présente en base est donc active.

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
    `SELECT id, label, allowed_dirs, created_at, last_used_at FROM agent_keys
     WHERE user_id = $1 ORDER BY created_at DESC`,
    [userId],
  );
  return rows;
}

export interface RevokeOutcome {
  revoked: boolean;
  /** Tâches annulées parce qu'elles ciblaient ce PC ou s'y exécutaient. */
  cancelled_task_ids: string[];
}

/**
 * Révoque (supprime) une clé de l'utilisateur — T16 / contrat §7. La FK
 * agent_tasks.(target_agent_key_id|claimed_by_key_id) ON DELETE SET NULL ferait d'une tâche
 * planifiée pour CE PC (vérifiée contre SES allowed_dirs) une tâche non ciblée, réclamable
 * et finalisable par n'importe quel autre PC. Dans la MÊME transaction, avant le DELETE :
 *  - verrou de la clé (un claim concurrent par cette clé attend puis échoue sur la FK) ;
 *  - tâches 'pending' ciblant la clé (corrections en attente comprises) → 'cancelled' ;
 *  - tâches 'in_progress' réclamées par la clé (ou la ciblant) → 'cancelled' + control 'stop'
 *    (l'agent révoqué ne peut plus rien envoyer ; aucun autre PC ne doit la finaliser).
 */
export async function revokeAgentKey(userId: string, id: string): Promise<RevokeOutcome> {
  const outcome = await withTransaction(async (client) => {
    const q = buildRevokeKeyQueries(id, userId);
    const key = await client.query(q.lockKey.sql, q.lockKey.values);
    if (key.rowCount !== 1) return { revoked: false, cancelled_task_ids: [] as string[] };
    const pending = await client.query(q.cancelPending.sql, q.cancelPending.values);
    const running = await client.query(q.cancelRunning.sql, q.cancelRunning.values);
    const del = await client.query(q.deleteKey.sql, q.deleteKey.values);
    if (del.rowCount !== 1) throw new Error("révocation concurrente de la clé agent");
    const ids = [...pending.rows, ...running.rows].map((r) => r.id as string);
    return { revoked: true, cancelled_task_ids: ids };
  });
  // Timeline (best-effort, hors transaction : un échec ici n'annule pas la révocation).
  for (const taskId of outcome.cancelled_task_ids) {
    pool
      .query(
        "INSERT INTO agent_events (task_id, user_id, type, message, data) VALUES ($1, $2, 'task_cancelled', $3, $4::jsonb)",
        [taskId, userId, "PC révoqué : tâche annulée", JSON.stringify({ source: "agent", key_revoked: true })],
      )
      .catch(() => {});
  }
  return outcome;
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

function toDirs(list: unknown): string[] {
  return Array.isArray(list) ? list.filter((d): d is string => typeof d === "string" && d.length > 0) : [];
}

/**
 * Union des dossiers autorisés de toutes les clés d'un utilisateur. N'est plus utilisée
 * pour planifier (le planner reçoit les dossiers de la clé CIBLÉE) ; conservée pour les
 * tâches héritées sans cible.
 */
export async function getUserAllowedDirs(userId: string): Promise<string[]> {
  const { rows } = await pool.query("SELECT allowed_dirs FROM agent_keys WHERE user_id = $1", [userId]);
  const dirs = new Set<string>();
  for (const row of rows) for (const d of toDirs(row.allowed_dirs)) dirs.add(d);
  return [...dirs];
}

/**
 * Nom affiché d'un PC : son libellé, sinon « PC <8 premiers caractères de l'id> » (même repli
 * que le front) — deux PC sans libellé restent distinguables dans la liste de choix (§7).
 */
export function agentName(id: string, label: unknown): string {
  const l = typeof label === "string" ? label.trim() : "";
  return l || `PC ${String(id).slice(0, 8)}`;
}

export interface AgentKeyInfo {
  id: string;
  name: string;
  allowed_dirs: string[];
}

/** Clé d'un utilisateur par id (null si absente / d'un autre compte / révoquée). */
export async function getAgentKey(userId: string, keyId: string): Promise<AgentKeyInfo | null> {
  const { rows } = await pool.query(
    "SELECT id, label, allowed_dirs FROM agent_keys WHERE id = $1 AND user_id = $2",
    [keyId, userId],
  );
  if (rows.length === 0) return null;
  return { id: rows[0].id, name: agentName(rows[0].id, rows[0].label), allowed_dirs: toDirs(rows[0].allowed_dirs) };
}

export type TargetChoice =
  | { ok: true; key: AgentKeyInfo | null }
  | { ok: false; status: number; error: string; agents?: { id: string; name: string }[] };

/**
 * Choix (pur) du PC ciblé (contrat LOT 1 §7) parmi les clés actives de l'utilisateur :
 *  - agent_key_id fourni → doit être l'une de ses clés (sinon 400) ;
 *  - sinon une seule clé → ciblée ; plusieurs → 400 { error, agents:[{id,name}] } ;
 *  - aucune clé → pas de cible (null) : seul un futur agent pourra la prendre.
 */
export function chooseTargetKey(keys: AgentKeyInfo[], requestedId?: string): TargetChoice {
  if (requestedId) {
    const k = keys.find((x) => x.id === requestedId);
    if (!k) return { ok: false, status: 400, error: "agent_key_id inconnu ou révoqué" };
    return { ok: true, key: k };
  }
  if (keys.length === 1) return { ok: true, key: keys[0] };
  if (keys.length === 0) return { ok: true, key: null };
  return {
    ok: false,
    status: 400,
    error: "Plusieurs agents sont enregistrés : précisez agent_key_id",
    agents: keys.map((k) => ({ id: k.id, name: k.name })),
  };
}

/** Résout le PC ciblé pour un utilisateur (lecture des clés + chooseTargetKey). */
export async function resolveTargetKey(userId: string, requestedId?: string): Promise<TargetChoice> {
  const { rows } = await pool.query(
    "SELECT id, label, allowed_dirs FROM agent_keys WHERE user_id = $1 ORDER BY created_at ASC",
    [userId],
  );
  const keys: AgentKeyInfo[] = rows.map((r) => ({
    id: r.id as string,
    name: agentName(r.id as string, r.label),
    allowed_dirs: toDirs(r.allowed_dirs),
  }));
  return chooseTargetKey(keys, requestedId);
}
