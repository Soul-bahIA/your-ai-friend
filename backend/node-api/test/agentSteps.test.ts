import { describe, expect, it } from "vitest";
import {
  AGENT_STEP_TYPES,
  MAX_STEPS,
  clampAndValidatePlanSteps,
  validateGoalBody,
  validateSteps,
  validateTaskCreateBody,
} from "../src/lib/agentSteps";

describe("validateSteps", () => {
  it("accepte des étapes connues de l'agent", () => {
    const r = validateSteps([
      { type: "open_software", software: "vscode", description: "Ouvrir VS Code" },
      { type: "wait", seconds: 3 },
      { type: "hotkey", keys: ["ctrl", "s"] },
    ]);
    expect(r.ok).toBe(true);
  });

  it("couvre les skills du registre de l'agent", () => {
    for (const t of ["phone_tap", "start_recording_bg", "resolve_montage", "run_command", "write_file"]) {
      expect(AGENT_STEP_TYPES).toContain(t);
    }
  });

  it("rejette une action inconnue", () => {
    const r = validateSteps([{ type: "format_disk" }]);
    expect(r).toEqual({ ok: false, error: expect.stringContaining("action inconnue") });
  });

  it("rejette liste vide, non-liste et trop d'étapes", () => {
    expect(validateSteps([]).ok).toBe(false);
    expect(validateSteps("x").ok).toBe(false);
    expect(validateSteps(Array.from({ length: MAX_STEPS + 1 }, () => ({ type: "wait" }))).ok).toBe(false);
  });

  it("rejette objets imbriqués, clés invalides et nombres non finis", () => {
    expect(validateSteps([{ type: "wait", extra: { a: 1 } }]).ok).toBe(false);
    expect(validateSteps([{ type: "wait", "Bad-Key": 1 }]).ok).toBe(false);
    expect(validateSteps([{ type: "wait", seconds: Infinity }]).ok).toBe(false);
    expect(validateSteps([{ type: "edit_video", clips: [{ p: 1 }] }]).ok).toBe(false);
  });
});

describe("clampAndValidatePlanSteps", () => {
  it("borne le nombre d'étapes d'un plan généré", () => {
    const steps = Array.from({ length: MAX_STEPS + 10 }, () => ({ type: "wait", seconds: 1 }));
    const r = clampAndValidatePlanSteps(steps);
    expect(r.ok && r.value.length).toBe(MAX_STEPS);
  });
});

describe("validateTaskCreateBody", () => {
  const base = { task_type: "full_training_video", priority: 1, payload: { title: "t", steps: [{ type: "wait" }] } };

  it("accepte le corps envoyé par le front", () => {
    const r = validateTaskCreateBody(base);
    expect(r).toEqual({ ok: true, value: { task_type: "full_training_video", payload: base.payload, priority: 1 } });
  });

  it("priorité par défaut 5", () => {
    const { priority, ...rest } = base;
    void priority;
    const r = validateTaskCreateBody(rest);
    expect(r.ok && r.value.priority).toBe(5);
  });

  it("rejette les clés inconnues au premier niveau", () => {
    expect(validateTaskCreateBody({ ...base, user_id: "x" })).toEqual({
      ok: false,
      error: expect.stringContaining("user_id"),
    });
  });

  it("rejette goal_meta (réservé au serveur), task_type invalide, priorité hors bornes", () => {
    expect(validateTaskCreateBody({ ...base, payload: { ...base.payload, goal_meta: {} } }).ok).toBe(false);
    expect(validateTaskCreateBody({ ...base, task_type: "DROP TABLE" }).ok).toBe(false);
    expect(validateTaskCreateBody({ ...base, priority: 0 }).ok).toBe(false);
    expect(validateTaskCreateBody({ ...base, priority: 2.5 }).ok).toBe(false);
  });

  it("rejette un payload trop volumineux ou sans étapes", () => {
    expect(validateTaskCreateBody({ ...base, payload: { steps: [{ type: "wait" }], blob: "x".repeat(300_000) } }).ok).toBe(false);
    expect(validateTaskCreateBody({ ...base, payload: { title: "t" } }).ok).toBe(false);
  });
});

describe("validateGoalBody", () => {
  it("accepte { goal } et le nettoie", () => {
    expect(validateGoalBody({ goal: "  ouvrir le bloc-notes " })).toEqual({ ok: true, value: "ouvrir le bloc-notes" });
  });
  it("rejette vide, trop long et clés inconnues", () => {
    expect(validateGoalBody({ goal: " " }).ok).toBe(false);
    expect(validateGoalBody({ goal: "x".repeat(2001) }).ok).toBe(false);
    expect(validateGoalBody({ goal: "ok", steps: [] }).ok).toBe(false);
  });
});
