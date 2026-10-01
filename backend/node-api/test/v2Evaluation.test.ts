// LOT 10 — DSL de critères et règles de verdict (fonctions pures).
import { describe, expect, it } from "vitest";
import { CRITERION_TYPES, assess, evaluateCriterion, normalizePath, parseCriteria, type ActionEvidence } from "../src/v2/evaluation/criteria";
import { allIdempotent } from "../src/v2/evaluation/engine";
import { rubricContext } from "../src/v2/evaluation/judge";

const SHA = "a".repeat(64);
const act = (over: Partial<ActionEvidence>): ActionEvidence => ({ step_index: 0, tool: "wait", status: "verified", params: {}, evidence: [], ...over });

describe("parseCriteria", () => {
  it("normalise : required par défaut, min_confidence par type, paramètres connus seulement", () => {
    const r = parseCriteria([{ type: "file_exists", path: "C:\\w\\a.txt" }, { type: "llm_rubric", rubric: "clair ?", required: false }]);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value[0]).toEqual({ type: "file_exists", required: true, min_confidence: "medium", params: { path: "C:\\w\\a.txt" } });
    expect(r.value[1]).toMatchObject({ type: "llm_rubric", required: false, min_confidence: "low" });
    expect(CRITERION_TYPES.length).toBe(10);
  });

  it("refuse : type inconnu, paramètre manquant ou inconnu, sha invalide, statut HTTP, confiance", () => {
    expect(parseCriteria([{ type: "magic" }]).ok).toBe(false);
    expect(parseCriteria([{ type: "file_exists" }]).ok).toBe(false);
    expect(parseCriteria([{ type: "file_exists", path: "x", extra: 1 }]).ok).toBe(false);
    expect(parseCriteria([{ type: "artifact_hash", sha256: "abc" }]).ok).toBe(false);
    expect(parseCriteria([{ type: "http_status", status: 999 }]).ok).toBe(false);
    expect(parseCriteria([{ type: "file_contains", path: "x" }]).ok).toBe(false);
    expect(parseCriteria([{ type: "command_succeeds", min_confidence: "énorme" }]).ok).toBe(false);
    expect(parseCriteria("x").ok).toBe(false);
    expect(parseCriteria(undefined)).toEqual({ ok: true, value: [] });
  });
});

describe("evaluateCriterion : chaque type sur des preuves", () => {
  const crit = (raw: Record<string, unknown>) => {
    const r = parseCriteria([raw]);
    if (!r.ok) throw new Error(r.error);
    return r.value[0];
  };

  it("file_exists : chemin normalisé, confiance minimale", () => {
    const a = act({ tool: "move_file", evidence: [{ kind: "file_path", confidence: "medium", value: "C:/W/Out.txt" }] });
    expect(normalizePath("C:/W/Out.txt")).toBe(normalizePath("c:\\w\\out.txt"));
    expect(evaluateCriterion(crit({ type: "file_exists", path: "c:\\w\\out.txt" }), [a])).toMatchObject({ passed: true, confidence: "medium", steps: [0] });
    expect(evaluateCriterion(crit({ type: "file_exists", path: "c:\\w\\out.txt", min_confidence: "high" }), [a]).passed).toBe(false);
    expect(evaluateCriterion(crit({ type: "file_exists", path: "c:\\w\\autre.txt" }), [a]).passed).toBe(false);
    // une étape non exécutée ne prouve rien
    expect(evaluateCriterion(crit({ type: "file_exists", path: "c:\\w\\out.txt" }), [{ ...a, status: "attempted" }]).passed).toBe(false);
  });

  it("file_contains : empreinte au chemin, ou texte observé", () => {
    const a = act({ tool: "write_file", params: { path: "C:\\w\\a.txt" }, evidence: [{ kind: "file_path", confidence: "medium", value: "C:\\w\\a.txt" }, { kind: "sha256", confidence: "high", sha256: SHA }] });
    expect(evaluateCriterion(crit({ type: "file_contains", path: "C:\\w\\a.txt", sha256: SHA }), [a])).toMatchObject({ passed: true, confidence: "high" });
    expect(evaluateCriterion(crit({ type: "file_contains", path: "C:\\w\\a.txt", sha256: "b".repeat(64) }), [a]).passed).toBe(false);
    const o = act({ tool: "run_command", evidence: [{ kind: "command_output", confidence: "medium", value: "Build OK en 3 s" }] });
    expect(evaluateCriterion(crit({ type: "file_contains", text: "Build OK" }), [o]).passed).toBe(true);
  });

  it("command_succeeds / tests_pass", () => {
    const run = (command: string, code: number) => act({ tool: "run_command", params: { command, args: ["run", "test"] }, evidence: [{ kind: "exit_code", confidence: "high", value: code }] });
    expect(evaluateCriterion(crit({ type: "command_succeeds" }), [run("npm", 0)]).passed).toBe(true);
    expect(evaluateCriterion(crit({ type: "command_succeeds" }), [run("npm", 1)]).passed).toBe(false);
    expect(evaluateCriterion(crit({ type: "command_succeeds", command: "git" }), [run("npm", 0)]).passed).toBe(false);
    expect(evaluateCriterion(crit({ type: "tests_pass" }), [run("npm", 0)]).passed).toBe(true); // « npm run test »
    expect(evaluateCriterion(crit({ type: "tests_pass" }), [act({ tool: "run_command", params: { command: "python", args: ["build.py"] }, evidence: [{ kind: "exit_code", confidence: "high", value: 0 }] })]).passed).toBe(false);
    expect(evaluateCriterion(crit({ type: "tests_pass" }), [act({ evidence: [{ kind: "test_report", confidence: "high", value: { total: 12, failed: 0 } }] })]).passed).toBe(true);
  });

  it("http_status, git_branch_contains, video_valid, ui_element_state, artifact_hash, llm_rubric", () => {
    expect(evaluateCriterion(crit({ type: "http_status", status: 200 }), [act({ evidence: [{ kind: "http_status", confidence: "high", value: 200 }] })]).passed).toBe(true);
    const git = act({ tool: "run_command", params: { command: "git", args: ["log", "main"] }, evidence: [{ kind: "exit_code", confidence: "high", value: 0 }, { kind: "command_output", confidence: "medium", value: "abc123 corrige le bug" }] });
    expect(evaluateCriterion(crit({ type: "git_branch_contains", branch: "main", text: "corrige le bug" }), [git]).passed).toBe(true);
    expect(evaluateCriterion(crit({ type: "video_valid" }), [act({ evidence: [{ kind: "video_probe", confidence: "high", value: { duration: 12.5, video_codec: "h264" } }] })]).passed).toBe(true);
    expect(evaluateCriterion(crit({ type: "video_valid" }), [act({ evidence: [{ kind: "video_probe", confidence: "high", value: { ok: false } }] })]).passed).toBe(false);
    expect(evaluateCriterion(crit({ type: "ui_element_state", window_title: "Bloc-notes" }), [act({ evidence: [{ kind: "window_title", confidence: "medium", description: "focus → « Sans titre - Bloc-notes »" }] })]).passed).toBe(true);
    expect(evaluateCriterion(crit({ type: "artifact_hash", sha256: SHA }), [act({ evidence: [{ kind: "screenshot", confidence: "low", sha256: SHA }] })])).toMatchObject({ passed: false, confidence: "low" });
    expect(evaluateCriterion(crit({ type: "artifact_hash", sha256: SHA, min_confidence: "low" }), [act({ evidence: [{ kind: "screenshot", confidence: "low", sha256: SHA }] })]).passed).toBe(true);
    expect(evaluateCriterion(crit({ type: "llm_rubric", rubric: "?" }), [])).toMatchObject({ passed: false, pending_llm: true });
  });
});

