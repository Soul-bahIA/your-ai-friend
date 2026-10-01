// LOT 12 — codeurs en worktrees sur Postgres réel (critère §13) : 3 codeurs pris EN MÊME TEMPS
// par un runtime, une relecture QA (P1) par codeur, puis la fusion testée — jamais avant les
// relectures ; une relecture refusée échoue et bloque la fusion. Le runtime est simulé par les
// routes /api/v2/runtime (les vrais git/worktrees sont testés côté agent : test_lot12_git.py).
// Sauté sans TEST_DATABASE_URL.
import { randomBytes } from "node:crypto";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";

const DB_URL = (process.env.TEST_DATABASE_URL ?? "").trim();
const RUN = DB_URL !== "";
const TOKEN = randomBytes(32).toString("hex");
const U = "a0000000-0000-4000-8000-000000000c12";
if (RUN) {
  process.env.DATABASE_URL = DB_URL;
  process.env.DATABASE_SSL = "false";
  process.env.PG_SSL_CA = "";
  process.env.SOULBAH_ENV = "test";
  process.env.HOST = "127.0.0.1";
  process.env.AUTH_MODE = "dev-local";
  process.env.DEV_LOCAL_TOKEN = TOKEN;
  process.env.DEV_LOCAL_USER_ID = U;
  process.env.SOULBAH_APPROVAL_SECRET = randomBytes(32).toString("hex");
  process.env.IA_SERVICE_URL = "http://127.0.0.1:9";
}

type Pool = {
  query: (
    sql: string,
    values?: unknown[],
  ) => Promise<{ rows: Record<string, unknown>[]; rowCount: number | null }>;
  end: () => Promise<void>;
};
type Leased = { id: string; node_key: string; attempt: number };

