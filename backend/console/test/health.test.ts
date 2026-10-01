// Tests de la barre de santé (T32) — exécutés par `npm test` (node --test, types effacés par Node).
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { healthView, probeFromResponse } from "../src/api/health.ts";

describe("probeFromResponse", () => {
  it("décode un état lu", () => {
    assert.deepEqual(probeFromResponse(200, { status: "degraded", checks: { postgres: "ok", python_ia: "down" } }), {
      kind: "ok",
      health: { status: "degraded", checks: { postgres: "ok", python_ia: "down" } },
    });
  });

  it("un refus HTTP n'est pas un état (401 hors dev)", () => {
    assert.deepEqual(probeFromResponse(401, { error: "Non authentifié" }), { kind: "http", status: 401 });
    assert.deepEqual(probeFromResponse(503, null), { kind: "http", status: 503 });
  });

  it("corps 2xx inexploitable ; check non textuel = panne", () => {
    assert.deepEqual(probeFromResponse(200, { error: "x" }), { kind: "invalid" });
    assert.deepEqual(probeFromResponse(200, null), { kind: "invalid" });
    const probe = probeFromResponse(200, { status: "ok", checks: { postgres: { up: true } } });
    assert.deepEqual(probe, { kind: "ok", health: { status: "ok", checks: { postgres: "down" } } });
  });
});

describe("healthView (T32)", () => {
  it("401/403 → « connexion requise », pas « API injoignable »", () => {
    for (const status of [401, 403]) {
      const view = healthView({ kind: "http", status });
      assert.equal(view.tone, "warn");
      assert.match(view.message, /Connexion requise/);
      assert.doesNotMatch(view.message, /injoignable/);
    }
  });

  it("aucune réponse → backend arrêté ou origine absente de CORS_ORIGINS", () => {
    const view = healthView({ kind: "network" }, "http://localhost:5173");
    assert.equal(view.tone, "down");
    assert.match(view.message, /injoignable/);
    assert.match(view.message, /http:\/\/localhost:5173/);
    assert.match(view.message, /CORS_ORIGINS/);
  });

  it("autres erreurs HTTP et réponse invalide", () => {
    assert.deepEqual(healthView({ kind: "http", status: 500 }), { tone: "down", message: "API en erreur (HTTP 500)", checks: [] });
    assert.equal(healthView({ kind: "invalid" }).tone, "down");
  });

  it("état lu : pastilles par dépendance", () => {
    const view = healthView({ kind: "ok", health: { status: "degraded", checks: { postgres: "ok", python_ia: "down" } } });
    assert.deepEqual(view, {
      tone: "warn",
      message: "API degraded",
      checks: [
        ["postgres", "ok"],
        ["python_ia", "down"],
      ],
    });
    assert.equal(healthView({ kind: "ok", health: { status: "ok", checks: {} } }).tone, "ok");
  });

  it("en attente de la première sonde", () => {
    assert.deepEqual(healthView(null), { tone: "warn", message: "Vérification des services…", checks: [] });
  });
});
