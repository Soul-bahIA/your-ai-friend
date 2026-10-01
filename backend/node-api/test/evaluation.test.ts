// Boucle Observer → Corriger : jamais d'évaluation pour un run annulé / simulé / vide,
// corrections liées et soumises à approbation, mémoire proposée, texte saisi masqué.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { fakeDb } from "./helpers/fakeDb";

vi.mock("../src/db.js", async () => (await import("./helpers/fakeDb")).dbMock);
vi.mock("../src/clients/iaClient.js", async (importOriginal) => ({
  ...(await importOriginal<object>()),
  evaluateGoal: vi.fn(),
}));

const { maybeEvaluateGoalTask, evaluationSkipReason } = await import("../src/routes/agentGoal");
const iaClient = await import("../src/clients/iaClient");
const evaluate = vi.mocked(iaClient.evaluateGoal);

const T = "11111111-1111-4111-8111-111111111111";
const ROOT = "55555555-5555-4555-8555-555555555555";
const U = "22222222-2222-4222-8222-222222222222";
const K = "33333333-3333-4333-8333-333333333333";

const meta = { goal: "écrire un rapport", attempt: 1, max_attempts: 3, root_task_id: ROOT };
const executed = { steps: [{ index: 0, type: "type_text", ok: true, detail: "ok" }] };

function task(over: Record<string, unknown> = {}) {
  return {
    status: "completed",
    control: "none",
    payload: { steps: [{ type: "type_text", text: "mot de passe secret" }], goal_meta: meta },
    result: executed,
    target_agent_key_id: K,
    ...over,
  };
}

