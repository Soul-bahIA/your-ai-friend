import { useEffect, useState } from "react";
import {
  Brain, Search, GraduationCap, AppWindow, Monitor, Video,
  Film, RefreshCw, Database, Shield, Cloud, Zap,
} from "lucide-react";
import DashboardLayout from "@/components/DashboardLayout";
import ModuleCard from "@/components/ModuleCard";
import StatCard from "@/components/StatCard";
import ActivityFeed from "@/components/ActivityFeed";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";

const moduleIcons: Record<string, any> = {
  "IA Centrale": Brain,
  "Recherche Internet": Search,
  "Génération de Cours": GraduationCap,
  "Génération d'Apps": AppWindow,
  "Automatisation PC": Monitor,
  "Capture Vidéo": Video,
  "Montage Automatique": Film,
  "Auto-Optimisation": RefreshCw,
  "Base de Données": Database,
  "Sécurité": Shield,
  "Cloud Hybride": Cloud,
  "Microservices": Zap,
};

const defaultModules = [
  { icon: Brain, title: "IA Centrale", description: "Orchestration et prise de décision autonome", status: "active" as const, stats: "Prêt" },
  { icon: Search, title: "Recherche Internet", description: "Analyse et extraction de connaissances", status: "active" as const, stats: "Prêt" },
  { icon: GraduationCap, title: "Génération de Cours", description: "Création automatique de formations structurées", status: "idle" as const, stats: "En attente" },
  { icon: AppWindow, title: "Génération d'Apps", description: "Création d'applications complètes", status: "idle" as const, stats: "En attente" },
  { icon: Monitor, title: "Automatisation PC", description: "Contrôle et exécution sur le système", status: "idle" as const, stats: "En attente" },
  { icon: Video, title: "Capture Vidéo", description: "Enregistrement automatique des sessions", status: "idle" as const, stats: "En attente" },
  { icon: Film, title: "Montage Automatique", description: "Post-production intelligente", status: "idle" as const, stats: "En attente" },
  { icon: RefreshCw, title: "Auto-Optimisation", description: "Amélioration continue des performances", status: "active" as const, stats: "Prêt" },
  { icon: Database, title: "Base de Données", description: "PostgreSQL + Redis — stockage et cache", status: "active" as const, stats: "Connecté" },
  { icon: Shield, title: "Sécurité", description: "Monitoring et protection en temps réel", status: "active" as const, stats: "0 menaces" },
  { icon: Cloud, title: "Cloud Hybride", description: "Synchronisation locale et cloud", status: "active" as const, stats: "Connecté" },
  { icon: Zap, title: "Microservices", description: "Services haute performance Rust/Go", status: "idle" as const, stats: "En attente" },
];

const Index = () => {
  const { user } = useAuth();
  const [formationsCount, setFormationsCount] = useState(0);
  const [appsCount, setAppsCount] = useState(0);
  const [logsCount, setLogsCount] = useState(0);

  useEffect(() => {
    if (!user) return;
    const fetchStats = async () => {
      const [f, a, l] = await Promise.all([
        supabase.from("formations").select("id", { count: "exact", head: true }),
        supabase.from("applications").select("id", { count: "exact", head: true }),
        supabase.from("system_logs").select("id", { count: "exact", head: true }),
      ]);
      setFormationsCount(f.count || 0);
      setAppsCount(a.count || 0);
      setLogsCount(l.count || 0);
    };
    fetchStats();
  }, [user]);

  return (
    <DashboardLayout>
      <div className="px-8 py-8">
        <div className="mb-8 opacity-0 animate-fade-in">
          <h1 className="text-3xl font-bold tracking-tight">
            Centre de <span className="text-gradient-primary">Commande</span>
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Plateforme IA autonome — tous les modules opérationnels
          </p>
        </div>

        <div className="grid grid-cols-4 gap-4 mb-8">
          <StatCard label="Formations" value={String(formationsCount)} change="Base de données" delay={100} />
          <StatCard label="Applications" value={String(appsCount)} change="Base de données" delay={150} />
          <StatCard label="Événements" value={String(logsCount)} change="Logs système" delay={200} />
          <StatCard label="Système" value="100%" change="Opérationnel" positive delay={250} />
        </div>

        <div className="grid grid-cols-12 gap-6">
          <div className="col-span-8">
            <h2 className="text-sm font-semibold text-foreground mb-4 opacity-0 animate-fade-in" style={{ animationDelay: "300ms" }}>
              Modules du Système
            </h2>
            <div className="grid grid-cols-3 gap-4">
              {defaultModules.map((mod, i) => (
                <ModuleCard key={mod.title} {...mod} delay={350 + i * 50} />
              ))}
            </div>
          </div>
          <div className="col-span-4">
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
