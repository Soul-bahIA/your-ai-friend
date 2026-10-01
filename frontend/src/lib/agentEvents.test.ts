import { describe, expect, it } from "vitest";
import {
  cockpitReducer,
  eventText,
  initialCockpitState,
  isCockpitEvent,
  MAX_EVENTS,
  type AgentEvent,
  type CockpitState,
} from "@/lib/agentEvents";

let n = 0;
const ev = (type: string, over: Partial<AgentEvent> = {}): AgentEvent => ({
  id: `e${++n}`,
  task_id: "t1",
  type,
  message: null,
  data: {},
  created_at: "2026-10-01T10:00:00Z",
  ...over,
});

const run = (events: AgentEvent[], start: CockpitState = initialCockpitState) =>
  events.reduce((s, e) => cockpitReducer(s, { type: "event", event: e }), start);

describe("filtrage des évènements (T29)", () => {
  it("ignore les évènements de formation", () => {
    expect(isCockpitEvent(ev("step_started", { data: { source: "formation" } }))).toBe(false);
    expect(isCockpitEvent(ev("step_started", { data: { source: "agent" } }))).toBe(true);
    expect(isCockpitEvent(ev("step_started", { data: null }))).toBe(true);
    const s = run([ev("task_started", { task_id: "f1", data: { source: "formation" } })]);
    expect(s).toBe(initialCockpitState);
  });

  it("une formation n'interrompt pas la tâche suivie", () => {
    const s = run([
      ev("task_started"),
      ev("step_started", { message: "Étape 1" }),
      ev("info", { task_id: "f1", message: "Module 2/5", data: { source: "formation" } }),
    ]);
    expect(s.taskId).toBe("t1");
    expect(s.events.map((e) => e.message)).toEqual([null, "Étape 1"]);
    expect(s.running).toBe(true);
  });

  it("ignore les évènements d'une autre tâche pendant l'exécution", () => {
    const s = run([ev("task_started"), ev("step_started", { task_id: "t2" })]);
    expect(s.taskId).toBe("t1");
    expect(s.events).toHaveLength(1);
  });

  it("bascule sur une nouvelle tâche au repos, mais pas pour un simple cycle de vie", () => {
    const done = run([ev("task_started"), ev("task_completed")]);
    expect(done.running).toBe(false);
    expect(run([ev("task_approved", { task_id: "t2" })], done).taskId).toBe("t1");
    const next = run([ev("step_started", { task_id: "t2" })], done);
    expect(next.taskId).toBe("t2");
    expect(next.running).toBe(true);
    expect(next.events).toHaveLength(1);
  });

  it("un évènement de cycle de vie isolé n'ouvre pas de timeline", () => {
    expect(run([ev("task_cancelled")])).toBe(initialCockpitState);
  });
});

describe("cycle d'exécution", () => {
  it("démarre, termine, annule", () => {
    const s = run([ev("task_started"), ev("step_done", { data: { duration_s: 1 } })]);
    expect(s.running).toBe(true);
    expect(run([ev("task_cancelled")], s).running).toBe(false);
    expect(run([ev("task_failed")], s).running).toBe(false);
  });

  it("task_started réinitialise la timeline et l'image", () => {
    const s = run([ev("task_started"), ev("screenshot", { data: { image_b64: "QUJD" } })]);
    expect(s.liveImage).toBe("data:image/jpeg;base64,QUJD");
    const restarted = run([ev("task_started", { task_id: "t2" })], s);
    expect(restarted).toMatchObject({ taskId: "t2", liveImage: null, running: true });
    expect(restarted.events).toHaveLength(1);
  });

  it("limite la timeline à MAX_EVENTS", () => {
    const many = Array.from({ length: MAX_EVENTS + 20 }, () => ev("step_done"));
    expect(run([ev("task_started"), ...many]).events).toHaveLength(MAX_EVENTS);
  });

  it("« stopped » met le cockpit au repos", () => {
    const s = run([ev("task_started"), ev("approval_required", { data: { step_index: 0 } })]);
    const stopped = cockpitReducer(s, { type: "stopped" });
    expect(stopped.running).toBe(false);
    expect(stopped.pendingApproval).toBeNull();
  });
});

describe("captures (contrat §8)", () => {
  it("data.has_image déclenche une requête de capture", () => {
    const shot = ev("screenshot", { data: { has_image: true } });
    const s = run([ev("task_started"), shot]);
    expect(s.screenshotRequest).toEqual({ taskId: "t1", eventId: shot.id });
    expect(s.liveImage).toBeNull();
  });

  it("le base64 hérité est retiré de la timeline mais affiché", () => {
    const s = run([ev("task_started"), ev("screenshot", { data: { image_b64: "QUJD", media_type: "image/png" } })]);
    expect(s.liveImage).toBe("data:image/png;base64,QUJD");
    expect(s.events[1].data?.image_b64).toBeUndefined();
  });

  it("n'applique une capture reçue que pour la tâche suivie", () => {
    const s = run([ev("task_started")]);
    expect(cockpitReducer(s, { type: "screenshot", taskId: "t1", image: "data:image/png;base64,QQ==" }).liveImage).toBe(
      "data:image/png;base64,QQ==",
    );
    expect(cockpitReducer(s, { type: "screenshot", taskId: "t2", image: "data:x" })).toBe(s);
    expect(cockpitReducer(s, { type: "screenshot", taskId: "t1", image: null })).toBe(s);
  });
});