function setupTask(row: Record<string, unknown>) {
  fakeDb.on(/SELECT payload, result, status, control, target_agent_key_id/, { rows: [row] });
  fakeDb.on(/evaluation_status', 'running'/, { rows: [{ id: T }] });
  fakeDb.on(/SELECT id, label, allowed_dirs FROM agent_keys WHERE id = \$1/, {
    rows: [{ id: K, label: "PC", allowed_dirs: ["C:\\SoulbahWorkspace"] }],
  });
  fakeDb.on(/INSERT INTO agent_tasks/, (_sql, values) => ({ rows: [{ id: values[0] }] }));
}

const evaluationWrite = () => {
  const w = fakeDb.find(/jsonb_build_object\('evaluation', \$1::jsonb/)[0];
  return w ? (JSON.parse(w.values[0] as string) as Record<string, unknown>) : undefined;
};

beforeEach(() => {
  fakeDb.reset();
  evaluate.mockReset();
});

describe("evaluationSkipReason (contrat §2, §4)", () => {
  it("annulé, stoppé, simulé, plan vide, rien d'exécuté → jamais évalué", () => {
    expect(evaluationSkipReason(task({ status: "cancelled" }) as never)).toBe("cancelled");
    expect(evaluationSkipReason(task({ status: "failed", control: "stop" }) as never)).toBe("stopped_by_user");
    expect(evaluationSkipReason(task({ result: { ...executed, simulated: true } }) as never)).toBe("simulated");
    expect(evaluationSkipReason(task({ status: "failed", result: { empty_plan: true } }) as never)).toBe("empty_plan");
    expect(evaluationSkipReason(task({ result: { steps: [] } }) as never)).toBe("no_step_executed");
  });

  it("agent ancien (dry-run sans drapeau), déjà évalué, tâche non issue d'un objectif", () => {
    const legacyDry = { steps: [{ type: "wait", ok: true, detail: "[dry-run] attendre 1 s" }] };
    expect(evaluationSkipReason(task({ result: legacyDry }) as never)).toBe("simulated");
    expect(evaluationSkipReason(task({ result: { ...executed, evaluation: {} } }) as never)).toBe("already_evaluated");
    expect(evaluationSkipReason(task({ payload: { steps: [{ type: "wait" }] } }) as never)).toBe("not_goal");
    expect(evaluationSkipReason(task() as never)).toBeNull();
  });
});

describe("maybeEvaluateGoalTask", () => {
  it("tâche annulée ou simulée : aucun appel LLM, aucune écriture", async () => {
    for (const row of [task({ status: "cancelled" }), task({ result: { ...executed, simulated: true } })]) {
      fakeDb.reset();
      setupTask(row);
      const out = await maybeEvaluateGoalTask(T, U);
      expect(out.skipped).toBeDefined();
    }
    expect(evaluate).not.toHaveBeenCalled();
    expect(fakeDb.find(/INSERT INTO agent_memory|INSERT INTO agent_tasks/)).toHaveLength(0);
  });

  it("réservation atomique : déjà évaluée par une autre requête → aucun appel LLM", async () => {
    fakeDb.on(/SELECT payload, result, status, control, target_agent_key_id/, { rows: [task()] });
    const out = await maybeEvaluateGoalTask(T, U);
    expect(out).toEqual({ skipped: "already_evaluated" });
    expect(evaluate).not.toHaveBeenCalled();
  });

  it("success → mémoire PROPOSÉE ; texte saisi masqué avant l'envoi au LLM (contrat §12)", async () => {
    setupTask(task());
    evaluate.mockResolvedValue({ verdict: "success", reason: "fait", corrective_steps: [] });
    const out = await maybeEvaluateGoalTask(T, U, { screenshots: ["A", "B", "C", "D"] });
    expect(out).toEqual({ verdict: "success", action_taken: "memory_proposed" });
    const [, steps, , shots] = evaluate.mock.calls[0];
    expect(JSON.stringify(steps)).not.toContain("mot de passe secret");
    expect(JSON.stringify(steps)).toContain("[texte masqué : 19 car.]");
    expect(shots).toEqual(["B", "C", "D"]);
    const mem = fakeDb.find(/INSERT INTO agent_memory/)[0];
    expect(mem.values[6]).toBe("proposed");
    expect(String(mem.values[3])).not.toContain("mot de passe secret");
    expect(evaluationWrite()).toMatchObject({ verdict: "success", action_taken: "memory_proposed" });
  });

  it("retry → correction liée (parent/root, même PC) EN ATTENTE D'APPROBATION ; id renvoyé dans l'évaluation", async () => {
    setupTask(task({ status: "failed" }));
    evaluate.mockResolvedValue({
      verdict: "retry",
      reason: "fenêtre absente",
      corrective_steps: [{ type: "write_file", path: "C:\\SoulbahWorkspace\\r.txt", content: "x" }],
    });
    const out = await maybeEvaluateGoalTask(T, U);
    expect(out.action_taken).toBe("correction_awaiting_approval");
    const ins = fakeDb.find(/INSERT INTO agent_tasks/)[0];
    const payload = JSON.parse(ins.values[2] as string);
    expect(payload.goal_meta).toMatchObject({ awaiting_approval: true, parent_task_id: T, root_task_id: ROOT, attempt: 2 });
    expect(payload.requires_confirmation).toBe(true);
    expect(ins.values[3]).toBe(K);
    expect(out.corrective_task_id).toBe(ins.values[0]);
    expect(evaluationWrite()).toMatchObject({ verdict: "retry", corrective_task_id: ins.values[0] });
    const ev = fakeDb.find(/VALUES \(\$1, \$2, 'evaluation'/)[0];
    expect(JSON.parse(ev.values[3] as string)).toMatchObject({ corrective_task_id: ins.values[0], source: "agent" });
  });

  it("retry avec plan correctif hors whitelist → aucune tâche ; verdict effectif 'abort' (pas de « Correction lancée »)", async () => {
    setupTask(task({ status: "failed" }));
    evaluate.mockResolvedValue({
      verdict: "retry",
      reason: "r",
      corrective_steps: [{ type: "read_file", path: "C:\\Users\\me\\agent\\.env" }],
    });
    const out = await maybeEvaluateGoalTask(T, U);
    expect(out).toEqual({ verdict: "abort", action_taken: "correction_invalid" });
    expect(fakeDb.find(/INSERT INTO agent_tasks/)).toHaveLength(0);
    expect(evaluationWrite()).toMatchObject({ verdict: "abort", llm_verdict: "retry" });
  });

  it("retry au-delà de max_attempts → abandon, aucune tâche", async () => {
    setupTask(task({ status: "failed", payload: { steps: [{ type: "wait" }], goal_meta: { ...meta, attempt: 3 } } }));
    evaluate.mockResolvedValue({ verdict: "retry", reason: "r", corrective_steps: [{ type: "wait", seconds: 1 }] });
    const out = await maybeEvaluateGoalTask(T, U);
    expect(out).toEqual({ verdict: "abort", action_taken: "max_attempts_reached" });
    expect(fakeDb.find(/INSERT INTO agent_tasks/)).toHaveLength(0);
  });

  it("verdict python-ia 'not_evaluable' → ni succès, ni correction, ni mémoire", async () => {
    setupTask(task());
    evaluate.mockResolvedValue({ verdict: "not_evaluable", reason: "simulé", corrective_steps: [], evaluable: false });
    const out = await maybeEvaluateGoalTask(T, U);
    expect(out).toEqual({ verdict: "not_evaluable", action_taken: "none" });
    expect(fakeDb.find(/INSERT INTO agent_memory|INSERT INTO agent_tasks/)).toHaveLength(0);
  });

  it("échec du service IA → évaluation marquée en erreur, message public uniquement", async () => {
    setupTask(task());
    evaluate.mockRejectedValue(new iaClient.ServiceError(502, "Erreur du service IA"));
    const out = await maybeEvaluateGoalTask(T, U);
    expect(out.action_taken).toBe("evaluation_failed");
    const w = fakeDb.find(/jsonb_build_object\('evaluation', \$1::jsonb/)[0];
    expect(w.values[1]).toBe("error");
  });
});
