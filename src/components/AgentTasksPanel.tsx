import { useState, useEffect, useCallback } from "react";
import type { RealtimePostgresChangesPayload } from "@supabase/supabase-js";
import { toast } from "sonner";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { useCommandPrefill } from "@/hooks/useCommandPrefill";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Monitor, Loader2, CheckCircle2, XCircle, Clock, Trash2, RefreshCw, Sparkles, type LucideIcon } from "lucide-react";
import { apiFetch, errorMessage } from "@/lib/api";
import ErrorState from "@/components/ErrorState";

interface AgentTaskResult {
  file?: string;
  evaluation?: { verdict?: string; reason?: string };
}

interface AgentTaskPayload {
  goal_meta?: { goal?: string; attempt?: number };
}

interface AgentTask {
  id: string;
  task_type: string;
  status: string;
  payload: AgentTaskPayload | null;
  result: AgentTaskResult | null;
  error_message: string | null;
  created_at: string;
  completed_at: string | null;
}

const statusConfig: Record<string, { label: string; color: string; icon: LucideIcon }> = {
  pending: { label: "En attente", color: "bg-warning/10 text-warning", icon: Clock },
  in_progress: { label: "En cours", color: "bg-primary/10 text-primary", icon: Loader2 },
  completed: { label: "Terminé", color: "bg-success/10 text-success", icon: CheckCircle2 },
  failed: { label: "Échoué", color: "bg-destructive/10 text-destructive", icon: XCircle },
};

const taskTypeLabels: Record<string, string> = {
  screen_recording: "📹 Capture écran",
  tts_generation: "🔊 Synthèse vocale",
  open_software: "🚀 Ouverture logiciel",
  keyboard_action: "⌨️ Action clavier",
  mouse_action: "🖱️ Action souris",
  demo_execution: "🎯 Démonstration",
  video_production: "🎞️ Production vidéo",
  full_training_video: "🎬 Vidéo de formation",
  goal: "🧠 Objectif (plan IA)",
};

const MAX_TASKS = 200;

/** Applique un événement temps réel à la liste (sans refetch complet). */
function applyTaskChange(
  prev: AgentTask[],
  payload: RealtimePostgresChangesPayload<Record<string, unknown>>,
): AgentTask[] {
  if (payload.eventType === "DELETE") {
    const id = (payload.old as { id?: string }).id;
    return id ? prev.filter((t) => t.id !== id) : prev;
  }
  const row = payload.new as unknown as AgentTask;
  if (!row?.id) return prev;
  const idx = prev.findIndex((t) => t.id === row.id);
  if (idx === -1) return [row, ...prev].slice(0, MAX_TASKS);
  const next = prev.slice();
  next[idx] = { ...prev[idx], ...row };
  return next;
}

interface AgentTasksPanelProps {
  formationId?: string;
  formationTitle?: string;
  formationScript?: string;
}

