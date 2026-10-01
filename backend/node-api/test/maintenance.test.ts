// Maintenance (rétention des médias T37), reaper global (T19), tâches de fond (T17),
// intégration python-ia (x-deadline-ms, x-llm-usage, statuts), masquage (contrat §12).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { fakeDb } from "./helpers/fakeDb";
import { maskTypedText } from "../src/lib/redact";
import { mapUpstreamStatus } from "../src/lib/upstream";
import { parseLlmUsage } from "../src/services/llmUsage";

vi.mock("../src/db.js", async () => (await import("./helpers/fakeDb")).dbMock);

const { mediaNameFromUrl, purgeMedia, selectMediaToPurge } = await import("../src/services/maintenance");
const { reapStaleTasks, REAPER_LOCK_KEY } = await import("../src/services/reaper");
const { runInBackground, drainBackgroundJobs, pendingBackgroundJobs } = await import("../src/services/backgroundJobs");
const { deadlineHeaderMs } = await import("../src/clients/iaClient");

const DAY = 86_400_000;
const NOW = Date.parse("2026-10-01T00:00:00Z");

beforeEach(() => fakeDb.reset());

describe("rétention des médias (T37)", () => {
  it("selectMediaToPurge : vieux ET non référencé ET fichier visible", () => {
    const files = [
      { name: "vieux.mp4", mtimeMs: NOW - 40 * DAY, isFile: true },
      { name: "reference.mp4", mtimeMs: NOW - 40 * DAY, isFile: true },
      { name: "recent.pdf", mtimeMs: NOW - 2 * DAY, isFile: true },
      { name: ".gitkeep", mtimeMs: NOW - 400 * DAY, isFile: true },
      { name: "dossier", mtimeMs: NOW - 400 * DAY, isFile: false },
    ];
    expect(selectMediaToPurge(files, new Set(["reference.mp4"]), NOW, 30)).toEqual(["vieux.mp4"]);
    expect(selectMediaToPurge(files, new Set(), NOW, 0)).toEqual([]);
    expect(mediaNameFromUrl("/media/formation_a.mp4")).toBe("formation_a.mp4");
    expect(mediaNameFromUrl("https://ailleurs/x.mp4")).toBeNull();
  });

  it("purgeMedia : supprime les fichiers orphelins, jamais ceux d'une formation (video_url / pdf_url)", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "soulbah-purge-"));
    const old = (NOW - 60 * DAY) / 1000;
    for (const f of ["orphelin.mp4", "video.mp4", "support.pdf", "neuf.mp4"]) fs.writeFileSync(path.join(dir, f), "x");
    for (const f of ["orphelin.mp4", "video.mp4", "support.pdf"]) fs.utimesSync(path.join(dir, f), old, old);
    fakeDb.on(/FROM formations/, { rows: [{ video_url: "/media/video.mp4", pdf_url: "/media/support.pdf" }] });
    const removed = await purgeMedia(dir, NOW + 30 * DAY);
    expect(removed).toBe(1);
    expect(fs.readdirSync(dir).sort()).toEqual(["neuf.mp4", "support.pdf", "video.mp4"]);
  });

  it("purgeMedia : références illisibles (DB en panne) → rien n'est supprimé", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "soulbah-purge-"));
    fs.writeFileSync(path.join(dir, "a.mp4"), "x");
    fs.utimesSync(path.join(dir, "a.mp4"), 0, 0);
    fakeDb.on(/FROM formations/, () => {
      throw new Error("Connection terminated");
    });
    await expect(purgeMedia(dir, NOW)).rejects.toThrow();
    expect(fs.existsSync(path.join(dir, "a.mp4"))).toBe(true);
  });
});

