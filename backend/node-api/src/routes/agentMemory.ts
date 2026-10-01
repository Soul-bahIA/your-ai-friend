import type { FastifyInstance } from "fastify";
import { pool } from "../db.js";
import { requireUser } from "../auth.js";
import { analyzePerformance, ServiceError } from "../clients/iaClient.js";
import { isPlainObject, isUuid } from "../lib/sanitize.js";
import { logEvent } from "../services/logs.js";
import {
  GENERAL_GOAL,
  effectiveMemoryStatus,
  formatMemoryContext,
  memoryWords,
  rankMemories,
  type MemoryRow,
} from "../lib/memoryRanking.js";

// Mémoire d'exécution de l'agent : erreurs, solutions, bonnes pratiques.
// Réinjectée dans la planification (getMemoryContext) et enrichie après chaque objectif
// évalué (writeMemory, appelé depuis agentGoal.ts). Tout ce qui vient de l'évaluateur ou
// de l'auto-amélioration est PROPOSÉ ; seule une action explicite de l'utilisateur
// (POST/PATCH status='validated') valide une entrée (metadata.validated_by).

const CANDIDATES_LIMIT = 60;

/** Contexte mémoire pertinent pour un objectif, injecté (comme données non fiables) dans le plan. */
export async function getMemoryContext(userId: string, goal: string): Promise<string | undefined> {
  const words = memoryWords(goal).slice(0, 8);
  const patterns = words.map((w) => `%${w}%`);
  const { rows } = await pool.query(
    `SELECT id, type, level, status, goal, content, metadata, created_at FROM agent_memory
      WHERE user_id = $1 AND status <> 'rejected'
        AND (goal = $2 OR goal ILIKE ANY($3::text[]))
      ORDER BY created_at DESC LIMIT ${CANDIDATES_LIMIT}`,
    [userId, GENERAL_GOAL, patterns],
  );
  return formatMemoryContext(rankMemories(goal, rows as MemoryRow[]));
}

// Niveaux de mémoire (extensible) : mémoire de travail, projet, utilisateur, technique,
// documentaire, workflow, erreurs, optimisations.
export type MemoryLevel =
  | "working"
  | "project"
  | "user"
  | "technical"
  | "documentary"
  | "workflow"
  | "error"
  | "optimization";
export type MemoryStatus = "proposed" | "validated" | "rejected";

const TYPES = ["error", "solution", "practice"];
const LEVELS = ["working", "project", "user", "technical", "documentary", "workflow", "error", "optimization"];
const STATUSES = ["proposed", "validated", "rejected"];

/** Enregistre une expérience dans la mémoire (PROPOSÉE par défaut — jamais validée d'office). */
export async function writeMemory(
  userId: string,
  type: "error" | "solution" | "practice",
  goal: string,
  content: string,
  metadata: unknown = {},
  level: MemoryLevel = "workflow",
  status: MemoryStatus = "proposed",
): Promise<void> {
  await pool.query(
    `INSERT INTO agent_memory (user_id, type, goal, content, metadata, level, status)
     VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7)`,
    [userId, type, goal.slice(0, 2000), content.slice(0, 10_000), JSON.stringify(metadata), level, status],
  );
}

/** Métadonnées fournies par un client : objet borné, sans les champs de validation (posés par le serveur). */
function clientMetadata(v: unknown): Record<string, unknown> | null {
  if (v === undefined || v === null) return {};
  if (!isPlainObject(v)) return null;
  const { validated_by: _vb, validated_at: _va, ...rest } = v;
  void _vb;
  void _va;
  return JSON.stringify(rest).length > 10_000 ? null : rest;
}