const AgentTasksPanel = ({ formationId, formationTitle, formationScript }: AgentTasksPanelProps) => {
  const { user } = useAuth();
  const userId = user?.id;
  const [tasks, setTasks] = useState<AgentTask[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const [goal, setGoal] = useState("");
  useCommandPrefill(setGoal);
  const [planning, setPlanning] = useState(false);
  const [goalFeedback, setGoalFeedback] = useState<string | null>(null);

  const fetchTasks = useCallback(async () => {
    if (!userId) return;
    setLoadError(null);
    try {
      const data = await apiFetch<{ tasks?: AgentTask[] }>("/api/agent-tasks");
      setTasks(data?.tasks ?? []);
    } catch (e) {
      console.error("Error fetching tasks:", e);
      setLoadError(errorMessage(e));
    }
    setLoading(false);
  }, [userId]);

  const sendGoal = async () => {
    if (!userId || !goal.trim() || planning) return;
    setPlanning(true);
    setGoalFeedback(null);
    try {
      const data = await apiFetch<{
        success?: boolean;
        steps?: unknown[];
        understanding?: string;
        reason?: string;
        error?: string;
      }>("/api/agent/goal", { method: "POST", json: { goal: goal.trim() } });
      if (data?.success) {
        setGoalFeedback(`✅ Plan créé (${data.steps?.length ?? 0} étapes) : ${data.understanding ?? ""}`);
        setGoal("");
        fetchTasks();
      } else {
        setGoalFeedback(`❌ ${data?.reason || data?.error || "Échec de la planification"}`);
      }
    } catch (e) {
      setGoalFeedback(`❌ ${errorMessage(e, "Backend injoignable")}`);
    }
    setPlanning(false);
  };

  useEffect(() => {
    if (!userId) return;
    fetchTasks();
    // Temps réel : uniquement les tâches de l'utilisateur, appliquées directement à l'état.
    const channel = supabase
      .channel(`agent-tasks-realtime-${userId}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "agent_tasks", filter: `user_id=eq.${userId}` },
        (payload) => setTasks((prev) => applyTaskChange(prev, payload)),
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [userId, fetchTasks]);

  const sendTrainingVideoTask = async () => {
    if (!userId || !formationTitle) return;
    setSending(true);

    try {
      const data = await apiFetch<{ success?: boolean; task?: AgentTask; error?: string }>("/api/agent-tasks", {
        method: "POST",
        json: {
          task_type: "full_training_video",
          priority: 1,
          payload: {
            title: formationTitle,
            formation_id: formationId,
            script: formationScript || `Vidéo de formation : ${formationTitle}`,
            steps: [
              { type: "open_software", software: "vscode", description: "Ouvrir VS Code" },
              { type: "wait", seconds: 3, description: "Attendre le chargement" },
            ],
          },
        },
      });
      const task = data?.task;
      if (data?.success && task) {
        setTasks((prev) => (prev.some((t) => t.id === task.id) ? prev : [task, ...prev]));
      } else {
        toast.error("Envoi de la tâche impossible", { description: data?.error });
      }
    } catch (e) {
      console.error("Error sending task:", e);
      toast.error("Envoi de la tâche impossible", { description: errorMessage(e) });
    }
    setSending(false);
  };

  const deleteTask = async (taskId: string) => {
    const { error } = await supabase.from("agent_tasks").delete().eq("id", taskId);
    if (error) {
      console.error("Error deleting task:", error);
      toast.error("Suppression impossible", { description: error.message });
      return;
    }
    setTasks((prev) => prev.filter((t) => t.id !== taskId));
  };

  return (
    <div className="rounded-lg border border-border bg-card p-4 space-y-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Monitor className="h-4 w-4 text-primary" />
          <h3 className="text-sm font-semibold">Agent Local</h3>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="ghost" size="icon" className="h-7 w-7" onClick={fetchTasks} aria-label="Rafraîchir les tâches">
            <RefreshCw className="h-3.5 w-3.5" />
          </Button>
          {formationTitle && (
            <Button size="sm" onClick={sendTrainingVideoTask} disabled={sending} className="text-xs">
              {sending ? <Loader2 className="h-3 w-3 mr-1 animate-spin" /> : <Monitor className="h-3 w-3 mr-1" />}
              Produire la vidéo
            </Button>
          )}
        </div>
      </div>

      {/* Moteur de raisonnement : objectif en langage naturel → plan → agent */}
      <form
        onSubmit={(e) => { e.preventDefault(); sendGoal(); }}
        className="space-y-2"
      >
        <div className="flex gap-2">
          <Input
            value={goal}
            onChange={(e) => setGoal(e.target.value)}
            placeholder="Objectif (ex: Ouvre le bloc-notes et écris Bonjour)"
            className="bg-secondary border-border text-xs h-8"
            disabled={planning}
            aria-label="Objectif pour l'agent"
          />
          <Button type="submit" size="sm" className="h-8 px-3 text-xs" disabled={planning || !goal.trim()}>
            {planning ? <Loader2 className="h-3.5 w-3.5 animate-spin" aria-label="Planification en cours" /> : <><Sparkles className="h-3.5 w-3.5 mr-1" /> Planifier</>}
          </Button>
        </div>
        {goalFeedback && (
          <p className="text-[10px] text-muted-foreground">{goalFeedback}</p>
        )}
      </form>

      {loading ? (
        <p className="text-xs text-muted-foreground">Chargement...</p>
      ) : loadError ? (
        <ErrorState compact message="Impossible de charger les tâches de l'agent." detail={loadError} onRetry={fetchTasks} />
      ) : tasks.length === 0 ? (
        <div className="text-center py-6">
          <Monitor className="h-8 w-8 text-muted-foreground/30 mx-auto mb-2" />
          <p className="text-xs text-muted-foreground">Aucune tâche pour le moment</p>
          <p className="text-[10px] text-muted-foreground/60 mt-1 max-w-xs mx-auto">
            Décrivez un objectif ci-dessus, puis lancez l'agent sur votre poste :{" "}
            <code className="bg-secondary px-1 rounded">python soulbah_agent.py</code>{" "}
            (dossier <code className="bg-secondary px-1 rounded">agent/</code> du projet)
          </p>
        </div>
      ) : (
        <ScrollArea className="max-h-[300px]">
          <div className="space-y-2">
            {tasks.map((task) => {
              const config = statusConfig[task.status] || statusConfig.pending;
              const Icon = config.icon;
              const evaluation = task.result?.evaluation;
              const goalMeta = task.payload?.goal_meta;
              return (
                <div key={task.id} className="flex items-center gap-3 rounded-md bg-secondary/50 px-3 py-2">
                  <Icon className={`h-4 w-4 flex-shrink-0 ${task.status === "in_progress" ? "animate-spin" : ""} ${config.color.split(" ")[1]}`} />
                  <div className="flex-1 min-w-0">
                    <p className="text-xs font-medium truncate">
                      {taskTypeLabels[task.task_type] || task.task_type}
                    </p>
                    <p className="text-[10px] text-muted-foreground">
                      {new Date(task.created_at).toLocaleString("fr-FR")}
                    </p>
                    {task.error_message && (
                      <p className="text-[10px] text-destructive mt-0.5">{task.error_message}</p>
                    )}
                    {task.result?.file && (
                      <p className="text-[10px] text-success mt-0.5">📁 {task.result.file}</p>
                    )}
                    {goalMeta?.goal && (
                      <p className="text-[10px] text-muted-foreground/80 mt-0.5 truncate">
                        🎯 {goalMeta.goal}
                        {(goalMeta.attempt ?? 0) > 1 && ` (tentative ${goalMeta.attempt})`}
                      </p>
                    )}
                    {evaluation && (
                      <p className={`text-[10px] mt-0.5 ${evaluation.verdict === "success" ? "text-success" : evaluation.verdict === "retry" ? "text-warning" : "text-destructive"}`}>
                        🧠 {evaluation.verdict === "success" ? "Objectif atteint" : evaluation.verdict === "retry" ? "Correction lancée" : "Abandonné"} — {evaluation.reason}
                      </p>
                    )}
                  </div>
                  <Badge variant="outline" className={`text-[9px] ${config.color}`}>
                    {config.label}
                  </Badge>
                  <button
                    onClick={() => deleteTask(task.id)}
                    className="text-muted-foreground hover:text-destructive"
                    aria-label="Supprimer la tâche"
                  >
                    <Trash2 className="h-3 w-3" />
                  </button>
                </div>
              );
            })}
          </div>
        </ScrollArea>
      )}
    </div>
  );
};

export default AgentTasksPanel;
