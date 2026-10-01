// LOT 12 — ordinateur, navigateur, VS Code, worktrees : catalogue, politique, critères, gabarit.
import { describe, expect, it } from "vitest";
import { TOOL_BY_TYPE } from "../src/lib/agentSteps";
import { decide } from "../src/v2/security/policy";
import { evaluateCriterion, parseCriteria, type ActionEvidence } from "../src/v2/evaluation/criteria";
import { buildFromTemplate, codeParallel } from "../src/v2/planner/templates";
import { validateDag, type DagContext } from "../src/v2/planner/validateDag";
import { ROLE_BY_NAME } from "../src/v2/planner/roles";

const CTX: DagContext = { userId: "a0000000-0000-4000-8000-000000000001", allowedDirs: ["C:\\w"], sessionMaxLevel: "L2" };
const act = (over: Partial<ActionEvidence>): ActionEvidence => ({ step_index: 0, tool: "wait", status: "verified", params: {}, evidence: [], ...over });
const crit = (raw: Record<string, unknown>) => {
  const r = parseCriteria([raw]);
  if (!r.ok) throw new Error(r.error);
  return r.value[0];
};

describe("catalogue LOT 12", () => {
  it("outils et niveaux", () => {
    const levels = Object.fromEntries(
      ["git_worktree", "git_commit", "git_merge", "git_branch_delete", "git_push", "browser_get", "ui_snapshot", "vscode_open"].map((t) => [t, TOOL_BY_TYPE.get(t)?.security_level]),
    );
    expect(levels).toEqual({
      git_worktree: "L1",
      git_commit: "L1",
      git_merge: "L2",
      git_branch_delete: "L3",
      git_push: "L3",
      browser_get: "L1",
      ui_snapshot: "L0",
      vscode_open: "L2",
    });
    expect(TOOL_BY_TYPE.get("git_merge")!.requires_confirmation).toBe(true);
    expect(TOOL_BY_TYPE.get("vscode_open")!.requires_desktop_input).toBe(true);
  });

  it("rôles : git pour le codeur (sans suppression ni push), web et interface pour le chercheur", () => {
    const coder = ROLE_BY_NAME.get("coder")!;
    expect(coder.tools).toEqual(expect.arrayContaining(["git_worktree", "git_commit", "git_merge"]));
    for (const r of ROLE_BY_NAME.values()) expect(r.tools.some((t) => t === "git_branch_delete" || t === "git_push"), r.name).toBe(false);
    expect(ROLE_BY_NAME.get("researcher")!.tools).toEqual(expect.arrayContaining(["browser_get", "ui_snapshot"]));
    expect(ROLE_BY_NAME.get("desktop_operator")!.tools).toEqual(expect.arrayContaining(["ui_snapshot", "vscode_open"]));
  });
});

describe("politique : branch -D refusé sans L3", () => {
  const grantAll = [{ level: "L2" as const, tools: ["*"] }];
  it("git_branch_delete et git_push : approbation par action L3, payload complet, jamais couverts par un grant", () => {
    for (const tool of ["git_branch_delete", "git_push"]) {
      const d = decide({ tool, userMaxLevel: "L3", sessionMaxLevel: "L3", sessionApproved: true, grants: grantAll });
      expect(d).toMatchObject({ decision: "approve_each", level: "L3", requiresPayload: true });
    }
  });
  it("au plafond L2 (défaut) : refusé", () => {
    expect(decide({ tool: "git_branch_delete", sessionApproved: true, grants: grantAll })).toMatchObject({ decision: "deny" });
  });
  it("fusion : confirmée à chaque fois ; worktree et commit : couverts par l'approbation de la session", () => {
    expect(decide({ tool: "git_merge", sessionApproved: true, grants: grantAll }).decision).toBe("approve_each");
    expect(decide({ tool: "git_worktree", sessionApproved: true }).decision).toBe("allow");
    expect(decide({ tool: "git_commit", sessionApproved: false }).decision).toBe("session_grant");
    expect(decide({ tool: "ui_snapshot" }).decision).toBe("allow");
  });
});

