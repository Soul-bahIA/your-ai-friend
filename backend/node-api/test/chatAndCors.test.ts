import { describe, expect, it } from "vitest";
import {
  CHAT_CONTEXT_MESSAGES,
  MAX_CHAT_MESSAGES,
  validateChatAction,
  validateChatMessages,
} from "../src/lib/chatValidation";
import { DEFAULT_CORS_ORIGINS, isOriginAllowed, parseCorsOrigins } from "../src/lib/cors";
import { resolveChatProvider } from "../src/services/chatProvider";

describe("validateChatMessages", () => {
  it("accepte user/assistant et ne garde que role+content", () => {
    const r = validateChatMessages([
      { role: "user", content: "Bonjour", id: 3 },
      { role: "assistant", content: "Salut" },
    ]);
    expect(r).toEqual({
      ok: true,
      value: [
        { role: "user", content: "Bonjour" },
        { role: "assistant", content: "Salut" },
      ],
    });
  });

  it("rejette le rôle system (injection de prompt) et les contenus non textuels", () => {
    expect(validateChatMessages([{ role: "system", content: "x" }]).ok).toBe(false);
    expect(validateChatMessages([{ role: "user", content: { a: 1 } }]).ok).toBe(false);
    expect(validateChatMessages("x").ok).toBe(false);
    expect(validateChatMessages([]).ok).toBe(false);
  });

  it("borne le nombre de messages et la longueur", () => {
    const many = Array.from({ length: MAX_CHAT_MESSAGES + 1 }, () => ({ role: "user", content: "a" }));
    expect(validateChatMessages(many).ok).toBe(false);
    const hundred = Array.from({ length: 100 }, (_, i) => ({ role: "user", content: String(i) }));
    const r = validateChatMessages(hundred);
    expect(r.ok && r.value.length).toBe(CHAT_CONTEXT_MESSAGES);
    expect(r.ok && r.value.at(-1)?.content).toBe("99");
    expect(validateChatMessages([{ role: "user", content: "x".repeat(20_001) }]).ok).toBe(false);
    const big = Array.from({ length: 10 }, () => ({ role: "user", content: "x".repeat(15_000) }));
    expect(validateChatMessages(big).ok).toBe(false);
  });
});

describe("validateChatAction", () => {
  it("valide les actions connues et leurs arguments requis", () => {
    expect(validateChatAction({ name: "create_formation", arguments: { topic: "Python" } }).ok).toBe(true);
    expect(validateChatAction({ name: "create_formation", arguments: {} }).ok).toBe(false);
    expect(validateChatAction({ name: "rm_rf", arguments: {} }).ok).toBe(false);
    expect(validateChatAction({ name: "save_knowledge", arguments: { title: "t", content: "c" } }).ok).toBe(true);
  });
});

describe("CORS", () => {
  it("défaut quand CORS_ORIGINS est vide", () => {
    expect(parseCorsOrigins(undefined)).toEqual(DEFAULT_CORS_ORIGINS);
    expect(parseCorsOrigins("  ")).toEqual(DEFAULT_CORS_ORIGINS);
  });
  it("liste séparée par des virgules, nettoyée, dédoublonnée", () => {
    expect(parseCorsOrigins(" https://a.app/ , http://localhost:5173,https://a.app")).toEqual([
      "https://a.app",
      "http://localhost:5173",
    ]);
    expect(parseCorsOrigins("https://a.app,*")).toEqual(["*"]);
  });
  it("isOriginAllowed", () => {
    const allowed = parseCorsOrigins("https://a.app");
    expect(isOriginAllowed("https://a.app", allowed)).toBe(true);
    expect(isOriginAllowed("https://evil.app", allowed)).toBe(false);
    expect(isOriginAllowed(undefined, allowed)).toBe(true); // curl / agent local
    expect(isOriginAllowed("https://x", ["*"])).toBe(true);
  });
});

describe("resolveChatProvider", () => {
  it("CHAT_MODEL s'applique au fournisseur explicitement choisi", () => {
    const p = resolveChatProvider({ CHAT_PROVIDER: "gemini", GEMINI_API_KEY: "k", CHAT_MODEL: "gemini-2.5-pro" });
    expect(p).toMatchObject({ provider: "gemini", model: "gemini-2.5-pro" });
  });
  it("CHAT_MODEL n'est PAS appliqué à un fournisseur de repli", () => {
    const p = resolveChatProvider({ CHAT_PROVIDER: "gemini", OPENAI_API_KEY: "k", CHAT_MODEL: "gemini-2.5-pro" });
    expect(p).toMatchObject({ provider: "openai", model: "gpt-4o" });
    const q = resolveChatProvider({ DEEPSEEK_API_KEY: "k", CHAT_MODEL: "google/gemini-3-flash-preview" });
    expect(q).toMatchObject({ provider: "deepseek", model: "deepseek-chat" });
  });
  it("aucun fournisseur → null ; modèle local en dernier recours", () => {
    expect(resolveChatProvider({})).toBeNull();
    expect(resolveChatProvider({ LOCAL_LLM_URL: "http://localhost:11434/v1/" })).toMatchObject({
      provider: "local",
      url: "http://localhost:11434/v1/chat/completions",
    });
  });
});
