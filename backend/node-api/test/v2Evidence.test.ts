// LOT 9 — preuves typées (schéma partagé), détection de contenu binaire, règle de niveau.
import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { CONFIDENCES, EVIDENCE_KINDS, bestConfidence, containsBinaryBlob, meetsLevelRequirement, validateEvidence, validateEvidenceList } from "../src/v2/evidence";
import { artifactPath, sha256Hex } from "../src/v2/routes/artifacts";

describe("preuves (shared/schemas/evidence.schema.json)", () => {
  it("le validateur et le schéma partagé listent les mêmes types et confiances", () => {
    const schema = JSON.parse(fs.readFileSync(path.resolve(__dirname, "../../../shared/schemas/evidence.schema.json"), "utf8"));
    expect([...schema.properties.kind.enum].sort()).toEqual([...EVIDENCE_KINDS].sort());
    expect(schema.properties.confidence.enum).toEqual([...CONFIDENCES]);
    expect(Object.keys(schema.properties).sort()).toEqual(["artifact_id", "at", "confidence", "description", "kind", "sha256", "step_index", "value"]);
  });

  it("accepte une preuve bien formée, refuse kind/confidence inconnus, champ inconnu, valeur trop longue", () => {
    expect(validateEvidence({ kind: "exit_code", confidence: "high", value: 0 }).ok).toBe(true);
    expect(validateEvidence({ kind: "screenshot", confidence: "medium", sha256: "a".repeat(64) }).ok).toBe(true);
    expect(validateEvidence({ kind: "nope", confidence: "high" }).ok).toBe(false);
    expect(validateEvidence({ kind: "exit_code", confidence: "sure" }).ok).toBe(false);
    expect(validateEvidence({ kind: "exit_code", confidence: "high", extra: 1 }).ok).toBe(false);
    expect(validateEvidence({ kind: "command_output", confidence: "high", value: "x".repeat(4001) }).ok).toBe(false);
    expect(validateEvidence({ kind: "exit_code", confidence: "high", artifact_id: "pas-un-uuid" }).ok).toBe(false);
    expect(validateEvidence({ kind: "exit_code", confidence: "high", at: "hier" }).ok).toBe(false);
    expect(validateEvidence("texte").ok).toBe(false);
  });

  it("capture / vidéo : artefact obligatoire ; base64 et data URI interdits", () => {
    expect(validateEvidence({ kind: "screenshot", confidence: "medium" }).ok).toBe(false);
    const blob = "iVBORw0KGgo" + "A".repeat(300);
    expect(containsBinaryBlob(blob)).toBe(true);
    expect(containsBinaryBlob({ a: [{ image_b64: "x" }] })).toBe(true);
    expect(containsBinaryBlob("data:image/png;base64,AAAA")).toBe(true);
    expect(containsBinaryBlob({ note: "texte normal", n: 3 })).toBe(false);
    expect(containsBinaryBlob("f".repeat(64))).toBe(false); // une empreinte n'est pas un blob
    const r = validateEvidence({ kind: "command_output", confidence: "high", value: blob });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error).toContain("artefact");
  });

  it("liste : vide ok, 50 max, première erreur positionnée", () => {
    expect(validateEvidenceList(undefined)).toEqual({ ok: true, value: [] });
    expect(validateEvidenceList("x").ok).toBe(false);
    const bad = validateEvidenceList([{ kind: "exit_code", confidence: "high" }, { kind: "x", confidence: "high" }]);
    expect(bad.ok).toBe(false);
    if (!bad.ok) expect(bad.error).toContain("evidence[1]");
    expect(validateEvidenceList(Array.from({ length: 51 }, () => ({ kind: "exit_code", confidence: "high" }))).ok).toBe(false);
  });

  it("confiance : meilleure valeur ; une tâche L2+ exige ≥ medium (§9.8)", () => {
    expect(bestConfidence([])).toBeNull();
    expect(bestConfidence([{ kind: "self_report", confidence: "none" }, { kind: "window_title", confidence: "medium" }])).toBe("medium");
    expect(meetsLevelRequirement("L0", [])).toBe(true);
    expect(meetsLevelRequirement("L2", [{ kind: "self_report", confidence: "none" }])).toBe(false);
    expect(meetsLevelRequirement("L2", [{ kind: "window_title", confidence: "medium" }])).toBe(true);
    expect(meetsLevelRequirement("L3", [{ kind: "exit_code", confidence: "high" }])).toBe(true);
  });
});

describe("artefacts", () => {
  it("empreinte et chemin de stockage sûr", () => {
    expect(sha256Hex(Buffer.from("abc"))).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    const u = "a0000000-0000-4000-8000-000000000001";
    expect(artifactPath("C:\\m", u, "f".repeat(64))).toBe(path.join("C:\\m", "artifacts", u, "f".repeat(64)));
    expect(() => artifactPath("C:\\m", "../x", "f".repeat(64))).toThrow();
    expect(() => artifactPath("C:\\m", u, "..\\..\\etc")).toThrow();
  });
});