describe("reaper global (T19)", () => {
  it("verrou consultatif non obtenu (autre instance) → aucune mise à jour", async () => {
    fakeDb.on(/pg_try_advisory_xact_lock/, { rows: [{ locked: false }] });
    expect(await reapStaleTasks(180, 3)).toEqual({ locked: false, cancelled: 0, requeued: 0, abandoned: 0 });
    expect(fakeDb.find(/UPDATE agent_tasks/)).toHaveLength(0);
    expect(fakeDb.calls[0].values).toEqual([REAPER_LOCK_KEY]);
  });

  it("verrou obtenu → stop→cancelled, requeue, abandon, tous utilisateurs, avec évènements", async () => {
    fakeDb.on(/pg_try_advisory_xact_lock/, { rows: [{ locked: true }] });
    fakeDb.on(/SET status = 'cancelled'/, { rows: [{ id: "t1", user_id: "u1" }] });
    fakeDb.on(/SET status = 'pending'/, { rows: [{ id: "t2", user_id: "u2", requeue_count: 1 }] });
    fakeDb.on(/SET status = 'failed'/, { rows: [] });
    const r = await reapStaleTasks(180, 3);
    expect(r).toEqual({ locked: true, cancelled: 1, requeued: 1, abandoned: 0 });
    const events = fakeDb.find(/INSERT INTO agent_events/).map((c) => [c.values[0], c.values[2]]);
    expect(events).toEqual([
      ["t1", "task_cancelled"],
      ["t2", "task_requeued"],
    ]);
    expect(fakeDb.find(/UPDATE agent_tasks/).every((c) => !/user_id = \$/.test(c.sql))).toBe(true);
  });
});

describe("tâches de fond suivies (T17)", () => {
  it("une erreur est journalisée sans rejet ; l'arrêt attend les tâches en cours", async () => {
    let done = false;
    const failing = runInBackground("test-échec", async () => {
      throw new Error("boom");
    });
    await expect(failing).resolves.toBeUndefined();
    void runInBackground("test-lent", async () => {
      await new Promise((r) => setTimeout(r, 30));
      done = true;
    });
    expect(pendingBackgroundJobs()).toBeGreaterThan(0);
    expect(await drainBackgroundJobs(1000)).toBe(true);
    expect(done).toBe(true);
  });
});

describe("intégration python-ia", () => {
  it("x-deadline-ms = délai node restant moins une marge, borné", () => {
    expect(deadlineHeaderMs(120_000)).toBe(118_000);
    expect(deadlineHeaderMs(900_000)).toBe(898_000);
    expect(deadlineHeaderMs(500)).toBe(1_000);
  });

  it("x-llm-usage : analyse tolérante", () => {
    expect(parseLlmUsage('{"calls":2,"input_tokens":10,"output_tokens":5,"models":["m"]}')).toEqual({
      calls: 2,
      input_tokens: 10,
      output_tokens: 5,
      models: ["m"],
    });
    expect(parseLlmUsage("pas du json")).toBeNull();
    expect(parseLlmUsage(null)).toBeNull();
  });

  it("nouveaux statuts amont : 499 → 504, 502 tronqué, 503, jamais 401 ni détail exposé", () => {
    expect(mapUpstreamStatus(499).status).toBe(504);
    expect(mapUpstreamStatus(502)).toMatchObject({ status: 502, exposeDetail: false });
    expect(mapUpstreamStatus(503).status).toBe(503);
    expect(mapUpstreamStatus(401).status).toBe(502);
    expect(mapUpstreamStatus(400).exposeDetail).toBe(false);
  });
});

describe("masquage du texte saisi (contrat §12)", () => {
  it("text / content masqués partout, sans double masquage", () => {
    const out = maskTypedText({
      steps: [{ type: "type_text", text: "secret" }, { type: "write_file", path: "C:/a", content: "abc" }],
      result: { steps: [{ data: { text: "[texte masqué : 6 car.]" } }] },
    });
    expect(out.steps[0].text).toBe("[texte masqué : 6 car.]");
    expect(out.steps[1]).toEqual({ type: "write_file", path: "C:/a", content: "[texte masqué : 3 car.]" });
    expect(out.result.steps[0].data.text).toBe("[texte masqué : 6 car.]");
  });
});
