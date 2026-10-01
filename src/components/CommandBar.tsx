import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { Sparkles, Loader2, ArrowRight, X, BrainCircuit } from "lucide-react";
import { apiUrl } from "@/lib/api";
import { useAuth } from "@/hooks/useAuth";
import { useToast } from "@/hooks/use-toast";

interface RouteDecision {
  agent: string;
  agent_label: string;
  capability: string;
  task_type: string;
  reason: string;
  complexity: string;
  subtasks: string[];
  needs_memory_check: boolean;
}

// Capacité de l'agent choisi → page cible (barre de commande universelle).
const ROUTE_BY_CAPABILITY: Record<string, string> = {
  generate_formation: "/formations",
  generate_application: "/applications",
  generate: "/chat",
  research: "/knowledge",
  knowledge: "/knowledge",
  agent_goal: "/automation",
  vision: "/automation",
  self_improve: "/automation",
  formation_video: "/video",
  chat: "/chat",
  database: "/database",
};

const complexityColor: Record<string, string> = {
  simple: "bg-success/10 text-success",
  moyenne: "bg-warning/10 text-warning",
  complexe: "bg-primary/10 text-primary",
};

const CommandBar = () => {
  const { session } = useAuth();
  const { toast } = useToast();
  const navigate = useNavigate();
  const [input, setInput] = useState("");
  const [loading, setLoading] = useState(false);
  const [decision, setDecision] = useState<RouteDecision | null>(null);
  const [prompt, setPrompt] = useState("");

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!input.trim() || !session || loading) return;
    setLoading(true);
    setDecision(null);
    try {
      const resp = await fetch(apiUrl("/api/orchestrator/route"), {
        method: "POST",
        headers: {
          Authorization: `Bearer ${session.access_token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ request: input.trim() }),
      });
      const data = await resp.json();
      if (!resp.ok || !data.success) throw new Error(data.error || "Échec de l'orchestration");
      setDecision(data.decision as RouteDecision);
      setPrompt(input.trim());
      setInput("");
    } catch (err: any) {
      toast({ title: "Erreur", description: err.message, variant: "destructive" });
    } finally {
      setLoading(false);
    }
  };

  const launch = () => {
    if (!decision) return;
    const target = ROUTE_BY_CAPABILITY[decision.capability] ?? "/chat";
    // On passe la demande d'origine à la page cible (prefill possible via location.state).
    navigate(target, { state: { commandPrompt: prompt } });
    setDecision(null);
  };

  return (
    <div className="fixed bottom-4 left-1/2 z-50 w-[min(680px,92vw)] -translate-x-1/2 md:left-[calc(50%+8rem)]">
      {/* Carte de décision du Chief Agent */}
      {decision && (
        <div className="mb-2 rounded-xl border border-primary/30 bg-card/95 p-4 shadow-2xl backdrop-blur-xl animate-fade-in">
          <div className="mb-2 flex items-center justify-between">
            <div className="flex items-center gap-2">
              <BrainCircuit className="h-4 w-4 text-primary" />
              <span className="text-xs font-semibold">Chief Agent → {decision.agent_label}</span>
              <span className={`rounded px-1.5 py-0.5 text-[10px] font-mono ${complexityColor[decision.complexity] ?? "bg-secondary"}`}>
                {decision.complexity}
              </span>
            </div>
            <button onClick={() => setDecision(null)} className="text-muted-foreground hover:text-foreground">
              <X className="h-4 w-4" />
            </button>
          </div>
          <p className="mb-2 text-xs text-muted-foreground">{decision.reason}</p>
          {decision.subtasks.length > 0 && (
            <ul className="mb-3 space-y-0.5">
              {decision.subtasks.map((s, i) => (
                <li key={i} className="text-[11px] text-foreground/80">
                  <span className="text-primary">{i + 1}.</span> {s}
                </li>
              ))}
            </ul>
          )}
          <button
            onClick={launch}
            className="flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-xs font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          >
            Ouvrir {decision.agent_label} <ArrowRight className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      {/* La barre de commande */}
      <form
        onSubmit={submit}
        className="flex items-center gap-2 rounded-full border border-border bg-card/95 px-4 py-2 shadow-2xl backdrop-blur-xl"
      >
        {loading ? (
          <Loader2 className="h-5 w-5 flex-shrink-0 animate-spin text-primary" />
        ) : (
          <Sparkles className="h-5 w-5 flex-shrink-0 text-primary" />
        )}
        <input
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Demandez n'importe quoi — « Crée une formation marketing », « Ouvre Notepad », « Cherche… »"
          className="flex-1 bg-transparent text-sm outline-none placeholder:text-muted-foreground/60"
          disabled={loading}
        />
        <button
          type="submit"
          disabled={loading || !input.trim()}
          className="flex-shrink-0 rounded-full bg-primary p-1.5 text-primary-foreground transition-colors hover:bg-primary/90 disabled:opacity-40"
        >
          <ArrowRight className="h-4 w-4" />
        </button>
      </form>
    </div>
  );
};

export default CommandBar;
