// LOT 7 — noyau V2 pur : machine à états exhaustive (§9.4), backoff, DAG, parallélisme, SSE.
import { describe, expect, it } from "vitest";
import {
  TASK_STATUSES,
  TRANSITIONS,
  afterFailure,
  allowedPairs,
  assertTransition,
  canTransition,
  IllegalTransition,
  isTerminal,
  retryBackoffMs,
} from "../src/v2/tasks/stateMachine";
import { findCycle, topologicalOrder, validatePlan } from "../src/v2/sessions/dag";
import { effectiveMaxParallel, grantableSlots, parseGlobalMaxParallel } from "../src/v2/scheduler/parallelism";
import { snapshotDigest, sseFrame } from "../src/v2/routes/stream";
import { canSessionTransition } from "../src/v2/sessions/repo";

describe("machine à états des tâches (§9.4) — exhaustive", () => {
  // La table de l'audit, recopiée indépendamment du code : toute paire absente est interdite.
  const AUDIT_TABLE: [string, string][] = [
    ["PENDING", "READY"], ["PENDING", "BLOCKED"],
    ["READY", "RUNNING"],
    ["RUNNING", "WAITING"], ["RUNNING", "BLOCKED"], ["RUNNING", "VALIDATING"], ["RUNNING", "RETRYING"], ["RUNNING", "FAILED"],
    ["WAITING", "RUNNING"], ["WAITING", "BLOCKED"], ["WAITING", "RETRYING"], ["WAITING", "FAILED"],
    ["BLOCKED", "READY"], ["BLOCKED", "PENDING"], ["BLOCKED", "FAILED"],
    ["VALIDATING", "COMPLETED"], ["VALIDATING", "RETRYING"], ["VALIDATING", "FAILED"],
    ["RETRYING", "READY"],
    ["FAILED", "READY"],
  ];
  const nonTerminal = TASK_STATUSES.filter((s) => !isTerminal(s));
  const expected = new Set([...AUDIT_TABLE.map(([a, b]) => `${a}>${b}`), ...nonTerminal.map((s) => `${s}>CANCELLED`)]);

  it("toutes les transitions du tableau sont acceptées, aucune autre (100 paires)", () => {
    let checked = 0;
    for (const from of TASK_STATUSES) {
      for (const to of TASK_STATUSES) {
        checked++;
        expect(canTransition(from, to), `${from} → ${to}`).toBe(expected.has(`${from}>${to}`));
      }
    }
    expect(checked).toBe(100);
    expect(allowedPairs().length).toBe(expected.size);
    expect(Object.keys(TRANSITIONS).sort()).toEqual([...TASK_STATUSES].sort());
  });

  it("états terminaux : rien n'en sort sauf FAILED → READY ; assertTransition lève", () => {
    expect(isTerminal("COMPLETED") && isTerminal("FAILED") && isTerminal("CANCELLED")).toBe(true);
    expect(canTransition("COMPLETED", "CANCELLED")).toBe(false);
    expect(canTransition("CANCELLED", "READY")).toBe(false);
    expect(canTransition("FAILED", "READY")).toBe(true);
    expect(canTransition("RUNNING", "RUNNING")).toBe(false);
    expect(() => assertTransition("PENDING", "RUNNING")).toThrow(IllegalTransition);
    expect(() => assertTransition("READY", "RUNNING")).not.toThrow();
  });

  it("backoff 30 s, 2 min, 8 min puis 8 min ; politique de retry", () => {
    expect([0, 1, 2, 3, 9].map(retryBackoffMs)).toEqual([30_000, 120_000, 480_000, 480_000, 480_000]);
    expect(afterFailure(0, 2, "crash")).toBe("RETRYING");
    expect(afterFailure(2, 2, "crash")).toBe("FAILED");
    expect(afterFailure(0, 2, "lease_expired")).toBe("RETRYING");
    expect(afterFailure(0, 5, "policy_refused")).toBe("FAILED");
    expect(afterFailure(0, 5, "simulated")).toBe("FAILED");
  });
});

describe("sessions : cycle DRAFT → … → terminal", () => {
  it("transitions de session", () => {
    expect(canSessionTransition("DRAFT", "AWAITING_APPROVAL")).toBe(true);
    expect(canSessionTransition("AWAITING_APPROVAL", "RUNNING")).toBe(true);
    expect(canSessionTransition("RUNNING", "PAUSED") && canSessionTransition("PAUSED", "RUNNING")).toBe(true);
    expect(canSessionTransition("RUNNING", "CANCELLED")).toBe(true);
    expect(canSessionTransition("COMPLETED", "RUNNING")).toBe(false);
    expect(canSessionTransition("CANCELLED", "CANCELLED")).toBe(false);
    expect(canSessionTransition("DRAFT", "RUNNING")).toBe(false);
  });
});

