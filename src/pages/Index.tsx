import {
  Brain,
  Search,
  GraduationCap,
  AppWindow,
  Monitor,
  Video,
  Film,
  RefreshCw,
  Database,
  Shield,
  Cloud,
  Zap,
} from "lucide-react";
import DashboardLayout from "@/components/DashboardLayout";
import ModuleCard from "@/components/ModuleCard";
import StatCard from "@/components/StatCard";
import ActivityFeed from "@/components/ActivityFeed";

const modules = [
  { icon: Brain, title: "IA Centrale", description: "Orchestration et prise de décision autonome", status: "active" as const, stats: "1,247 décisions / jour" },
  { icon: Search, title: "Recherche Internet", description: "Analyse et extraction de connaissances", status: "active" as const, stats: "342 sources indexées" },
  { icon: GraduationCap, title: "Génération de Cours", description: "Création automatique de formations structurées", status: "processing" as const, stats: "3 formations en cours" },
  { icon: AppWindow, title: "Génération d'Apps", description: "Création d'applications complètes", status: "active" as const, stats: "12 apps déployées" },
  { icon: Monitor, title: "Automatisation PC", description: "Contrôle et exécution sur le système", status: "idle" as const, stats: "En attente" },
  { icon: Video, title: "Capture Vidéo", description: "Enregistrement automatique des sessions", status: "active" as const, stats: "4.2 TB enregistrés" },
  { icon: Film, title: "Montage Automatique", description: "Post-production intelligente", status: "processing" as const, stats: "2 vidéos en montage" },
  { icon: RefreshCw, title: "Auto-Optimisation", description: "Amélioration continue des performances", status: "active" as const, stats: "+12% cette semaine" },
  { icon: Database, title: "Base de Données", description: "PostgreSQL + Redis — stockage et cache", status: "active" as const, stats: "99.9% uptime" },
  { icon: Shield, title: "Sécurité", description: "Monitoring et protection en temps réel", status: "active" as const, stats: "0 menaces détectées" },
  { icon: Cloud, title: "Cloud Hybride", description: "Synchronisation locale et cloud", status: "active" as const, stats: "Dernière sync: 2m" },
  { icon: Zap, title: "Microservices", description: "Services haute performance Rust/Go", status: "active" as const, stats: "< 5ms latence" },
];

const Index = () => {
  return (
    <DashboardLayout>
      <div className="px-8 py-8">
        {/* Header */}
        <div className="mb-8 opacity-0 animate-fade-in">
          <h1 className="text-3xl font-bold tracking-tight">
            Centre de <span className="text-gradient-primary">Commande</span>
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Plateforme IA autonome — tous les modules opérationnels
          </p>
        </div>

        {/* Stats */}
        <div className="grid grid-cols-4 gap-4 mb-8">
          <StatCard label="Formations Générées" value="847" change="23 cette semaine" delay={100} />
          <StatCard label="Applications" value="156" change="8 ce mois" delay={150} />
          <StatCard label="Temps d'Activité" value="99.97%" change="0.02%" positive delay={200} />
          <StatCard label="Optimisations" value="2,341" change="156 auto-corrections" delay={250} />
        </div>

        {/* Modules Grid + Activity */}
        <div className="grid grid-cols-12 gap-6">
          <div className="col-span-8">
            <h2 className="text-sm font-semibold text-foreground mb-4 opacity-0 animate-fade-in" style={{ animationDelay: "300ms" }}>
              Modules du Système
            </h2>
            <div className="grid grid-cols-3 gap-4">
              {modules.map((mod, i) => (
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
