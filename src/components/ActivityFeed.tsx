import { useEffect, useState } from "react";
import { Activity } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";

interface LogItem {
  id: string;
  module: string;
  event: string;
  level: string;
  created_at: string;
}

const levelColors: Record<string, string> = {
  info: "text-primary",
  success: "text-success",
  warning: "text-warning",
  error: "text-destructive",
};

const dotColors: Record<string, string> = {
  info: "bg-primary",
  success: "bg-success",
  warning: "bg-warning",
  error: "bg-destructive",
};

function timeAgo(dateStr: string) {
  const diff = Date.now() - new Date(dateStr).getTime();
  const minutes = Math.floor(diff / 60000);
  if (minutes < 1) return "à l'instant";
  if (minutes < 60) return `il y a ${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `il y a ${hours}h`;
  return `il y a ${Math.floor(hours / 24)}j`;
}

const ActivityFeed = () => {
  const { user } = useAuth();
  const [logs, setLogs] = useState<LogItem[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!user) return;

    const fetchLogs = async () => {
      const { data } = await supabase
        .from("system_logs")
        .select("*")
        .order("created_at", { ascending: false })
        .limit(20);
      if (data) setLogs(data);
      setLoading(false);
    };

    fetchLogs();

    // Realtime subscription
    const channel = supabase
      .channel("system_logs_realtime")
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "system_logs" },
        (payload) => {
          setLogs((prev) => [payload.new as LogItem, ...prev].slice(0, 20));
        }
      )
      .subscribe();

    return () => { supabase.removeChannel(channel); };
  }, [user]);

  if (loading) {
    return (
      <div className="rounded-lg border border-border bg-card p-5 opacity-0 animate-fade-in" style={{ animationDelay: "400ms" }}>
        <div className="flex items-center gap-2 mb-4">
          <Activity className="h-4 w-4 text-primary" />
          <h3 className="text-sm font-semibold text-foreground">Activité Récente</h3>
        </div>
        <p className="text-xs text-muted-foreground">Chargement...</p>
      </div>
    );
  }

  return (
    <div className="rounded-lg border border-border bg-card p-5 opacity-0 animate-fade-in" style={{ animationDelay: "400ms" }}>
      <div className="flex items-center gap-2 mb-4">
        <Activity className="h-4 w-4 text-primary" />
        <h3 className="text-sm font-semibold text-foreground">Activité Récente</h3>
      </div>
      {logs.length === 0 ? (
        <p className="text-xs text-muted-foreground">Aucune activité pour le moment.</p>
      ) : (
        <div className="space-y-3">
          {logs.map((item) => (
            <div key={item.id} className="flex items-start gap-3">
              <div className={`mt-1.5 h-1.5 w-1.5 rounded-full ${dotColors[item.level] || "bg-primary"} shrink-0`} />
              <div className="flex-1 min-w-0">
                <p className="text-xs text-foreground leading-relaxed">
                  <span className="font-mono text-muted-foreground">[{item.module}]</span> {item.event}
                </p>
                <p className="text-[10px] text-muted-foreground font-mono mt-0.5">{timeAgo(item.created_at)}</p>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

export default ActivityFeed;
