// Routes V2 — approbations par action (LOT 6) et journal d'audit.
//
//   POST /api/v2/approvals/request   (clé agent)  demande d'approbation L2/L3 avec le payload complet
//   GET  /api/v2/approvals/:id       (clé agent)  statut ; jeton HMAC si approuvée (recalculé, jamais stocké)
//   POST /api/v2/approvals/verify    (clé agent)  vérifie un jeton pour le payload RÉELLEMENT exécuté
//   GET  /api/v2/approvals           (JWT)        boîte de réception (pending par défaut)
//   POST /api/v2/approvals/:id/approve (JWT)      approuve — l'empreinte AFFICHÉE doit être renvoyée
//   POST /api/v2/approvals/:id/deny  (JWT)        refuse
//   GET  /api/v2/audit/verify        (JWT)        vérification de la chaîne d'audit
//   GET  /api/v2/audit               (JWT)        dernières entrées de l'utilisateur
//
// Chaque décision est auditée dans la même transaction (soulbah.audit_logs).
import type { FastifyInstance, FastifyReply } from "fastify";
import { pool, withTransaction, type Queryable } from "../../db.js";
import { requireAgentKey, requireUser } from "../../auth.js";
import { TOOL_BY_TYPE } from "../../lib/agentSteps.js";
import { isPlainObject, isUuid, sanitizeLimit, unknownKeys } from "../../lib/sanitize.js";
import { audit, listAudit, userActor, verifyChain } from "../audit.js";
import { createApprovalToken, payloadSha256, tokenHash, verifyApprovalToken } from "../security/approvals.js";
import { decide, isSecurityLevel } from "../security/policy.js";
import { redactSecrets } from "../security/redactSecrets.js";
import { getTask, transitionTask } from "../tasks/repo.js";

const APPROVAL_STATUSES = ["pending", "approved", "denied", "expired", "revoked"] as const;
type ApprovalStatus = (typeof APPROVAL_STATUSES)[number];
const DEFAULT_TTL_S = 600;
const MIN_TTL_S = 30;
const MAX_TTL_S = 3600;
const MAX_PAYLOAD_BYTES = 64 * 1024;
const MAX_SUMMARY = 500;

const COLS = `id, user_id, kind, security_level, scope, payload_sha256, payload_presented, status,
  decided_by, decided_at, expires_at, token_hash, created_at`;

interface PermissionRow {
  id: string;
  user_id: string;
  kind: string;
  security_level: "L0" | "L1" | "L2" | "L3";
  scope: Record<string, unknown>;
  payload_sha256: string | null;
  payload_presented: Record<string, unknown> | null;
  status: ApprovalStatus;
  decided_by: string | null;
  decided_at: string | Date | null;
  expires_at: string | Date | null;
  token_hash: string | null;
  created_at: string | Date;
}

/** DTO de l'interface (frontend/src/lib/approvals.ts). */
export function toApprovalDto(r: PermissionRow) {
  const scope = r.scope ?? {};
  return {
    id: r.id,
    status: r.status,
    security_level: r.security_level,
    kind: r.kind,
    tool: typeof scope.tool === "string" ? scope.tool : null,
    summary: typeof scope.summary === "string" ? scope.summary : null,
    task_id: typeof scope.v1_task_id === "string" ? scope.v1_task_id : null,
    attempt: typeof scope.attempt === "number" ? scope.attempt : null,
    step_index: typeof scope.step_index === "number" ? scope.step_index : null,
    payload_presented: r.payload_presented,
    payload_sha256: r.payload_sha256,
    reason: typeof scope.reason === "string" ? scope.reason : null,
    created_at: r.created_at,
    expires_at: r.expires_at,
    decided_at: r.decided_at,
  };
}

function isExpired(r: PermissionRow, now = new Date()): boolean {
  return r.expires_at !== null && new Date(r.expires_at).getTime() <= now.getTime();
}

/** Une demande « pending » dont l'échéance est passée devient « expired » (mise à jour paresseuse). */
async function loadForUser(id: string, userId: string): Promise<PermissionRow | null> {
  const { rows } = await pool.query(`SELECT ${COLS} FROM soulbah.permissions WHERE id = $1 AND user_id = $2`, [id, userId]);
  if (rows.length === 0) return null;
  let row = rows[0] as PermissionRow;
  if (row.status === "pending" && isExpired(row)) {
    const upd = await pool.query(
      `UPDATE soulbah.permissions SET status = 'expired' WHERE id = $1 AND status = 'pending' RETURNING ${COLS}`,
      [id],
    );
    if (upd.rows.length === 1) row = upd.rows[0] as PermissionRow;
  }
  return row;
}

function badRequest(reply: FastifyReply, error: string) {
  return reply.status(400).send({ error });
}

