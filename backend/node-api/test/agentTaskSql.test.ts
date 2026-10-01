import { describe, expect, it } from "vitest";
import { buildAgentTaskUpdate, buildTaskTouch, isAgentTaskStatus, parseAttempt } from "../src/lib/agentTaskSql";

const T = "11111111-1111-4111-8111-111111111111";
const U = "22222222-2222-4222-8222-222222222222";

describe("statuts et attempt", () => {
  it("liste blanche des statuts", () => {
    for (const s of ["pending", "in_progress", "completed", "failed", "cancelled"]) expect(isAgentTaskStatus(s)).toBe(true);
    expect(isAgentTaskStatus("done")).toBe(false);
    expect(isAgentTaskStatus(undefined)).toBe(false);
  });
  it("parseAttempt", () => {
    expect(parseAttempt(undefined)).toBeUndefined();
    expect(parseAttempt(null)).toBeUndefined();
    expect(parseAttempt(0)).toBe(0);
    expect(parseAttempt(2)).toBe(2);
    expect(parseAttempt(-1)).toBeNull();
    expect(parseAttempt("1")).toBeNull();
    expect(parseAttempt(1.5)).toBeNull();
  });
});

describe("buildAgentTaskUpdate", () => {
  it("claim : exige status='pending', pose started_at", () => {
    const q = buildAgentTaskUpdate({ taskId: T, userId: U, status: "in_progress" });
    expect(q.kind).toBe("claim");
    expect(q.sql).toContain("status = 'pending'");
    expect(q.sql).toContain("started_at = now()");
    expect(q.sql).toContain("RETURNING id, status, requeue_count");
    expect(q.values).toEqual(["in_progress", T, U]);
  });

  it("terminal : exige status='in_progress' et requeue_count = attempt", () => {
    const q = buildAgentTaskUpdate({ taskId: T, userId: U, status: "completed", result: { ok: true }, attempt: 2 });
    expect(q.kind).toBe("transition");
    expect(q.sql).toMatch(/WHERE id = \$3 AND user_id = \$4 AND status = 'in_progress' AND requeue_count = \$5/);
    expect(q.sql).toContain("completed_at = now()");
    expect(q.values).toEqual(["completed", JSON.stringify({ ok: true }), T, U, 2]);
  });

  it("failed avec message, sans attempt : pas de garde requeue_count", () => {
    const q = buildAgentTaskUpdate({ taskId: T, userId: U, status: "failed", errorMessage: "boom" });
    expect(q.sql).not.toContain("requeue_count =");
    expect(q.sql).toContain("error_message = $2");
    expect(q.values).toEqual(["failed", "boom", T, U]);
  });

  it("cancelled est terminal ; pending (libération) remet started_at à NULL", () => {
    expect(buildAgentTaskUpdate({ taskId: T, userId: U, status: "cancelled" }).sql).toContain("completed_at = now()");
    const q = buildAgentTaskUpdate({ taskId: T, userId: U, status: "pending" });
    expect(q.sql).toContain("started_at = NULL");
    expect(q.sql).toContain("status = 'in_progress'");
  });
});

describe("buildTaskTouch", () => {
  it("avec et sans attempt", () => {
    expect(buildTaskTouch(T, U).values).toEqual([T, U]);
    const q = buildTaskTouch(T, U, 1);
    expect(q.sql).toContain("status = 'in_progress' AND requeue_count = $3");
    expect(q.values).toEqual([T, U, 1]);
  });
});
