import { describe, expect, it } from "vitest";
import {
  applyApproveResponse,
  applyCancelResponse,
  applyTaskChange,
  canCancelTask,
  canDeleteTask,
  describeStep,
  evaluationView,
  findCorrection,
  isAwaitingApproval,
  normalizeTaskRow,
  plannedSteps,
  recordingPaths,
  statusLabel,
  type AgentTask,
} from "@/lib/agentTasks";

const task = (over: Partial<AgentTask> = {}): AgentTask => ({
  id: "t1",
  task_type: "goal",
  status: "pending",
  control: "none",
  payload: null,
  result: null,
  error_message: null,
  created_at: "2026-10-01T10:00:00Z",
  completed_at: null,
  ...over,
});

describe("statuts", () => {
  it("affiche « Annulée » pour cancelled", () => {
    expect(statusLabel(task({ status: "cancelled" }))).toBe("Annulée");
    expect(statusLabel(task({ status: "in_progress" }))).toBe("En cours");
    expect(statusLabel(task({ status: "in_progress", control: "stop" }))).toBe("Arrêt demandé");
    expect(statusLabel(task({ status: "weird" }))).toBe("weird");
  });

  it("ne permet la suppression que pour une tâche terminée", () => {
    expect(canDeleteTask(task({ status: "pending" }))).toBe(false);
    expect(canDeleteTask(task({ status: "in_progress" }))).toBe(false);
    expect(canDeleteTask(task({ status: "completed" }))).toBe(true);
    expect(canDeleteTask(task({ status: "failed" }))).toBe(true);
    expect(canDeleteTask(task({ status: "cancelled" }))).toBe(true);
  });

  it("permet l'annulation d'une tâche active seulement", () => {
    expect(canCancelTask(task({ status: "pending" }))).toBe(true);
    expect(canCancelTask(task({ status: "in_progress" }))).toBe(true);
    expect(canCancelTask(task({ status: "in_progress", control: "stop" }))).toBe(false);
    expect(canCancelTask(task({ status: "completed" }))).toBe(false);
    expect(canCancelTask(task({ status: "cancelled" }))).toBe(false);
  });
});

describe("annulation / approbation (mise à jour locale)", () => {
  it("applique la réponse du serveur", () => {
    expect(applyCancelResponse(task(), { status: "cancelled" }).status).toBe("cancelled");
    const running = applyCancelResponse(task({ status: "in_progress" }), { status: "in_progress", control: "stop" });
    expect(running).toMatchObject({ status: "in_progress", control: "stop" });
  });

  it("a un repli conforme au contrat sans corps", () => {
    expect(applyCancelResponse(task(), undefined).status).toBe("cancelled");
    expect(applyCancelResponse(task({ status: "in_progress" }), {}).control).toBe("stop");
  });

  it("l'approbation lève awaiting_approval", () => {
    const t = task({ payload: { goal_meta: { goal: "g", awaiting_approval: true } } });
    expect(isAwaitingApproval(t)).toBe(true);
    const approved = applyApproveResponse(t, { });
    expect(isAwaitingApproval(approved)).toBe(false);
    expect(approved.payload?.goal_meta?.goal).toBe("g");
  });

  it("une correction n'est « à approuver » que si elle est en attente", () => {
    const meta = { goal_meta: { awaiting_approval: true } };
    expect(isAwaitingApproval(task({ status: "cancelled", payload: meta }))).toBe(false);
    expect(statusLabel(task({ payload: meta }))).toBe("À approuver");
  });
});

