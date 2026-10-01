import type { FastifyInstance } from "fastify";
import { pool } from "../db";
import { requireUser } from "../auth";
import { analyzePerformance } from "../clients/iaClient";
import { logEvent } from "../services/logs";

// Mémoire d'exécution de l'agent : erreurs, solutions validées, bonnes pratiques.
// Réinjectée dans la planification (getMemoryContext) et enrichie après chaque
// objectif terminé (writeMemory, appelé depuis agentGoal.ts).

/** Contexte mémoire pertinent pour un objectif (mots-clés en commun), injecté dans le plan. */
export async function getMemoryContext(userId: string, goal: string): Promise<string | undefined> {
  const words = Array.from(
    new Set(
      goal
        .toLowerCase()
        .split(/[^a-zà-ÿ0-9]+/i)
        .filter((w) => w.length > 3),
    ),
  ).slice(0, 6);
  if (words.length === 0) return undefined;

  const conditions = words.map((_, i) => `goal ILIKE $${i + 2}`).join(" OR ");
  const params = [userId, ...words.map((w) => `%${w}%`)];
  // On n'injecte JAMAIS une optimisation seulement PROPOSÉE : seules les entrées
  // validées (ou les faits d'exécution : erreurs/solutions) nourrissent le plan.
  const { rows } = await pool.query(
    `SELECT type, goal, content FROM agent_memory
     WHERE user_id = $1 AND (${conditions})
       AND (status = 'validated' OR type IN ('error', 'solution'))
     ORDER BY created_at DESC LIMIT 5`,
    params,
  );
  if (rows.length === 0) return undefined;

  const lines = rows.map((r: { type: string; goal: string; content: string }) => {
    if (r.type === "error") {
      return `- [ÉCHEC PASSÉ] pour un objectif similaire (« ${r.goal} ») : ${r.content} — évite de répéter cette approche.`;
    }
    if (r.type === "solution") {
      return `- [SOLUTION VALIDÉE] pour un objectif similaire (« ${r.goal} ») : ${r.content}`;
    }
    return `- [BONNE PRATIQUE] ${r.content}`;
  });
  return `MÉMOIRE — expériences passées pertinentes :\n${lines.join("\n")}`;
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

/** Enregistre une expérience dans la mémoire (niveau + statut de validation). */
export async function writeMemory(
  userId: string,
  type: "error" | "solution" | "practice",
  goal: string,
  content: string,
  metadata: unknown = {},
  level: MemoryLevel = "workflow",
  status: MemoryStatus = "validated",
): Promise<void> {
  await pool.query(
    `INSERT INTO agent_memory (user_id, type, goal, content, metadata, level, status)
     VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7)`,
    [userId, type, goal, content, JSON.stringify(metadata), level, status],
  );
}

export async function agentMemoryRoutes(app: FastifyInstance): Promise<void> {
  // --- Lister sa mémoire (JWT), filtrable par niveau et statut ---
  app.get("/api/agent/memory", { preHandler: requireUser }, async (request) => {
    const userId = request.user!.id;
    const q = request.query as { level?: string; status?: string };
    const where: string[] = ["user_id = $1"];
    const params: unknown[] = [userId];
    let i = 2;
    if (q.level) { where.push(`level = $${i++}`); params.push(q.level); }
    if (q.status) { where.push(`status = $${i++}`); params.push(q.status); }
    const { rows } = await pool.query(
      `SELECT id, type, level, status, goal, content, created_at FROM agent_memory
       WHERE ${where.join(" AND ")} ORDER BY created_at DESC LIMIT 100`,
      params,
    );
    return { memory: rows };
  });

  // --- Écrire une entrée de mémoire à un niveau donné (JWT) ---
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
    if (!body.content) return reply.status(400).send({ error: "content requis" });
    await writeMemory(
      userId, body.type ?? "practice", body.goal ?? "(général)", body.content,
      body.metadata ?? {}, body.level ?? "workflow", body.status ?? "validated",
    );
    return { success: true };
  });

  // --- Valider / rejeter une entrée (l'utilisateur garde le contrôle) ---
  app.patch("/api/agent/memory/:id", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    const { status } = (request.body ?? {}) as { status?: MemoryStatus };
    if (!status || !["proposed", "validated", "rejected"].includes(status)) {
      return reply.status(400).send({ error: "status valide requis (proposed|validated|rejected)" });
    }
    const { rowCount } = await pool.query(
      "UPDATE agent_memory SET status = $1, updated_at = now() WHERE id = $2 AND user_id = $3",
      [status, id, userId],
    );
    if (rowCount === 0) return reply.status(404).send({ error: "Entrée introuvable" });
    return { success: true };
  });

  // --- Oublier une entrée (réversible : l'utilisateur garde le contrôle) ---
  app.delete("/api/agent/memory/:id", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { id } = request.params as { id: string };
    const { rowCount } = await pool.query(
      "DELETE FROM agent_memory WHERE id = $1 AND user_id = $2",
      [id, userId],
    );
    if (rowCount === 0) return reply.status(404).send({ error: "Entrée introuvable" });
    return { success: true };
  });

  // --- Auto-amélioration : analyse les tâches récentes, propose des optimisations ---
  app.post("/api/agent/self-improve", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;

    const { rows } = await pool.query(
      `SELECT payload, result, status, created_at FROM agent_tasks
       WHERE user_id = $1 AND task_type = 'goal' AND status IN ('completed', 'failed')
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
        const steps = (r.result?.steps ?? [])
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
      return reply.status(502).send({ error: (e as Error).message });
    }

    // Traçable ET validée : chaque suggestion est PROPOSÉE (status='proposed'), pas
    // encore appliquée. Elle ne nourrira la planification qu'après validation explicite.
    for (const suggestion of report.suggestions) {
      await writeMemory(
        userId, "practice", "(général)", suggestion,
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
