// Stockage de l'historique du chat (V3) : Supabase (comportement historique) ou, en connexion
// locale (VITE_AUTH_MODE=dev-local), le plan de contrôle node-api (/api/chat/conversations) qui
// écrit dans la base PostgreSQL locale — l'interface fonctionne alors sans Supabase.
import { supabase } from "@/integrations/supabase/client";
import { apiFetch } from "@/lib/api";
import { devLocalAuth } from "@/lib/localAuth";

export interface ConversationRow {
  id: string;
  title: string;
  created_at: string;
}

export interface StoredMessage {
  role: "user" | "assistant" | "system";
  content: string;
}

export interface ChatStore {
  readonly kind: "supabase" | "api";
  list(userId: string): Promise<ConversationRow[]>;
  create(userId: string, title: string): Promise<ConversationRow>;
  remove(id: string): Promise<void>;
  messages(conversationId: string): Promise<StoredMessage[]>;
  save(conversationId: string, userId: string, role: StoredMessage["role"], content: string): Promise<void>;
  touch(conversationId: string): Promise<void>;
}

const supabaseStore: ChatStore = {
  kind: "supabase",
  async list(userId) {
    const { data, error } = await supabase
      .from("chat_conversations")
      .select("id, title, created_at")
      .eq("user_id", userId)
      .order("updated_at", { ascending: false });
    if (error) throw new Error(error.message);
    return data ?? [];
  },
  async create(userId, title) {
    const { data, error } = await supabase.from("chat_conversations").insert({ user_id: userId, title }).select("id, title, created_at").single();
    if (error || !data) throw new Error(error?.message ?? "création impossible");
    return data;
  },
  async remove(id) {
    const { error } = await supabase.from("chat_conversations").delete().eq("id", id);
    if (error) throw new Error(error.message);
  },
  async messages(conversationId) {
    const { data, error } = await supabase
      .from("chat_messages")
      .select("role, content")
      .eq("conversation_id", conversationId)
      .order("created_at", { ascending: true });
    if (error) throw new Error(error.message);
    return (data ?? []).map((m) => ({ role: m.role as StoredMessage["role"], content: m.content }));
  },
  async save(conversationId, userId, role, content) {
    const { error } = await supabase.from("chat_messages").insert({ conversation_id: conversationId, user_id: userId, role, content });
    if (error) throw new Error(error.message);
  },
  async touch(conversationId) {
    const { error } = await supabase.from("chat_conversations").update({ updated_at: new Date().toISOString() }).eq("id", conversationId);
    if (error) throw new Error(error.message);
  },
};

const apiStore: ChatStore = {
  kind: "api",
  async list() {
    return (await apiFetch<{ conversations: ConversationRow[] }>("/api/chat/conversations")).conversations;
  },
  async create(_userId, title) {
    return (await apiFetch<{ conversation: ConversationRow }>("/api/chat/conversations", { method: "POST", json: { title } })).conversation;
  },
  async remove(id) {
    await apiFetch(`/api/chat/conversations/${encodeURIComponent(id)}`, { method: "DELETE" });
  },
  async messages(conversationId) {
    return (await apiFetch<{ messages: StoredMessage[] }>(`/api/chat/conversations/${encodeURIComponent(conversationId)}/messages`)).messages;
  },
  async save(conversationId, _userId, role, content) {
    await apiFetch(`/api/chat/conversations/${encodeURIComponent(conversationId)}/messages`, { method: "POST", json: { role, content } });
  },
  async touch() {
    // L'enregistrement d'un message met déjà à jour la conversation côté serveur.
  },
};

export function chatStore(): ChatStore {
  return devLocalAuth() ? apiStore : supabaseStore;
}