/**
 * LOT 9 : la tâche V2 qui attendait cette décision reprend UNE seule fois (WAITING → RUNNING,
 * CAS sur l'état) à l'approbation ; au refus elle passe BLOCKED (§9.4 « approbation refusée »).
 */
async function resumeWaitingTask(client: Queryable, perm: PermissionRow, userId: string, decision: "approved" | "denied"): Promise<void> {
  const taskId = typeof perm.scope?.v2_task_id === "string" ? perm.scope.v2_task_id : null;
  if (!taskId) return;
  const task = await getTask(client, taskId, userId);
  if (!task || task.status !== "WAITING") return;
  if (decision === "approved") {
    await transitionTask(client, { task, to: "RUNNING", set: { waiting_reason: null }, actor: userActor(userId), data: { approval_id: perm.id, resumed: true } });
  } else {
    await transitionTask(client, {
      task,
      to: "BLOCKED",
      set: { blocked_reason: `approbation refusée : ${String(perm.scope?.tool ?? "action")}`, waiting_reason: null, escalate_at: new Date(Date.now() + 24 * 3600 * 1000) },
      actor: userActor(userId),
      data: { approval_id: perm.id, reason: "approval_denied" },
    });
  }
}

export async function approvalRoutes(app: FastifyInstance): Promise<void> {
  // --- Runtime / agent : demande d'approbation ------------------------------------------
  app.post("/api/v2/approvals/request", { preHandler: requireAgentKey, bodyLimit: 256 * 1024 }, async (request, reply) => {
    const userId = request.agentUserId!;
    const body = request.body;
    if (!isPlainObject(body)) return badRequest(reply, "corps JSON objet attendu");
    const extra = unknownKeys(body, ["task_id", "attempt", "step_index", "tool", "level", "payload", "summary", "ttl_s", "v2_task_id"]);
    if (extra.length) return badRequest(reply, `champ(s) inconnu(s) : ${extra.join(", ").slice(0, 200)}`);
    if (typeof body.tool !== "string" || !TOOL_BY_TYPE.has(body.tool)) return badRequest(reply, "tool : type d'étape inconnu du catalogue");
    if (body.level !== "L2" && body.level !== "L3") return badRequest(reply, "level : L2 ou L3 attendu");
    if (!isPlainObject(body.payload)) return badRequest(reply, "payload (objet) requis");
    if (Buffer.byteLength(JSON.stringify(body.payload), "utf8") > MAX_PAYLOAD_BYTES) return badRequest(reply, "payload trop volumineux (64 Ko max)");
    if (body.task_id !== undefined && body.task_id !== null && !isUuid(body.task_id)) return badRequest(reply, "task_id : uuid attendu");
    if (body.v2_task_id !== undefined && body.v2_task_id !== null && !isUuid(body.v2_task_id)) return badRequest(reply, "v2_task_id : uuid attendu");
    for (const k of ["attempt", "step_index"] as const) {
      const v = body[k];
      if (v !== undefined && v !== null && !(typeof v === "number" && Number.isInteger(v) && v >= 0)) return badRequest(reply, `${k} : entier ≥ 0 attendu`);
    }
    if (body.summary !== undefined && body.summary !== null && typeof body.summary !== "string") return badRequest(reply, "summary : texte attendu");
    let ttl = DEFAULT_TTL_S;
    if (body.ttl_s !== undefined && body.ttl_s !== null) {
      if (typeof body.ttl_s !== "number" || !Number.isFinite(body.ttl_s)) return badRequest(reply, "ttl_s : nombre attendu");
      ttl = Math.max(MIN_TTL_S, Math.min(MAX_TTL_S, Math.trunc(body.ttl_s)));
    }

    // Politique : un outil interdit (deny-list, plafond) n'ouvre jamais de demande.
    const policy = decide({ tool: body.tool, step: body.payload, userMaxLevel: "L3" });
    if (policy.decision === "deny") {
      await audit({ userId, actor: `agent:${request.agentKeyId}`, action: "permission.refused", entity: "tool", data: { tool: body.tool, reason: policy.reason } }).catch(() => {});
      return reply.status(403).send({ error: "action refusée par la politique", reason: policy.reason });
    }
    const level = policy.level === "DENY" ? body.level : policy.level === "L3" || body.level === "L3" ? "L3" : "L2";
    const sha = payloadSha256(body.payload);
    const scope = {
      tool: body.tool,
      v1_task_id: isUuid(body.task_id) ? body.task_id : null,
      v2_task_id: isUuid(body.v2_task_id) ? body.v2_task_id : null,
      attempt: typeof body.attempt === "number" ? body.attempt : null,
      step_index: typeof body.step_index === "number" ? body.step_index : null,
      summary: typeof body.summary === "string" ? body.summary.slice(0, MAX_SUMMARY) : null,
      agent_key_id: request.agentKeyId,
      policy_reason: policy.reason,
    };
    const row = await withTransaction(async (client) => {
      const ins = await client.query(
        `INSERT INTO soulbah.permissions (user_id, kind, security_level, scope, payload_sha256, payload_presented, status, expires_at)
         VALUES ($1, 'request', $2, $3::jsonb, $4, $5::jsonb, 'pending', now() + make_interval(secs => $6))
         RETURNING ${COLS}`,
        [userId, level, JSON.stringify(scope), sha, JSON.stringify(redactSecrets(body.payload)), ttl],
      );
      const r = ins.rows[0] as PermissionRow;
      // LOT 9 : une tâche V2 en cours attend l'approbation (RUNNING → WAITING, §9.4) ; elle
      // reprendra UNE fois à l'approbation (WAITING → RUNNING), ou passera BLOCKED au refus.
      if (scope.v2_task_id) {
        const task = await getTask(client, scope.v2_task_id, userId);
        if (task && task.status === "RUNNING" && (typeof body.attempt !== "number" || task.attempt === body.attempt)) {
          await transitionTask(client, {
            task,
            to: "WAITING",
            set: { waiting_reason: `approbation ${level} requise : ${body.tool} (demande ${r.id})` },
            actor: `agent:${request.agentKeyId}`,
            data: { approval_id: r.id, tool: body.tool, level },
          });
        }
      }
      await audit(
        {
          userId,
          actor: `agent:${request.agentKeyId}`,
          action: "permission.requested",
          entity: "permission",
          entityId: r.id,
          data: { tool: body.tool, level, payload_sha256: sha, v1_task_id: scope.v1_task_id, step_index: scope.step_index },
        },
        client,
      );
      return r;
    });
    return reply.status(201).send({ id: row.id, status: row.status, payload_sha256: sha, expires_at: row.expires_at });
  });

  // --- Runtime / agent : statut (+ jeton si approuvée) ------------------------------------
  app.get("/api/v2/approvals/:id", { preHandler: requireAgentKey }, async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return badRequest(reply, "id invalide");
    const row = await loadForUser(id, request.agentUserId!);
    if (!row) return reply.status(404).send({ error: "Demande introuvable" });
    const out: Record<string, unknown> = {
      id: row.id,
      status: row.status,
      expires_at: row.expires_at,
      decided_at: row.decided_at,
      reason: typeof row.scope?.reason === "string" ? row.scope.reason : null,
    };
    if (row.status === "approved" && row.payload_sha256 && row.expires_at && !isExpired(row)) {
      const token = createApprovalToken({ id: row.id, payloadSha256: row.payload_sha256, expiresAt: new Date(row.expires_at), level: row.security_level });
      // Le hash stocké doit correspondre : sinon le secret a changé ou la ligne a été altérée → révoquée.
      if (row.token_hash === tokenHash(token)) out.token = token;
      else out.status = "revoked";
    } else if (row.status === "approved") {
      out.status = "expired";
    }
    return out;
  });

  // --- Runtime / agent : vérification d'un jeton pour le payload exécuté -----------------
  app.post("/api/v2/approvals/verify", { preHandler: requireAgentKey, bodyLimit: 256 * 1024 }, async (request, reply) => {
    const body = request.body;
    if (!isPlainObject(body) || typeof body.token !== "string" || !isPlainObject(body.payload)) {
      return badRequest(reply, "token (texte) et payload (objet) requis");
    }
    const sha = payloadSha256(body.payload);
    const v = verifyApprovalToken(body.token, { payloadSha256: sha });
    if (!v.ok) return { ok: false, reason: v.reason };
    const row = await loadForUser(v.body.id, request.agentUserId!);
    if (!row) return { ok: false, reason: "unknown" };
    if (row.status !== "approved") return { ok: false, reason: row.status };
    if (isExpired(row)) return { ok: false, reason: "expired" };
    if (row.token_hash !== tokenHash(body.token)) return { ok: false, reason: "revoked" };
    if (row.payload_sha256 !== sha) return { ok: false, reason: "payload_mismatch" };
    return { ok: true, approval_id: row.id, level: row.security_level };
  });

  // --- Utilisateur : boîte de réception -------------------------------------------------
  app.get("/api/v2/approvals", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const q = request.query as { status?: string; limit?: string };
    const status = q.status ?? "pending";
    if (status !== "all" && !(APPROVAL_STATUSES as readonly string[]).includes(status)) return badRequest(reply, "status invalide");
    const limit = sanitizeLimit(q.limit, 50, 200);
    // Expiration paresseuse des demandes en attente de l'utilisateur.
    await pool.query(
      "UPDATE soulbah.permissions SET status = 'expired' WHERE user_id = $1 AND kind = 'request' AND status = 'pending' AND expires_at <= now()",
      [userId],
    );
    const values: unknown[] = [userId];
    let where = "user_id = $1 AND kind = 'request'";
    if (status !== "all") {
      values.push(status);
      where += " AND status = $2";
    }
    const { rows } = await pool.query(`SELECT ${COLS} FROM soulbah.permissions WHERE ${where} ORDER BY created_at DESC LIMIT ${limit}`, values);
    return { approvals: (rows as PermissionRow[]).map(toApprovalDto) };
  });

  // --- Utilisateur : approuver (empreinte affichée obligatoire) ------------------------
  app.post("/api/v2/approvals/:id/approve", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return badRequest(reply, "id invalide");
    const body = (request.body ?? {}) as { payload_sha256?: unknown };
    if (typeof body.payload_sha256 !== "string" || !/^[0-9a-f]{64}$/.test(body.payload_sha256)) {
      return badRequest(reply, "payload_sha256 (empreinte affichée) requis");
    }
    const current = await loadForUser(id, userId);
    if (!current) return reply.status(404).send({ error: "Demande introuvable" });
    if (current.status !== "pending") return reply.status(409).send({ error: `Demande déjà « ${current.status} »`, status: current.status });
    if (current.payload_sha256 !== body.payload_sha256) {
      return reply.status(409).send({ error: "L'empreinte du payload affiché ne correspond pas à la demande", status: current.status });
    }
    const expiresAt = new Date(current.expires_at as string);
    const token = createApprovalToken({ id, payloadSha256: current.payload_sha256, expiresAt, level: current.security_level });
    const updated = await withTransaction(async (client) => {
      const upd = await client.query(
        `UPDATE soulbah.permissions
            SET status = 'approved', decided_by = $2, decided_at = now(), token_hash = $3
          WHERE id = $1 AND user_id = $2 AND status = 'pending' AND expires_at > now()
          RETURNING ${COLS}`,
        [id, userId, tokenHash(token)],
      );
      if (upd.rows.length !== 1) return null;
      const r = upd.rows[0] as PermissionRow;
      await resumeWaitingTask(client, r, userId, "approved");
      await audit(
        {
          userId,
          actor: userActor(userId),
          action: "permission.approved",
          entity: "permission",
          entityId: id,
          data: { tool: r.scope?.tool, level: r.security_level, payload_sha256: r.payload_sha256, v1_task_id: r.scope?.v1_task_id ?? null },
        },
        client,
      );
      return r;
    });
    if (!updated) return reply.status(409).send({ error: "Demande plus en attente (expirée ou déjà décidée)" });
    return { id, status: "approved", expires_at: updated.expires_at };
  });

  // --- Utilisateur : refuser ------------------------------------------------------------
  app.post("/api/v2/approvals/:id/deny", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return badRequest(reply, "id invalide");
    const body = (request.body ?? {}) as { reason?: unknown };
    const reason = typeof body.reason === "string" ? body.reason.slice(0, MAX_SUMMARY) : null;
    const updated = await withTransaction(async (client) => {
      const upd = await client.query(
        `UPDATE soulbah.permissions
            SET status = 'denied', decided_by = $2, decided_at = now(),
                scope = scope || jsonb_build_object('reason', $3::text)
          WHERE id = $1 AND user_id = $2 AND status = 'pending'
          RETURNING ${COLS}`,
        [id, userId, reason],
      );
      if (upd.rows.length !== 1) return null;
      const r = upd.rows[0] as PermissionRow;
      await resumeWaitingTask(client, r, userId, "denied");
      await audit(
        { userId, actor: userActor(userId), action: "permission.denied", entity: "permission", entityId: id, data: { tool: r.scope?.tool, level: r.security_level, reason } },
        client,
      );
      return r;
    });
    if (!updated) {
      const cur = await loadForUser(id, userId);
      if (!cur) return reply.status(404).send({ error: "Demande introuvable" });
      return reply.status(409).send({ error: `Demande déjà « ${cur.status} »`, status: cur.status });
    }
    return { id, status: "denied" };
  });

  // --- Audit ---------------------------------------------------------------------------
  app.get("/api/v2/audit/verify", { preHandler: requireUser }, async () => verifyChain());

  app.get("/api/v2/audit", { preHandler: requireUser }, async (request, reply) => {
    const q = request.query as { limit?: string; session_id?: string };
    if (q.session_id !== undefined && !isUuid(q.session_id)) return badRequest(reply, "session_id invalide");
    const entries = await listAudit(request.user!.id, { sessionId: q.session_id, limit: sanitizeLimit(q.limit, 100, 500) });
    return { entries };
  });
}
