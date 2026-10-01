import { useState, useRef, useEffect, useCallback } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet";
import { Brain, Send, Loader2, User, Plus, Trash2, MessageSquare, Sparkles, Menu } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { useIsMobile } from "@/hooks/use-mobile";
import { apiFetch, apiFetchRaw, ApiError, errorMessage, isAbortError } from "@/lib/api";
import { applyChatDelta, createSseParser, type PendingToolCall } from "@/lib/sse";
import ConfirmAction from "@/components/ConfirmAction";
import ErrorState from "@/components/ErrorState";
import { toast } from "sonner";

type Msg = { role: "user" | "assistant"; content: string };
type Conversation = { id: string; title: string; created_at: string };

interface ActionResult {
  success?: boolean;
  type?: string;
  title?: string;
  lessonsCount?: number;
  error?: string;
}

const AiChat = () => {
  const { user } = useAuth();
  const userId = user?.id;
  const isMobile = useIsMobile();
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [conversationsError, setConversationsError] = useState<string | null>(null);
  const [activeConversationId, setActiveConversationId] = useState<string | null>(null);
  const [messages, setMessages] = useState<Msg[]>([]);
  const [messagesError, setMessagesError] = useState<string | null>(null);
  const [messagesReload, setMessagesReload] = useState(0);
  const [input, setInput] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [showConversations, setShowConversations] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);
  // Conversation dans laquelle une réponse est en cours de streaming : on ne recharge
  // PAS ses messages depuis la DB (le fetch écraserait la réponse en cours).
  const streamingConvRef = useRef<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const abortStream = useCallback(() => {
    abortRef.current?.abort();
    abortRef.current = null;
    streamingConvRef.current = null;
    setIsLoading(false);
  }, []);

  // Interrompt le flux en cours si le composant est démonté.
  useEffect(() => () => abortRef.current?.abort(), []);

  const loadConversations = useCallback(async () => {
    if (!userId) return;
    setConversationsError(null);
    const { data, error } = await supabase
      .from("chat_conversations")
      .select("id, title, created_at")
      .eq("user_id", userId)
      .order("updated_at", { ascending: false });
    if (error) {
      console.error("Error loading conversations:", error);
      setConversationsError(error.message);
      return;
    }
    setConversations(data ?? []);
  }, [userId]);

  useEffect(() => {
    loadConversations();
  }, [loadConversations]);

  useEffect(() => {
    setMessagesError(null);
    if (!activeConversationId || !userId) {
      setMessages([]);
      return;
    }
    // Conversation en cours de streaming : les messages sont déjà à l'écran.
    if (streamingConvRef.current === activeConversationId) return;

    let ignore = false;
    (async () => {
      const { data, error } = await supabase
        .from("chat_messages")
        .select("role, content")
        .eq("conversation_id", activeConversationId)
        .order("created_at", { ascending: true });
      // Réponse obsolète (l'utilisateur a changé de conversation entre-temps).
      if (ignore) return;
      if (error) {
        console.error("Error loading messages:", error);
        setMessagesError(error.message);
        setMessages([]);
        return;
      }
      setMessages((data ?? []).map((m) => ({ role: m.role as Msg["role"], content: m.content })));
    })();
    return () => {
      ignore = true;
    };
  }, [activeConversationId, userId, messagesReload]);

  useEffect(() => {
    scrollRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  const createConversation = async (firstMessage: string) => {
    if (!userId) return null;
    const title = firstMessage.slice(0, 60) + (firstMessage.length > 60 ? "..." : "");
    const { data, error } = await supabase
      .from("chat_conversations")
      .insert({ user_id: userId, title })
      .select("id, title, created_at")
      .single();
    if (error || !data) {
      console.error("Conversation creation error:", error);
      toast.error("Erreur lors de la création de la conversation");
      return null;
    }
    setConversations((prev) => [data, ...prev]);
    return data.id;
  };

  const saveMessage = async (conversationId: string, role: Msg["role"], content: string) => {
    if (!userId) return false;
    const { error } = await supabase.from("chat_messages").insert({
      conversation_id: conversationId,
      user_id: userId,
      role,
      content,
    });
    if (error) {
      console.error("Error saving message:", error);
      toast.error("Le message n'a pas pu être enregistré", { description: error.message });
      return false;
    }
    return true;
  };

  const deleteConversation = async (id: string) => {
    const { error } = await supabase.from("chat_conversations").delete().eq("id", id);
    if (error) {
      toast.error("Suppression impossible", { description: error.message });
      return;
    }
    setConversations((prev) => prev.filter((c) => c.id !== id));
    if (activeConversationId === id) {
      if (streamingConvRef.current === id) abortStream();
      setActiveConversationId(null);
      setMessages([]);
    }
    toast.success("Conversation supprimée");
  };

  const executeAction = async (actionName: string, actionArgs: unknown, signal: AbortSignal): Promise<string> => {
    try {
      const result = await apiFetch<ActionResult>("/api/chat", {
        method: "POST",
        json: { messages: [], action: { name: actionName, arguments: actionArgs } },
        signal,
      });
      if (result?.success) {
        switch (result.type) {
          case "formation":
            toast.success(`Formation "${result.title}" créée !`);
            return `✅ Formation **"${result.title}"** créée avec succès${result.lessonsCount ? ` (${result.lessonsCount} leçons)` : ""}. Vous pouvez la consulter dans l'onglet Formations.`;
          case "application":
            toast.success(`Application "${result.title}" créée !`);
            return `✅ Application **"${result.title}"** créée avec succès. Consultez-la dans l'onglet Applications.`;
          case "knowledge":
            toast.success(`Connaissance "${result.title}" sauvegardée !`);
            return `✅ Connaissance **"${result.title}"** sauvegardée dans votre base de connaissances.`;
          default:
            return `✅ Action exécutée avec succès.`;
        }
      }
      return `❌ Erreur : ${result?.error || "Action échouée"}`;
    } catch (err) {
      if (isAbortError(err)) throw err;
      return `❌ ${errorMessage(err, "Erreur de connexion lors de l'exécution de l'action.")}`;
    }
  };

  const send = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!input.trim() || isLoading || !userId) return;

    const userMsg: Msg = { role: "user", content: input.trim() };
    const allMessages = [...messages, userMsg];
    setMessages(allMessages);
    setInput("");
    setIsLoading(true);

    const controller = new AbortController();
    abortRef.current?.abort();
    abortRef.current = controller;
    const { signal } = controller;

    let convId = activeConversationId;
    if (!convId) {
      convId = await createConversation(userMsg.content);
      if (!convId) {
        setIsLoading(false);
        return;
      }
      streamingConvRef.current = convId;
      setActiveConversationId(convId);
    } else {
      streamingConvRef.current = convId;
    }

    await saveMessage(convId, "user", userMsg.content);

    let assistantSoFar = "";
    const upsert = (chunk: string) => {
      assistantSoFar += chunk;
      // Flux interrompu (changement de conversation) : ne pas écrire dans l'écran courant.
      if (signal.aborted) return;
      const content = assistantSoFar;
      setMessages((prev) => {
        const last = prev[prev.length - 1];
        if (last?.role === "assistant") {
          return prev.map((m, i) => (i === prev.length - 1 ? { ...m, content } : m));
        }
        return [...prev, { role: "assistant", content }];
      });
    };

    try {
      const resp = await apiFetchRaw("/api/chat", {
        method: "POST",
        json: { messages: allMessages },
        signal,
      });
      if (!resp.body) throw new ApiError("Réponse vide du service IA.", resp.status);

      const reader = resp.body.getReader();
      const decoder = new TextDecoder();
      const parser = createSseParser();
      const pendingToolCalls: PendingToolCall[] = [];
      let finished = false;

      const handle = (events: ReturnType<typeof parser.push>) => {
        for (const ev of events) {
          if (ev.type === "done") {
            finished = true;
            return;
          }
          if (ev.type === "invalid") {
            console.warn("[Chat] Ligne SSE invalide ignorée :", ev.line);
            continue;
          }
          const text = applyChatDelta(ev.data, pendingToolCalls);
          if (text) upsert(text);
        }
      };

      while (!finished) {
        const { done, value } = await reader.read();
        if (done) {
          handle(parser.flush());
          break;
        }
        handle(parser.push(decoder.decode(value, { stream: true })));
      }
      if (finished) reader.cancel().catch(() => {});

      for (const tc of pendingToolCalls) {
        if (tc && tc.name) {
          let args: unknown = {};
          try {
            args = JSON.parse(tc.arguments || "{}");
          } catch (err) {
            console.warn(`[Chat] Arguments invalides pour l'outil ${tc.name} :`, err);
          }
          upsert(`\n\n⚡ *Exécution : ${tc.name}...*\n\n`);
          upsert(await executeAction(tc.name, args, signal));
        }
      }
    } catch (err) {
      if (!isAbortError(err)) {
        if (err instanceof ApiError && err.status === 401) {
          upsert("🔒 Session expirée. Reconnectez-vous pour utiliser l'IA.");
        } else {
          upsert(errorMessage(err, "Erreur de connexion au service IA."));
        }
      }
    }

    if (assistantSoFar && convId) {
      await saveMessage(convId, "assistant", assistantSoFar);
      const { error } = await supabase
        .from("chat_conversations")
        .update({ updated_at: new Date().toISOString() })
        .eq("id", convId);
      if (error) console.error("Error updating conversation:", error);
    }

    // Ne réinitialise l'état que si ce flux est toujours le flux courant.
    if (abortRef.current === controller) {
      abortRef.current = null;
      streamingConvRef.current = null;
      setIsLoading(false);
    }
  };

  const newChat = () => {
    abortStream();
    setActiveConversationId(null);
    setMessages([]);
    if (isMobile) setShowConversations(false);
  };

  const selectConversation = (id: string) => {
    if (id !== activeConversationId) abortStream();
    setActiveConversationId(id);
    if (isMobile) setShowConversations(false);
  };

  const conversationList = (
    <div className="flex flex-col h-full">
      <div className="p-3 border-b border-border">
        <Button onClick={newChat} variant="outline" size="sm" className="w-full gap-2">
          <Plus className="h-4 w-4" /> Nouvelle conversation
        </Button>
      </div>
      <ScrollArea className="flex-1">
        <div className="p-2 space-y-1">
          {conversationsError && (
            <ErrorState
              compact
              message="Impossible de charger les conversations."
              detail={conversationsError}
              onRetry={loadConversations}
            />
          )}
          {conversations.map((c) => (
            <div
              key={c.id}
              className={`group flex items-center gap-2 rounded-md px-3 py-2 text-sm cursor-pointer transition-colors ${
                activeConversationId === c.id
                  ? "bg-primary/10 text-primary"
                  : "text-muted-foreground hover:bg-secondary hover:text-foreground"
              }`}
              onClick={() => selectConversation(c.id)}
            >
              <MessageSquare className="h-3.5 w-3.5 flex-shrink-0" />
              <span className="truncate flex-1">{c.title}</span>
              <ConfirmAction
                title="Supprimer cette conversation ?"
                description={`« ${c.title} » et tous ses messages seront définitivement supprimés.`}
                onConfirm={() => deleteConversation(c.id)}
                trigger={
                  <button
                    onClick={(e) => e.stopPropagation()}
                    aria-label={`Supprimer la conversation « ${c.title} »`}
                    className="opacity-100 md:opacity-0 md:group-hover:opacity-100 focus-visible:opacity-100 text-muted-foreground hover:text-destructive transition-all"
                  >
                    <Trash2 className="h-3.5 w-3.5" />
                  </button>
                }
              />
            </div>
          ))}
          {!conversationsError && conversations.length === 0 && (
            <p className="text-xs text-muted-foreground text-center py-8">Aucune conversation</p>
          )}
        </div>
      </ScrollArea>
    </div>
  );

  const chatArea = (
    <div className="flex-1 flex flex-col min-w-0">
      {isMobile && (
        <div className="flex items-center gap-2 pb-3 border-b border-border mb-2">
          <Button
            variant="ghost"
            size="icon"
            onClick={() => setShowConversations(true)}
            className="h-8 w-8"
            aria-label="Afficher les conversations"
          >
            <Menu className="h-4 w-4" />
          </Button>
          <span className="text-xs text-muted-foreground truncate flex-1">
            {activeConversationId
              ? conversations.find((c) => c.id === activeConversationId)?.title || "Conversation"
              : "Nouvelle conversation"}
          </span>
        </div>
      )}

      <ScrollArea className="flex-1 pr-2 md:pr-4">
        <div className="space-y-4 py-4">
          {messagesError && (
            <ErrorState
              message="Impossible de charger les messages de cette conversation."
              detail={messagesError}
              onRetry={() => setMessagesReload((n) => n + 1)}
            />
          )}
          {!messagesError && messages.length === 0 && (
            <div className="text-center py-8 md:py-16 space-y-4">
              <div className="h-14 w-14 md:h-16 md:w-16 rounded-full bg-primary/10 flex items-center justify-center mx-auto">
                <Brain className="h-7 w-7 md:h-8 md:w-8 text-primary" />
              </div>
              <h3 className="text-base md:text-lg font-semibold text-foreground">SOULBAH IA</h3>
              <p className="text-xs md:text-sm text-muted-foreground max-w-md mx-auto px-4">
                Votre IA personnelle. Je peux créer des formations, des applications,
                sauvegarder vos connaissances et répondre à toutes vos questions.
              </p>
              <div className="flex flex-col sm:flex-row flex-wrap gap-2 justify-center mt-4 px-4">
                {["Crée une formation sur Python", "Développe une app de gestion", "Retiens cette info"].map((s) => (
                  <button
                    key={s}
                    onClick={() => setInput(s)}
                    className="text-xs px-3 py-1.5 rounded-full border border-border text-muted-foreground hover:text-foreground hover:border-primary/30 transition-colors"
                  >
                    <Sparkles className="h-3 w-3 inline mr-1" />
                    {s}
                  </button>
                ))}
              </div>
            </div>
          )}
          {messages.map((msg, i) => (
            <div key={i} className={`flex gap-2 md:gap-3 ${msg.role === "user" ? "justify-end" : "justify-start"}`}>
              {msg.role === "assistant" && (
                <div className="flex-shrink-0 h-6 w-6 md:h-7 md:w-7 rounded-full bg-primary/10 flex items-center justify-center mt-1">
                  <Brain className="h-3 w-3 md:h-3.5 md:w-3.5 text-primary" />
                </div>
              )}
              <div
                className={`max-w-[85%] md:max-w-[75%] rounded-lg px-3 py-2 md:px-4 md:py-3 text-sm whitespace-pre-wrap ${
                  msg.role === "user"
                    ? "bg-primary text-primary-foreground"
                    : "bg-card border border-border text-foreground"
                }`}
              >
                {msg.content}
              </div>
              {msg.role === "user" && (
                <div className="flex-shrink-0 h-6 w-6 md:h-7 md:w-7 rounded-full bg-secondary flex items-center justify-center mt-1">
                  <User className="h-3 w-3 md:h-3.5 md:w-3.5 text-muted-foreground" />
                </div>
              )}
            </div>
          ))}
          {isLoading && messages[messages.length - 1]?.role !== "assistant" && (
            <div className="flex gap-2 md:gap-3">
              <div className="flex-shrink-0 h-6 w-6 md:h-7 md:w-7 rounded-full bg-primary/10 flex items-center justify-center mt-1">
                <Brain className="h-3 w-3 md:h-3.5 md:w-3.5 text-primary" />
              </div>
              <div className="bg-card border border-border rounded-lg px-3 py-2 md:px-4 md:py-3">
                <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" aria-label="Réponse en cours" />
              </div>
            </div>
          )}
          <div ref={scrollRef} />
        </div>
      </ScrollArea>

      <form onSubmit={send} className="flex gap-2 pt-3 md:pt-4 border-t border-border">
        <Input
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder={isMobile ? "Demandez à l'IA..." : "Demandez n'importe quoi à SOULBAH IA..."}
          className="flex-1 bg-secondary border-border"
          disabled={isLoading}
          aria-label="Message pour l'IA"
        />
        <Button type="submit" disabled={isLoading || !input.trim()} size="icon" aria-label="Envoyer le message">
          <Send className="h-4 w-4" />
        </Button>
      </form>
    </div>
  );

  return (
    <div className="flex h-[calc(100dvh-190px)] min-h-[360px] md:h-[calc(100vh-150px)] gap-0 md:gap-4">
      {!isMobile && (
        <div className="w-64 flex-shrink-0 border border-border rounded-lg bg-card flex flex-col">
          {conversationList}
        </div>
      )}

      {isMobile && (
        <Sheet open={showConversations} onOpenChange={setShowConversations}>
          <SheetContent side="left" className="w-72 p-0">
            <SheetTitle className="sr-only">Conversations</SheetTitle>
            {conversationList}
          </SheetContent>
        </Sheet>
      )}

      {chatArea}
    </div>
  );
};

export default AiChat;
