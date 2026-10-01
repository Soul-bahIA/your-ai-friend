// Analyse incrémentale d'un flux Server-Sent Events (format OpenAI-compatible).
// Pur (sans React) pour être testable.

export type SseEvent =
  | { type: "data"; data: unknown }
  | { type: "done" }
  | { type: "invalid"; line: string };

/**
 * Crée un analyseur SSE. `push(chunk)` renvoie les événements des lignes COMPLÈTES ;
 * seule une ligne finale partielle (sans retour à la ligne) est conservée en tampon.
 * Une ligne `data:` complète mais non-JSON est signalée (`invalid`) puis ignorée —
 * elle n'est jamais ré-insérée dans le tampon (ce qui bloquait le reste de la réponse).
 */
export function createSseParser() {
  let buffer = "";

  const parseLine = (rawLine: string): SseEvent | null => {
    const line = rawLine.endsWith("\r") ? rawLine.slice(0, -1) : rawLine;
    if (line.trim() === "" || line.startsWith(":")) return null;
    if (!line.startsWith("data:")) return null;
    const payload = line.slice(5).trim();
    if (payload === "[DONE]") return { type: "done" };
    if (payload === "") return null;
    try {
      return { type: "data", data: JSON.parse(payload) };
    } catch {
      return { type: "invalid", line };
    }
  };

  return {
    push(chunk: string): SseEvent[] {
      buffer += chunk;
      const events: SseEvent[] = [];
      let idx: number;
      while ((idx = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 1);
        const ev = parseLine(line);
        if (ev) events.push(ev);
      }
      return events;
    },
    /** À appeler en fin de flux : traite la dernière ligne sans retour à la ligne. */
    flush(): SseEvent[] {
      const rest = buffer;
      buffer = "";
      const ev = rest ? parseLine(rest) : null;
      return ev ? [ev] : [];
    },
  };
}

export interface PendingToolCall {
  id: string;
  name: string;
  arguments: string;
}

interface ChatDeltaToolCall {
  index?: number;
  id?: string;
  function?: { name?: string; arguments?: string };
}

/**
 * Applique un chunk de complétion (choices[0].delta) : renvoie le texte à ajouter
 * et accumule les appels d'outils dans `toolCalls` (mutation volontaire).
 */
export function applyChatDelta(parsed: unknown, toolCalls: PendingToolCall[]): string {
  if (!parsed || typeof parsed !== "object") return "";
  const choices = (parsed as { choices?: unknown }).choices;
  if (!Array.isArray(choices) || !choices[0] || typeof choices[0] !== "object") return "";
  const delta = (choices[0] as { delta?: { content?: unknown; tool_calls?: unknown } }).delta;
  if (!delta) return "";

  if (Array.isArray(delta.tool_calls)) {
    for (const tc of delta.tool_calls as ChatDeltaToolCall[]) {
      if (typeof tc?.index !== "number") continue;
      const slot = (toolCalls[tc.index] ??= { id: tc.id ?? "", name: "", arguments: "" });
      if (tc.id && !slot.id) slot.id = tc.id;
      if (tc.function?.name) slot.name = tc.function.name;
      if (tc.function?.arguments) slot.arguments += tc.function.arguments;
    }
  }
  return typeof delta.content === "string" ? delta.content : "";
}
