// Routes de la file agent via fastify.inject, avec une couche de requêtes simulée.
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { fakeDb } from "./helpers/fakeDb";

vi.mock("../src/db.js", async () => (await import("./helpers/fakeDb")).dbMock);
vi.mock("../src/auth.js", async (importOriginal) => (await import("./helpers/authMock")).mockAuth(await importOriginal()));
vi.mock("../src/clients/iaClient.js", async (importOriginal) => ({
  ...(await importOriginal<object>()),
  evaluateGoal: vi.fn(async () => ({ verdict: "success", reason: "ok", corrective_steps: [] })),
}));

const { buildApp } = await import("../src/app");
const { drainBackgroundJobs } = await import("../src/services/backgroundJobs");
const iaClient = await import("../src/clients/iaClient");

const U = "22222222-2222-4222-8222-222222222222";
const OTHER = "99999999-9999-4999-8999-999999999999";
const T = "11111111-1111-4111-8111-111111111111";
const K = "33333333-3333-4333-8333-333333333333";
const K2 = "44444444-4444-4444-8444-444444444444";
const user = { "x-test-user": U };
const agent = { "x-test-agent-user": U, "x-test-agent-key": K };

let app: FastifyInstance;
beforeAll(async () => {
  app = await buildApp({ mediaDir: path.join(os.tmpdir(), "soulbah-test-media") });
});
afterAll(async () => {
  await app.close();
});
beforeEach(() => {
  fakeDb.reset();
  vi.mocked(iaClient.evaluateGoal).mockClear();
});

describe("POST /api/agent-tasks/:id/cancel (contrat §2, S9)", () => {
  it("pending → cancelled immédiatement (+ évènement)", async () => {
    fakeDb.on(/UPDATE agent_tasks SET\s+status = CASE/, { rows: [{ id: T, status: "cancelled", control: "none" }] });
    const r = await app.inject({ method: "POST", url: `/api/agent-tasks/${T}/cancel`, headers: user });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toMatchObject({ success: true, status: "cancelled", control: "none" });
    expect(fakeDb.find(/INSERT INTO agent_events/)[0].values).toContain("task_cancelled");
  });

  it("in_progress → control 'stop' (l'agent finira en 'cancelled')", async () => {
    fakeDb.on(/UPDATE agent_tasks SET\s+status = CASE/, { rows: [{ id: T, status: "in_progress", control: "stop" }] });
    const r = await app.inject({ method: "POST", url: `/api/agent-tasks/${T}/cancel`, headers: user });
    expect(r.json()).toMatchObject({ success: true, status: "in_progress", control: "stop", task: { id: T, control: "stop" } });
  });

  it("terminée → 409 ; inexistante → 404 ; sans JWT → 401", async () => {
    fakeDb.on(/SELECT status FROM agent_tasks/, { rows: [{ status: "completed" }] });
    expect((await app.inject({ method: "POST", url: `/api/agent-tasks/${T}/cancel`, headers: user })).statusCode).toBe(409);
    fakeDb.reset();
    expect((await app.inject({ method: "POST", url: `/api/agent-tasks/${T}/cancel`, headers: user })).statusCode).toBe(404);
    expect((await app.inject({ method: "POST", url: `/api/agent-tasks/${T}/cancel` })).statusCode).toBe(401);
  });
});

describe("410 pour une tâche disparue (contrat §3)", () => {
  it("GET /:id/control (agent) → 410 {error:'gone'}", async () => {
    const r = await app.inject({ method: "GET", url: `/api/agent-tasks/${T}/control`, headers: agent });
    expect(r.statusCode).toBe(410);
    expect(r.json()).toMatchObject({ error: "gone" });
  });

  it("POST /event et heartbeat → 410", async () => {
    for (const type of ["step_started", "heartbeat"]) {
      const r = await app.inject({
        method: "POST",
        url: "/api/agent-tasks/event",
        headers: agent,
        payload: { task_id: T, type, attempt: 0 },
      });
      expect(r.statusCode).toBe(410);
      expect(r.json().error).toBe("gone");
    }
  });

  it("POST /update (final et claim) → 410 ; claim d'une tâche existante déjà prise → 409", async () => {
    const fin = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/update",
      headers: agent,
      payload: { task_id: T, status: "failed", attempt: 0 },
    });
    expect(fin.statusCode).toBe(410);
    const claim = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/update",
      headers: agent,
      payload: { task_id: T, status: "in_progress", attempt: 0 },
    });
    expect(claim.statusCode).toBe(410);
    fakeDb.on(/SELECT 1 FROM agent_tasks/, { rows: [{ "?column?": 1 }] });
    const taken = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/update",
      headers: agent,
      payload: { task_id: T, status: "in_progress", attempt: 0 },
    });
    expect(taken.statusCode).toBe(409);
  });
});