describe("assess : règles de verdict (§9.8)", () => {
  const facts = { simulated: false, hasSteps: true, resultOk: true, securityLevel: "L1" as const };
  const ok = act({ tool: "move_file", evidence: [{ kind: "file_path", confidence: "medium", value: "C:\\w\\x" }] });

  it("simulé → not_evaluable ; plan non joué → failure ; échec annoncé → failure", () => {
    expect(assess([], [ok], { ...facts, simulated: true }).verdict).toBe("not_evaluable");
    expect(assess([], [], facts).verdict).toBe("failure");
    expect(assess([], [act({ status: "attempted" })], facts).verdict).toBe("failure");
    expect(assess([], [], { ...facts, hasSteps: false }).verdict).toBe("success"); // tâche sans étapes (relecture…)
    expect(assess([], [ok], { ...facts, resultOk: false }).verdict).toBe("failure");
  });

  it("L2+ exige une preuve ≥ medium", () => {
    const weak = act({ tool: "type_text", evidence: [{ kind: "self_report", confidence: "none" }] });
    const r = assess([], [weak], { ...facts, securityLevel: "L2" });
    expect(r.verdict).toBe("failure");
    expect(r.reasons.join(" ")).toContain("≥ medium");
    expect(assess([], [weak, ok], { ...facts, securityLevel: "L2" }).verdict).toBe("success");
  });

  it("critères requis / facultatifs ; llm_rubric non jugé → failure (en attente)", () => {
    const c = parseCriteria([{ type: "file_exists", path: "C:\\w\\x" }, { type: "file_exists", path: "C:\\w\\y", required: false }]);
    if (!c.ok) throw new Error(c.error);
    const r = assess(c.value, [ok], facts);
    expect(r.verdict).toBe("partial");
    expect(r.confidence).toBe("medium");
    const req = parseCriteria([{ type: "file_exists", path: "C:\\w\\y" }]);
    if (!req.ok) throw new Error(req.error);
    expect(assess(req.value, [ok], facts).verdict).toBe("failure");
    const llm = parseCriteria([{ type: "llm_rubric", rubric: "?" }]);
    if (!llm.ok) throw new Error(llm.error);
    expect(assess(llm.value, [ok], facts).verdict).toBe("failure");
    const judged = new Map([[0, { type: "llm_rubric" as const, required: true, min_confidence: "low" as const, passed: true, confidence: "low" as const, reason: "ok", steps: [] }]]);
    expect(assess(llm.value, [ok], facts, judged)).toMatchObject({ verdict: "success", confidence: "low" });
  });

  it("rejouable seulement si toutes les étapes exécutées sont idempotentes ; contexte du juge borné", () => {
    expect(allIdempotent([act({ tool: "wait" }), act({ tool: "read_file" })])).toBe(true);
    expect(allIdempotent([act({ tool: "wait" }), act({ tool: "move_file" })])).toBe(false);
    const ctx = rubricContext({ rubric: "r", task: { id: "t", title: "Titre", role: "coder", security_level: "L1" }, actions: [ok], result: { ok: true } });
    expect(ctx).toContain("move_file");
    expect(ctx).toContain("file_path (medium)");
  });
});
