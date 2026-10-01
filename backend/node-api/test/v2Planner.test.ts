// LOT 11 — planificateur : jeux golden de validateDag, gabarits, rôles publiés.
import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { ROLES, P1_ROLE_NAMES, rolesDocument } from "../src/v2/planner/roles";
import { desktopResource, validateDag, type DagContext } from "../src/v2/planner/validateDag";
import { TEMPLATE_NAMES, buildFromTemplate, criteriaFromSteps, levelFor, roleFor } from "../src/v2/planner/templates";
import { TOOL_BY_TYPE } from "../src/lib/agentSteps";

const GOLDEN = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "plans", "golden.json"), "utf8")) as {
  context: DagContext;
  cases: { name: string; plan: unknown; context?: Partial<DagContext>; expect: "ok" | string[] }[];
};
const CTX: DagContext = GOLDEN.context;

describe("validateDag — jeux golden (fixtures/plans/golden.json)", () => {
  for (const c of GOLDEN.cases) {
    it(c.name, () => {
      const r = validateDag(c.plan, { ...CTX, ...(c.context ?? {}) });
      if (c.expect === "ok") {
        expect(r.ok, JSON.stringify(r)).toBe(true);
      } else {
        expect(r.ok).toBe(false);
        if (r.ok) return;
        const all = r.errors.join(" | ");
        for (const fragment of c.expect) expect(all).toContain(fragment);
      }
    });
  }

  it("ressource exclusive desktop.input ajoutée aux nœuds qui pilotent le bureau, pas aux autres", () => {
    const r = validateDag(GOLDEN.cases[0].plan, CTX);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const byKey = new Map(r.plan.nodes.map((n) => [n.key, n]));
    expect(byKey.get("act")!.resources).toEqual([{ key: desktopResource(CTX.userId), mode: "exclusive" }]);
    expect(byKey.get("observe")!.resources).toEqual([]);
  });
});

