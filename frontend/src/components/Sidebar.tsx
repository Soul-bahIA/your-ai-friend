import { Link, useLocation } from "react-router-dom";
import {
  Brain,
  LayoutDashboard,
  GraduationCap,
  AppWindow,
  Database,
  Monitor,
  Video,
  Settings,
  Shield,
  LogOut,
  MessageCircle,
  BookOpen,
} from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { useSystemStatus } from "@/hooks/useSystemStatus";
import { SERVICE_STATE_LABELS, statusView, type ServiceState } from "@/lib/systemStatus";

const navItems = [
  { icon: LayoutDashboard, label: "Dashboard", path: "/" },
  { icon: MessageCircle, label: "Chat IA", path: "/chat" },
  { icon: GraduationCap, label: "Formations", path: "/formations" },
  { icon: AppWindow, label: "Applications", path: "/applications" },
  { icon: BookOpen, label: "Connaissances", path: "/knowledge" },
  { icon: Database, label: "Base de données", path: "/database" },
  { icon: Monitor, label: "Automatisation", path: "/automation" },
  { icon: Video, label: "Vidéo", path: "/video" },
  { icon: Shield, label: "Sécurité", path: "/security" },
  { icon: Settings, label: "Paramètres", path: "/settings" },
];

const Sidebar = ({ onNavigate }: { onNavigate?: () => void }) => {
  const location = useLocation();
  const { user, signOut } = useAuth();
  const status = useSystemStatus();
  const view = statusView(status.overall);
  const services: [string, ServiceState][] = [
    ["API", status.backend],
    ["Base", status.postgres],
    ["IA", status.pythonIa],
    ["Supabase", status.supabase],
  ];

  return (
    <aside className="h-full w-64 border-r border-border bg-sidebar flex flex-col md:fixed md:left-0 md:top-0 md:z-40 md:h-screen">
      {/* Logo */}
      <div className="flex items-center gap-3 px-6 py-5 border-b border-border">
        <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-primary/10 glow-primary">
          <Brain className="h-5 w-5 text-primary" />
        </div>
        <div>
          <h1 className="text-sm font-bold text-foreground tracking-tight">SOULBAH IA</h1>
          <p className="text-[10px] text-muted-foreground font-mono">v1.0.0 — Autonome</p>
        </div>
      </div>

      {/* Nav */}
      <nav className="flex-1 px-3 py-4 space-y-1">
        {navItems.map((item) => {
          const isActive = location.pathname === item.path;
          return (
            <Link
              key={item.path}
              to={item.path}
              onClick={onNavigate}
              className={`flex items-center gap-3 rounded-md px-3 py-2.5 text-sm transition-colors ${
                isActive
                  ? "bg-primary/10 text-primary font-medium"
                  : "text-muted-foreground hover:text-foreground hover:bg-secondary"
              }`}
            >
              <item.icon className="h-4 w-4" />
              {item.label}
            </Link>
          );
        })}
      </nav>

      {/* User & Status */}
      <div className="px-4 py-4 border-t border-border">
        {user && (
          <div className="flex items-center justify-between mb-3">
            <span className="text-xs text-foreground truncate max-w-[160px]">{user.email}</span>
            <button onClick={signOut} className="text-muted-foreground hover:text-destructive transition-colors" aria-label="Se déconnecter" title="Se déconnecter">
              <LogOut className="h-4 w-4" />
            </button>
          </div>
        )}
        {/* État réel des services (sondes /health, /health/deep et Supabase) */}
        <div className="flex items-center gap-2" role="status" aria-live="polite">
          <div className={`h-2 w-2 rounded-full ${view.dotClass} ${view.pulse ? "animate-pulse" : ""}`} />
          <span className="text-xs text-muted-foreground">{view.label}</span>
        </div>
        <p className="mt-1 text-[10px] text-muted-foreground font-mono">
          {services.map(([name, state]) => `${name} ${SERVICE_STATE_LABELS[state]}`).join(" · ")}
        </p>
        <p className="text-[10px] text-muted-foreground/70 mt-0.5">CPU / RAM : non disponible</p>
      </div>
    </aside>
  );
};

export default Sidebar;
