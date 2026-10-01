// LOT 2 — contrat d'outils unique : node lit le catalogue GÉNÉRÉ (copie de
// shared/tools/catalog.json), plus aucune liste tenue à la main.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { fakeDb } from "./helpers/fakeDb";

vi.mock("../src/db.js", async () => (await import("./helpers/fakeDb")).dbMock);
vi.mock("../src/clients/iaClient.js", async (importOriginal) => ({
  ...(await importOriginal<object>()),
  planGoal: vi.fn(),
}));

const {
  AGENT_STEP_TYPES,
  PATH_KEYS,
  PATH_LIST_KEYS,
  REQUIRED_FIELDS,
  SENSITIVE_STEP_TYPES,
  STEP_PARAMS,
  TOOL_BY_TYPE,
  clampAndValidatePlanSteps,
  compactStep,
  findInvalidStep,
  findPathOutsideAllowed,
  requiresConfirmation,
} = await import("../src/lib/agentSteps");
const { TOOL_CATALOG, parseToolCatalog } = await import("../src/lib/toolCatalog");
const { MASKED_KEYS } = await import("../src/lib/redact");
const { planAndQueueGoal } = await import("../src/routes/agentGoal");
const iaClient = await import("../src/clients/iaClient");

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SHARED_CATALOG = path.resolve(HERE, "../../../shared/tools/catalog.json");
const LOCAL_COPY = path.resolve(HERE, "../src/generated/tool_catalog.json");
const WS = "C:\\Users\\me\\SoulbahWorkspace";
const U = "22222222-2222-4222-8222-222222222222";
const K = "33333333-3333-4333-8333-333333333333";

