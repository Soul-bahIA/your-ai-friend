import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { Brain, Check, Loader2, RefreshCw, Sparkles, X } from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import ErrorState from "@/components/ErrorState";
import { errorMessage } from "@/lib/api";
import {
  GENERAL_GOAL,
  listMemories,
  MEMORY_LEVEL_LABELS,
  MEMORY_TYPE_LABELS,
  reviewMemory,
  runSelfImprove,
  type MemoryDecision,
  type MemoryEntry,
} from "@/lib/agentMemory";

/**
 * Revue de la mémoire de l'agent (contrat LOT 1 §9) : les leçons PROPOSÉES par l'évaluateur
 * et l'auto-amélioration ne deviennent « validées » que par un clic explicite ici.
 */
const AgentMemoryReview = () => {
  const { user } = useAuth();
  const userId = user?.id;
  const [entries, setEntries] = useState<MemoryEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [analyzing, setAnalyzing] = useState(false);

  const fetchEntries = useCallback(async () => {
    if (!userId) return;
    setLoadError(null);
    try {
      setEntries(await listMemories("proposed"));
    } catch (e) {
      setLoadError(errorMessage(e));
    }
    setLoading(false);
  }, [userId]);

  useEffect(() => {
    fetchEntries();
  }, [fetchEntries]);

  const decide = async (entry: MemoryEntry, decision: MemoryDecision) => {
    setBusyId(entry.id);
    try {
      const found = await reviewMemory(entry.id, decision);
      setEntries((prev) => prev.filter((e) => e.id !== entry.id));
      if (!found) toast.info("Entrée déjà supprimée");
      else toast.success(decision === "validated" ? "Leçon validée" : "Leçon rejetée");
    } catch (e) {
      toast.error(decision === "validated" ? "Validation impossible" : "Rejet impossible", { description: errorMessage(e) });
    } finally {
      setBusyId(null);
    }
  };

  const analyze = async () => {
    setAnalyzing(true);
    try {
      const out = await runSelfImprove();
      if (out.kind === "not_enough_history") {
        toast.info("Analyse impossible", { description: out.message });
      } else {
        toast.success(`${out.proposed} optimisation(s) proposée(s)`, {
          description: `${out.analyzed} exécution(s) analysée(s) — à valider ci-dessous.`,
        });
        fetchEntries();
      }
    } catch (e) {
      toast.error("Analyse impossible", { description: errorMessage(e) });
    } finally {
      setAnalyzing(false);
    }
  };

  return (
    <div className="rounded-lg border border-border bg-card p-4 space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Brain className="h-4 w-4 text-primary" />
          <h3 className="text-sm font-semibold">Mémoire de l'agent — leçons à valider</h3>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="outline" size="sm" className="h-7 text-xs" onClick={analyze} disabled={analyzing}>
            {analyzing ? <Loader2 className="h-3 w-3 mr-1 animate-spin" /> : <Sparkles className="h-3 w-3 mr-1" />}
            Analyser mes exécutions
          </Button>
          <Button variant="ghost" size="icon" className="h-7 w-7" onClick={fetchEntries} aria-label="Rafraîchir la mémoire">
            <RefreshCw className="h-3.5 w-3.5" />
          </Button>
        </div>
      </div>
      <p className="text-[10px] text-muted-foreground">
        L'IA propose des leçons après chaque objectif évalué. Une bonne pratique ou une optimisation ne sert à
        planifier qu'une fois validée ; une leçon rejetée n'est plus jamais réutilisée.
      </p>

      {loading ? (
        <p className="text-xs text-muted-foreground">Chargement...</p>
      ) : loadError ? (
        <ErrorState compact message="Impossible de charger la mémoire de l'agent." detail={loadError} onRetry={fetchEntries} />
      ) : entries.length === 0 ? (
        <p className="text-xs text-muted-foreground">Aucune leçon en attente de validation.</p>
      ) : (
        <ul className="space-y-2" aria-label="Leçons proposées">
          {entries.map((entry) => {
            const busy = busyId === entry.id;
            return (
              <li key={entry.id} className="rounded-md bg-secondary/50 px-3 py-2 space-y-1">
                <div className="flex flex-wrap items-center gap-1.5">
                  <Badge variant="outline" className="text-[9px]">
                    {MEMORY_TYPE_LABELS[entry.type] ?? entry.type}
                  </Badge>
                  <span className="text-[10px] text-muted-foreground">
                    Niveau {MEMORY_LEVEL_LABELS[entry.level] ?? entry.level}
                    {entry.created_at && ` · ${new Date(entry.created_at).toLocaleString("fr-FR")}`}
                  </span>
                </div>
                {entry.goal && entry.goal !== GENERAL_GOAL && (
                  <p className="text-[10px] text-muted-foreground/80 break-words">🎯 {entry.goal}</p>
                )}
                <p className="max-h-32 overflow-y-auto text-[11px] text-foreground/90 whitespace-pre-wrap break-words">
                  {entry.content}
                </p>
                <div className="flex gap-2 pt-1">
                  <Button size="sm" className="h-7 text-xs" disabled={busy} onClick={() => decide(entry, "validated")}>
                    {busy ? <Loader2 className="h-3 w-3 mr-1 animate-spin" /> : <Check className="h-3 w-3 mr-1" />}
                    Valider
                  </Button>
                  <Button
                    size="sm"
                    variant="outline"
                    className="h-7 text-xs"
                    disabled={busy}
                    onClick={() => decide(entry, "rejected")}
                  >
                    <X className="h-3 w-3 mr-1" /> Rejeter
                  </Button>
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
};

export default AgentMemoryReview;