describe("critères alimentés par les nouveaux outils", () => {
  it("git_branch_contains : sortie de git_commit (confiance haute)", () => {
    const c = crit({ type: "git_branch_contains", branch: "soulbah/s1/t1", text: "soulbah:t1" });
    const ok = evaluateCriterion(c, [
      act({ tool: "git_commit", evidence: [{ kind: "exit_code", confidence: "high", value: 0 }, { kind: "command_output", confidence: "medium", value: "soulbah/s1/t1 abc123 soulbah:t1 travail" }] }),
    ]);
    expect(ok).toMatchObject({ passed: true, confidence: "high" });
    const ko = evaluateCriterion(c, [act({ tool: "git_commit", evidence: [{ kind: "exit_code", confidence: "high", value: 1 }, { kind: "command_output", confidence: "medium", value: "soulbah/s1/t1 soulbah:t1" }] })]);
    expect(ko.passed).toBe(false);
  });

  it("tests_pass et git_branch_contains : rapport de tests de git_merge", () => {
    const merge = act({
      tool: "git_merge",
      evidence: [
        { kind: "exit_code", confidence: "high", value: 0 },
        { kind: "command_output", confidence: "medium", value: "soulbah/s1/integration 0f0f ← soulbah/s1/t2" },
        { kind: "test_report", confidence: "high", value: { passed: true, returncode: 0 } },
      ],
    });
    expect(evaluateCriterion(crit({ type: "tests_pass" }), [merge]).passed).toBe(true);
    expect(evaluateCriterion(crit({ type: "git_branch_contains", branch: "soulbah/s1/integration", text: "soulbah/s1/t2" }), [merge]).passed).toBe(true);
    const red = act({ tool: "git_merge", status: "failed", evidence: [{ kind: "test_report", confidence: "high", value: { passed: false } }] });
    expect(evaluateCriterion(crit({ type: "tests_pass" }), [red]).passed).toBe(false);
  });

  it("ui_element_state, artifact_hash, http_status : preuves de ui_snapshot et browser_get", () => {
    const sha = "b".repeat(64);
    const snap = act({
      tool: "ui_snapshot",
      evidence: [
        { kind: "window_title", confidence: "high", value: "notes.txt - Bloc-notes" },
        { kind: "ui_state", confidence: "high", value: { name: "notes.txt - Bloc-notes", state: "foreground" } },
        { kind: "sha256", confidence: "high", sha256: sha },
      ],
    });
    expect(evaluateCriterion(crit({ type: "ui_element_state", name: "notes.txt - Bloc-notes", state: "foreground" }), [snap]).passed).toBe(true);
    expect(evaluateCriterion(crit({ type: "ui_element_state", window_title: "Bloc-notes" }), [snap]).passed).toBe(true);
    expect(evaluateCriterion(crit({ type: "artifact_hash", sha256: sha }), [snap]).passed).toBe(true);
    const web = act({ tool: "browser_get", evidence: [{ kind: "http_status", confidence: "high", value: { status: 200, url: "https://example.com/" } }] });
    expect(evaluateCriterion(crit({ type: "http_status", status: 200, url: "https://example.com/" }), [web]).passed).toBe(true);
  });
});

describe("gabarit code_parallel", () => {
  const params = {
    repo: "C:\\w\\app",
    worktrees_dir: "C:\\w\\wt",
    session_slug: "s1",
    test: { program: "npm", args: ["test"] },
    tasks: [
      { key: "t1", title: "Tri", steps: [{ type: "write_file", path: "C:\\w\\wt\\t1\\tri.py", content: "x" }] },
      { key: "t2", title: "Recherche", steps: [{ type: "write_file", path: "C:\\w\\wt\\t2\\recherche.py", content: "x" }] },
      { key: "t3", title: "Docs", steps: [{ type: "write_file", path: "C:\\w\\wt\\t3\\README.md", content: "x" }] },
    ],
  };

  it("3 codeurs indépendants (parallèles) → 3 relectures → fusion testée, accepté par validateDag", () => {
    const t = buildFromTemplate("code_parallel", params);
    expect(t.ok, JSON.stringify(t)).toBe(true);
    if (!t.ok) return;
    const v = validateDag(t.plan, CTX);
    expect(v.ok, JSON.stringify(v)).toBe(true);
    if (!v.ok) return;
    const keys = v.plan.nodes.map((n) => n.key);
    expect(keys).toEqual(["t1", "review_t1", "t2", "review_t2", "t3", "review_t3", "merge"]);
    // Aucune arête entre codeurs : ils peuvent tourner en même temps.
    const coders = new Set(["t1", "t2", "t3"]);
    expect(v.plan.edges.filter((e) => coders.has(e.from) && coders.has(e.to))).toEqual([]);
    expect(v.plan.edges.filter((e) => e.to === "merge").map((e) => e.from).sort()).toEqual(["review_t1", "review_t2", "review_t3"]);
    const t2 = v.plan.nodes.find((n) => n.key === "t2")!;
    const steps = (t2.spec as { steps: Record<string, unknown>[] }).steps;
    expect(steps[0]).toMatchObject({ type: "git_worktree", path: "C:\\w\\wt\\t2", branch: "soulbah/s1/t2" });
    expect(steps.at(-1)).toMatchObject({ type: "git_commit", cwd: "C:\\w\\wt\\t2" });
    expect(t2.acceptance_criteria[0]).toEqual({ type: "git_branch_contains", branch: "soulbah/s1/t2", text: "soulbah:t2" });
    const merge = v.plan.nodes.find((n) => n.key === "merge")!;
    expect(merge.resources).toEqual([{ key: "git.merge:s1", mode: "exclusive" }]);
    expect((merge.spec as { steps: { source: string }[] }).steps.map((s) => s.source)).toEqual(["soulbah/s1/t1", "soulbah/s1/t2", "soulbah/s1/t3"]);
    expect(merge.acceptance_criteria[0]).toEqual({ type: "tests_pass" });
    expect(v.plan.nodes.find((n) => n.key === "review_t2")!.spec).toEqual({ review_of_key: "t2" });
  });

  it("refus : clés invalides ou en double, session invalide, paramètres manquants", () => {
    expect(codeParallel({ ...params, session_slug: "S 1" }).ok).toBe(false);
    expect(codeParallel({ ...params, tasks: [{ key: "merge" }] }).ok).toBe(false);
    expect(codeParallel({ ...params, tasks: [{ key: "review_x" }] }).ok).toBe(false);
    expect(codeParallel({ ...params, tasks: [{ key: "a" }, { key: "a" }] }).ok).toBe(false);
    expect(codeParallel({ ...params, tasks: [] }).ok).toBe(false);
    expect(codeParallel({ ...params, repo: "" }).ok).toBe(false);
  });

  it("worktrees hors des dossiers autorisés : refusé par validateDag", () => {
    const t = buildFromTemplate("code_parallel", { ...params, worktrees_dir: "D:\\ailleurs" });
    expect(t.ok).toBe(true);
    if (!t.ok) return;
    const v = validateDag(t.plan, CTX);
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.errors.join(" | ")).toContain("hors des dossiers autorisés");
  });
});
