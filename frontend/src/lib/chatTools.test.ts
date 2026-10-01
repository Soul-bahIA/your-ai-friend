import { describe, expect, it } from "vitest";
import {
  buildConfirmedActionBody,
  describeAction,
  proposalNotice,
  proposeToolCalls,
  transitionAction,
  type ProposedAction,
} from "@/lib/chatTools";

const call = (name: string, args: unknown, id = "call_1") => ({
  id,
  name,
  arguments: typeof args === "string" ? args : JSON.stringify(args),
});

describe("proposeToolCalls (S12)", () => {
  it("transforme les appels en actions PROPOSÉES, jamais exécutées", () => {
    const [a] = proposeToolCalls([call("create_formation", { topic: "Python" })], "conv-1");
    expect(a).toMatchObject({
      name: "create_formation",
      args: { topic: "Python" },
      status: "proposed",
      invalid: null,
      conversationId: "conv-1",
    });
  });

  it("ignore les entrées vides et donne des clés uniques", () => {
    const list = proposeToolCalls(
      [undefined, call("", {}), call("save_knowledge", { title: "a", content: "b" }), call("save_knowledge", { title: "c", content: "d" })],
      null,
    );
    expect(list).toHaveLength(2);
    expect(list[0].key).not.toBe(list[1].key);
  });

  it("marque non exécutables : JSON invalide, outil inconnu, argument manquant", () => {
    const [badJson, unknown, missing] = proposeToolCalls(
      [call("create_formation", "{oops"), call("delete_everything", {}), call("create_application", { appName: " " })],
      "c",
    );
    expect(badJson.invalid).toContain("JSON");
    expect(unknown.invalid).toBe("Action inconnue");
    expect(missing.invalid).toContain("appName");
  });
});

describe("transitionAction", () => {
  const proposed = (): ProposedAction => proposeToolCalls([call("create_formation", { topic: "x" })], "c")[0];

  it("proposed → executing → done", () => {
    const executing = transitionAction(proposed(), { type: "confirm" });
    expect(executing.status).toBe("executing");
    const done = transitionAction(executing, { type: "succeeded", text: "ok" });
    expect(done).toMatchObject({ status: "done", resultText: "ok" });
  });

  it("une action annulée ne peut plus être confirmée", () => {
    const cancelled = transitionAction(proposed(), { type: "cancel" });
    expect(cancelled.status).toBe("cancelled");
    expect(transitionAction(cancelled, { type: "confirm" }).status).toBe("cancelled");
  });

  it("pas de double exécution ni de confirmation d'une action invalide", () => {
    const executing = transitionAction(proposed(), { type: "confirm" });
    expect(transitionAction(executing, { type: "confirm" })).toBe(executing);
    expect(transitionAction(executing, { type: "cancel" })).toBe(executing);
    const invalid = proposeToolCalls([call("unknown_tool", {})], "c")[0];
    expect(transitionAction(invalid, { type: "confirm" }).status).toBe("proposed");
    expect(transitionAction(proposed(), { type: "succeeded", text: "x" }).status).toBe("proposed");
  });

  it("échec", () => {
    const failed = transitionAction(transitionAction(proposed(), { type: "confirm" }), { type: "failed", text: "boom" });
    expect(failed).toMatchObject({ status: "failed", resultText: "boom" });
  });
});

describe("buildConfirmedActionBody", () => {
  it("refuse une action non confirmée", () => {
    const action = proposeToolCalls([call("create_formation", { topic: "x" })], "c")[0];
    expect(() => buildConfirmedActionBody(action)).toThrow(/non confirmée/);
    expect(() => buildConfirmedActionBody(transitionAction(action, { type: "cancel" }))).toThrow();
  });

  it("porte confirmed:true une fois confirmée", () => {
    const action = transitionAction(proposeToolCalls([call("save_knowledge", { title: "T", content: "C" })], "c")[0], {
      type: "confirm",
    });
    expect(buildConfirmedActionBody(action)).toEqual({
      messages: [],
      action: { name: "save_knowledge", arguments: { title: "T", content: "C" }, confirmed: true },
      confirmed: true,
    });
  });
});

describe("carte de confirmation", () => {
  it("décrit l'action et ses arguments", () => {
    expect(describeAction("create_formation", { topic: "Python", details: "débutants" })).toEqual({
      title: "Créer une formation",
      fields: [
        { label: "Sujet", value: "Python", long: false },
        { label: "Détails", value: "débutants", long: false },
      ],
    });
    const kb = describeAction("save_knowledge", { title: "T", content: "x".repeat(700), tags: ["a", 1, "b"] });
    // Contenu affiché EN ENTIER (zone défilante), plus de troncature à 600 caractères (S12).
    expect(kb.fields.find((f) => f.label === "Contenu")).toEqual({ label: "Contenu", value: "x".repeat(700), long: true });
    expect(kb.fields.find((f) => f.label === "Tags")?.value).toBe("a, b");
    expect(describeAction("other", { a: 1 }).title).toBe("Action « other »");
  });

  it("montre tout ce qui sera exécuté : rien de caché après le 600e caractère (S12)", () => {
    const content = `${"Note légitime. ".repeat(48)}hidden payload`;
    expect(content.length).toBeGreaterThan(700);
    const [proposed] = proposeToolCalls(
      [call("save_knowledge", { title: "T", content, category: "c".repeat(450), tags: ["t".repeat(80)], extra: "ignoré" })],
      "c",
    );
    const card = describeAction(proposed.name, proposed.args);
    expect(card.fields.find((f) => f.label === "Contenu")?.value).toContain("hidden payload");

    const body = buildConfirmedActionBody(transitionAction(proposed, { type: "confirm" }));
    // Seuls les arguments affichés partent, et chacun figure en entier dans la carte.
    expect(Object.keys(body.action.arguments).sort()).toEqual(["category", "content", "tags", "title"]);
    const shown = card.fields.map((f) => f.value);
    for (const [key, sent] of Object.entries(body.action.arguments)) {
      const text = Array.isArray(sent) ? sent.join(", ") : String(sent);
      expect(shown, key).toContain(text.trim());
    }
  });

  it("formation / application : détails et description longs affichés en entier", () => {
    const details = `${"d".repeat(450)}FIN`;
    const formation = describeAction("create_formation", { topic: "Rust", details });
    expect(formation.fields[1]).toEqual({ label: "Détails", value: details, long: true });
    const appDesc = `ligne 1\nligne 2 ${"z".repeat(500)}`;
    const app = describeAction("create_application", { appName: "CRM", appDesc });
    expect(app.fields[1]).toEqual({ label: "Description", value: appDesc, long: true });
  });

  it("mentionne la proposition dans la réponse", () => {
    const list = proposeToolCalls([call("create_application", { appName: "CRM" })], "c");
    expect(proposalNotice(list)).toContain("Créer une application");
    expect(proposalNotice(list)).toContain("confirmation");
    expect(proposalNotice([])).toBe("");
  });
});
