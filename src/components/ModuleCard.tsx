import { LucideIcon } from "lucide-react";

interface ModuleCardProps {
  icon: LucideIcon;
  title: string;
  description: string;
  status: "active" | "idle" | "processing";
  stats?: string;
  delay?: number;
}

const statusColors = {
  active: "bg-success",
  idle: "bg-muted-foreground",
  processing: "bg-warning",
};

const statusLabels = {
  active: "Actif",
  idle: "Inactif",
  processing: "En cours",
};

const ModuleCard = ({ icon: Icon, title, description, status, stats, delay = 0 }: ModuleCardProps) => {
  return (
    <div
      className="group relative rounded-lg border border-border bg-card p-5 transition-all duration-300 hover:border-primary/30 hover:glow-primary opacity-0 animate-fade-in"
      style={{ animationDelay: `${delay}ms` }}
    >
      <div className="absolute inset-0 rounded-lg bg-gradient-to-br from-primary/5 to-transparent opacity-0 transition-opacity group-hover:opacity-100" />
      <div className="relative">
        <div className="flex items-center justify-between mb-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-md bg-secondary">
            <Icon className="h-5 w-5 text-primary" />
          </div>
          <div className="flex items-center gap-2">
            <div className={`h-2 w-2 rounded-full ${statusColors[status]} ${status === "processing" ? "animate-pulse" : ""}`} />
            <span className="text-xs text-muted-foreground font-mono">{statusLabels[status]}</span>
          </div>
        </div>
        <h3 className="text-sm font-semibold text-foreground mb-1">{title}</h3>
        <p className="text-xs text-muted-foreground leading-relaxed">{description}</p>
        {stats && (
          <div className="mt-3 pt-3 border-t border-border">
            <span className="text-xs font-mono text-primary">{stats}</span>
          </div>
        )}
      </div>
    </div>
  );
};

export default ModuleCard;
