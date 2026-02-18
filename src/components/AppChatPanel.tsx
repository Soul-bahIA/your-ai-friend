import { useState, useRef, useEffect } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Send, Loader2, Bot, User } from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import type { Json } from "@/integrations/supabase/types";

interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

interface AppChatPanelProps {
  applicationId: string;
  appTitle: string;
  existingArchitecture: Json | null;
  onAppUpdated: (result: any) => void;
}

const AppChatPanel = ({ applicationId, appTitle, existingArchitecture, onAppUpdated }: AppChatPanelProps) => {
  const { session } = useAuth();
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState("");
  const [loading, setLoading] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" });
  }, [messages]);

  const handleSend = async () => {
    if (!input.trim() || loading || !session) return;

    const userMsg: ChatMessage = { role: "user", content: input.trim() };
    const newMessages = [...messages, userMsg];
    setMessages(newMessages);
    setInput("");
    setLoading(true);

    try {
      const response = await fetch(
        `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/generate-application`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${session.access_token}`,
            apikey: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
          },
          body: JSON.stringify({
            appName: appTitle,
            applicationId,
            conversationHistory: newMessages,
            existingArchitecture: existingArchitecture || {},
          }),
        }
      );

      const result = await response.json();
      if (!response.ok) throw new Error(result.error || "Échec");

      const assistantMsg: ChatMessage = {
        role: "assistant",
        content: `✅ Application mise à jour !\n\n**${result.application.title}**\n${result.application.description}\n\n• ${result.application.architecture?.frontend?.components?.length || 0} composants\n• ${result.application.architecture?.backend?.endpoints?.length || 0} endpoints\n• ${result.application.architecture?.database?.tables?.length || 0} tables`,
      };
      setMessages((prev) => [...prev, assistantMsg]);
      onAppUpdated(result.application);
    } catch (err: any) {
      setMessages((prev) => [
        ...prev,
        { role: "assistant", content: `❌ Erreur : ${err.message}` },
      ]);
    }

    setLoading(false);
  };

  return (
    <div className="border-t border-border flex flex-col h-[300px]">
      <div className="px-4 py-2 border-b border-border bg-secondary/30">
        <span className="text-[11px] font-medium text-muted-foreground">
          💬 Chat — Améliorez « {appTitle} » en décrivant vos modifications
        </span>
      </div>

      <div ref={scrollRef} className="flex-1 overflow-y-auto px-4 py-3 space-y-3">
        {messages.length === 0 && (
          <p className="text-xs text-muted-foreground text-center mt-8">
            Décrivez ce que vous voulez modifier ou ajouter à votre application...
          </p>
        )}
        {messages.map((msg, i) => (
          <div key={i} className={`flex gap-2 ${msg.role === "user" ? "justify-end" : "justify-start"}`}>
            {msg.role === "assistant" && (
              <div className="flex-shrink-0 h-6 w-6 rounded-full bg-accent/20 flex items-center justify-center">
                <Bot className="h-3.5 w-3.5 text-accent" />
              </div>
            )}
            <div className={`max-w-[80%] rounded-lg px-3 py-2 text-xs whitespace-pre-wrap ${
              msg.role === "user"
                ? "bg-accent text-accent-foreground"
                : "bg-secondary text-foreground"
            }`}>
              {msg.content}
            </div>
            {msg.role === "user" && (
              <div className="flex-shrink-0 h-6 w-6 rounded-full bg-primary/20 flex items-center justify-center">
                <User className="h-3.5 w-3.5 text-primary" />
              </div>
            )}
          </div>
        ))}
        {loading && (
          <div className="flex gap-2 items-center">
            <div className="h-6 w-6 rounded-full bg-accent/20 flex items-center justify-center">
              <Loader2 className="h-3.5 w-3.5 text-accent animate-spin" />
            </div>
            <span className="text-xs text-muted-foreground">Amélioration en cours...</span>
          </div>
        )}
      </div>

      <form onSubmit={(e) => { e.preventDefault(); handleSend(); }} className="px-4 py-3 border-t border-border flex gap-2">
        <Input
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Ex: Ajoute un système de paiement, change le design..."
          className="bg-secondary border-border text-xs h-8"
          disabled={loading}
        />
        <Button type="submit" size="sm" className="h-8 px-3 bg-accent text-accent-foreground" disabled={loading || !input.trim()}>
          <Send className="h-3.5 w-3.5" />
        </Button>
      </form>
    </div>
  );
};

export default AppChatPanel;
