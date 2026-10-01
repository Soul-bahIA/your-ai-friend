import { useState, useEffect, useCallback, useMemo } from "react";
import { toast } from "sonner";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { useCommandPrefill } from "@/hooks/useCommandPrefill";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import ConfirmAction from "@/components/ConfirmAction";
import ErrorState from "@/components/ErrorState";
import {
  Monitor, Loader2, CheckCircle2, XCircle, Clock, Trash2, RefreshCw, Sparkles, Ban, ShieldQuestion,
  ChevronDown, ChevronUp, Check, X, Film, type LucideIcon,
} from "lucide-react";
import { apiFetch, errorMessage } from "@/lib/api";
import {
  agentChoiceFromError,
  approveAgentTask,
  cancelAgentTask,
  deleteAgentTask,
  listAgents,
  submitGoal,
  type AgentChoice,
} from "@/lib/agentApi";
import {
  applyApproveResponse,
  applyCancelResponse,
  applyDeleteOutcome,
  applyTaskChange,
  approvalStepView,
  canCancelTask,
  canDeleteTask,
  describeStep,
  evaluationView,
  isAwaitingApproval,
  normalizeTaskRow,
  plannedSteps,
  recordingPaths,
  statusLabel,
  type AgentTask,
  type Tone,
} from "@/lib/agentTasks";

const statusStyle: Record<string, { color: string; icon: LucideIcon }> = {
  pending: { color: "bg-warning/10 text-warning", icon: Clock },
  in_progress: { color: "bg-primary/10 text-primary", icon: Loader2 },
  completed: { color: "bg-success/10 text-success", icon: CheckCircle2 },
  failed: { color: "bg-destructive/10 text-destructive", icon: XCircle },
  cancelled: { color: "bg-muted text-muted-foreground", icon: Ban },
};

