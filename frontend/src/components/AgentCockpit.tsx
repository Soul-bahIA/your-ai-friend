import { useEffect, useReducer, useRef, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { apiFetch, errorMessage } from "@/lib/api";
import { cancelAgentTask, fetchTaskScreenshot } from "@/lib/agentApi";
import {
  cockpitReducer,
  eventText,
  initialCockpitState,
  type AgentEvent,
  type PendingApproval,
} from "@/lib/agentEvents";
import { toast } from "sonner";
import {
  Play, Pause, Square, Monitor, CheckCircle2, XCircle, Loader2,
  Camera, Flag, ChevronRight, Circle, ShieldAlert, ShieldCheck, Ban, Brain, RotateCcw, type LucideIcon,
} from "lucide-react";

const typeMeta: Record<string, { icon: LucideIcon; color: string; label: string }> = {
  task_started: { icon: Flag, color: "text-primary", label: "Démarrage" },
  step_started: { icon: ChevronRight, color: "text-warning", label: "Étape" },
  step_done: { icon: CheckCircle2, color: "text-success", label: "OK" },
  step_failed: { icon: XCircle, color: "text-destructive", label: "Échec" },
  screenshot: { icon: Camera, color: "text-accent", label: "Capture" },
  approval_required: { icon: ShieldAlert, color: "text-warning", label: "Confirmation" },
  approval_result: { icon: ShieldCheck, color: "text-muted-foreground", label: "Réponse" },
  task_completed: { icon: CheckCircle2, color: "text-success", label: "Terminé" },
  task_failed: { icon: XCircle, color: "text-destructive", label: "Arrêté" },
  task_cancelled: { icon: Ban, color: "text-muted-foreground", label: "Annulée" },
  task_approved: { icon: ShieldCheck, color: "text-success", label: "Approuvée" },
  task_requeued: { icon: RotateCcw, color: "text-warning", label: "Remise en file" },
  evaluation: { icon: Brain, color: "text-primary", label: "Évaluation" },
  info: { icon: Circle, color: "text-muted-foreground", label: "Info" },
};

/** Autres tâches en cours (autres PC) dont on recharge les confirmations au démarrage. */
const MAX_PARALLEL_TASKS = 5;

const approvalText = (a: PendingApproval) =>
  [a.stepIndex !== null ? `Étape ${a.stepIndex + 1}` : "", a.action].filter(Boolean).join(" · ") +
  (a.summary ? ` — ${a.summary}` : "");

const AgentCockpit = () => {
  const { user } = useAuth();
  const userId = user?.id;
  const [state, dispatch] = useReducer(cockpitReducer, initialCockpitState);
  const { events, liveImage, taskId, running, pendingApproval, otherApprovals, screenshotRequest } = state;
  const [busy, setBusy] = useState(false);
  const timelineRef = useRef<HTMLDivElement>(null);

  // Reprise après rafraîchissement : recharge la tâche en cours et sa timeline, puis les
  // confirmations attendues sur les autres PC (tâches exécutées en parallèle, §7/§13).
  useEffect(() => {
    if (!userId) return;
    let ignore = false;
    const eventsOf = async (id: string) =>
      (await apiFetch<{ events?: AgentEvent[] }>(`/api/agent-tasks/${encodeURIComponent(id)}/events`))?.events ?? [];
    (async () => {
      try {
        const d = await apiFetch<{ tasks?: { id: string }[] }>("/api/agent-tasks?status=in_progress");
        const [task, ...others] = d?.tasks ?? [];
        if (!task || ignore) return;
        const history = await eventsOf(task.id);
        if (ignore) return;
        dispatch({ type: "hydrate", taskId: task.id, events: history });
        for (const other of others.slice(0, MAX_PARALLEL_TASKS)) {
          const otherHistory = await eventsOf(other.id);
          if (ignore) return;
          dispatch({ type: "approvals", taskId: other.id, events: otherHistory });
        }
      } catch (err) {
        // Pas de tâche en cours ou backend injoignable : cockpit au repos.
        console.warn("[Cockpit] Reprise impossible :", errorMessage(err));
      }
    })();
    return () => {
      ignore = true;
    };
  }, [userId]);

  // Abonnement temps réel aux évènements de l'agent (INSERT sur agent_events).
  // Le filtrage (formations ignorées, autre tâche…) est fait par le réducteur.
  useEffect(() => {
    if (!userId) return;
    const channel = supabase
      .channel(`agent-events-live-${userId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "agent_events", filter: `user_id=eq.${userId}` },
        (payload) => dispatch({ type: "event", event: payload.new as AgentEvent }),
      )
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [userId]);

  // Capture signalée (data.has_image) : récupérée via GET /:id/screenshot (contrat §8).
  useEffect(() => {
    if (!screenshotRequest) return;
    const ctrl = new AbortController();
    const { taskId: shotTask } = screenshotRequest;
    fetchTaskScreenshot(shotTask, ctrl.signal)
      .then((image) => {
        if (!ctrl.signal.aborted) dispatch({ type: "screenshot", taskId: shotTask, image });
      })
      .catch((err) => {
        if (!ctrl.signal.aborted) console.warn("[Cockpit] Capture indisponible :", errorMessage(err));
      });
    return () => ctrl.abort();
  }, [screenshotRequest]);

  // Auto-scroll de la timeline.
  useEffect(() => {
    timelineRef.current?.scrollTo({ top: timelineRef.current.scrollHeight, behavior: "smooth" });
  }, [events]);

  const control = async (value: "pause" | "resume" | "stop") => {
    if (!taskId || !userId) return;
    setBusy(true);
    try {
      if (value === "stop") {
        // Arrêt = annulation (contrat §2) : l'agent finit l'étape courante puis passe en « cancelled ».
        await cancelAgentTask(taskId);
        dispatch({ type: "stopped" });
        toast.success("Arrêt demandé", { description: "L'agent s'arrête après l'étape en cours." });
      } else {
        await apiFetch(`/api/agent-tasks/${taskId}/control`, {
          method: "POST",
          json: { control: value },
        });
      }
    } catch (err) {
      toast.error("Commande de l'agent impossible", { description: errorMessage(err) });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="rounded-xl border border-border bg-card overflow-hidden">
      {/* Barre de contrôle */}
      <div className="flex items-center justify-between border-b border-border px-4 py-2.5">
        <div className="flex items-center gap-2">
          <Monitor className="h-4 w-4 text-primary" />
          <h3 className="text-sm font-semibold">Poste de pilotage</h3>
          <span className={`flex items-center gap-1 text-[10px] font-mono ${running ? "text-success" : "text-muted-foreground"}`}>
            <span className={`h-1.5 w-1.5 rounded-full ${running ? "bg-success animate-pulse" : "bg-muted-foreground/40"}`} />
            {running ? "en cours" : "au repos"}
          </span>
        </div>
        <div className="flex items-center gap-1">
          <button onClick={() => control("pause")} disabled={!running || busy}
            className="rounded-md p-1.5 text-muted-foreground hover:bg-secondary hover:text-warning disabled:opacity-30" title="Pause" aria-label="Mettre l'agent en pause">
            <Pause className="h-4 w-4" />
          </button>
          <button onClick={() => control("resume")} disabled={!running || busy}
            className="rounded-md p-1.5 text-muted-foreground hover:bg-secondary hover:text-success disabled:opacity-30" title="Reprendre" aria-label="Reprendre l'agent">
            <Play className="h-4 w-4" />
          </button>
          <button onClick={() => control("stop")} disabled={!running || busy}
            className="rounded-md p-1.5 text-muted-foreground hover:bg-secondary hover:text-destructive disabled:opacity-30" title="Arrêter" aria-label="Arrêter l'agent">
            <Square className="h-4 w-4" />
          </button>
        </div>
      </div>

      {/* Confirmation demandée à la console du PC (contrat §13) */}
      {pendingApproval && (
        <div className="flex items-start gap-2 border-b border-warning/30 bg-warning/10 px-4 py-2" role="status" aria-live="polite">
          <Loader2 className="mt-0.5 h-3.5 w-3.5 flex-shrink-0 animate-spin text-warning" />
          <div className="min-w-0 text-xs">
            <p className="font-medium text-warning">En attente de confirmation sur le PC</p>
            <p className="text-muted-foreground break-words">{approvalText(pendingApproval)}</p>
          </div>
        </div>
      )}
      {/* Confirmations attendues pour d'autres tâches (autre PC, exécution en parallèle) */}
      {otherApprovals.map((a) => (
        <div
          key={a.taskId}
          className="flex items-start gap-2 border-b border-warning/30 bg-warning/5 px-4 py-2"
          role="status"
          aria-live="polite"
        >
          <ShieldAlert className="mt-0.5 h-3.5 w-3.5 flex-shrink-0 text-warning" />
          <div className="min-w-0 text-xs">
            <p className="font-medium text-warning">
              En attente de confirmation sur le PC — autre tâche ({a.taskId.slice(0, 8)})
            </p>
            <p className="text-muted-foreground break-words">{approvalText(a)}</p>
          </div>
        </div>
      ))}

      <div className="grid grid-cols-1 md:grid-cols-2">
        {/* Écran live */}
        <div className="flex min-h-[240px] items-center justify-center border-b border-border bg-black/40 md:border-b-0 md:border-r">
          {liveImage ? (
            <img src={liveImage} alt="Écran de l'agent en direct" className="max-h-[320px] w-full object-contain" />
          ) : (
            <div className="p-8 text-center">
              <Monitor className="mx-auto mb-2 h-10 w-10 text-muted-foreground/20" />
              <p className="text-xs text-muted-foreground">En attente d'une capture d'écran de l'agent…</p>
            </div>
          )}
        </div>

        {/* Timeline */}
        <div ref={timelineRef} className="max-h-[320px] min-h-[240px] overflow-y-auto p-3">
          {events.length === 0 ? (
            <p className="py-8 text-center text-xs text-muted-foreground">
              Aucune exécution en cours. Lancez un objectif ci-dessous et lancez l'agent local.
            </p>
          ) : (
            <ol className="space-y-1.5">
              {events.map((ev) => {
                const meta = typeMeta[ev.type] ?? typeMeta.info;
                const Icon = meta.icon;
                return (
                  <li key={ev.id} className="flex items-start gap-2">
                    <Icon className={`mt-0.5 h-3.5 w-3.5 flex-shrink-0 ${meta.color}`} />
                    <div className="min-w-0 flex-1">
                      <span className="text-[11px] text-foreground/90">{eventText(ev)}</span>
                      {ev.data?.duration_s !== undefined && (
                        <span className="ml-1 text-[10px] text-muted-foreground">({ev.data.duration_s}s)</span>
                      )}
                    </div>
                  </li>
                );
              })}
            </ol>
          )}
        </div>
      </div>
    </div>
  );
};

export default AgentCockpit;