describe("plan (DAG)", () => {
  const nodes = [
    { key: "observe", title: "Observer", role: "desktop_operator", security_level: "L0" },
    { key: "code", title: "Coder", role: "coder", security_level: "L1", resources: ["repo:1:worktree:code"] },
    { key: "review", title: "Relire", role: "qa_reviewer", security_level: "L0", priority: 3, max_retries: 0 },
  ];
  it("plan valide : normalisation, ordre topologique", () => {
    const r = validatePlan({ nodes, edges: [{ from: "observe", to: "code" }, { from: "code", to: "review", kind: "soft" }] });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.nodes[1].resources).toEqual([{ key: "repo:1:worktree:code", mode: "exclusive" }]);
    expect(r.value.nodes[0].priority).toBe(5);
    expect(r.value.nodes[2].max_retries).toBe(0);
    expect(r.value.edges[1].kind).toBe("soft");
    expect(topologicalOrder(r.value)).toEqual(["observe", "code", "review"]);
  });

  it("refus : cycle, clé en double, nœud inconnu, auto-dépendance, bornes, niveau, champ inconnu", () => {
    const cyc = validatePlan({ nodes, edges: [{ from: "observe", to: "code" }, { from: "code", to: "observe" }] });
    expect(cyc.ok).toBe(false);
    if (!cyc.ok) expect(cyc.error).toContain("cycle");
    expect(validatePlan({ nodes: [...nodes, nodes[0]] }).ok).toBe(false);
    expect(validatePlan({ nodes, edges: [{ from: "observe", to: "nope" }] }).ok).toBe(false);
    expect(validatePlan({ nodes, edges: [{ from: "code", to: "code" }] }).ok).toBe(false);
    expect(validatePlan({ nodes: [{ ...nodes[0], priority: 11 }] }).ok).toBe(false);
    expect(validatePlan({ nodes: [{ ...nodes[0], security_level: "L9" }] }).ok).toBe(false);
    expect(validatePlan({ nodes: [{ ...nodes[0], extra: 1 }] }).ok).toBe(false);
    expect(validatePlan({ nodes: [] }).ok).toBe(false);
    expect(validatePlan("x").ok).toBe(false);
    expect(validatePlan({ nodes: [{ ...nodes[0], key: "Majuscule" }] }).ok).toBe(false);
    expect(validatePlan({ nodes: [{ ...nodes[0], resources: ["clé invalide"] }] }).ok).toBe(false);
  });

  it("findCycle : A → B → C → A, et aucun cycle", () => {
    expect(findCycle(["a", "b", "c"], [{ from: "a", to: "b", kind: "hard" }, { from: "b", to: "c", kind: "hard" }, { from: "c", to: "a", kind: "hard" }])).toEqual(["a", "b", "c", "a"]);
    expect(findCycle(["a", "b", "c"], [{ from: "a", to: "b", kind: "hard" }, { from: "a", to: "c", kind: "hard" }])).toBeNull();
  });
});

describe("parallélisme effectif (§9.6)", () => {
  it("minimum des quatre plafonds, bornes 1–32, défaut 6", () => {
    expect(effectiveMaxParallel({})).toBe(6);
    expect(effectiveMaxParallel({ global: 6, user: 3, session: null, runtime: 8 })).toBe(3);
    expect(effectiveMaxParallel({ global: 6, user: 10, session: 1, runtime: 8 })).toBe(1);
    expect(effectiveMaxParallel({ global: 100 })).toBe(32);
    expect(effectiveMaxParallel({ global: 6, runtime: 0 })).toBe(1);
    expect(grantableSlots(6, 4, 5)).toBe(2);
    expect(grantableSlots(3, 3, 2)).toBe(0);
    expect(grantableSlots(3, 0, -1)).toBe(0);
    expect(parseGlobalMaxParallel(undefined)).toBe(6);
    expect(parseGlobalMaxParallel("3")).toBe(3);
    expect(parseGlobalMaxParallel("abc")).toBe(6);
  });
});

describe("flux SSE", () => {
  it("empreinte stable et trame", () => {
    const snap = { session: { id: "s", status: "RUNNING", plan_version: 1, updated_at: "t1" }, tasks: [{ id: "a", node_key: "a", status: "READY", attempt: 0, updated_at: "t1" }], busy_agents: 0, last_message_at: null, last_audit_seq: 3 };
    const d1 = snapshotDigest(snap);
    expect(snapshotDigest({ ...snap })).toBe(d1);
    expect(snapshotDigest({ ...snap, tasks: [{ ...snap.tasks[0], status: "RUNNING" }] })).not.toBe(d1);
    expect(sseFrame("snapshot", { a: 1 }, "x")).toBe('id: x\nevent: snapshot\ndata: {"a":1}\n\n');
    expect(sseFrame("ping", null)).toBe("event: ping\ndata: null\n\n");
  });
});
