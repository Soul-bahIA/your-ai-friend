import { useQuery } from "@tanstack/react-query";
import {
  Brain, Search, GraduationCap, AppWindow, Monitor, Video,
  Film, RefreshCw, Database, Shield, Cloud, Zap, type LucideIcon,
} from "lucide-react";
import DashboardLayout from "@/components/DashboardLayout";
import ModuleCard from "@/components/ModuleCard";
import StatCard from "@/components/StatCard";
import ActivityFeed from "@/components/ActivityFeed";
import ErrorState from "@/components/ErrorState";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { useBackendHealth } from "@/hooks/useSystemStatus";
import {
  computeOverallStatus,
  deepCheck,
  overallLabels,
  type ServiceState,
} from "@/lib/systemStatus";

type ModuleStatus = "active" | "idle" | "processing";

interface ModuleDef {
  icon: LucideIcon;
  title: string;
  description: string;
  status: ModuleStatus;
  stats: string;
}

const stateToModule = (s: ServiceState): ModuleStatus =>
  s === "ok" ? "active" : s === "unknown" ? "processing" : "idle";

const stateLabel = (s: ServiceState, okLabel = "Connecté") =>
  s === "ok" ? okLabel : s === "unknown" ? "Vérification…" : "Hors ligne";

async function fetchStats() {
  const [f, a, l] = await Promise.all([
    supabase.from("formations").select("id", { count: "exact", head: true }),
    supabase.from("applications").select("id", { count: "exact", head: true }),
    supabase.from("system_logs").select("id", { count: "exact", head: true }),
  ]);
  const err = f.error ?? a.error ?? l.error;
  if (err) throw new Error(err.message || "Supabase injoignable");
  return { formations: f.count ?? 0, applications: a.count ?? 0, logs: l.count ?? 0 };
}

const Index = () => {
  const { user } = useAuth();
  const userId = user?.id;

  const stats = useQuery({
    queryKey: ["dashboard-stats", userId],
    queryFn: fetchStats,
    enabled: !!userId,
    retry: 1,
    refetchOnWindowFocus: false,
  });
  const health = useBackendHealth();

  const supabaseState: ServiceState = stats.isPending ? "unknown" : stats.isError ? "down" : "ok";
  const overall = computeOverallStatus({
    backend: health.backend,
    deep: health.deep,
    supabase: supabaseState,
  });
  const postgres = health.backend === "down" ? "down" : deepCheck(health.deep, "postgres");
  const pythonIa = health.backend === "down" ? "down" : deepCheck(health.deep, "python_ia");
  const backendModuleState: ServiceState = health.backend;

  const modules: ModuleDef[] = [
    { icon: Brain, title: "IA Centrale", description: "Orchestration et prise de décision autonome", status: stateToModule(pythonIa), stats: `Service IA : ${stateLabel(pythonIa, "Prêt")}` },
    { icon: Search, title: "Recherche Internet", description: "Analyse et extraction de connaissances", status: stateToModule(pythonIa), stats: stateLabel(pythonIa, "Prêt") },
    { icon: GraduationCap, title: "Génération de Cours", description: "Création automatique de formations structurées", status: stateToModule(backendModuleState), stats: stateLabel(backendModuleState, "Disponible") },
    { icon: AppWindow, title: "Génération d'Apps", description: "Création d'applications complètes", status: stateToModule(backendModuleState), stats: stateLabel(backendModuleState, "Disponible") },
    { icon: Monitor, title: "Automatisation PC", description: "Contrôle et exécution sur le système", status: "idle", stats: "Nécessite l'agent local" },
    { icon: Video, title: "Capture Vidéo", description: "Enregistrement automatique des sessions", status: "idle", stats: "Nécessite l'agent local" },
    { icon: Film, title: "Montage Automatique", description: "Post-production intelligente", status: "idle", stats: "En attente" },
    { icon: RefreshCw, title: "Auto-Optimisation", description: "Amélioration continue des performances", status: "idle", stats: "En attente" },
    { icon: Database, title: "Base de Données", description: "PostgreSQL — stockage du backend", status: stateToModule(postgres), stats: `PostgreSQL : ${stateLabel(postgres)}` },
    { icon: Shield, title: "Sécurité", description: "Monitoring et protection", status: "idle", stats: "Détection de menaces : non disponible" },
    { icon: Cloud, title: "Cloud Hybride", description: "Synchronisation locale et cloud (Supabase)", status: stateToModule(supabaseState), stats: `Supabase : ${stateLabel(supabaseState)}` },
    { icon: Zap, title: "Microservices", description: "Services haute performance", status: "idle", stats: "Non déployé" },
  ];

  const subtitle =
    overall === "operational"
      ? "Plateforme IA autonome — tous les services répondent"
      : overall === "checking"
        ? "Plateforme IA autonome — vérification des services…"
        : overall === "offline"
          ? "Plateforme IA autonome — services injoignables"
          : "Plateforme IA autonome — certains services ne répondent pas";

  const statValue = (n: number | undefined) => (stats.isError ? "—" : stats.isPending ? "…" : String(n ?? 0));

  return (
    <DashboardLayout>
      <div className="px-4 py-6 md:px-8 md:py-8">
        <div className="mb-6 md:mb-8 opacity-0 animate-fade-in">
          <h1 className="text-2xl md:text-3xl font-bold tracking-tight">
            Centre de <span className="text-gradient-primary">Commande</span>
          </h1>
          <p className="text-sm text-muted-foreground mt-1">{subtitle}</p>
        </div>

        {stats.isError && (
          <div className="mb-4">
            <ErrorState
              compact
              message="Impossible de charger les statistiques (Supabase injoignable)."
              detail={stats.error instanceof Error ? stats.error.message : null}
              onRetry={() => stats.refetch()}
            />
          </div>
        )}

        <div className="grid grid-cols-2 md:grid-cols-4 gap-3 md:gap-4 mb-6 md:mb-8">
          <StatCard label="Formations" value={statValue(stats.data?.formations)} change="Base de données" delay={100} />
          <StatCard label="Applications" value={statValue(stats.data?.applications)} change="Base de données" delay={150} />
          <StatCard label="Événements" value={statValue(stats.data?.logs)} change="Logs système" delay={200} />
          <StatCard
            label="Système"
            value={overallLabels[overall]}
            change={`Backend : ${stateLabel(health.backend, "OK")} · Supabase : ${stateLabel(supabaseState, "OK")}`}
            positive={overall === "operational" || overall === "checking"}
            delay={250}
          />
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">
          <div className="lg:col-span-8">
            <h2 className="text-sm font-semibold text-foreground mb-4 opacity-0 animate-fade-in" style={{ animationDelay: "300ms" }}>
              Modules du Système
            </h2>
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 md:gap-4">
              {modules.map((mod, i) => (
                <ModuleCard key={mod.title} {...mod} delay={350 + i * 50} />
              ))}
            </div>
          </div>
          <div className="lg:col-span-4">
            <h2 className="text-sm font-semibold text-foreground mb-4 opacity-0 animate-fade-in" style={{ animationDelay: "300ms" }}>
              Journal Système
            </h2>
            <ActivityFeed />
          </div>
        </div>
      </div>
    </DashboardLayout>
  );
};

export default Index;
