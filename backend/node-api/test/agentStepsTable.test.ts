// T3 (catalogue d'outils unique — LOT 2 —, compactStep, cwd), S21 (chemins confinés) et agent_key_id.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  AGENT_STEP_TYPES,
  REQUIRED_FIELDS,
  STEP_PARAMS,
  compactStep,
  findInvalidStep,
  findPathOutsideAllowed,
  requiresConfirmation,
  validateGoalBody,
  validateTaskCreateBody,
} from "../src/lib/agentSteps";
import { isPathInside } from "../src/lib/paths";

describe("compactStep (T3)", () => {
  it("garde path et fps de start/stop_recording_bg", () => {
    expect(compactStep({ type: "start_recording_bg", path: "C:/w/demo.mp4", fps: 15, junk: 1 })).toEqual({
      type: "start_recording_bg",
      path: "C:/w/demo.mp4",
      fps: 15,
    });
    expect(compactStep({ type: "stop_recording_bg", path: "C:/w/demo.mp4" })).toEqual({
      type: "stop_recording_bg",
      path: "C:/w/demo.mp4",
    });
  });

  it("garde timeout/cwd (run_command), button/clicks (clic), method/interval (type_text)", () => {
    expect(compactStep({ type: "run_command", program: "git", args: ["status"], cwd: "C:/w", timeout: 60 })).toEqual({
      type: "run_command",
      program: "git",
      args: ["status"],
      cwd: "C:/w",
      timeout: 60,
    });
    expect(compactStep({ type: "click", x: 0, y: 10, button: "right", clicks: 2 })).toEqual({
      type: "click",
      x: 0,
      y: 10,
      button: "right",
      clicks: 2,
    });
    expect(compactStep({ type: "type_text", text: "bonjour", method: "typewrite", interval: 0.05 })).toEqual({
      type: "type_text",
      text: "bonjour",
      method: "typewrite",
      interval: 0.05,
    });
  });

  it("retire les champs inconnus et les valeurs nulles, garde note", () => {
    expect(compactStep({ type: "wait", seconds: null, note: "pause", password: "x" })).toEqual({ type: "wait", note: "pause" });
    expect(compactStep({ type: "inconnu", path: "x" })).toEqual({ type: "inconnu" });
  });
});

describe("findInvalidStep (T3)", () => {
  it("run_command exige cwd (sinon l'agent refuse toujours)", () => {
    expect(findInvalidStep([{ type: "run_command", program: "git", args: [] }])).toContain("cwd");
    expect(findInvalidStep([{ type: "run_command", program: "git", cwd: "C:/w" }])).toBeNull();
    expect(REQUIRED_FIELDS.shell).toEqual(["program", "cwd"]);
  });

  it("accepte les alias (software pour open_app, title pour window) ; path requis pour l'enregistrement", () => {
    expect(findInvalidStep([{ type: "open_software", software: "vscode" }])).toBeNull();
    expect(findInvalidStep([{ type: "focus_window", title: "Bloc-notes" }])).toBeNull();
    expect(findInvalidStep([{ type: "open_app" }])).toContain("app");
    expect(findInvalidStep([{ type: "start_recording_bg" }])).toContain("path");
  });
});

// Lecture SEULE des skills de l'agent : toute dérive (paramètre ou type ajouté côté agent
// sans manifeste, donc absent du catalogue généré) fait échouer ces tests.
const SKILLS_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../agent/skills");
const skillsAvailable = fs.existsSync(SKILLS_DIR);
const NOT_SKILLS = new Set(["__init__.py", "base.py", "manifests.py"]);

