// LOT 11 — planificateur et orchestrateur sur Postgres réel. Critère §13 : les modules d'une
// formation s'exécutent EN PARALLÈLE (horodatages qui se chevauchent) ; plans proposés par un
// modèle validés avant d'être posés ; pont /api/agent/goal → mission V2 ; /demos via gabarit.
// Le service IA est simulé (vi.mock) : aucun appel réseau. Sauté sans TEST_DATABASE_URL.
import { randomBytes } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";

const DB_URL = (process.env.TEST_DATABASE_URL ?? "").trim();
const RUN = DB_URL !== "";
const TOKEN = randomBytes(32).toString("hex");
const U = "a0000000-0000-4000-8000-0000000000cb";
const MEDIA = fs.mkdtempSync(path.join(os.tmpdir(), "soulbah-planner-media-"));
if (RUN) {
  process.env.DATABASE_URL = DB_URL;
  process.env.DATABASE_SSL = "false";
  process.env.PG_SSL_CA = "";
  process.env.SOULBAH_ENV = "test";
  process.env.HOST = "127.0.0.1";
  process.env.AUTH_MODE = "dev-local";
  process.env.DEV_LOCAL_TOKEN = TOKEN;
  process.env.DEV_LOCAL_USER_ID = U;
  process.env.SOULBAH_APPROVAL_SECRET = randomBytes(32).toString("hex");
  process.env.SOULBAH_V2_GOAL_BRIDGE = "1";
  process.env.MEDIA_DIR = MEDIA;
  process.env.IA_SERVICE_URL = "http://127.0.0.1:9";
}

vi.mock("../../src/clients/iaClient.js", async (importOriginal) => ({
  ...(await importOriginal<object>()),
  planGoal: vi.fn(),
  proposePlan: vi.fn(),
}));

type Pool = { query: (sql: string, values?: unknown[]) => Promise<{ rows: Record<string, unknown>[]; rowCount: number | null }>; end: () => Promise<void> };