describe.skipIf(!RUN)("worktrees et fusion testée (LOT 12)", () => {
  let app: FastifyInstance;
  let pool: Pool;
  let sched: typeof import("../../src/v2/scheduler/scheduler");
  let reviewer: typeof import("../../src/v2/evaluation/reviewer");
  const jwt = { authorization: `Bearer ${TOKEN}` };
  const rawKey = "sbk_" + randomBytes(32).toString("hex");
  const agent = { "x-agent-key": rawKey };
  let runtimeId = "";

  beforeAll(async () => {
    ({ pool } = (await import("../../src/db")) as unknown as { pool: Pool });
    const { hashKey } = await import("../../src/services/agentKeys");
    sched = await import("../../src/v2/scheduler/scheduler");
    reviewer = await import("../../src/v2/evaluation/reviewer");
    const { buildApp } = await import("../../src/app");
    app = await buildApp();
    await pool.query(
      "INSERT INTO auth.users (id, email) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
      [U, "worktrees@soulbah.local"],
    );
    await pool.query(
      "INSERT INTO agent_keys (user_id, key_hash, label, allowed_dirs) VALUES ($1, $2, 'PC code', $3::jsonb)",
      [U, hashKey(rawKey), JSON.stringify(["C:\\w"])],
    );
    const reg = await app.inject({
      method: "POST",
      url: "/api/v2/runtime/register",
      headers: agent,
      payload: { hostname: "pc", version: "2.0.0", protocol: 1, max_slots: 8 },
    });
    runtimeId = reg.json().runtime_id;
  });

  afterAll(async () => {
    await pool.query("DELETE FROM soulbah.sessions WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM soulbah.runtimes WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM soulbah.permissions WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM agent_keys WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM user_roles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM profiles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM auth.users WHERE id = $1", [U]);
    await app.close();
    await pool.end();
  });

  beforeEach(async () => {
    const active = await pool.query(
      "SELECT id FROM soulbah.sessions WHERE user_id = $1 AND status IN ('RUNNING', 'AWAITING_APPROVAL', 'DRAFT', 'PAUSED')",
      [U],
    );
    for (const r of active.rows)
      await app.inject({
        method: "POST",
        url: `/api/v2/sessions/${r.id}/cancel`,
        headers: jwt,
        payload: {},
      });
  });

  const lease = async (slots = 8) =>
    (
      await app.inject({
        method: "POST",
        url: "/api/v2/runtime/lease",
        headers: agent,
        payload: { runtime_id: runtimeId, slots },
      })
    ).json().tasks as Leased[];
  const action = (t: Leased, body: object) =>
    app.inject({
      method: "POST",
      url: `/api/v2/runtime/tasks/${t.id}/actions`,
      headers: agent,
      payload: { runtime_id: runtimeId, attempt: t.attempt, ...body },
    });
  const result = (t: Leased) =>
    app.inject({
      method: "POST",
      url: `/api/v2/runtime/tasks/${t.id}/result`,
      headers: agent,
      payload: {
        runtime_id: runtimeId,
        attempt: t.attempt,
        result: { ok: true },
      },
    });
  const statusOf = async (sid: string) =>
    Object.fromEntries(
      (
        await pool.query(
          "SELECT node_key, status FROM soulbah.tasks WHERE session_id = $1",
          [sid],
        )
      ).rows.map((r) => [r.node_key, r.status]),
    );

  /** Le runtime « exécute » un codeur : worktree, fichier écrit, commit (preuves typées). */
  async function runCoder(t: Leased) {
    const wt = `C:\\w\\wt\\${t.node_key}`;
    const ev = (step_index: number, tool: string, evidence: object[]) =>
      action(t, { step_index, tool, status: "verified", evidence });
    expect(
      (
        await ev(0, "git_worktree", [
          { kind: "file_path", confidence: "medium", value: wt },
        ])
      ).statusCode,
    ).toBeLessThan(300);
    await ev(1, "write_file", [
      { kind: "file_path", confidence: "medium", value: `${wt}\\mod.py` },
    ]);
    await ev(2, "git_commit", [
      { kind: "exit_code", confidence: "high", value: 0 },
      {
        kind: "command_output",
        confidence: "medium",
        value: `soulbah/s1/${t.node_key} 0123abcd soulbah:${t.node_key} ${t.node_key}`,
      },
    ]);
    const r = await result(t);
    expect(r.json().status, r.body).toBe("COMPLETED");
  }

  async function planned(params: object) {
    const s = await app.inject({
      method: "POST",
      url: "/api/v2/sessions",
      headers: jwt,
      payload: { goal: "coder en parallèle" },
    });
    const sid = s.json().session.id as string;
    const p = await app.inject({
      method: "POST",
      url: `/api/v2/sessions/${sid}/propose`,
      headers: jwt,
      payload: { template: "code_parallel", params },
    });
    expect(p.statusCode, p.body).toBe(200);
    await app.inject({
      method: "POST",
      url: `/api/v2/sessions/${sid}/approve`,
      headers: jwt,
    });
    await sched.tick();
    return sid;
  }

  const PARAMS = {
    repo: "C:\\w\\app",
    worktrees_dir: "C:\\w\\wt",
    session_slug: "s1",
    test: { program: "npm", args: ["test"] },
    tasks: ["t1", "t2", "t3"].map((k) => ({
      key: k,
      title: k,
      steps: [
        {
          type: "write_file",
          path: `C:\\w\\wt\\${k}\\mod.py`,
          content: "x = 1",
        },
      ],
    })),
  };

  it("3 codeurs en même temps → 3 relectures QA (P1) → fusion testée → mission COMPLETED", async () => {
    const sid = await planned(PARAMS);
    // Les relectures désignent bien la tâche relue (clé → identifiant résolu à la pose du plan).
    const rows = (
      await pool.query(
        "SELECT id, node_key, spec FROM soulbah.tasks WHERE session_id = $1",
        [sid],
      )
    ).rows;
    const idOf = new Map(
      rows.map((r) => [r.node_key as string, r.id as string]),
    );
    for (const k of ["t1", "t2", "t3"])
      expect(
        (
          rows.find((r) => r.node_key === `review_${k}`)!.spec as {
            review_of: string;
          }
        ).review_of,
      ).toBe(idOf.get(k));

    const first = await lease();
    expect(first.map((t) => t.node_key).sort()).toEqual(["t1", "t2", "t3"]); // les trois en parallèle, rien d'autre
    const running = (
      await pool.query(
        "SELECT count(*)::int AS n FROM soulbah.tasks WHERE session_id = $1 AND status = 'RUNNING'",
        [sid],
      )
    ).rows[0].n;
    expect(Number(running)).toBe(3);
    for (const t of first) await runCoder(t);

    await sched.tick();
    expect(await lease()).toEqual([]); // fusion jamais avant les relectures ; relectures jamais au runtime
    expect((await statusOf(sid)).merge).toBe("PENDING");
    expect(await reviewer.runReviews({ limit: 10 })).toMatchObject({
      reviewed: 3,
      errors: 0,
    });
    const afterReview = await statusOf(sid);
    for (const k of ["t1", "t2", "t3"])
      expect(afterReview[`review_${k}`]).toBe("COMPLETED");

    await sched.tick();
    const merge = await lease();
    expect(merge.map((t) => t.node_key)).toEqual(["merge"]);
    for (const [i, k] of ["t1", "t2", "t3"].entries()) {
      await action(merge[0], {
        step_index: i,
        tool: "git_merge",
        status: "verified",
        evidence: [
          { kind: "exit_code", confidence: "high", value: 0 },
          {
            kind: "command_output",
            confidence: "medium",
            value: `soulbah/s1/integration f00${i} ← soulbah/s1/${k}`,
          },
          {
            kind: "test_report",
            confidence: "high",
            value: { passed: true, returncode: 0, program: "npm" },
          },
        ],
      });
    }
    const done = await result(merge[0]);
    expect(done.json().status, done.body).toBe("COMPLETED");
    const ev = (
      await pool.query(
        "SELECT verdict, results FROM soulbah.evaluations WHERE task_id = $1",
        [merge[0].id],
      )
    ).rows[0];
    expect(ev.verdict).toBe("success");
    await sched.tick();
    expect(
      (
        await app.inject({
          method: "GET",
          url: `/api/v2/sessions/${sid}`,
          headers: jwt,
        })
      ).json().session.status,
    ).toBe("COMPLETED");
  });

  it("fusion avec tests rouges : la tâche de fusion n'est jamais COMPLETED", async () => {
    const sid = await planned({ ...PARAMS, tasks: PARAMS.tasks.slice(0, 1) });
    const [t1] = await lease();
    await runCoder(t1);
    await sched.tick();
    await reviewer.runReviews();
    await sched.tick();
    const [merge] = await lease();
    expect(merge.node_key).toBe("merge");
    // Le skill git_merge a annulé la fusion : étape en échec, rapport de tests rouge.
    await action(merge, {
      step_index: 0,
      tool: "git_merge",
      status: "failed",
      evidence: [
        {
          kind: "test_report",
          confidence: "high",
          value: { passed: false, returncode: 1 },
        },
      ],
    });
    const r = await result(merge);
    expect(r.json().status).not.toBe("COMPLETED");
    expect((await statusOf(sid)).merge).not.toBe("COMPLETED");
  });

  it("relecture refusée (grille rejetée) → relecture FAILED → fusion BLOQUÉE", async () => {
    const s = await app.inject({
      method: "POST",
      url: "/api/v2/sessions",
      headers: jwt,
      payload: {
        goal: "relecture stricte",
        plan: {
          nodes: [
            {
              key: "t1",
              title: "Coder",
              role: "coder",
              security_level: "L2",
              spec: {
                steps: [
                  {
                    type: "git_worktree",
                    repo: "C:\\w\\app",
                    path: "C:\\w\\wt\\t1",
                    branch: "soulbah/s1/t1",
                  },
                  {
                    type: "write_file",
                    path: "C:\\w\\wt\\t1\\mod.py",
                    content: "x",
                  },
                  {
                    type: "git_commit",
                    cwd: "C:\\w\\wt\\t1",
                    message: "soulbah:t1 t1",
                  },
                ],
              },
              acceptance_criteria: [
                {
                  type: "git_branch_contains",
                  branch: "soulbah/s1/t1",
                  text: "soulbah:t1",
                },
              ],
            },
            {
              key: "review_t1",
              title: "Relire",
              role: "qa_reviewer",
              security_level: "L0",
              spec: {
                review_of_key: "t1",
                request: { rubric: "Le code respecte-t-il les conventions ?" },
              },
            },
            {
              key: "merge",
              title: "Fusionner",
              role: "coder",
              security_level: "L2",
              spec: {
                steps: [
                  {
                    type: "git_merge",
                    repo: "C:\\w\\app",
                    path: "C:\\w\\wt\\integration",
                    source: "soulbah/s1/t1",
                    target: "soulbah/s1/integration",
                    test_program: "npm",
                    test_args: ["test"],
                  },
                ],
              },
              acceptance_criteria: [{ type: "tests_pass" }],
            },
          ],
          edges: [
            { from: "t1", to: "review_t1" },
            { from: "review_t1", to: "merge" },
          ],
        },
      },
    });
    expect(s.statusCode, s.body).toBe(201);
    const sid = s.json().session.id as string;
    await app.inject({
      method: "POST",
      url: `/api/v2/sessions/${sid}/approve`,
      headers: jwt,
    });
    await sched.tick();
    const [t1] = await lease();
    await runCoder(t1);
    await sched.tick();
    const rep = await reviewer.runReviews({
      judge: async () => ({
        passed: false,
        reason: "conventions non respectées",
      }),
    });
    expect(rep.reviewed).toBe(1);
    expect((await statusOf(sid)).review_t1).toBe("FAILED");
    await sched.tick();
    expect((await statusOf(sid)).merge).toBe("BLOCKED");
    expect(await lease()).toEqual([]);
  });

  it("plan avec fusion sans relecture : refusé (422), aucune tâche", async () => {
    const s = await app.inject({
      method: "POST",
      url: "/api/v2/sessions",
      headers: jwt,
      payload: { goal: "fusion directe" },
    });
    const sid = s.json().session.id as string;
    const r = await app.inject({
      method: "POST",
      url: `/api/v2/sessions/${sid}/plan`,
      headers: jwt,
      payload: {
        plan: {
          nodes: [
            {
              key: "merge",
              title: "Fusionner",
              role: "coder",
              security_level: "L2",
              spec: {
                steps: [
                  {
                    type: "git_merge",
                    repo: "C:\\w\\app",
                    path: "C:\\w\\wt\\integration",
                    source: "soulbah/s1/t1",
                    target: "soulbah/s1/integration",
                  },
                ],
              },
              acceptance_criteria: [{ type: "tests_pass" }],
            },
          ],
          edges: [],
        },
      },
    });
    expect(r.statusCode).toBe(422);
    expect(r.json().errors.join(" ")).toContain(
      "fusion git sans relecture QA préalable",
    );
    expect(
      Number(
        (
          await pool.query(
            "SELECT count(*)::int AS n FROM soulbah.tasks WHERE session_id = $1",
            [sid],
          )
        ).rows[0].n,
      ),
    ).toBe(0);
  });
});