function parseSkillFile(src: string): { types: string[]; params: string[] } {
  const types = new Set<string>();
  for (const m of src.matchAll(/step_types\s*=\s*\(([^)]*)\)/g)) {
    for (const q of m[1].matchAll(/["']([a-z_0-9]+)["']/g)) types.add(q[1]);
  }
  const params = new Set<string>();
  for (const m of src.matchAll(/\bstep\.get\(\s*["']([a-z_0-9]+)["']/g)) params.add(m[1]);
  for (const m of src.matchAll(/\bstep\[\s*["']([a-z_0-9]+)["']\s*\]/g)) params.add(m[1]);
  params.delete("type");
  return { types: [...types], params: [...params] };
}

describe.skipIf(!skillsAvailable)("dérive catalogue ↔ agent/skills (T3, LOT 2)", () => {
  const files = skillsAvailable
    ? fs.readdirSync(SKILLS_DIR).filter((f) => f.endsWith(".py") && !NOT_SKILLS.has(f))
    : [];
  const parsed = new Map(files.map((f) => [f, parseSkillFile(fs.readFileSync(path.join(SKILLS_DIR, f), "utf8"))]));

  it("chaque type d'étape d'un skill de l'agent est dans le catalogue (et inversement)", () => {
    const skillTypes = [...parsed.values()].flatMap((p) => p.types);
    expect([...AGENT_STEP_TYPES].sort()).toEqual(skillTypes.sort());
  });

  it("paramètres lus par chaque fichier de skill = paramètres déclarés pour ses types", () => {
    for (const [f, p] of parsed) {
      if (p.types.length === 0) continue;
      const declared = new Set(p.types.flatMap((t) => STEP_PARAMS[t] ?? []));
      for (const param of p.params) {
        expect(declared.has(param), `${f} lit « ${param} », absent du catalogue (compactStep le perdrait)`).toBe(true);
      }
      expect([...declared].sort(), `${f} : paramètre déclaré jamais lu`).toEqual([...p.params].sort());
    }
  });

  it("le parseur détecte bien un paramètre (garde-fou du test lui-même)", () => {
    expect(parseSkillFile('step_types = ("a",)\nx = step.get("fps", 10)\ny = step["path"]')).toEqual({
      types: ["a"],
      params: ["fps", "path"],
    });
  });
});

describe("chemins hors whitelist (S21)", () => {
  const dirs = ["C:\\Users\\me\\SoulbahWorkspace"];

  it("accepte un chemin dans le dossier autorisé (casse et séparateurs Windows indifférents)", () => {
    expect(findPathOutsideAllowed([{ type: "write_file", path: "c:/users/ME/soulbahworkspace/a.txt" }], dirs)).toBeNull();
    expect(
      findPathOutsideAllowed([{ type: "run_command", program: "git", cwd: "C:\\Users\\me\\SoulbahWorkspace" }], dirs),
    ).toBeNull();
  });

  it("refuse hors dossier, chemin relatif, remontée .. et clips hors whitelist", () => {
    expect(findPathOutsideAllowed([{ type: "read_file", path: "C:/Users/me/agent/.env" }], dirs)).toContain("hors des dossiers");
    expect(findPathOutsideAllowed([{ type: "read_file", path: "notes.txt" }], dirs)).toContain("relatif");
    expect(findPathOutsideAllowed([{ type: "read_file", path: "C:/Users/me/SoulbahWorkspace/../x" }], dirs)).not.toBeNull();
    expect(
      findPathOutsideAllowed(
        [{ type: "edit_video", clips: ["C:/Users/me/SoulbahWorkspace/a.mp4", "D:/b.mp4"], output: "C:/Users/me/SoulbahWorkspace/o.mp4" }],
        dirs,
      ),
    ).toContain("D:/b.mp4");
    expect(findPathOutsideAllowed([{ type: "write_file", path: "C:/x.txt" }], [])).toContain("aucun dossier autorisé");
  });

  it("isPathInside : pas de faux positif par préfixe ni entre OS", () => {
    expect(isPathInside("C:\\workshop\\a", "C:\\work")).toBe(false);
    expect(isPathInside("/home/u/ws/a", "/home/u/ws")).toBe(true);
    expect(isPathInside("/home/u/ws/a", "C:\\ws")).toBe(false);
  });
});

describe("requires_confirmation et agent_key_id", () => {
  it("requiresConfirmation : vrai pour run_command / write_file / type_text / hotkey", () => {
    for (const t of ["run_command", "write_file", "type_text", "hotkey"]) expect(requiresConfirmation([{ type: t }])).toBe(true);
    expect(requiresConfirmation([{ type: "wait" }, { type: "screenshot" }])).toBe(false);
  });

  it("validateTaskCreateBody / validateGoalBody acceptent un agent_key_id uuid et refusent le reste", () => {
    const k = "33333333-3333-4333-8333-333333333333";
    const r = validateTaskCreateBody({ task_type: "t", payload: { steps: [{ type: "wait" }] }, agent_key_id: k });
    expect(r.ok && r.value.agent_key_id).toBe(k);
    expect(validateTaskCreateBody({ task_type: "t", payload: { steps: [{ type: "wait" }] }, agent_key_id: "pc-1" }).ok).toBe(false);
    expect(validateGoalBody({ goal: "x", agent_key_id: k })).toEqual({ ok: true, value: "x" });
    expect(validateGoalBody({ goal: "x", agent_key_id: 42 }).ok).toBe(false);
  });
});
