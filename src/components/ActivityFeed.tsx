import { Activity } from "lucide-react";

interface ActivityItem {
  time: string;
  message: string;
  type: "info" | "success" | "warning" | "error";
}

const typeColors = {
  info: "text-primary",
  success: "text-success",
  warning: "text-warning",
  error: "text-destructive",
};

const dotColors = {
  info: "bg-primary",
  success: "bg-success",
  warning: "bg-warning",
  error: "bg-destructive",
};

const activities: ActivityItem[] = [
  { time: "il y a 2m", message: "Formation « React Avancé » générée avec succès", type: "success" },
  { time: "il y a 8m", message: "Module de montage vidéo en cours de traitement", type: "warning" },
  { time: "il y a 15m", message: "Application e-commerce déployée automatiquement", type: "success" },
  { time: "il y a 23m", message: "Auto-optimisation : amélioration de 12% des performances", type: "info" },
  { time: "il y a 45m", message: "Sauvegarde cloud synchronisée", type: "info" },
  { time: "il y a 1h", message: "Détection d'erreur corrigée dans le module de recherche", type: "error" },
];

const ActivityFeed = () => {
  return (
    <div className="rounded-lg border border-border bg-card p-5 opacity-0 animate-fade-in" style={{ animationDelay: "400ms" }}>
      <div className="flex items-center gap-2 mb-4">
        <Activity className="h-4 w-4 text-primary" />
        <h3 className="text-sm font-semibold text-foreground">Activité Récente</h3>
      </div>
      <div className="space-y-3">
        {activities.map((item, i) => (
          <div key={i} className="flex items-start gap-3">
            <div className={`mt-1.5 h-1.5 w-1.5 rounded-full ${dotColors[item.type]} shrink-0`} />
            <div className="flex-1 min-w-0">
              <p className="text-xs text-foreground leading-relaxed">{item.message}</p>
              <p className="text-[10px] text-muted-foreground font-mono mt-0.5">{item.time}</p>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
};

export default ActivityFeed;
