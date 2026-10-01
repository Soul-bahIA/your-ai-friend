// LOT 10 — évaluation, QA et chaos sur Postgres réel. Critères §13 : un run simulé ou vide
// n'est jamais COMPLETED ; node tué en VALIDATING → une seule évaluation ; coupure de la base →
// aucun bail récupéré avant une durée de bail (0 doublon). Sauté sans TEST_DATABASE_URL.
import { randomBytes } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";

const DB_URL = (process.env.TEST_DATABASE_URL ?? "").trim();
const RUN = DB_URL !== "";
const TOKEN = randomBytes(32).toString("hex");
const U = "a0000000-0000-4000-8000-0000000000ca";
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

type Pool = { query: (sql: string, values?: unknown[]) => Promise<{ rows: Record<string, unknown>[]; rowCount: number | null }>; end: () => Promise<void> };
type Node = Record<string, unknown>;

describe.skipIf(!RUN)("évaluation par critères, QA et chaos (LOT 10)", () => {
  let app: FastifyInstance;
  let pool: Pool;
  let sched: typeof import("../../src/v2/scheduler/scheduler");
  let engine: typeof import("../../src/v2/evaluation/engine");
  const jwt = { authorization: `Bearer ${TOKEN}` };
  const rawKey = "sbk_" + randomBytes(32).toString("hex");
  const agent = { "x-agent-key": rawKey };
  let runtimeId = "";

  beforeAll(async () => {
    ({ pool } = (await import("../../src/db")) as unknown as { pool: Pool });
    const { hashKey } = await import("../../src/services/agentKeys");
    sched = await import("../../src/v2/scheduler/scheduler");
    engine = await import("../../src/v2/evaluation/engine");
    const { buildApp } = await import("../../src/app");
    app = await buildApp({ mediaDir: path.join(os.tmpdir(), "soulbah-pg-eval-media") });
    await pool.query("INSERT INTO auth.users (id, email) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING", [U, "eval@soulbah.local"]);
    await pool.query("INSERT INTO agent_keys (user_id, key_hash, label, allowed_dirs) VALUES ($1, $2, 'PC eval', $3::jsonb)", [U, hashKey(rawKey), JSON.stringify(["C:\\w"])]);
    const reg = await app.inject({ method: "POST", url: "/api/v2/runtime/register", headers: agent, payload: { hostname: "pc", version: "2.0.0", protocol: 1, max_slots: 8 } });
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

  /** Session approuvée, tâches promues, baux pris : renvoie les tâches dans l'ordre des nœuds. */
  async function running(nodes: Node[], simulated = false) {
    // Chaque scénario part d'une file vide : les missions précédentes encore actives sont annulées
    // (sinon leurs tâches READY seraient servies en premier par le bail).
    const active = await pool.query("SELECT id FROM soulbah.sessions WHERE user_id = $1 AND status IN ('RUNNING', 'AWAITING_APPROVAL', 'DRAFT', 'PAUSED')", [U]);
    for (const r of active.rows) await app.inject({ method: "POST", url: `/api/v2/sessions/${r.id}/cancel`, headers: jwt, payload: {} });
    const s = await app.inject({ method: "POST", url: "/api/v2/sessions", headers: jwt, payload: { goal: "évaluation", simulated, plan: { nodes } } });
    expect(s.statusCode, s.body).toBe(201);
    await app.inject({ method: "POST", url: `/api/v2/sessions/${s.json().session.id}/approve`, headers: jwt });
    await sched.tick();
    const l = await app.inject({ method: "POST", url: "/api/v2/runtime/lease", headers: agent, payload: { runtime_id: runtimeId, slots: nodes.length } });
    const byKey = new Map((l.json().tasks as { id: string; node_key: string; attempt: number }[]).map((t) => [t.node_key, t]));
    return nodes.map((n) => byKey.get(n.key as string)!);
  }
  const action = (taskId: string, body: object) =>
    app.inject({ method: "POST", url: `/api/v2/runtime/tasks/${taskId}/actions`, headers: agent, payload: { runtime_id: runtimeId, attempt: 1, ...body } });
  const result = (taskId: string, res: object = { ok: true }, simulated = false) =>
    app.inject({ method: "POST", url: `/api/v2/runtime/tasks/${taskId}/result`, headers: agent, payload: { runtime_id: runtimeId, attempt: 1, result: res, simulated } });
  const status = async (id: string) => (await pool.query("SELECT status, error, retry_count FROM soulbah.tasks WHERE id = $1", [id])).rows[0];
  const evaluations = async (id: string) => (await pool.query("SELECT attempt, verdict, confidence, action_taken, evaluator, results FROM soulbah.evaluations WHERE task_id = $1", [id])).rows;

  it("critère file_exists satisfait par une preuve → COMPLETED, évaluation enregistrée et visible", async () => {
    const [t] = await running([{ key: "w", title: "écrire", role: "coder", security_level: "L1", spec: { steps: [{ type: "move_file", src: "C:\\w\\a", dest: "C:\\w\\b" }] }, acceptance_criteria: [{ type: "file_exists", path: "C:\\w\\b" }] }]);
    await action(t.id, { step_index: 0, tool: "move_file", status: "executed", evidence: [{ kind: "file_path", confidence: "medium", value: "C:\\w\\b" }] });
    await action(t.id, { step_index: 0, tool: "move_file", status: "verified" });
    const r = await result(t.id);
    expect(r.json().status).toBe("COMPLETED");
    const ev = await evaluations(t.id);
    expect(ev).toHaveLength(1);
    expect(ev[0]).toMatchObject({ attempt: 1, verdict: "success", confidence: "medium", action_taken: "completed", evaluator: "rules" });
    const detail = await app.inject({ method: "GET", url: `/api/v2/tasks/${t.id}`, headers: jwt });
    expect(detail.json().evaluations[0].verdict).toBe("success");
  });

  it("critère non satisfait : étapes non idempotentes → FAILED (humain) ; idempotentes → RETRYING", async () => {
    const [a, b] = await running([
      { key: "a", title: "déplacer", role: "coder", security_level: "L1", spec: { steps: [{ type: "move_file", src: "C:\\w\\a", dest: "C:\\w\\c" }] }, acceptance_criteria: [{ type: "file_exists", path: "C:\\w\\absent" }] },
      { key: "b", title: "lire", role: "coder", security_level: "L1", spec: { steps: [{ type: "read_file", path: "C:\\w\\a" }] }, acceptance_criteria: [{ type: "file_exists", path: "C:\\w\\absent" }] },
    ]);
    await action(a.id, { step_index: 0, tool: "move_file", status: "verified" });
    await action(b.id, { step_index: 0, tool: "read_file", status: "verified", evidence: [{ kind: "file_content", confidence: "high", sha256: "c".repeat(64) }] });
    expect((await result(a.id)).json().status).toBe("FAILED");
    expect((await evaluations(a.id))[0]).toMatchObject({ verdict: "failure", action_taken: "failed_needs_human" });
    expect((await result(b.id)).json().status).toBe("RETRYING");
    expect(await status(b.id)).toMatchObject({ status: "RETRYING", retry_count: 1 });
    expect((await evaluations(b.id))[0].action_taken).toBe("retry_scheduled");
  });

  it("un run simulé ou vide n'est JAMAIS COMPLETED", async () => {
    const [sim] = await running([{ key: "s", title: "simulé", role: "coder", security_level: "L1", spec: { steps: [{ type: "wait" }] } }], true);
    await action(sim.id, { step_index: 0, tool: "wait", status: "simulated" });
    expect((await result(sim.id, { ok: true }, true)).json().status).toBe("FAILED");
    expect((await evaluations(sim.id))[0]).toMatchObject({ verdict: "not_evaluable", action_taken: "failed_not_evaluable" });

    // Résultat « simulé » annoncé par un runtime pour une tâche réelle : idem.
    const [fake] = await running([{ key: "f", title: "faux", role: "coder", security_level: "L1", spec: { steps: [{ type: "wait" }] } }]);
    await action(fake.id, { step_index: 0, tool: "wait", status: "verified" });
    expect((await result(fake.id, { ok: true, simulated: true })).json().status).toBe("FAILED");

    // Plan avec étapes mais aucune exécutée : jamais COMPLETED.
    const [empty] = await running([{ key: "e", title: "vide", role: "coder", security_level: "L1", spec: { steps: [{ type: "wait" }] } }]);
    expect((await result(empty.id)).json().status).not.toBe("COMPLETED");
    expect((await evaluations(empty.id))[0].verdict).toBe("failure");
    // aucune ligne COMPLETED parmi ces trois tâches, dans la base comme dans l'audit
    const done = await pool.query("SELECT count(*)::int AS n FROM soulbah.tasks WHERE id = ANY($1::uuid[]) AND status = 'COMPLETED'", [[sim.id, fake.id, empty.id]]);
    expect(Number(done.rows[0].n)).toBe(0);
  });

  it("tâche L2 sans preuve ≥ medium → échec ; avec une preuve medium → COMPLETED", async () => {
    // Deux nœuds qui pilotent le bureau : ressource exclusive desktop.input — jamais en même temps.
    const node = (key: string) => ({ key, title: "taper", role: "desktop_operator", security_level: "L2", spec: { steps: [{ type: "screenshot" }, { type: "type_text", text: "x" }] }, acceptance_criteria: [{ type: "ui_element_state", window_title: "Bloc-notes" }] });
    const both = await running([node("weak"), node("strong")]);
    expect(both.filter(Boolean)).toHaveLength(1);
    const [weak] = await running([node("weak")]);
    await action(weak.id, { step_index: 0, tool: "type_text", status: "verified", evidence: [{ kind: "self_report", confidence: "none" }] });
    expect((await result(weak.id)).json().status).toBe("FAILED");
    const [strong] = await running([node("strong")]);
    await action(strong.id, { step_index: 0, tool: "type_text", status: "verified", evidence: [{ kind: "self_report", confidence: "none" }] });
    await action(strong.id, { step_index: 1, tool: "window", status: "verified", evidence: [{ kind: "window_title", confidence: "medium", value: "Bloc-notes" }] });
    expect((await result(strong.id)).json().status).toBe("COMPLETED");
  });

  it("VALIDATING durable : crash pendant le jugement → rollback ; 6 évaluateurs concurrents → UNE seule évaluation", async () => {
    const [t] = await running([{ key: "llm", title: "rédiger", role: "coder", security_level: "L1", spec: { steps: [{ type: "wait" }] }, acceptance_criteria: [{ type: "llm_rubric", rubric: "le rapport est clair" }] }]);
    await action(t.id, { step_index: 0, tool: "wait", status: "verified" });
    expect((await result(t.id)).json().status).toBe("VALIDATING"); // jugement de modèle requis : reste en VALIDATING

    // « node tué » au milieu de l'évaluation : le juge lève, la transaction est annulée.
    const crash = await engine.runEvaluations({ judge: async () => { throw new Error("node tué"); } });
    expect(crash.errors).toBeGreaterThanOrEqual(1);
    expect((await status(t.id)).status).toBe("VALIDATING");
    expect(await evaluations(t.id)).toHaveLength(0);

    // Sans juge (python-ia absent), la tâche attend : jamais conclue au hasard.
    expect((await engine.runEvaluations()).evaluated).toBe(0);
    expect((await status(t.id)).status).toBe("VALIDATING");

    let calls = 0;
    const judge = async () => {
      calls++;
      await new Promise((r) => setTimeout(r, 50));
      return { passed: true, reason: "clair" };
    };
    const reports = await Promise.all(Array.from({ length: 6 }, () => engine.runEvaluations({ judge })));
    expect(reports.reduce((n, r) => n + r.evaluated, 0)).toBe(1);
    expect(calls).toBe(1); // verrou de ligne : un seul évaluateur a jugé
    expect((await status(t.id)).status).toBe("COMPLETED");
    const ev = await evaluations(t.id);
    expect(ev).toHaveLength(1);
    expect(ev[0]).toMatchObject({ verdict: "success", confidence: "low", evaluator: "llm" });
    const trans = await pool.query("SELECT count(*)::int AS n FROM soulbah.audit_logs WHERE task_id = $1 AND action = 'task.transition' AND data ->> 'from' = 'VALIDATING'", [t.id]);
    expect(Number(trans.rows[0].n)).toBe(1);
  });

  it("chaos : après une coupure de la base, aucun bail expiré n'est récupéré avant une durée de bail", async () => {
    const [t] = await running([{ key: "long", title: "long", role: "coder", security_level: "L1", spec: { steps: [{ type: "wait" }] } }]);
    // La base a été coupée : le runtime n'a pas pu prolonger son bail, qui a expiré.
    await pool.query("UPDATE soulbah.tasks SET lease_expires_at = now() - interval '30 seconds' WHERE id = $1", [t.id]);
    const grace = new Date(Date.now() + 60_000);
    expect((await sched.tick({ reapNotBefore: grace })).reaped).toBe(0);
    expect((await status(t.id)).status).toBe("RUNNING");
    // Le runtime se manifeste dans la grâce : son keepalive prolonge le bail, rien n'est rejoué.
    const ka = await app.inject({ method: "POST", url: "/api/v2/runtime/keepalive", headers: agent, payload: { runtime_id: runtimeId, tasks: [{ task_id: t.id, attempt: 1 }] } });
    expect(ka.json().tasks[0].control).toBe("continue");
    expect((await sched.tick()).reaped).toBe(0);
    // Sans signe de vie au-delà de la grâce : récupéré une seule fois (RETRYING), pas de second bail en double.
    await pool.query("UPDATE soulbah.tasks SET lease_expires_at = now() - interval '1 second' WHERE id = $1", [t.id]);
    expect((await sched.tick({ reapNotBefore: new Date(Date.now() - 1) })).reaped).toBe(1);
    expect((await status(t.id)).status).toBe("RETRYING");
    const late = await result(t.id);
    expect(late.statusCode).toBe(409); // le résultat tardif de l'ancienne tentative est refusé
  });
});