export async function agentMemoryRoutes(app: FastifyInstance): Promise<void> {
  // --- Lister sa mémoire (JWT), filtrable par niveau et statut (statut EFFECTIF) ---
  app.get("/api/agent/memory", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const q = request.query as { level?: string; status?: string };
    if (q.level !== undefined && !LEVELS.includes(q.level)) return reply.status(400).send({ error: "level invalide" });
    if (q.status !== undefined && !STATUSES.includes(q.status)) return reply.status(400).send({ error: "status invalide" });
    const where: string[] = ["user_id = $1"];
    const params: unknown[] = [userId];
    if (q.level) {
      params.push(q.level);
      where.push(`level = $${params.length}`);
    }
    if (q.status === "validated") where.push("status = 'validated' AND metadata ? 'validated_by'");
    else if (q.status === "proposed") where.push("(status = 'proposed' OR (status = 'validated' AND NOT metadata ? 'validated_by'))");
    else if (q.status === "rejected") where.push("status = 'rejected'");
    const { rows } = await pool.query(
      `SELECT id, type, level, status, goal, content, metadata, created_at FROM agent_memory
       WHERE ${where.join(" AND ")} ORDER BY created_at DESC LIMIT 100`,
      params,
    );
    return {
      memory: rows.map(({ metadata, ...r }) => ({
        ...r,
        stored_status: r.status,
        status: effectiveMemoryStatus({ status: r.status, metadata }),
      })),
    };
  });

  // --- Écrire une entrée de mémoire à un niveau donné (JWT) — proposée par défaut ---
  app.post("/api/agent/memory", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const body = (request.body ?? {}) as {
      type?: "error" | "solution" | "practice";
      level?: MemoryLevel;
      goal?: string;
      content?: string;
      status?: MemoryStatus;
      metadata?: unknown;
    };
    if (typeof body.content !== "string" || !body.content.trim()) return reply.status(400).send({ error: "content requis" });
    if (body.content.length > 10_000 || (body.goal !== undefined && (typeof body.goal !== "string" || body.goal.length > 2000))) {
      return reply.status(400).send({ error: "content (10000 car.) ou goal (2000 car.) trop long" });
    }
    if (body.type !== undefined && !TYPES.includes(body.type)) return reply.status(400).send({ error: "type invalide" });
    if (body.level !== undefined && !LEVELS.includes(body.level)) return reply.status(400).send({ error: "level invalide" });
    if (body.status !== undefined && !STATUSES.includes(body.status)) return reply.status(400).send({ error: "status invalide" });
    const metadata = clientMetadata(body.metadata);
    if (metadata === null) return reply.status(400).send({ error: "metadata invalide (objet ≤ 10 Ko)" });
    const status = body.status ?? "proposed";
    // Valider à la création est une action EXPLICITE de l'utilisateur : tracée.
    if (status === "validated") Object.assign(metadata, { validated_by: userId, validated_at: new Date().toISOString() });
    await writeMemory(
      userId, body.type ?? "practice", body.goal ?? GENERAL_GOAL, body.content,
      metadata, body.level ?? "workflow", status,
    );
    return { success: true, status };
  });

  // --- Valider / rejeter une entrée (l'utilisateur garde le contrôle) ---
  app.patch("/api/agent/memory/:id", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const { status } = (request.body ?? {}) as { status?: MemoryStatus };
    if (!status || !STATUSES.includes(status)) {
      return reply.status(400).send({ error: "status valide requis (proposed|validated|rejected)" });
    }
    const metaExpr =
      status === "validated"
        ? `COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('validated_by', $4::text, 'validated_at', now())`
        : `COALESCE(metadata, '{}'::jsonb) - 'validated_by' - 'validated_at'`;
    const params: unknown[] = [status, id, userId];
    if (status === "validated") params.push(userId);
    const { rowCount } = await pool.query(
      `UPDATE agent_memory SET status = $1, metadata = ${metaExpr}, updated_at = now() WHERE id = $2 AND user_id = $3`,
      params,
    );
    if (rowCount === 0) return reply.status(404).send({ error: "Entrée introuvable" });
    return { success: true, status };
  });

  // --- Oublier une entrée (réversible : l'utilisateur garde le contrôle) ---
  app.delete("/api/agent/memory/:id", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return reply.status(400).send({ error: "id invalide" });
    const { rowCount } = await pool.query(
      "DELETE FROM agent_memory WHERE id = $1 AND user_id = $2",
      [id, userId],
    );
    if (rowCount === 0) return reply.status(404).send({ error: "Entrée introuvable" });
    return { success: true };
  });

  // --- Auto-amélioration : analyse les tâches récentes, propose des optimisations ---
  app.post("/api/agent/self-improve", { preHandler: requireUser, config: { rateLimit: { max: 5, timeWindow: "1 minute" } } }, async (request, reply) => {
    const userId = request.user!.id;

    // Runs simulés / à plan vide exclus : ils ne disent rien de l'exécution réelle.
    const { rows } = await pool.query(
      `SELECT payload, result, status, created_at FROM agent_tasks
       WHERE user_id = $1 AND task_type = 'goal' AND status IN ('completed', 'failed')
         AND (result -> 'simulated') IS DISTINCT FROM 'true'::jsonb
         AND (result -> 'empty_plan') IS DISTINCT FROM 'true'::jsonb
       ORDER BY created_at DESC LIMIT 20`,
      [userId],
    );
    if (rows.length === 0) {
      return reply.status(422).send({ error: "Pas encore assez d'historique d'exécution à analyser" });
    }

    const summary = rows
      .map((r, i) => {
        const goal = r.payload?.goal_meta?.goal ?? "(objectif inconnu)";
        const verdict = r.result?.evaluation?.verdict ?? r.status;
        const steps = (Array.isArray(r.result?.steps) ? r.result.steps : [])
          .map((s: { type: string; ok: boolean; duration_s?: number }) =>
            `${s.type}(ok=${s.ok}${s.duration_s !== undefined ? `,${s.duration_s}s` : ""})`,
          )
          .join(", ");
        return `Tâche ${i + 1} — objectif: "${goal}" | verdict: ${verdict} | étapes: [${steps}]`;
      })
      .join("\n");

    let report;
    try {
      report = await analyzePerformance(summary);
    } catch (e) {
      if (e instanceof ServiceError) return reply.status(e.status).send({ error: e.message });
      throw e;
    }

    // Chaque suggestion est PROPOSÉE (status='proposed') : elle ne nourrira la
    // planification qu'après validation explicite de l'utilisateur.
    for (const suggestion of report.suggestions) {
      await writeMemory(
        userId, "practice", GENERAL_GOAL, suggestion,
        { source: "self-improve" }, "optimization", "proposed",
      );
    }

    await logEvent(
      userId,
      "Agent",
      `Auto-amélioration : ${report.suggestions.length} optimisation(s) proposée(s) à valider (${rows.length} tâches analysées)`,
      "info",
    );

    return { success: true, tasks_analyzed: rows.length, report };
  });
}