describe.skipIf(!RUN)("planificateur V2 (LOT 11)", () => {
  let app: FastifyInstance;
  let pool: Pool;
  let sched: typeof import("../../src/v2/scheduler/scheduler");
  let content: typeof import("../../src/v2/planner/contentRunner");
  let ia: typeof import("../../src/clients/iaClient");
  const jwt = { authorization: `Bearer ${TOKEN}` };
  const rawKey = "sbk_" + randomBytes(32).toString("hex");
  const agent = { "x-agent-key": rawKey };
  let runtimeId = "";
  let keyId = "";

  beforeAll(async () => {
    ({ pool } = (await import("../../src/db")) as unknown as { pool: Pool });
    const { hashKey } = await import("../../src/services/agentKeys");
    sched = await import("../../src/v2/scheduler/scheduler");
    content = await import("../../src/v2/planner/contentRunner");
    ia = await import("../../src/clients/iaClient");
    const { buildApp } = await import("../../src/app");
    app = await buildApp({ mediaDir: MEDIA });
    await pool.query("INSERT INTO auth.users (id, email) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING", [U, "planner@soulbah.local"]);
    const k = await pool.query("INSERT INTO agent_keys (user_id, key_hash, label, allowed_dirs) VALUES ($1, $2, 'PC planner', $3::jsonb) RETURNING id", [U, hashKey(rawKey), JSON.stringify(["C:\\w"])]);
    keyId = k.rows[0].id as string;
    const reg = await app.inject({ method: "POST", url: "/api/v2/runtime/register", headers: agent, payload: { hostname: "pc", version: "2.0.0", protocol: 1, max_slots: 8 } });
    runtimeId = reg.json().runtime_id;
  });

  afterAll(async () => {
    await pool.query("DELETE FROM soulbah.sessions WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM soulbah.artifacts WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM soulbah.runtimes WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM soulbah.permissions WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM formations WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM agent_tasks WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM agent_keys WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM user_roles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM profiles WHERE user_id = $1", [U]);
    await pool.query("DELETE FROM auth.users WHERE id = $1", [U]);
    await app.close();
    await pool.end();
    fs.rmSync(MEDIA, { recursive: true, force: true });
  });

  beforeEach(async () => {
    vi.mocked(ia.planGoal).mockReset();
    vi.mocked(ia.proposePlan).mockReset();
    const active = await pool.query("SELECT id FROM soulbah.sessions WHERE user_id = $1 AND status IN ('RUNNING', 'AWAITING_APPROVAL', 'DRAFT', 'PAUSED')", [U]);
    for (const r of active.rows) await app.inject({ method: "POST", url: `/api/v2/sessions/${r.id}/cancel`, headers: jwt, payload: {} });
  });

  async function newSession(goal = "mission") {
    const s = await app.inject({ method: "POST", url: "/api/v2/sessions", headers: jwt, payload: { goal } });
    expect(s.statusCode, s.body).toBe(201);
    return s.json().session.id as string;
  }

  it("formation par gabarit : modules rédigés EN PARALLÈLE (horodatages qui se chevauchent), puis assemblage", async () => {
    const sid = await newSession("formation SQL");
    const p = await app.inject({ method: "POST", url: `/api/v2/sessions/${sid}/propose`, headers: jwt, payload: { template: "formation", params: { topic: "SQL", modules: ["Sélections", "Jointures", "Agrégats"] } } });
    expect(p.statusCode, p.body).toBe(200);
    expect(p.json()).toMatchObject({ source: "template", session: { status: "AWAITING_APPROVAL" } });
    expect(p.json().tasks).toHaveLength(4);
    await app.inject({ method: "POST", url: `/api/v2/sessions/${sid}/approve`, headers: jwt });
    await sched.tick();
    // Les rédactions ne sont JAMAIS confiées à un runtime.
    const l = await app.inject({ method: "POST", url: "/api/v2/runtime/lease", headers: agent, payload: { runtime_id: runtimeId, slots: 8 } });
    expect(l.json().tasks).toEqual([]);

    let inFlight = 0;
    let maxInFlight = 0;
    const generate: import("../../src/v2/planner/contentRunner").ContentGenerator = async ({ spec, inputs }) => {
      inFlight++;
      maxInFlight = Math.max(maxInFlight, inFlight);
      await new Promise((r) => setTimeout(r, 400));
      inFlight--;
      if (spec.kind === "formation_assemble") return { kind: "formation", modules: inputs.map((i) => i.title) };
      return { kind: "formation_module", module: { title: (spec.module as { title: string }).title, sections: 3 } };
    };
    const first = await content.runContentTasks({ generate, mediaDir: MEDIA });
    expect(first).toMatchObject({ started: 3, completed: 3, failed: 0 }); // l'assemblage attend ses dépendances
    expect(maxInFlight).toBe(3);
    const mods = await pool.query("SELECT started_at, finished_at, status FROM soulbah.tasks WHERE session_id = $1 AND node_key LIKE 'module_%' ORDER BY node_key", [sid]);
    expect(mods.rows.every((r) => r.status === "COMPLETED")).toBe(true);
    const starts = mods.rows.map((r) => new Date(r.started_at as string).getTime());
    const ends = mods.rows.map((r) => new Date(r.finished_at as string).getTime());
    expect(Math.max(...starts)).toBeLessThan(Math.min(...ends)); // les trois intervalles se chevauchent

    await sched.tick(); // assemblage → READY
    const second = await content.runContentTasks({ generate, mediaDir: MEDIA });
    expect(second).toMatchObject({ started: 1, completed: 1 });
    await sched.tick(); // clôture de la session
    const s = await app.inject({ method: "GET", url: `/api/v2/sessions/${sid}`, headers: jwt });
    expect(s.json().session.status).toBe("COMPLETED");
    const assemble = (s.json().tasks as { node_key: string; result: { modules: string[] } }[]).find((t) => t.node_key === "assemble")!;
    expect(assemble.result.modules).toHaveLength(3);
  });

  it("contenu volumineux : stocké comme artefact sha256, référencé dans le résultat", async () => {
    const sid = await newSession("gros module");
    await app.inject({ method: "POST", url: `/api/v2/sessions/${sid}/propose`, headers: jwt, payload: { template: "formation", params: { topic: "Long", modules: ["Unique"] } } });
    await app.inject({ method: "POST", url: `/api/v2/sessions/${sid}/approve`, headers: jwt });
    await sched.tick();
    const big = "x".repeat(content.INLINE_RESULT_MAX_BYTES + 1000);
    const r = await content.runContentTasks({ generate: async ({ spec }) => (spec.kind === "formation_module" ? { kind: "formation_module", body: big } : { kind: "formation" }), mediaDir: MEDIA });
    expect(r.completed).toBe(1);
    const row = (await pool.query("SELECT result FROM soulbah.tasks WHERE session_id = $1 AND node_key = 'module_1'", [sid])).rows[0].result as { artifact_id: string; sha256: string; size_bytes: number };
    expect(row.artifact_id).toBeTruthy();
    expect(row.size_bytes).toBeGreaterThan(content.INLINE_RESULT_MAX_BYTES);
    expect(fs.existsSync(path.join(MEDIA, "artifacts", U, row.sha256))).toBe(true);
    expect(JSON.stringify(row)).not.toContain("xxxxxxxxxx");
  });

  it("échec de rédaction → ERROR → RETRYING (rédaction rejouable)", async () => {
    const sid = await newSession("échec");
    await app.inject({ method: "POST", url: `/api/v2/sessions/${sid}/propose`, headers: jwt, payload: { template: "formation", params: { topic: "T", modules: ["M"] } } });
    await app.inject({ method: "POST", url: `/api/v2/sessions/${sid}/approve`, headers: jwt });
    await sched.tick();
    const r = await content.runContentTasks({ generate: async () => { throw new Error("modèle indisponible"); }, mediaDir: MEDIA });
    expect(r).toMatchObject({ started: 1, failed: 1 });
    expect((await pool.query("SELECT status FROM soulbah.tasks WHERE session_id = $1 AND node_key = 'module_1'", [sid])).rows[0].status).toBe("RETRYING");
  });

  it("proposition du modèle : plan invalide → 422 avec les erreurs (rien n'est posé) ; plan valide → AWAITING_APPROVAL", async () => {
    const sid = await newSession("Tape bonjour");
    vi.mocked(ia.proposePlan).mockResolvedValueOnce({
      feasible: true,
      understanding: "taper",
      reason: "",
      plan: { nodes: [{ key: "act", title: "Taper", role: "desktop_operator", security_level: "L2", spec: { steps: [{ type: "type_text", text: "bonjour" }] } }], edges: [] },
    });
    const bad = await app.inject({ method: "POST", url: `/api/v2/sessions/${sid}/propose`, headers: jwt, payload: {} });
    expect(bad.statusCode).toBe(422);
    expect(bad.json().errors.join(" ")).toContain("sans observation préalable");
    expect(bad.json().errors.join(" ")).toContain("sans critère d'acceptation requis");
    expect(Number((await pool.query("SELECT count(*)::int AS n FROM soulbah.tasks WHERE session_id = $1", [sid])).rows[0].n)).toBe(0);
    // Le planificateur reçoit les rôles, les dossiers autorisés et le plafond de la mission.
    const call = vi.mocked(ia.proposePlan).mock.calls[0][0];
    expect(call.allowed_dirs).toEqual(["C:\\w"]);
    expect(call.roles.map((r) => r.name)).toContain("content_writer");

    vi.mocked(ia.proposePlan).mockResolvedValueOnce({
      feasible: true,
      understanding: "taper",
      reason: "",
      plan: {
        nodes: [
          { key: "observe", title: "Observer", role: "desktop_operator", security_level: "L1", spec: { steps: [{ type: "screenshot" }] } },
          { key: "act", title: "Taper", role: "desktop_operator", security_level: "L2", spec: { steps: [{ type: "type_text", text: "bonjour" }] }, acceptance_criteria: [{ type: "ui_element_state", window_title: "Bloc-notes" }] },
        ],
        edges: [{ from: "observe", to: "act" }],
      },
    });
    const ok = await app.inject({ method: "POST", url: `/api/v2/sessions/${sid}/propose`, headers: jwt, payload: { goal: "Tape bonjour dans le bloc-notes" } });
    expect(ok.statusCode, ok.body).toBe(200);
    expect(ok.json()).toMatchObject({ source: "llm", session: { status: "AWAITING_APPROVAL", plan_version: 1 } });
    vi.mocked(ia.proposePlan).mockResolvedValueOnce({ feasible: false, understanding: "?", reason: "hors capacités", plan: { nodes: [], edges: [] } });
    const nope = await app.inject({ method: "POST", url: `/api/v2/sessions/${sid}/propose`, headers: jwt, payload: {} });
    expect(nope.statusCode).toBe(422);
    expect(nope.json().reason).toBe("hors capacités");
  });

  it("gabarit avec un chemin hors workspace → 422 ; plan manuel aussi validé", async () => {
    const sid = await newSession("écrire");
    const p = await app.inject({ method: "POST", url: `/api/v2/sessions/${sid}/propose`, headers: jwt, payload: { template: "desktop_goal", params: { goal: "écrire", steps: [{ type: "write_file", path: "D:\\ailleurs\\x.txt", content: "x" }] } } });
    expect(p.statusCode).toBe(422);
    expect(p.json().errors.join(" ")).toContain("chemin hors des dossiers autorisés");
    const manual = await app.inject({ method: "POST", url: `/api/v2/sessions/${sid}/plan`, headers: jwt, payload: { plan: { nodes: [{ key: "a", title: "A", role: "hacker", security_level: "L0" }] } } });
    expect(manual.statusCode).toBe(422);
    expect(manual.json().errors[0]).toContain("rôle inconnu");
  });

  it("pont /api/agent/goal (SOULBAH_V2_GOAL_BRIDGE=1) : mission V2 en attente d'approbation, aucune tâche V1", async () => {
    vi.mocked(ia.planGoal).mockResolvedValueOnce({ understanding: "ouvrir et taper", feasible: true, reason: "", steps: [{ type: "open_app", app: "notepad" }, { type: "type_text", text: "salut" }] } as never);
    const r = await app.inject({ method: "POST", url: "/api/agent/goal", headers: jwt, payload: { goal: "Ouvre le bloc-notes et tape salut" } });
    expect(r.statusCode, r.body).toBe(200);
    expect(r.json()).toMatchObject({ success: true, v2: true, status: "AWAITING_APPROVAL" });
    expect((r.json().tasks as { node_key: string }[]).map((t) => t.node_key)).toEqual(["observe", "act"]);
    const env = (await pool.query("SELECT environment FROM soulbah.sessions WHERE id = $1", [r.json().session_id])).rows[0].environment as { source: string; agent_key_id: string };
    expect(env).toMatchObject({ source: "api/agent/goal", agent_key_id: keyId });
    expect(Number((await pool.query("SELECT count(*)::int AS n FROM agent_tasks WHERE user_id = $1", [U])).rows[0].n)).toBe(0);
    // Le planificateur V1 a reçu les dossiers du PC ciblé.
    expect(String(vi.mocked(ia.planGoal).mock.calls[0][1])).toContain("C:\\w");
    vi.mocked(ia.planGoal).mockResolvedValueOnce({ understanding: "?", feasible: false, reason: "impossible", steps: [] } as never);
    const no = await app.inject({ method: "POST", url: "/api/agent/goal", headers: jwt, payload: { goal: "voler la lune" } });
    expect(no.statusCode).toBe(422);
  });

  it("/api/formations/:id/demos : démonstration → mission V2 observer → filmer → monter", async () => {
    const f = await pool.query("INSERT INTO formations (user_id, title) VALUES ($1, 'Excel débutant') RETURNING id", [U]);
    vi.mocked(ia.planGoal).mockResolvedValueOnce({ understanding: "démo", feasible: true, reason: "", steps: [{ type: "open_app", app: "notepad" }, { type: "type_text", text: "=SOMME(A1:A3)" }] } as never);
    const r = await app.inject({ method: "POST", url: `/api/formations/${f.rows[0].id}/demos`, headers: jwt, payload: { demo: "Montrer une somme" } });
    expect(r.statusCode, r.body).toBe(201);
    expect((r.json().tasks as { node_key: string; role: string }[]).map((t) => `${t.node_key}:${t.role}`)).toEqual(["observe:desktop_operator", "record:desktop_operator", "montage:video_editor"]);
    const record = (await pool.query("SELECT spec, resources FROM soulbah.tasks WHERE session_id = $1 AND node_key = 'record'", [r.json().session_id])).rows[0];
    const steps = (record.spec as { steps: { type: string; path?: string }[] }).steps;
    expect(steps[0]).toMatchObject({ type: "start_recording_bg", path: "C:\\w\\excel_debutant_brut.mp4" });
    expect(record.resources).toEqual([{ key: `desktop.input:${U}`, mode: "exclusive" }]);
    expect((await app.inject({ method: "POST", url: `/api/formations/${f.rows[0].id}/demos`, headers: jwt, payload: {} })).statusCode).toBe(400);
  });
});
