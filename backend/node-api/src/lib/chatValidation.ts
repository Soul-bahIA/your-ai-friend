// Validation des messages du chat (POST /api/chat).
import { isPlainObject } from "./sanitize";
import type { Result } from "./agentSteps";

export interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

export const MAX_CHAT_MESSAGES = 200; // au-delà : rejet
export const CHAT_CONTEXT_MESSAGES = 60; // seuls les N derniers sont envoyés au modèle
export const MAX_CHAT_MESSAGE_LEN = 20_000;
export const MAX_CHAT_TOTAL_LEN = 120_000;

/**
 * Valide `messages` : tableau de { role: 'user'|'assistant', content: string }.
 * Les champs supplémentaires sont ignorés (on ne relaie que role+content).
 * Garde les CHAT_CONTEXT_MESSAGES derniers, borne la longueur totale.
 */
export function validateChatMessages(messages: unknown): Result<ChatMessage[]> {
  if (!Array.isArray(messages)) return { ok: false, error: "messages doit être une liste" };
  if (messages.length === 0) return { ok: false, error: "messages ne peut pas être vide" };
  if (messages.length > MAX_CHAT_MESSAGES) {
    return { ok: false, error: `trop de messages (max ${MAX_CHAT_MESSAGES})` };
  }
  const out: ChatMessage[] = [];
  for (const [i, m] of messages.entries()) {
    if (!isPlainObject(m)) return { ok: false, error: `message ${i + 1} : objet attendu` };
    if (m.role !== "user" && m.role !== "assistant") {
      return { ok: false, error: `message ${i + 1} : role doit être 'user' ou 'assistant'` };
    }
    if (typeof m.content !== "string") return { ok: false, error: `message ${i + 1} : content (texte) requis` };
    if (m.content.length > MAX_CHAT_MESSAGE_LEN) {
      return { ok: false, error: `message ${i + 1} trop long (max ${MAX_CHAT_MESSAGE_LEN} caractères)` };
    }
    out.push({ role: m.role, content: m.content });
  }
  const kept = out.slice(-CHAT_CONTEXT_MESSAGES);
  const total = kept.reduce((n, m) => n + m.content.length, 0);
  if (total > MAX_CHAT_TOTAL_LEN) {
    return { ok: false, error: `conversation trop longue (max ${MAX_CHAT_TOTAL_LEN} caractères)` };
  }
  return { ok: true, value: kept };
}

export const CHAT_ACTION_NAMES = ["create_formation", "create_application", "save_knowledge"] as const;

/** Valide une action (tool-call) : { name, arguments: objet } avec des textes bornés. */
export function validateChatAction(action: unknown): Result<{ name: string; arguments: Record<string, unknown> }> {
  if (!isPlainObject(action)) return { ok: false, error: "action invalide" };
  if (typeof action.name !== "string" || !(CHAT_ACTION_NAMES as readonly string[]).includes(action.name)) {
    return { ok: false, error: "action inconnue" };
  }
  const args = action.arguments ?? {};
  if (!isPlainObject(args)) return { ok: false, error: "arguments (objet) requis" };
  if (JSON.stringify(args).length > 100_000) return { ok: false, error: "arguments trop volumineux" };
  const required: Record<string, string[]> = {
    create_formation: ["topic"],
    create_application: ["appName"],
    save_knowledge: ["title", "content"],
  };
  for (const f of required[action.name]) {
    if (typeof args[f] !== "string" || !(args[f] as string).trim()) {
      return { ok: false, error: `argument « ${f} » requis` };
    }
  }
  return { ok: true, value: { name: action.name, arguments: args } };
}