describe("evaluationView (T17)", () => {
  const evaluated = (evaluation: Record<string, unknown>) =>
    task({ id: "parent", status: "failed", result: { evaluation } });

  it("objectif atteint", () => {
    expect(evaluationView(evaluated({ verdict: "success", reason: "ok" }), [])).toEqual({
      text: "Objectif atteint — ok",
      tone: "success",
    });
  });

  it("n'affiche PAS « Correction lancée » sans tâche créée", () => {
    const v = evaluationView(evaluated({ verdict: "retry", reason: "fenêtre absente" }), []);
    expect(v?.text).not.toContain("Correction lancée");
    expect(v?.text).toContain("aucune correction créée");
    const invalid = evaluationView(evaluated({ verdict: "abort", action_taken: "correction_invalid" }), []);
    expect(invalid?.text).toContain("Aucune correction créée");
  });

  it("correction créée mais en attente d'approbation", () => {
    const parent = evaluated({ verdict: "retry", action_taken: "correction_awaiting_approval", corrective_task_id: "child" });
    expect(evaluationView(parent, [])?.text).toContain("en attente de votre approbation");
    const child = task({ id: "child", payload: { goal_meta: { parent_task_id: "parent", awaiting_approval: true } } });
    expect(evaluationView(parent, [parent, child])?.text).toContain("en attente de votre approbation");
  });

  it("« Correction lancée » une fois la correction approuvée", () => {
    const parent = evaluated({ verdict: "retry", corrective_task_id: "child" });
    const child = task({ id: "child", status: "in_progress", payload: { goal_meta: { parent_task_id: "parent" } } });
    expect(evaluationView(parent, [parent, child])).toEqual({ text: "Correction lancée", tone: "warning" });
    const rejected = { ...child, status: "cancelled" };
    expect(evaluationView(parent, [parent, rejected])?.text).toBe("Correction rejetée");
  });

  it("retrouve la correction par parent_task_id", () => {
    const parent = evaluated({ verdict: "retry" });
    const child = task({ id: "c2", payload: { goal_meta: { parent_task_id: "parent" } } });
    expect(findCorrection(parent, [child])?.id).toBe("c2");
    expect(findCorrection(parent, [])).toBeNull();
  });

  it("évaluation impossible / abandon", () => {
    expect(evaluationView(evaluated({ verdict: null, action_taken: "evaluation_failed" }), [])?.text).toBe(
      "Évaluation impossible",
    );
    expect(evaluationView(evaluated({ verdict: "abort", action_taken: "max_attempts_reached" }), [])?.tone).toBe(
      "destructive",
    );
    expect(evaluationView(task(), [])).toBeNull();
  });
});

describe("plan et enregistrements (C36, C18)", () => {
  it("décrit les étapes planifiées", () => {
    expect(describeStep({ type: "open_app", app: "notepad" })).toBe("Ouvrir : notepad");
    expect(describeStep({ type: "hotkey", keys: ["ctrl", "s"] })).toBe("Raccourci : ctrl+s");
    expect(describeStep({ type: "wait", seconds: 2 })).toBe("Attendre : 2 s");
    expect(describeStep({ type: "run_command", program: "git", args: ["status"] })).toBe("Commande : git status");
    expect(describeStep({ type: "type_text", text: "x".repeat(100) })).toMatch(/^Taper : « x+… »$/);
    expect(describeStep({ type: "open_software", software: "vscode", description: "Ouvrir VS Code" })).toBe(
      "Ouvrir : vscode (Ouvrir VS Code)",
    );
    expect(describeStep({ type: "custom_tool" })).toBe("custom_tool");
    expect(describeStep(null)).toBe("Étape invalide");
  });

  it("lit les étapes du payload", () => {
    expect(plannedSteps(task({ payload: { steps: [{ type: "wait" }] } }))).toHaveLength(1);
    expect(plannedSteps(task())).toEqual([]);
  });

  it("extrait les chemins d'enregistrement réussis", () => {
    const t = task({
      result: {
        steps: [
          { type: "start_recording_bg", ok: true, data: { path: "C:/w/a.mp4" } },
          { type: "stop_recording_bg", ok: true, data: { path: "C:/w/a.mp4" } },
          { type: "record_screen", ok: true, data: { path: "C:/w/b.mp4" } },
          { type: "record_screen", ok: false, data: { path: "C:/w/c.mp4" } },
          { type: "screenshot", ok: true, data: { path: "C:/w/s.png" } },
        ],
      },
    });
    expect(recordingPaths(t)).toEqual(["C:/w/a.mp4", "C:/w/b.mp4"]);
    expect(recordingPaths(task())).toEqual([]);
  });
});

describe("temps réel", () => {
  it("normalise une ligne", () => {
    expect(normalizeTaskRow({ id: "x", status: "cancelled", payload: [], result: "?" })).toMatchObject({
      id: "x",
      status: "cancelled",
      payload: null,
      result: null,
    });
    expect(normalizeTaskRow({ status: "pending" })).toBeNull();
  });

  it("insère, met à jour sans perdre les colonnes absentes, supprime", () => {
    const base = [task({ id: "a", payload: { steps: [{ type: "wait" }] } })];
    const inserted = applyTaskChange(base, { eventType: "INSERT", new: { id: "b", status: "pending" } });
    expect(inserted.map((t) => t.id)).toEqual(["b", "a"]);
    const updated = applyTaskChange(inserted, { eventType: "UPDATE", new: { id: "a", status: "cancelled" } });
    const a = updated.find((t) => t.id === "a");
    expect(a?.status).toBe("cancelled");
    expect(a?.payload?.steps).toHaveLength(1);
    expect(applyTaskChange(updated, { eventType: "DELETE", old: { id: "b" } }).map((t) => t.id)).toEqual(["a"]);
    expect(applyTaskChange(updated, { eventType: "DELETE", old: {} })).toBe(updated);
  });
});