describe("POST /update : final 'cancelled' et évaluation", () => {
  it("'cancelled' accepté comme terminal avec garde attempt, JAMAIS évalué", async () => {
    fakeDb.on(/^UPDATE agent_tasks SET status = \$1/, { rows: [{ id: T, status: "cancelled", requeue_count: 1 }] });
    const r = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/update",
      headers: agent,
      payload: { task_id: T, status: "cancelled", attempt: 1, result: { cancelled: true } },
    });
    expect(r.statusCode).toBe(200);
    const upd = fakeDb.find(/^UPDATE agent_tasks SET status = \$1/)[0];
    expect(upd.sql).toContain("requeue_count = $");
    expect(upd.values).toContain(1);
    await drainBackgroundJobs(1000);
    expect(fakeDb.find(/SELECT payload, result, status, control/)).toHaveLength(0);
    expect(iaClient.evaluateGoal).not.toHaveBeenCalled();
  });

  it("'completed' : captures retirées du résultat stocké, dernières captures passées à l'évaluation", async () => {
    fakeDb.on(/^UPDATE agent_tasks SET status = \$1/, { rows: [{ id: T, status: "completed", requeue_count: 0 }] });
    fakeDb.on(/SELECT payload, result, status, control/, {
      rows: [{ status: "completed", control: "none", payload: { steps: [{ type: "wait" }], goal_meta: { goal: "g", attempt: 1, max_attempts: 3 } }, result: { steps: [{ type: "wait", ok: true, detail: "ok" }] }, target_agent_key_id: K }],
    });
    fakeDb.on(/evaluation_status', 'running'/, { rows: [{ id: T }] });
    const r = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/update",
      headers: agent,
      payload: {
        task_id: T,
        status: "completed",
        attempt: 0,
        result: { steps: [1, 2, 3, 4].map((i) => ({ type: "screenshot", ok: true, data: { image_b64: `IMG${i}` } })) },
      },
    });
    expect(r.statusCode).toBe(200);
    const stored = fakeDb.find(/^UPDATE agent_tasks SET status = \$1/)[0].values[1] as string;
    expect(stored).not.toContain("IMG");
    expect(stored).toContain("image_omitted");
    await drainBackgroundJobs(2000);
    expect(iaClient.evaluateGoal).toHaveBeenCalledTimes(1);
    expect(vi.mocked(iaClient.evaluateGoal).mock.calls[0][3]).toEqual(["IMG2", "IMG3", "IMG4"]);
  });
});

describe("POST /api/agent-tasks/:id/approve (contrat §6)", () => {
  it("approuve une correction en attente → 200", async () => {
    const payload = { steps: [{ type: "wait" }], goal_meta: { goal: "g", awaiting_approval: false } };
    fakeDb.on(/awaiting_approval}', 'false'::jsonb/, { rows: [{ id: T, status: "pending", control: "none", payload }] });
    const r = await app.inject({ method: "POST", url: `/api/agent-tasks/${T}/approve`, headers: user });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toMatchObject({ success: true, task_id: T, task: { id: T, status: "pending", payload } });
    expect(r.json().task.payload.goal_meta.awaiting_approval).toBe(false);
  });

  it("pas en attente → 409 ; inexistante → 404", async () => {
    fakeDb.on(/SELECT status FROM agent_tasks/, { rows: [{ status: "pending" }] });
    expect((await app.inject({ method: "POST", url: `/api/agent-tasks/${T}/approve`, headers: user })).statusCode).toBe(409);
    fakeDb.reset();
    expect((await app.inject({ method: "POST", url: `/api/agent-tasks/${T}/approve`, headers: user })).statusCode).toBe(404);
  });
});

describe("DELETE /api/agent-tasks/:id", () => {
  it("terminée → 204 ; active → 409 ; inexistante → 404", async () => {
    fakeDb.on(/DELETE FROM agent_tasks/, { rows: [{ id: T }] });
    const ok = await app.inject({ method: "DELETE", url: `/api/agent-tasks/${T}`, headers: user });
    expect(ok.statusCode).toBe(204);
    expect(fakeDb.find(/DELETE FROM agent_tasks/)[0].sql).toContain("status IN ('completed', 'failed', 'cancelled')");
    fakeDb.reset();
    fakeDb.on(/SELECT status FROM agent_tasks/, { rows: [{ status: "in_progress" }] });
    const active = await app.inject({ method: "DELETE", url: `/api/agent-tasks/${T}`, headers: user });
    expect(active.statusCode).toBe(409);
    fakeDb.reset();
    expect((await app.inject({ method: "DELETE", url: `/api/agent-tasks/${T}`, headers: user })).statusCode).toBe(404);
  });
});

describe("GET /api/agent-tasks/poll (contrat §7)", () => {
  it("filtre par clé appelante et exclut awaiting_approval ; plus de remise en file dans le poll", async () => {
    fakeDb.on(/FROM agent_tasks\s+WHERE user_id = \$1 AND status = 'pending'/, { rows: [{ id: T }] });
    const r = await app.inject({ method: "GET", url: "/api/agent-tasks/poll", headers: agent });
    expect(r.json()).toEqual({ tasks: [{ id: T }] });
    const q = fakeDb.calls[0];
    expect(q.values).toEqual([U, K]);
    expect(q.sql).toContain("target_agent_key_id = $2::uuid");
    expect(q.sql).toContain("awaiting_approval");
    expect(fakeDb.find(/requeue_count = requeue_count \+ 1/)).toHaveLength(0);
  });
});

