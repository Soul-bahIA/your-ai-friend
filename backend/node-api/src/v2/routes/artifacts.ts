// Artefacts (LOT 9, audit §9.8) : adressés par sha256, téléversés par PUT idempotent (clé
// agent), lus par GET authentifié (JWT propriétaire ou clé agent du même utilisateur). Le
// contenu vit sur disque (<MEDIA_DIR>/artifacts/<user>/<sha256>), la base ne porte que la
// fiche (soulbah.artifacts) : plus aucun base64 en base.
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { pool } from "../../db.js";
import { requireAgentKey, requireUser } from "../../auth.js";
import { isUuid, sanitizeLimit } from "../../lib/sanitize.js";
import { logger } from "../../lib/logger.js";
import { audit } from "../audit.js";

export const MAX_ARTIFACT_BYTES = 25 * 1024 * 1024;
export const ARTIFACT_KINDS = ["file", "screenshot", "video", "log", "report", "diff"] as const;
export const RETENTION_CLASSES = ["ephemeral", "task", "session", "permanent"] as const;
const SHA_RE = /^[0-9a-f]{64}$/;
/**
 * Types MIME acceptés en téléversement (binaire brut). JAMAIS application/json ni text/plain :
 * addContentTypeParser remplacerait l'analyseur JSON de Fastify pour TOUTES les routes. Un
 * artefact JSON ou texte se téléverse en application/octet-stream.
 */
export const ARTIFACT_CONTENT_TYPES = ["application/octet-stream", "image/png", "image/jpeg", "image/webp", "video/mp4", "application/pdf"];

export function sha256Hex(buf: Buffer): string {
  return createHash("sha256").update(buf).digest("hex");
}

/** Chemin de stockage d'un artefact (jamais dérivé d'une entrée libre : uuid + hex seulement). */
export function artifactPath(mediaDir: string, userId: string, sha: string): string {
  if (!isUuid(userId) || !SHA_RE.test(sha)) throw new Error("artefact : identifiants invalides");
  return path.join(mediaDir, "artifacts", userId, sha);
}

interface ArtifactRow {
  id: string;
  user_id: string;
  session_id: string | null;
  task_id: string | null;
  sha256: string;
  mime: string;
  size_bytes: string | number;
  uri: string;
  kind: string;
  retention_class: string;
  metadata: Record<string, unknown>;
  created_at: string | Date;
}

const COLS = "id, user_id, session_id, task_id, sha256, mime, size_bytes, uri, kind, retention_class, metadata, created_at";

/** Utilisateur de la requête : JWT ou clé agent (les deux préHandlers sont acceptés). */
async function anyUser(request: FastifyRequest, reply: FastifyReply): Promise<string | null> {
  if (request.headers["x-agent-key"]) {
    await requireAgentKey(request, reply);
    return reply.sent ? null : request.agentUserId!;
  }
  await requireUser(request, reply);
  return reply.sent ? null : request.user!.id;
}