describe("gabarits", () => {
  it("chaque gabarit produit un plan accepté par validateDag", () => {
    const params: Record<string, Record<string, unknown>> = {
      desktop_goal: { goal: "Écris bonjour dans le bloc-notes", steps: [{ type: "open_app", app: "notepad" }, { type: "type_text", text: "bonjour" }, { type: "screenshot" }] },
      formation: { topic: "Python", modules: ["Variables", { title: "Fonctions" }, "Classes"] },
      demo_video: { title: "Ouvrir le bloc-notes", output_dir: "C:\\w\\demos", steps: [{ type: "open_app", app: "notepad" }, { type: "type_text", text: "démo" }] },
      code_parallel: { repo: "C:\\w\\app", worktrees_dir: "C:\\w\\wt", session_slug: "s1", tasks: [{ key: "t1", steps: [] }, { key: "t2", steps: [] }] },
    };
    for (const name of TEMPLATE_NAMES) {
      const t = buildFromTemplate(name, params[name]);
      expect(t.ok, `${name} : ${JSON.stringify(t)}`).toBe(true);
      if (!t.ok) continue;
      const v = validateDag(t.plan, CTX);
      expect(v.ok, `${name} : ${JSON.stringify(v)}`).toBe(true);
    }
  });

  it("desktop_goal : observer d'abord, critère vérifiable ou grille, rôle déduit des outils", () => {
    const t = buildFromTemplate("desktop_goal", { goal: "taper", steps: [{ type: "click", x: 1, y: 1 }, { type: "type_text", text: "x" }] });
    expect(t.ok).toBe(true);
    if (!t.ok) return;
    expect(t.plan.nodes.map((n) => n.key)).toEqual(["observe", "act"]);
    expect(t.plan.nodes[1]).toMatchObject({ role: "desktop_operator", security_level: "L2" });
    expect((t.plan.nodes[1].acceptance_criteria as { type: string }[])[0].type).toBe("llm_rubric");
    const files = buildFromTemplate("desktop_goal", { goal: "écrire", steps: [{ type: "write_file", path: "C:\\w\\a.txt", content: "x" }] });
    expect(files.ok && files.plan.nodes.length).toBe(1); // pas de bureau : pas d'observation
    if (files.ok) expect(files.plan.nodes[0]).toMatchObject({ role: "coder", acceptance_criteria: [{ type: "file_exists", path: "C:\\w\\a.txt" }] });
    expect(buildFromTemplate("desktop_goal", { goal: "mixte", steps: [{ type: "click", x: 1, y: 1 }, { type: "run_command", program: "npm", cwd: "C:\\w" }] }).ok).toBe(false);
    expect(buildFromTemplate("desktop_goal", { goal: "", steps: [] }).ok).toBe(false);
  });

  it("formation : modules sans dépendance entre eux (parallèles), assemblage dépendant de tous", () => {
    const t = buildFromTemplate("formation", { topic: "SQL", modules: ["a", "b", "c", "d"] });
    expect(t.ok).toBe(true);
    if (!t.ok) return;
    expect(t.plan.nodes).toHaveLength(5);
    expect(t.plan.edges.every((e) => e.to === "assemble")).toBe(true);
    expect(t.plan.nodes.every((n) => n.role === "content_writer")).toBe(true);
    expect(buildFromTemplate("formation", { topic: "x", modules: [] }).ok).toBe(false);
    expect(buildFromTemplate("inconnu", {}).ok).toBe(false);
  });

  it("demo_video : enregistrement autour des actions, montage vérifié par probe", () => {
    const t = buildFromTemplate("demo_video", { title: "Démo Éditeur", output_dir: "C:\\w\\demos", steps: [{ type: "open_app", app: "notepad" }] });
    expect(t.ok).toBe(true);
    if (!t.ok) return;
    const record = t.plan.nodes.find((n) => n.key === "record")!;
    const steps = (record.spec as { steps: { type: string; path?: string }[] }).steps;
    expect(steps[0]).toMatchObject({ type: "start_recording_bg", path: "C:\\w\\demos\\demo_editeur_brut.mp4" });
    expect(steps.at(-1)).toMatchObject({ type: "stop_recording_bg" });
    expect(t.plan.nodes.find((n) => n.key === "montage")!.acceptance_criteria).toEqual([{ type: "video_valid", path: "C:\\w\\demos\\demo_editeur.mp4" }]);
  });

  it("aides : rôle, niveau et critères déduits des étapes", () => {
    expect(roleFor([{ type: "run_command" }, { type: "read_file" }])).toBe("coder");
    expect(roleFor([{ type: "phone_tap" }])).toBe("phone_operator");
    expect(roleFor([{ type: "inconnu" }])).toBeNull();
    expect(levelFor([{ type: "wait" }])).toBe("L1");
    expect(levelFor([{ type: "run_command" }])).toBe("L2");
    expect(criteriaFromSteps([{ type: "run_command", program: "npm" }, { type: "move_file", dest: "C:\\w\\b" }])).toEqual([
      { type: "command_succeeds", command: "npm" },
      { type: "file_exists", path: "C:\\w\\b" },
    ]);
  });
});

describe("rôles versionnés", () => {
  it("shared/roles/roles.json est à jour (régénérer depuis src/v2/planner/roles.ts)", () => {
    const published = JSON.parse(fs.readFileSync(path.resolve(__dirname, "../../../shared/roles/roles.json"), "utf8"));
    expect(published).toEqual(JSON.parse(JSON.stringify(rolesDocument())));
  });

  it("outils des rôles : tous dans le catalogue ; rôles P1 sans outils", () => {
    for (const r of ROLES) {
      for (const t of r.tools) expect(TOOL_BY_TYPE.get(t)?.name, `${r.name} → ${t}`).toBe(t);
      if (r.executor === "p1") expect(r.tools).toEqual([]);
    }
    expect(P1_ROLE_NAMES).toEqual(["qa_reviewer", "content_writer"]);
  });
});