describe("captures (contrat §8, T20)", () => {
  it("l'image n'est jamais insérée en base ; servie au propriétaire seulement", async () => {
    fakeDb.on(/UPDATE agent_tasks SET updated_at = now\(\)/, { rows: [{ id: T }] });
    const r = await app.inject({
      method: "POST",
      url: "/api/agent-tasks/event",
      headers: agent,
      payload: { task_id: T, type: "screenshot", attempt: 0, data: { index: 2, image_b64: "QUJD", media_type: "image/png", source: "formation" } },
    });
    expect(r.statusCode).toBe(200);
    const ins = fakeDb.find(/INSERT INTO agent_events/)[0];
    const data = JSON.parse(ins.values[4] as string);
    expect(data).toEqual({ index: 2, media_type: "image/png", has_image: true, source: "agent" });

    const mine = await app.inject({ method: "GET", url: `/api/agent-tasks/${T}/screenshot`, headers: user });
    expect(mine.statusCode).toBe(200);
    expect(mine.json()).toMatchObject({ image_b64: "QUJD", mime: "image/png" });
    expect(mine.headers["cache-control"]).toBe("no-store");
    const other = await app.inject({ method: "GET", url: `/api/agent-tasks/${T}/screenshot`, headers: { "x-test-user": OTHER } });
    expect(other.statusCode).toBe(404);
  });

  it("GET /:id/events retire image_b64 côté SQL (lignes héritées)", async () => {
    await app.inject({ method: "GET", url: `/api/agent-tasks/${T}/events`, headers: user });
    expect(fakeDb.calls[0].sql).toContain("(data - 'image_b64')");
  });
});

describe("POST /api/agent-tasks/:id/control (T45)", () => {
  it("même valeur → no-op (unchanged) sans prolonger le bail ; tâche terminée → 409", async () => {
    fakeDb.on(/SELECT status, control FROM agent_tasks/, { rows: [{ status: "in_progress", control: "pause" }] });
    const r = await app.inject({ method: "POST", url: `/api/agent-tasks/${T}/control`, headers: user, payload: { control: "pause" } });
    expect(r.json()).toEqual({ success: true, control: "pause", unchanged: true });
    const upd = fakeDb.find(/UPDATE agent_tasks SET control/)[0];
    expect(upd.sql).toContain("control IS DISTINCT FROM $1");
    expect(upd.sql).not.toContain("updated_at");
    fakeDb.reset();
    fakeDb.on(/SELECT status, control FROM agent_tasks/, { rows: [{ status: "completed", control: "none" }] });
    const done = await app.inject({ method: "POST", url: `/api/agent-tasks/${T}/control`, headers: user, payload: { control: "stop" } });
    expect(done.statusCode).toBe(409);
  });
});

describe("POST /api/agent-tasks : ciblage et S21", () => {
  const keys = (n: number) =>
    [{ id: K, label: "PC bureau", allowed_dirs: ["C:\\SoulbahWorkspace"] }, { id: K2, label: "Portable", allowed_dirs: [] }].slice(0, n);

  it("plusieurs agents sans agent_key_id → 400 avec la liste des agents", async () => {
    fakeDb.on(/SELECT id, label, allowed_dirs FROM agent_keys/, { rows: keys(2) });
    const r = await app.inject({
      method: "POST",
      url: "/api/agent-tasks",
      headers: user,
      payload: { task_type: "t", payload: { steps: [{ type: "wait" }] } },
    });
    expect(r.statusCode).toBe(400);
    expect(r.json().agents).toEqual([{ id: K, name: "PC bureau" }, { id: K2, name: "Portable" }]);
  });

  it("chemin hors des allowed_dirs de la clé ciblée → 400", async () => {
    fakeDb.on(/SELECT id, label, allowed_dirs FROM agent_keys/, { rows: keys(2) });
    const r = await app.inject({
      method: "POST",
      url: "/api/agent-tasks",
      headers: user,
      payload: { task_type: "t", agent_key_id: K, payload: { steps: [{ type: "write_file", path: "C:/Windows/x.txt", content: "x" }] } },
    });
    expect(r.statusCode).toBe(400);
    expect(r.json().error).toContain("hors des dossiers");
  });

  it("clé unique ciblée d'office ; run_command → requires_confirmation=true (non abaissable)", async () => {
    fakeDb.on(/SELECT id, label, allowed_dirs FROM agent_keys/, { rows: keys(1) });
    fakeDb.on(/INSERT INTO agent_tasks/, { rows: [{ id: T }] });
    const r = await app.inject({
      method: "POST",
      url: "/api/agent-tasks",
      headers: user,
      payload: {
        task_type: "t",
        payload: { requires_confirmation: false, steps: [{ type: "run_command", program: "git", args: ["status"], cwd: "C:\\SoulbahWorkspace\\repo" }] },
      },
    });
    expect(r.statusCode).toBe(200);
    const ins = fakeDb.find(/INSERT INTO agent_tasks/)[0];
    expect(JSON.parse(ins.values[2] as string).requires_confirmation).toBe(true);
    expect(ins.values[4]).toBe(K);
  });
});