export async function artifactRoutes(app: FastifyInstance, opts: { mediaDir: string }): Promise<void> {
  // Corps binaires bruts (uniquement pour ces types ; le JSON reste géré par Fastify).
  app.addContentTypeParser(ARTIFACT_CONTENT_TYPES, { parseAs: "buffer", bodyLimit: MAX_ARTIFACT_BYTES }, (_req, body, done) => done(null, body));

  // --- Téléversement idempotent (clé agent) ----------------------------------------------
  app.put("/api/v2/artifacts/:sha256", { preHandler: requireAgentKey, bodyLimit: MAX_ARTIFACT_BYTES }, async (request, reply) => {
    const userId = request.agentUserId!;
    const { sha256 } = request.params as { sha256: string };
    if (!SHA_RE.test(sha256)) return reply.status(400).send({ error: "sha256 (64 hex, minuscules) attendu dans l'URL" });
    const body = request.body;
    if (!Buffer.isBuffer(body)) return reply.status(415).send({ error: `corps binaire attendu (Content-Type : ${ARTIFACT_CONTENT_TYPES.join(", ")})` });
    const actual = sha256Hex(body);
    if (actual !== sha256) return reply.status(400).send({ error: "empreinte du contenu différente de l'URL", computed: actual });
    const q = request.query as { kind?: string; retention?: string; task_id?: string; session_id?: string; name?: string };
    const kind = q.kind ?? "file";
    if (!(ARTIFACT_KINDS as readonly string[]).includes(kind)) return reply.status(400).send({ error: "kind : file | screenshot | video | log | report | diff" });
    const retention = q.retention ?? "task";
    if (!(RETENTION_CLASSES as readonly string[]).includes(retention)) return reply.status(400).send({ error: "retention : ephemeral | task | session | permanent" });
    if (q.task_id !== undefined && !isUuid(q.task_id)) return reply.status(400).send({ error: "task_id : uuid attendu" });
    if (q.session_id !== undefined && !isUuid(q.session_id)) return reply.status(400).send({ error: "session_id : uuid attendu" });
    const mime = (request.headers["content-type"] ?? "application/octet-stream").split(";")[0].trim().toLowerCase();

    const file = artifactPath(opts.mediaDir, userId, sha256);
    const existing = await pool.query(`SELECT ${COLS} FROM soulbah.artifacts WHERE user_id = $1 AND sha256 = $2`, [userId, sha256]);
    if (existing.rows.length === 1 && fs.existsSync(file)) {
      return reply.status(200).send({ artifact: existing.rows[0], created: false });
    }
    // Écriture atomique (fichier temporaire puis renommage) : jamais un artefact partiel lisible.
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
    fs.writeFileSync(tmp, body);
    fs.renameSync(tmp, file);
    const { rows } = await pool.query(
      `INSERT INTO soulbah.artifacts (user_id, session_id, task_id, sha256, mime, size_bytes, uri, kind, retention_class, metadata)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb)
       ON CONFLICT (user_id, sha256) DO UPDATE SET uri = EXCLUDED.uri, mime = EXCLUDED.mime, task_id = coalesce(soulbah.artifacts.task_id, EXCLUDED.task_id)
       RETURNING ${COLS}`,
      [userId, q.session_id ?? null, q.task_id ?? null, sha256, mime, body.length, `file://artifacts/${userId}/${sha256}`, kind, retention, JSON.stringify({ name: typeof q.name === "string" ? q.name.slice(0, 200) : null })],
    );
    await audit({ userId, taskId: q.task_id ?? null, sessionId: q.session_id ?? null, actor: `agent:${request.agentKeyId}`, action: "artifact.stored", entity: "artifact", entityId: rows[0].id as string, data: { sha256, mime, size_bytes: body.length, kind } }).catch(() => {});
    return reply.status(201).send({ artifact: rows[0], created: existing.rows.length === 0 });
  });

  // --- Lecture (JWT propriétaire ou clé agent du même utilisateur) ---------------------------
  app.get("/api/v2/artifacts/:id", async (request, reply) => {
    const userId = await anyUser(request, reply);
    if (!userId) return;
    const { id } = request.params as { id: string };
    const { rows } = SHA_RE.test(id)
      ? await pool.query(`SELECT ${COLS} FROM soulbah.artifacts WHERE user_id = $1 AND sha256 = $2`, [userId, id])
      : isUuid(id)
        ? await pool.query(`SELECT ${COLS} FROM soulbah.artifacts WHERE user_id = $1 AND id = $2`, [userId, id])
        : { rows: [] };
    if (rows.length !== 1) return reply.status(404).send({ error: "Artefact introuvable" });
    const row = rows[0] as ArtifactRow;
    const file = artifactPath(opts.mediaDir, userId, row.sha256);
    if (!fs.existsSync(file)) {
      logger.warn({ artifact: row.id }, "artefact : fiche sans fichier");
      return reply.status(410).send({ error: "Contenu de l'artefact absent du stockage" });
    }
    const meta = (request.query as { meta?: string }).meta;
    if (meta === "1") return { artifact: row };
    reply.header("Content-Type", row.mime || "application/octet-stream");
    reply.header("Content-Length", String(row.size_bytes));
    reply.header("Cache-Control", "private, max-age=3600");
    reply.header("X-Content-Type-Options", "nosniff");
    reply.header("Content-Disposition", `attachment; filename="${row.sha256.slice(0, 16)}"`);
    return reply.send(fs.createReadStream(file));
  });

  // --- Liste (JWT) ---------------------------------------------------------------------------
  app.get("/api/v2/artifacts", { preHandler: requireUser }, async (request, reply) => {
    const q = request.query as { task_id?: string; session_id?: string; limit?: string };
    const values: unknown[] = [request.user!.id];
    let where = "user_id = $1";
    if (q.task_id !== undefined) {
      if (!isUuid(q.task_id)) return reply.status(400).send({ error: "task_id : uuid attendu" });
      values.push(q.task_id);
      where += ` AND task_id = $${values.length}`;
    }
    if (q.session_id !== undefined) {
      if (!isUuid(q.session_id)) return reply.status(400).send({ error: "session_id : uuid attendu" });
      values.push(q.session_id);
      where += ` AND session_id = $${values.length}`;
    }
    const { rows } = await pool.query(`SELECT ${COLS} FROM soulbah.artifacts WHERE ${where} ORDER BY created_at DESC LIMIT ${sanitizeLimit(q.limit, 50, 500)}`, values);
    return { artifacts: rows };
  });
}