const toneClass: Record<Tone, string> = {
  success: "text-success",
  warning: "text-warning",
  destructive: "text-destructive",
  primary: "text-primary",
  muted: "text-muted-foreground",
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

/** Valeur du sélecteur « PC cible » quand le serveur choisit (une seule clé active). */
const AUTO_AGENT = "auto";

type PendingSend = "goal" | "video";

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
  const [agents, setAgents] = useState<AgentChoice[]>([]);
  const [selectedAgent, setSelectedAgent] = useState<string>(AUTO_AGENT);
  // Choix du PC demandé par le serveur (400 + agents) pour l'envoi en attente.
  const [agentChoice, setAgentChoice] = useState<{ agents: AgentChoice[]; pending: PendingSend } | null>(null);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [busyTaskId, setBusyTaskId] = useState<string | null>(null);

  const agentNames = useMemo(() => new Map(agents.map((a) => [a.id, a.name])), [agents]);
  const explicitAgent = selectedAgent !== AUTO_AGENT ? selectedAgent : null;

  const fetchTasks = useCallback(async () => {
    if (!userId) return;
    setLoadError(null);
    try {
      const data = await apiFetch<{ tasks?: unknown[] }>("/api/agent-tasks");
      setTasks((data?.tasks ?? []).map(normalizeTaskRow).filter((t): t is AgentTask => t !== null));
    } catch (e) {
      console.error("Error fetching tasks:", e);
      setLoadError(errorMessage(e));
    }
    setLoading(false);
  }, [userId]);

  // PC disponibles (clés d'agent) : sélecteur affiché dès qu'il y en a plusieurs.
  useEffect(() => {
    if (!userId) return;
    let ignore = false;
    listAgents()
      .then((list) => {
        if (!ignore) setAgents(list);
      })
      .catch((e) => console.warn("[Agent] Liste des PC indisponible :", errorMessage(e)));
    return () => {
      ignore = true;
    };
  }, [userId]);

  const askAgentChoice = (list: AgentChoice[], pending: PendingSend) => {
    setAgentChoice({ agents: list, pending });
    setAgents((prev) => (prev.length > 0 ? prev : list));
  };

  const sendGoal = async (agentKeyId: string | null = explicitAgent) => {
    if (!userId || !goal.trim() || planning) return;
    setPlanning(true);
    setGoalFeedback(null);
    const outcome = await submitGoal(goal.trim(), agentKeyId);
    if (outcome.kind === "ok") {
      setGoalFeedback(`✅ Plan créé (${outcome.data.steps?.length ?? 0} étapes) : ${outcome.data.understanding ?? ""}`);
      setGoal("");
      setAgentChoice(null);
      fetchTasks();
    } else if (outcome.kind === "choose_agent") {
      askAgentChoice(outcome.agents, "goal");
      setGoalFeedback(`🖥️ ${outcome.message}`);
    } else {
      setGoalFeedback(`❌ ${outcome.message}`);
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

  const sendTrainingVideoTask = async (agentKeyId: string | null = explicitAgent) => {
    if (!userId || !formationTitle) return;
    setSending(true);

    try {
      const data = await apiFetch<{ success?: boolean; task?: unknown; error?: string }>("/api/agent-tasks", {
        method: "POST",
        json: {
          task_type: "full_training_video",
          priority: 1,
          ...(agentKeyId ? { agent_key_id: agentKeyId } : {}),
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
      const task = normalizeTaskRow(data?.task);
      if (data?.success && task) {
        setAgentChoice(null);
        setTasks((prev) => (prev.some((t) => t.id === task.id) ? prev : [task, ...prev]));
      } else {
        toast.error("Envoi de la tâche impossible", { description: data?.error });
      }
    } catch (e) {
      const choice = agentChoiceFromError(e);
      if (choice) {
        askAgentChoice(choice, "video");
        toast.info("Plusieurs PC disponibles", { description: "Choisissez le PC qui produira la vidéo." });
      } else {
        console.error("Error sending task:", e);
        toast.error("Envoi de la tâche impossible", { description: errorMessage(e) });
      }
    }
    setSending(false);
  };

  const retryWithAgent = (agentId: string) => {
    const pending = agentChoice?.pending;
    setSelectedAgent(agentId);
    setAgentChoice(null);
    if (pending === "video") sendTrainingVideoTask(agentId);
    else sendGoal(agentId);
  };

  const replaceTask = (taskId: string, update: (t: AgentTask) => AgentTask) =>
    setTasks((prev) => prev.map((t) => (t.id === taskId ? update(t) : t)));

  /** Annulation via l'API (S9) : pending → annulée, en cours → arrêt demandé. Sert aussi au rejet. */
  const cancelTask = async (task: AgentTask, rejecting = false) => {
    setBusyTaskId(task.id);
    try {
      const resp = await cancelAgentTask(task.id);
      replaceTask(task.id, (t) => applyCancelResponse(t, resp));
      toast.success(
        rejecting ? "Correction rejetée" : task.status === "in_progress" ? "Arrêt demandé à l'agent" : "Tâche annulée",
      );
    } catch (e) {
      toast.error(rejecting ? "Rejet impossible" : "Annulation impossible", { description: errorMessage(e) });
    } finally {
      setBusyTaskId(null);
    }
  };

  /** Approbation d'une correction proposée par l'évaluateur (S10). */
  const approveTask = async (task: AgentTask) => {
    setBusyTaskId(task.id);
    try {
      const resp = await approveAgentTask(task.id);
      replaceTask(task.id, (t) => applyApproveResponse(t, resp));
      toast.success("Correction approuvée", { description: "L'agent pourra l'exécuter à son prochain passage." });
    } catch (e) {
      toast.error("Approbation impossible", { description: errorMessage(e) });
    } finally {
      setBusyTaskId(null);
    }
  };

  // Suppression via l'API (S9) : uniquement pour une tâche terminée (une tâche active s'annule) ;
  // le serveur le vérifie (409) et oublie la capture en mémoire. Plus d'écriture Supabase directe.
  const deleteTask = async (task: AgentTask) => {
    if (!canDeleteTask(task)) return;
    setBusyTaskId(task.id);
    try {
      const outcome = await deleteAgentTask(task.id);
      setTasks((prev) => applyDeleteOutcome(prev, task.id, outcome));
      if (outcome.kind === "active") {
        toast.error("Suppression impossible", { description: "La tâche est encore active : annulez-la d'abord." });
      } else if (outcome.kind === "gone") {
        toast.info("Tâche déjà supprimée");
      }
    } catch (e) {
      console.error("Error deleting task:", e);
      toast.error("Suppression impossible", { description: errorMessage(e) });
    } finally {
      setBusyTaskId(null);
    }
  };

  const toggleExpanded = (id: string) =>
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

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
            <Button size="sm" onClick={() => sendTrainingVideoTask()} disabled={sending} className="text-xs">
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
        {agents.length > 1 && (
          <div className="flex items-center gap-2">
            <span className="text-[10px] text-muted-foreground">PC cible :</span>
            <Select value={selectedAgent} onValueChange={setSelectedAgent}>
              <SelectTrigger className="h-7 w-56 text-xs" aria-label="PC cible de l'agent">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={AUTO_AGENT}>Choisir au moment de l'envoi</SelectItem>
                {agents.map((a) => (
                  <SelectItem key={a.id} value={a.id}>{a.name}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        )}
        {goalFeedback && (
          <p className="text-[10px] text-muted-foreground">{goalFeedback}</p>
        )}
      </form>

      {/* Le serveur demande de choisir le PC (plusieurs agents actifs, contrat §7) */}
      {agentChoice && (
        <div className="rounded-md border border-primary/40 bg-primary/5 p-3 space-y-2" role="group" aria-label="Choix du PC cible">
          <p className="text-xs font-medium">Plusieurs PC sont connectés : lequel doit exécuter cette tâche ?</p>
          <div className="flex flex-wrap gap-2">
            {agentChoice.agents.map((a) => (
              <Button key={a.id} size="sm" variant="outline" className="h-7 text-xs" disabled={planning || sending} onClick={() => retryWithAgent(a.id)}>
                <Monitor className="h-3 w-3 mr-1" /> {a.name}
              </Button>
            ))}
            <Button size="sm" variant="ghost" className="h-7 text-xs" onClick={() => setAgentChoice(null)}>
              Annuler
            </Button>
          </div>
        </div>
      )}

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
        <ScrollArea className="max-h-[420px]">
          <div className="space-y-2">
            {tasks.map((task) => {
              const style = statusStyle[task.status] ?? statusStyle.pending;
              const Icon = style.icon;
              const awaiting = isAwaitingApproval(task);
              const evaluation = evaluationView(task, tasks);
              const goalMeta = task.payload?.goal_meta;
              const steps = plannedSteps(task);
              const showSteps = awaiting || expanded.has(task.id);
              const recordings = recordingPaths(task);
              const pcId = task.claimed_by_key_id ?? task.target_agent_key_id;
              const pcName = pcId ? agentNames.get(pcId) ?? `PC ${pcId.slice(0, 8)}` : null;
              const busy = busyTaskId === task.id;
              return (
                <div
                  key={task.id}
                  className={`rounded-md px-3 py-2 ${awaiting ? "border border-warning/40 bg-warning/5" : "bg-secondary/50"}`}
                >
                  <div className="flex items-center gap-3">
                    {awaiting ? (
                      <ShieldQuestion className="h-4 w-4 flex-shrink-0 text-warning" />
                    ) : (
                      <Icon className={`h-4 w-4 flex-shrink-0 ${task.status === "in_progress" ? "animate-spin" : ""} ${style.color.split(" ")[1]}`} />
                    )}
                    <div className="flex-1 min-w-0">
                      <p className="text-xs font-medium truncate">
                        {taskTypeLabels[task.task_type] || task.task_type}
                      </p>
                      <p className="text-[10px] text-muted-foreground">
                        {new Date(task.created_at).toLocaleString("fr-FR")}
                        {pcName && ` · 💻 ${pcName}`}
                      </p>
                    </div>
                    <Badge variant="outline" className={`text-[9px] ${awaiting ? "bg-warning/10 text-warning" : style.color}`}>
                      {statusLabel(task)}
                    </Badge>
                    {canCancelTask(task) && !awaiting && (
                      <ConfirmAction
                        title={task.status === "in_progress" ? "Arrêter cette tâche ?" : "Annuler cette tâche ?"}
                        description={
                          task.status === "in_progress"
                            ? "L'agent termine l'étape en cours puis s'arrête. La tâche passera à « Annulée »."
                            : "La tâche ne sera pas exécutée par l'agent."
                        }
                        confirmLabel={task.status === "in_progress" ? "Arrêter" : "Annuler la tâche"}
                        onConfirm={() => cancelTask(task)}
                        trigger={
                          <button
                            className="text-muted-foreground hover:text-destructive disabled:opacity-40"
                            aria-label="Annuler la tâche"
                            title="Annuler la tâche"
                            disabled={busy}
                          >
                            <Ban className="h-3 w-3" />
                          </button>
                        }
                      />
                    )}
                    {canDeleteTask(task) && (
                      <ConfirmAction
                        title="Supprimer cette tâche ?"
                        description="La tâche et son résultat seront retirés de l'historique."
                        onConfirm={() => deleteTask(task)}
                        trigger={
                          <button
                            className="text-muted-foreground hover:text-destructive disabled:opacity-40"
                            aria-label="Supprimer la tâche"
                            title="Supprimer la tâche"
                            disabled={busy}
                          >
                            <Trash2 className="h-3 w-3" />
                          </button>
                        }
                      />
                    )}
                  </div>

                  <div className="pl-7">
                    {task.error_message && (
                      <p className="text-[10px] text-destructive mt-0.5">{task.error_message}</p>
                    )}
                    {task.result?.file && (
                      <p className="text-[10px] text-success mt-0.5 break-all">📁 {task.result.file}</p>
                    )}
                    {recordings.map((path) => (
                      <p key={path} className="text-[10px] text-success mt-0.5 break-all flex items-center gap-1">
                        <Film className="h-3 w-3 flex-shrink-0" /> Enregistrement : {path}
                      </p>
                    ))}
                    {goalMeta?.goal && (
                      <p className="text-[10px] text-muted-foreground/80 mt-0.5 truncate">
                        🎯 {goalMeta.goal}
                        {(goalMeta.attempt ?? 0) > 1 && ` (tentative ${goalMeta.attempt})`}
                      </p>
                    )}
                    {evaluation && (
                      <p className={`text-[10px] mt-0.5 ${toneClass[evaluation.tone]}`}>🧠 {evaluation.text}</p>
                    )}

                    {awaiting && (
                      <p className="text-[10px] text-warning mt-1">
                        Correction proposée par l'IA : vérifiez le plan ci-dessous (chaque étape est affichée en
                        entier, telle que l'agent la recevra). Elle ne sera exécutée qu'après votre approbation.
                      </p>
                    )}

                    {steps.length > 0 && !awaiting && (
                      <button
                        onClick={() => toggleExpanded(task.id)}
                        className="mt-1 flex items-center gap-1 text-[10px] text-primary hover:underline"
                        aria-expanded={showSteps}
                      >
                        {showSteps ? <ChevronUp className="h-3 w-3" /> : <ChevronDown className="h-3 w-3" />}
                        {showSteps ? "Masquer le plan" : `Voir le plan (${steps.length} étape${steps.length > 1 ? "s" : ""})`}
                      </button>
                    )}
                    {showSteps && steps.length > 0 && !awaiting && (
                      <ol className="mt-1 space-y-0.5 list-decimal pl-4">
                        {steps.map((step, i) => (
                          <li key={i} className="text-[10px] text-foreground/80 break-words">{describeStep(step)}</li>
                        ))}
                      </ol>
                    )}
                    {/* Correction à approuver : rien de tronqué ni d'omis (S10) */}
                    {awaiting && steps.length > 0 && (
                      <ol className="mt-1 space-y-1.5 list-decimal pl-4" aria-label="Plan complet de la correction">
                        {steps.map((step, i) => {
                          const view = approvalStepView(step);
                          return (
                            <li key={i} className="text-[10px] text-foreground/80 break-words">
                              <span className={view.sensitive ? "font-medium text-warning" : undefined}>
                                {view.sensitive && "⚠️ "}
                                {view.summary}
                              </span>
                              <pre className="mt-0.5 max-h-40 overflow-auto whitespace-pre-wrap break-all rounded bg-background/60 p-1.5 font-mono text-[10px] text-muted-foreground">
                                {view.detail}
                              </pre>
                            </li>
                          );
                        })}
                      </ol>
                    )}

                    {awaiting && (
                      <div className="mt-2 flex gap-2">
                        <Button size="sm" className="h-7 text-xs" disabled={busy} onClick={() => approveTask(task)}>
                          {busy ? <Loader2 className="h-3 w-3 mr-1 animate-spin" /> : <Check className="h-3 w-3 mr-1" />}
                          Approuver
                        </Button>
                        <ConfirmAction
                          title="Rejeter cette correction ?"
                          description="La tâche de correction sera annulée et ne sera jamais exécutée."
                          confirmLabel="Rejeter"
                          onConfirm={() => cancelTask(task, true)}
                          trigger={
                            <Button size="sm" variant="outline" className="h-7 text-xs" disabled={busy}>
                              <X className="h-3 w-3 mr-1" /> Rejeter
                            </Button>
                          }
                        />
                      </div>
                    )}
                  </div>
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
