import { Link, useLocation } from "react-router-dom";
import {
  Brain,
  LayoutDashboard,
  GraduationCap,
  AppWindow,
  Monitor,
  Video,
  Settings,
  Shield,
  LogOut,
} from "lucide-react";
import { useAuth } from "@/hooks/useAuth";

const navItems = [
  { icon: LayoutDashboard, label: "Dashboard", path: "/" },
  { icon: GraduationCap, label: "Formations", path: "/formations" },
  { icon: AppWindow, label: "Applications", path: "/applications" },
  { icon: Monitor, label: "Automatisation", path: "/automation" },
  { icon: Video, label: "Vidéo", path: "/video" },
  { icon: Shield, label: "Sécurité", path: "/security" },
  { icon: Settings, label: "Paramètres", path: "/settings" },
];

const Sidebar = () => {
  const location = useLocation();
  const { user, signOut } = useAuth();

  return (
    <aside className="fixed left-0 top-0 z-40 h-screen w-64 border-r border-border bg-sidebar flex flex-col">
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
            <button onClick={signOut} className="text-muted-foreground hover:text-destructive transition-colors">
              <LogOut className="h-4 w-4" />
            </button>
          </div>
        )}
        <div className="flex items-center gap-2">
          <div className="h-2 w-2 rounded-full bg-success animate-pulse" />
          <span className="text-xs text-muted-foreground">Système opérationnel</span>
        </div>
        <div className="mt-2 flex items-center gap-2">
          <div className="flex-1 h-1.5 rounded-full bg-secondary overflow-hidden">
            <div className="h-full w-3/4 rounded-full bg-primary" />
          </div>
          <span className="text-[10px] font-mono text-muted-foreground">75%</span>
        </div>
        <p className="text-[10px] text-muted-foreground mt-1">CPU: 34% · RAM: 62%</p>
      </div>
    </aside>
  );
};

export default Sidebar;
