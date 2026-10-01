import { useEffect, useRef, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { apiUrl } from "@/lib/api";
import {
  Play, Pause, Square, Monitor, CheckCircle2, XCircle, Loader2,
  Camera, Flag, ChevronRight, Circle,
} from "lucide-react";

interface AgentEvent {
  id: string;
  task_id: string;
  type: string;
  message: string | null;
  data: { index?: number; image_b64?: string; media_type?: string; duration_s?: number; total?: number };
  created_at: string;
}

const typeMeta: Record<string, { icon: any; color: string; label: string }> = {
  task_started: { icon: Flag, color: "text-primary", label: "Démarrage" },
  step_started: { icon: ChevronRight, color: "text-warning", label: "Étape" },
  step_done: { icon: CheckCircle2, color: "text-success", label: "OK" },
  step_failed: { icon: XCircle, color: "text-destructive", label: "Échec" },
  screenshot: { icon: Camera, color: "text-accent", label: "Capture" },
  task_completed: { icon: CheckCircle2, color: "text-success", label: "Terminé" },
  task_failed: { icon: XCircle, color: "text-destructive", label: "Arrêté" },
  info: { icon: Circle, color: "text-muted-foreground", label: "Info" },
};

const AgentCockpit = () => {
  const { user, session } = useAuth();
  const [events, setEvents] = useState<AgentEvent[]>([]);
  const [liveImage, setLiveImage] = useState<string | null>(null);
  const [taskId, setTaskId] = useState<string | null>(null);
  const [running, setRunning] = useState(false);
  const [busy, setBusy] = useState(false);
  const timelineRef = useRef<HTMLDivElement>(null);

  // Reprise après rafraîchissement : recharge la tâche en cours et sa timeline.
  useEffect(() => {
    if (!session) return;
    (async () => {
      try {
        const headers = { Authorization: `Bearer ${session.access_token}` };
        const r = await fetch(apiUrl("/api/agent-tasks?status=in_progress"), { headers });
        const d = await r.json();
        const task = d.tasks?.[0];
        if (!task) return;
        setTaskId(task.id);
        setRunning(true);
        const er = await fetch(apiUrl(`/api/agent-tasks/${task.id}/events`), { headers });
        const ed = await er.json();
        if (ed.events?.length) {
          setEvents(ed.events as AgentEvent[]);
          const lastImg = [...ed.events].reverse().find((e: AgentEvent) => e.data?.image_b64);
          if (lastImg) {
            setLiveImage(`data:${lastImg.data.media_type ?? "image/jpeg"};base64,${lastImg.data.image_b64}`);
          }
        }
      } catch {
        /* pas de tâche en cours : cockpit au repos */
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session]);

  // Abonnement temps réel aux évènements de l'agent (INSERT sur agent_events).
  useEffect(() => {
    if (!user) return;
    const channel = supabase
      .channel("agent-events-live")
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "agent_events", filter: `user_id=eq.${user.id}` },
        (payload) => {
          const ev = payload.new as AgentEvent;
          // Nouvelle tâche : on réinitialise la timeline.
          if (ev.type === "task_started") {
            setEvents([ev]);
            setTaskId(ev.task_id);
            setLiveImage(null);
            setRunning(true);
          } else {
            setEvents((prev) => [...prev, ev]);
            if (ev.type === "task_completed" || ev.type === "task_failed") setRunning(false);
          }
          if (ev.data?.image_b64) {
            setLiveImage(`data:${ev.data.media_type ?? "image/jpeg"};base64,${ev.data.image_b64}`);
          }
        },
      )
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [user]);

  // Auto-scroll de la timeline.
  useEffect(() => {
    timelineRef.current?.scrollTo({ top: timelineRef.current.scrollHeight, behavior: "smooth" });
  }, [events]);

  const control = async (value: "pause" | "resume" | "stop") => {
    if (!taskId || !session) return;
    setBusy(true);
    try {
      await fetch(apiUrl(`/api/agent-tasks/${taskId}/control`), {
        method: "POST",
        headers: { Authorization: `Bearer ${session.access_token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ control: value }),
      });
      if (value === "stop") setRunning(false);
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
            className="rounded-md p-1.5 text-muted-foreground hover:bg-secondary hover:text-warning disabled:opacity-30" title="Pause">
            <Pause className="h-4 w-4" />
          </button>
          <button onClick={() => control("resume")} disabled={!running || busy}
            className="rounded-md p-1.5 text-muted-foreground hover:bg-secondary hover:text-success disabled:opacity-30" title="Reprendre">
            <Play className="h-4 w-4" />
          </button>
          <button onClick={() => control("stop")} disabled={!running || busy}
            className="rounded-md p-1.5 text-muted-foreground hover:bg-secondary hover:text-destructive disabled:opacity-30" title="Arrêter">
            <Square className="h-4 w-4" />
          </button>
        </div>
      </div>

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
                      <span className="text-[11px] text-foreground/90">{ev.message}</span>
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
