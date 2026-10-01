import { describe, expect, it } from "vitest";
import { applyChatDelta, createSseParser, type PendingToolCall } from "@/lib/sse";

const chunk = (content: string) => `data: ${JSON.stringify({ choices: [{ delta: { content } }] })}\n`;

/** Rejoue un flux SSE découpé en morceaux et renvoie le texte reconstitué. */
function replay(pieces: string[]) {
  const parser = createSseParser();
  const toolCalls: PendingToolCall[] = [];
  let text = "";
  let invalid = 0;
  let done = false;
  const handle = (events: ReturnType<typeof parser.push>) => {
    for (const ev of events) {
      if (ev.type === "done") done = true;
      else if (ev.type === "invalid") invalid++;
      else text += applyChatDelta(ev.data, toolCalls);
    }
  };
  for (const p of pieces) handle(parser.push(p));
  handle(parser.flush());
  return { text, invalid, done, toolCalls };
}

describe("createSseParser", () => {
  it("reconstitue le texte d'un flux normal", () => {
    const r = replay([chunk("Bon"), chunk("jour"), "data: [DONE]\n"]);
    expect(r.text).toBe("Bonjour");
    expect(r.done).toBe(true);
    expect(r.invalid).toBe(0);
  });

  it("gère une ligne coupée entre deux morceaux réseau", () => {
    const full = chunk("Salut") + chunk(" à tous");
    const r = replay([full.slice(0, 17), full.slice(17, 40), full.slice(40)]);
    expect(r.text).toBe("Salut à tous");
    expect(r.invalid).toBe(0);
  });

  it("ignore une ligne data: complète non-JSON sans perdre la suite (régression)", () => {
    const r = replay([chunk("Avant"), "data: {pas du json}\n", chunk(" après"), chunk(" fin")]);
    expect(r.text).toBe("Avant après fin");
    expect(r.invalid).toBe(1);
  });

  it("ignore commentaires, lignes vides, autres champs et CRLF", () => {
    const r = replay([": keep-alive\r\n", "\r\n", "event: message\r\n", "id: 3\n", chunk("ok").replace("\n", "\r\n")]);
    expect(r.text).toBe("ok");
    expect(r.invalid).toBe(0);
  });

  it("accepte 'data:' sans espace et traite la dernière ligne sans retour à la ligne", () => {
    const last = `data:${JSON.stringify({ choices: [{ delta: { content: "!" } }] })}`;
    const r = replay([chunk("Fin"), last]);
    expect(r.text).toBe("Fin!");
  });

  it("ne conserve en tampon que la ligne partielle finale", () => {
    const parser = createSseParser();
    expect(parser.push('data: {"a":')).toEqual([]);
    expect(parser.push("1}\n")).toEqual([{ type: "data", data: { a: 1 } }]);
    expect(parser.flush()).toEqual([]);
  });
});

describe("applyChatDelta", () => {
  it("accumule les appels d'outils fragmentés", () => {
    const calls: PendingToolCall[] = [];
    applyChatDelta({ choices: [{ delta: { tool_calls: [{ index: 0, id: "c1", function: { name: "create_formation", arguments: '{"topic":' } }] } }] }, calls);
    applyChatDelta({ choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: '"Python"}' } }] } }] }, calls);
    expect(calls).toEqual([{ id: "c1", name: "create_formation", arguments: '{"topic":"Python"}' }]);
    expect(JSON.parse(calls[0].arguments)).toEqual({ topic: "Python" });
  });

  it("tolère les objets inattendus", () => {
    const calls: PendingToolCall[] = [];
    expect(applyChatDelta(null, calls)).toBe("");
    expect(applyChatDelta({}, calls)).toBe("");
    expect(applyChatDelta({ choices: [] }, calls)).toBe("");
    expect(applyChatDelta({ choices: [{ delta: { content: 42 } }] }, calls)).toBe("");
    expect(applyChatDelta({ choices: [{ delta: { tool_calls: [{ function: { name: "x" } }] } }] }, calls)).toBe("");
    expect(calls).toEqual([]);
  });
});