describe("confirmations sur le PC (contrat §13)", () => {
  it("approval_required → en attente jusqu'à approval_result", () => {
    const s = run([
      ev("task_started"),
      ev("approval_required", { data: { step_index: 2, action: { type: "run_command" }, summary: "git status" } }),
    ]);
    expect(s.pendingApproval).toEqual({ stepIndex: 2, action: "run_command", summary: "git status" });
    expect(run([ev("approval_result", { data: { step_index: 2, approved: true } })], s).pendingApproval).toBeNull();
  });

  it("la fin de tâche efface l'attente", () => {
    const s = run([ev("task_started"), ev("approval_required", { data: { action: "type_text" } })]);
    expect(s.pendingApproval?.stepIndex).toBeNull();
    expect(run([ev("task_failed")], s).pendingApproval).toBeNull();
  });

  it("hydrate rejoue l'historique (sans task_id)", () => {
    const history = [
      ev("task_started", { task_id: undefined }),
      ev("approval_required", { task_id: undefined, data: { step_index: 0, action: "open_app" } }),
      ev("screenshot", { task_id: undefined, data: { has_image: true } }),
    ];
    const s = cockpitReducer(initialCockpitState, { type: "hydrate", taskId: "t9", events: history });
    expect(s).toMatchObject({ taskId: "t9", running: true });
    expect(s.pendingApproval?.action).toBe("open_app");
    expect(s.screenshotRequest?.taskId).toBe("t9");
    expect(s.events).toHaveLength(3);
  });
});

describe("confirmations d'une autre tâche / d'un autre PC (§7 + §13)", () => {
  const required = (taskId: string, step_index = 1) =>
    ev("approval_required", { task_id: taskId, data: { step_index, action: "run_command", summary: "npm test" } });

  it("approval_required d'une tâche non suivie est affiché sans quitter la timeline", () => {
    const s = run([ev("task_started", { task_id: "A" }), ev("step_started", { task_id: "A" }), required("B")]);
    expect(s.taskId).toBe("A");
    expect(s.events).toHaveLength(2);
    expect(s.pendingApproval).toBeNull();
    expect(s.otherApprovals).toEqual([{ taskId: "B", stepIndex: 1, action: "run_command", summary: "npm test" }]);
  });

  it("approval_result ou la fin de l'autre tâche retire l'attente", () => {
    const waiting = run([ev("task_started", { task_id: "A" }), required("B")]);
    expect(run([ev("approval_result", { task_id: "B", data: { approved: true } })], waiting).otherApprovals).toEqual([]);
    expect(run([ev("task_cancelled", { task_id: "B" })], waiting).otherApprovals).toEqual([]);
    // Un évènement ordinaire de l'autre tâche ne change rien (même objet d'état).
    expect(run([ev("step_done", { task_id: "B" })], waiting)).toBe(waiting);
  });

  it("le démarrage d'une autre tâche conserve l'attente de la tâche suivie jusque-là", () => {
    const s = run([ev("task_started", { task_id: "A" }), required("A", 3), ev("task_started", { task_id: "B" })]);
    expect(s.taskId).toBe("B");
    expect(s.pendingApproval).toBeNull();
    expect(s.otherApprovals).toEqual([{ taskId: "A", stepIndex: 3, action: "run_command", summary: "npm test" }]);
  });

  it("en basculant sur l'autre tâche, son attente devient celle de la tâche suivie", () => {
    const s = run([ev("task_started", { task_id: "A" }), required("B"), ev("task_completed", { task_id: "A" })]);
    expect(s.running).toBe(false);
    const switched = run([ev("step_started", { task_id: "B" })], s);
    expect(switched.taskId).toBe("B");
    expect(switched.pendingApproval).toEqual({ stepIndex: 1, action: "run_command", summary: "npm test" });
    expect(switched.otherApprovals).toEqual([]);
  });

  it("reprise : l'historique d'une autre tâche en cours restitue sa confirmation", () => {
    const followed = cockpitReducer(initialCockpitState, { type: "hydrate", taskId: "A", events: [ev("task_started", { task_id: "A" })] });
    const history = [ev("task_started", { task_id: "B" }), required("B", 0)];
    const s = cockpitReducer(followed, { type: "approvals", taskId: "B", events: history });
    expect(s.otherApprovals.map((a) => [a.taskId, a.stepIndex])).toEqual([["B", 0]]);
    const answered = [...history, ev("approval_result", { task_id: "B", data: { approved: false } })];
    expect(cockpitReducer(s, { type: "approvals", taskId: "B", events: answered }).otherApprovals).toEqual([]);
    // La tâche suivie n'est pas traitée comme « autre ».
    expect(cockpitReducer(followed, { type: "approvals", taskId: "A", events: history })).toBe(followed);
  });
});

describe("eventText", () => {
  it("décrit l'évaluation sans annoncer de correction inexistante", () => {
    expect(eventText(ev("evaluation", { data: { action_taken: "correction_awaiting_approval", corrective_task_id: "c" } }))).toBe(
      "Évaluation : correction proposée, en attente de votre approbation",
    );
    expect(eventText(ev("evaluation", { data: { action_taken: "correction_awaiting_approval" } }))).toContain(
      "aucune correction créée",
    );
    expect(eventText(ev("approval_result", { data: { approved: false } }))).toBe("Action refusée sur le PC");
    expect(eventText(ev("step_done", { message: "OK" }))).toBe("OK");
  });

  it("non évaluable (action_taken 'none') : texte lisible, pas « not_evaluable » brut (T17)", () => {
    const evaluation = ev("evaluation", {
      message: "Évaluation : not_evaluable",
      data: { verdict: "not_evaluable", action_taken: "none", corrective_task_id: null },
    });
    expect(eventText(evaluation)).toBe("Évaluation : tâche non évaluable (ni correction, ni mémoire)");
    expect(eventText(ev("evaluation", { message: "Évaluation : not_evaluable", data: { verdict: "not_evaluable" } }))).toBe(
      "Évaluation : tâche non évaluable (ni correction, ni mémoire)",
    );
  });
});
