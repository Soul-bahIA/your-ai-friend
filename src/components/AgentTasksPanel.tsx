import { useState, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Monitor, Loader2, CheckCircle2, XCircle, Clock, Trash2, RefreshCw } from "lucide-react";

interface AgentTask {
  id: string;
  task_type: string;
  status: string;
  payload: any;
  result: any;
  error_message: string | null;
  created_at: string;
  completed_at: string | null;
}

const TASK_URL = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/agent-tasks`;

const statusConfig: Record<string, { label: string; color: string; icon: any }> = {
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
};

interface AgentTasksPanelProps {
  formationId?: string;
  formationTitle?: string;
  formationScript?: string;
}

const AgentTasksPanel = ({ formationId, formationTitle, formationScript }: AgentTasksPanelProps) => {
  const { session } = useAuth();
  const [tasks, setTasks] = useState<AgentTask[]>([]);
  const [loading, setLoading] = useState(true);
  const [sending, setSending] = useState(false);

  const fetchTasks = async () => {
    if (!session) return;
    try {
      const resp = await fetch(TASK_URL, {
        headers: {
          Authorization: `Bearer ${session.access_token}`,
          "Content-Type": "application/json",
        },
      });
      const data = await resp.json();
      if (data.tasks) setTasks(data.tasks);
    } catch (e) {
      console.error("Error fetching tasks:", e);
    }
    setLoading(false);
  };

  useEffect(() => {
    fetchTasks();
    // Subscribe to realtime updates
    const channel = supabase
      .channel("agent-tasks-realtime")
      .on("postgres_changes", { event: "*", schema: "public", table: "agent_tasks" }, () => {
        fetchTasks();
      })
      .subscribe();

    return () => { supabase.removeChannel(channel); };
  }, [session]);

  const sendTrainingVideoTask = async () => {
    if (!session || !formationTitle) return;
    setSending(true);

    try {
      const resp = await fetch(TASK_URL, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${session.access_token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
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
        }),
      });

      const data = await resp.json();
      if (data.success) {
        setTasks((prev) => [data.task, ...prev]);
      }
    } catch (e) {
      console.error("Error sending task:", e);
    }
    setSending(false);
  };

  const deleteTask = async (taskId: string) => {
    await supabase.from("agent_tasks").delete().eq("id", taskId);
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
          <Button variant="ghost" size="icon" className="h-7 w-7" onClick={fetchTasks}>
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

      {loading ? (
        <p className="text-xs text-muted-foreground">Chargement...</p>
      ) : tasks.length === 0 ? (
        <div className="text-center py-6">
          <Monitor className="h-8 w-8 text-muted-foreground/30 mx-auto mb-2" />
          <p className="text-xs text-muted-foreground">Aucune tâche envoyée à l'agent local</p>
          <p className="text-[10px] text-muted-foreground/60 mt-1">
            Téléchargez l'agent sur <code className="bg-secondary px-1 rounded">/soulbah-agent/</code>
          </p>
        </div>
      ) : (
        <ScrollArea className="max-h-[300px]">
          <div className="space-y-2">
            {tasks.map((task) => {
              const config = statusConfig[task.status] || statusConfig.pending;
              const Icon = config.icon;
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
                  </div>
                  <Badge variant="outline" className={`text-[9px] ${config.color}`}>
                    {config.label}
                  </Badge>
                  <button onClick={() => deleteTask(task.id)} className="text-muted-foreground hover:text-destructive">
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