/** Remplace le marqueur de chemin des exemples par un dossier autorisé réel. */
function concretize(value: unknown): unknown {
  const ph = TOOL_CATALOG.workspace_placeholder;
  if (typeof value === "string") return value.startsWith(ph) ? WS + value.slice(ph.length).replace(/\//g, "\\") : value;
  if (Array.isArray(value)) return value.map(concretize);
  return value;
}

/** Valeur plausible d'un paramètre déclaré (sert à vérifier que compactStep le garde). */
function sampleValue(p: (typeof TOOL_CATALOG.tools)[number]["params"][number]): unknown {
  if (p.default !== undefined) return p.default;
  if (p.enum) return p.enum[0];
  const type = Array.isArray(p.type) ? p.type[0] : p.type;
  if (type === "array") return p.is_path ? [`${WS}\\a.mp4`] : ["x"];
  if (type === "number" || type === "integer") return p.min ?? 1;
  if (type === "boolean") return true;
  return p.is_path ? `${WS}\\f${p.extensions?.[0] ?? ".txt"}` : "x";
}

describe("catalogue généré (LOT 2)", () => {
  it.skipIf(!fs.existsSync(SHARED_CATALOG))("la copie de node-api est identique à shared/tools/catalog.json", () => {
    const norm = (f: string) => fs.readFileSync(f, "utf8").replace(/\r\n/g, "\n");
    expect(norm(LOCAL_COPY)).toBe(norm(SHARED_CATALOG));
  });

  it("types autorisés = noms + alias du catalogue, sans doublon", () => {
    const expected = TOOL_CATALOG.tools.flatMap((t) => [t.name, ...t.aliases]);
    expect([...AGENT_STEP_TYPES].sort()).toEqual([...expected].sort());
    expect(new Set(AGENT_STEP_TYPES).size).toBe(AGENT_STEP_TYPES.length);
    expect(TOOL_BY_TYPE.get("close_window")?.name).toBe("window");
  });

  it("compactStep garde CHAQUE paramètre déclaré, pour chaque type et alias", () => {
    for (const [type, tool] of TOOL_BY_TYPE) {
      const step: Record<string, unknown> = { type, note: "but", junk: 1 };
      for (const p of tool.params) step[p.name] = sampleValue(p);
      const { junk, ...expected } = step;
      void junk;
      expect(compactStep(step), type).toEqual(expected);
    }
  });

  it("les exemples du catalogue passent compactStep et toute la validation serveur", () => {
    for (const tool of TOOL_CATALOG.tools) {
      for (const ex of tool.examples) {
        const step = Object.fromEntries(Object.entries(ex).map(([k, v]) => [k, concretize(v)]));
        expect(compactStep(step), tool.name).toEqual(step);
        const checked = clampAndValidatePlanSteps([compactStep(step)]);
        expect(checked.ok, tool.name).toBe(true);
        expect(findInvalidStep([step]), tool.name).toBeNull();
        expect(findPathOutsideAllowed([step], [WS]), tool.name).toBeNull();
      }
    }
  });

  it("champs obligatoires dérivés du catalogue (dont cwd de run_command et les groupes « a|b »)", () => {
    expect(REQUIRED_FIELDS.run_command).toEqual(["program", "cwd"]);
    expect(REQUIRED_FIELDS.run_script).toEqual(["program", "cwd"]);
    expect(REQUIRED_FIELDS.open_app).toEqual(["app|software|name"]);
    expect(REQUIRED_FIELDS.close_window).toEqual(["window_title|title"]);
    expect(REQUIRED_FIELDS.move_mouse).toEqual(["x", "y"]);
    expect(REQUIRED_FIELDS.edit_video).toEqual(["clips", "output"]);
    expect(REQUIRED_FIELDS.wait).toEqual([]);
    expect(findInvalidStep([{ type: "move_mouse", x: 1 }])).toContain("« y »");
  });

  it("chemins contrôlés = paramètres is_path du catalogue (clés du LOT 1 + repo, LOT 12)", () => {
    expect([...PATH_KEYS].sort()).toEqual(["audio", "cwd", "dest", "output", "path", "repo", "src"]);
    expect(PATH_LIST_KEYS).toEqual(["clips"]);
    expect(findPathOutsideAllowed([{ type: "resolve_montage", clips: [`${WS}\\a.png`], audio: "D:/n.mp3", output: `${WS}\\o.mp4` }], [WS]))
      .toContain("D:/n.mp3");
  });

  it("étapes à confirmer = outils requires_confirmation (+ alias) : LOT 1 + git (LOT 12)", () => {
    expect([...SENSITIVE_STEP_TYPES].sort()).toEqual(
      [
        "run_command", "run_script", "shell", "write_file", "move_file", "move", "type_text", "type", "keyboard",
        "hotkey", "press", "key", "phone_tap", "phone_swipe", "phone_type", "phone_key", "phone_open_app",
        "git_merge", "git_branch_delete", "git_push",
      ].sort(),
    );
    expect(requiresConfirmation([{ type: "start_recording_bg" }, { type: "click" }])).toBe(false);
  });

  it("tout paramètre is_secret_text est masqué avant le LLM (redact.MASKED_KEYS)", () => {
    const secrets = TOOL_CATALOG.tools.flatMap((t) => t.params.filter((p) => p.is_secret_text).map((p) => p.name));
    expect(secrets.length).toBeGreaterThan(0);
    for (const s of secrets) expect(MASKED_KEYS).toContain(s);
  });

  it("paramètres par type plus précis qu'au LOT 1 : un paramètre d'un autre outil est retiré", () => {
    expect(STEP_PARAMS.read_file).toEqual(["path"]);
    expect(compactStep({ type: "scroll", dy: -3, x: 5, y: 5 })).toEqual({ type: "scroll", dy: -3 });
    expect(compactStep({ type: "phone_tap", x: 1, y: 2, path: "C:/x.png" })).toEqual({ type: "phone_tap", x: 1, y: 2 });
  });

  it("parseToolCatalog refuse une copie corrompue (type en double, groupe inconnu, catalogue vide)", () => {
    const clone = () => JSON.parse(JSON.stringify(TOOL_CATALOG)) as Record<string, unknown> & { tools: Record<string, unknown>[] };
    const dup = clone();
    dup.tools[1].aliases = [dup.tools[0].name as string];
    expect(() => parseToolCatalog(dup)).toThrow(/en double/);
    const badGroup = clone();
    badGroup.tools[0].required_any = [["inconnu", "x"]];
    expect(() => parseToolCatalog(badGroup)).toThrow(/required_any/);
    expect(() => parseToolCatalog({ ...clone(), tools: [] })).toThrow(/tools vide/);
    expect(parseToolCatalog(clone()).tools).toHaveLength(TOOL_CATALOG.tools.length);
  });
});

describe("start_recording_bg planifié (critère de sortie du LOT 2)", () => {
  const planned = [
    { type: "start_recording_bg", path: `${WS}\\demo.mp4`, fps: 15, monitor: 1, note: "filmer la démo" },
    { type: "open_app", app: "notepad", note: "ouvrir" },
    { type: "wait", seconds: 2 },
    { type: "stop_recording_bg", path: `${WS}\\demo.mp4`, fps: 99 },
  ];

  it("path et fps survivent à compactStep et à la validation", () => {
    const steps = planned.map((s) => compactStep(s));
    expect(steps[0]).toEqual({ type: "start_recording_bg", path: `${WS}\\demo.mp4`, fps: 15, monitor: 1, note: "filmer la démo" });
    // stop_recording_bg ne déclare que path : fps (inconnu de ce skill) est retiré.
    expect(steps[3]).toEqual({ type: "stop_recording_bg", path: `${WS}\\demo.mp4` });
    const checked = clampAndValidatePlanSteps(steps);
    expect(checked.ok).toBe(true);
    expect(findInvalidStep(steps)).toBeNull();
    expect(findPathOutsideAllowed(steps, [WS])).toBeNull();
    expect(findPathOutsideAllowed(steps, ["C:\\Autre"])).toContain("demo.mp4");
  });

  beforeEach(() => fakeDb.reset());

  it("POST /api/agent/goal (planAndQueueGoal) met en file le plan avec path et fps intacts", async () => {
    fakeDb.on(/SELECT id, label, allowed_dirs FROM agent_keys WHERE user_id = \$1/, {
      rows: [{ id: K, label: "PC", allowed_dirs: [WS] }],
    });
    fakeDb.on(/INSERT INTO agent_tasks/, (_sql, values) => ({ rows: [{ id: values[0] }] }));
    vi.mocked(iaClient.planGoal).mockResolvedValue({
      feasible: true,
      understanding: "filmer une démo du bloc-notes",
      reason: "",
      steps: planned,
    } as never);

    const out = await planAndQueueGoal(U, "filme une démo du bloc-notes");
    expect(out).toMatchObject({ ok: true, target_agent_key_id: K });
    const insert = fakeDb.find(/INSERT INTO agent_tasks/)[0];
    const payload = JSON.parse(String(insert.values[2])) as { steps: Record<string, unknown>[]; requires_confirmation: boolean };
    expect(payload.steps[0]).toMatchObject({ type: "start_recording_bg", path: `${WS}\\demo.mp4`, fps: 15 });
    expect(payload.steps[3]).toEqual({ type: "stop_recording_bg", path: `${WS}\\demo.mp4` });
    expect(payload.requires_confirmation).toBe(false);
  });
});
