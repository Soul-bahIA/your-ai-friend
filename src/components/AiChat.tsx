import { useState, useRef, useEffect, useCallback } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet";
import { Brain, Send, Loader2, User, Plus, Trash2, MessageSquare, Sparkles, Menu } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { useIsMobile } from "@/hooks/use-mobile";
import { toast } from "sonner";

type Msg = { role: "user" | "assistant"; content: string };
type Conversation = { id: string; title: string; created_at: string };

const CHAT_URL = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/chat`;

const AiChat = () => {
  const { user, session } = useAuth();
  const isMobile = useIsMobile();
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [activeConversationId, setActiveConversationId] = useState<string | null>(null);
  const [messages, setMessages] = useState<Msg[]>([]);
  const [input, setInput] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [showConversations, setShowConversations] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);

  const getAuthHeaders = async () => {
    const { data: { session: freshSession } } = await supabase.auth.getSession();
    const token = freshSession?.access_token || session?.access_token;
    
    if (!token) {
      toast.error("Session expirée. Veuillez vous reconnecter.");
      throw new Error("No valid session");
    }
    return {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    };
  };

  const loadConversations = useCallback(async () => {
    if (!user) return;
    await supabase.auth.getSession();
    const { data, error } = await supabase
      .from("chat_conversations")
      .select("id, title, created_at")
      .eq("user_id", user.id)
      .order("updated_at", { ascending: false });
    if (error) {
      console.error("Error loading conversations:", error);
      return;
    }
    if (data) setConversations(data);
  }, [user]);

  useEffect(() => { loadConversations(); }, [loadConversations]);

  useEffect(() => {
    if (!activeConversationId || !user) { setMessages([]); return; }
    (async () => {
      const { data } = await supabase
        .from("chat_messages")
        .select("role, content")
        .eq("conversation_id", activeConversationId)
        .order("created_at", { ascending: true });
      if (data) setMessages(data.map(m => ({ role: m.role as "user" | "assistant", content: m.content })));
    })();
  }, [activeConversationId, user]);

  useEffect(() => {
    scrollRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  const createConversation = async (firstMessage: string) => {
    if (!user) return null;
    await supabase.auth.getSession();
    const title = firstMessage.slice(0, 60) + (firstMessage.length > 60 ? "..." : "");
    const { data, error } = await supabase
      .from("chat_conversations")
      .insert({ user_id: user.id, title })
      .select("id, title, created_at")
      .single();
    if (error || !data) { 
      console.error("Conversation creation error:", error);
      toast.error("Erreur création conversation"); 
      return null; 
    }
    setConversations(prev => [data, ...prev]);
    setActiveConversationId(data.id);
    return data.id;
  };

  const saveMessage = async (conversationId: string, role: string, content: string) => {
    if (!user) return;
    await supabase.from("chat_messages").insert({
      conversation_id: conversationId,
      user_id: user.id,
      role,
      content,
    });
  };

  const deleteConversation = async (id: string) => {
    await supabase.from("chat_conversations").delete().eq("id", id);
    setConversations(prev => prev.filter(c => c.id !== id));
    if (activeConversationId === id) {
      setActiveConversationId(null);
      setMessages([]);
    }
  };

  const executeAction = async (actionName: string, actionArgs: any): Promise<string> => {
    try {
      const resp = await fetch(CHAT_URL, {
        method: "POST",
        headers: await getAuthHeaders(),
        body: JSON.stringify({
          messages: [],
          action: { name: actionName, arguments: actionArgs },
        }),
      });
      const result = await resp.json();
      if (result.success) {
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
      return `❌ Erreur : ${result.error || "Action échouée"}`;
    } catch {
      return "❌ Erreur de connexion lors de l'exécution de l'action.";
    }
  };

  const send = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!input.trim() || isLoading || !user) return;

    const userMsg: Msg = { role: "user", content: input.trim() };
    const allMessages = [...messages, userMsg];
    setMessages(allMessages);
    setInput("");
    setIsLoading(true);

    let convId = activeConversationId;
    if (!convId) {
      convId = await createConversation(userMsg.content);
      if (!convId) { setIsLoading(false); return; }
    }

    await saveMessage(convId, "user", userMsg.content);

    let assistantSoFar = "";
    const upsert = (chunk: string) => {
      assistantSoFar += chunk;
      setMessages((prev) => {
        const last = prev[prev.length - 1];
        if (last?.role === "assistant") {
          return prev.map((m, i) => (i === prev.length - 1 ? { ...m, content: assistantSoFar } : m));
        }
        return [...prev, { role: "assistant", content: assistantSoFar }];
      });
    };

    try {
      const resp = await fetch(CHAT_URL, {
        method: "POST",
        headers: await getAuthHeaders(),
        body: JSON.stringify({ messages: allMessages }),
      });

      if (!resp.ok || !resp.body) {
        const err = await resp.json().catch(() => ({ error: "Erreur réseau" }));
        if (resp.status === 401) {
          upsert("🔒 Accès refusé. Vous devez être connecté pour utiliser l'IA.");
        } else {
          upsert(err.error || "Erreur de connexion au service IA.");
        }
        setIsLoading(false);
        return;
      }

      const reader = resp.body.getReader();
      const decoder = new TextDecoder();
      let textBuffer = "";
      let pendingToolCalls: { id: string; name: string; arguments: string }[] = [];

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        textBuffer += decoder.decode(value, { stream: true });

        let newlineIndex: number;
        while ((newlineIndex = textBuffer.indexOf("\n")) !== -1) {
          let line = textBuffer.slice(0, newlineIndex);
          textBuffer = textBuffer.slice(newlineIndex + 1);
          if (line.endsWith("\r")) line = line.slice(0, -1);
          if (line.startsWith(":") || line.trim() === "") continue;
          if (!line.startsWith("data: ")) continue;
          const jsonStr = line.slice(6).trim();
          if (jsonStr === "[DONE]") break;
          try {
            const parsed = JSON.parse(jsonStr);
            const delta = parsed.choices?.[0]?.delta;
            if (delta?.content) upsert(delta.content);
            if (delta?.tool_calls) {
              for (const tc of delta.tool_calls) {
                if (tc.index !== undefined) {
                  if (!pendingToolCalls[tc.index]) {
                    pendingToolCalls[tc.index] = { id: tc.id || "", name: "", arguments: "" };
                  }
                  if (tc.function?.name) pendingToolCalls[tc.index].name = tc.function.name;
                  if (tc.function?.arguments) pendingToolCalls[tc.index].arguments += tc.function.arguments;
                }
              }
            }
          } catch {
            textBuffer = line + "\n" + textBuffer;
            break;
          }
        }
      }

      for (const tc of pendingToolCalls) {
        if (tc && tc.name) {
          let args: any = {};
          try { args = JSON.parse(tc.arguments); } catch {}
          upsert(`\n\n⚡ *Exécution : ${tc.name}...*\n\n`);
          const result = await executeAction(tc.name, args);
          upsert(result);
        }
      }

    } catch {
      upsert("Erreur de connexion.");
    }

    if (assistantSoFar && convId) {
      await saveMessage(convId, "assistant", assistantSoFar);
      await supabase.from("chat_conversations").update({ updated_at: new Date().toISOString() }).eq("id", convId);
    }

    setIsLoading(false);
  };

  const newChat = () => {
    setActiveConversationId(null);
    setMessages([]);
    if (isMobile) setShowConversations(false);
  };

  const selectConversation = (id: string) => {
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
              <button
                onClick={(e) => { e.stopPropagation(); deleteConversation(c.id); }}
                className="opacity-0 group-hover:opacity-100 text-muted-foreground hover:text-destructive transition-all"
              >
                <Trash2 className="h-3.5 w-3.5" />
              </button>
            </div>
          ))}
          {conversations.length === 0 && (
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
          <Button variant="ghost" size="icon" onClick={() => setShowConversations(true)} className="h-8 w-8">
            <Menu className="h-4 w-4" />
          </Button>
          <span className="text-xs text-muted-foreground truncate flex-1">
            {activeConversationId 
              ? conversations.find(c => c.id === activeConversationId)?.title || "Conversation"
              : "Nouvelle conversation"
            }
          </span>
        </div>
      )}

      <ScrollArea className="flex-1 pr-2 md:pr-4">
        <div className="space-y-4 py-4">
          {messages.length === 0 && (
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
                {["Crée une formation sur Python", "Développe une app de gestion", "Retiens cette info"].map(s => (
                  <button
                    key={s}
                    onClick={() => setInput(s)}
                    className="text-xs px-3 py-1.5 rounded-full border border-border text-muted-foreground hover:text-foreground hover:border-primary/30 transition-colors"
                  >
                    <Sparkles className="h-3 w-3 inline mr-1" />{s}
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
                <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" />
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
        />
        <Button type="submit" disabled={isLoading || !input.trim()} size="icon">
          <Send className="h-4 w-4" />
        </Button>
      </form>
    </div>
  );

  return (
    <div className="flex h-[calc(100vh-120px)] md:h-[calc(100vh-120px)] gap-0 md:gap-4">
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
