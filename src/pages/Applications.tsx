import { useState } from "react";
import DashboardLayout from "@/components/DashboardLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { AppWindow, Sparkles, Globe, Database, Code2 } from "lucide-react";

const sampleApps = [
  { title: "E-Commerce Platform", type: "Web App", tech: "React + Node.js", status: "Déployé" },
  { title: "Task Management API", type: "API REST", tech: "Go + PostgreSQL", status: "Déployé" },
  { title: "Chat Application", type: "Web App", tech: "React + WebSocket", status: "En test" },
];

const Applications = () => {
  const [appName, setAppName] = useState("");
  const [appDesc, setAppDesc] = useState("");

  return (
    <DashboardLayout>
      <div className="px-8 py-8 max-w-5xl">
        <div className="mb-8 opacity-0 animate-fade-in">
          <h1 className="text-3xl font-bold tracking-tight">
            Générateur d'<span className="text-gradient-accent">Applications</span>
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Créez des applications complètes automatiquement
          </p>
        </div>

        {/* Generator */}
        <div className="rounded-lg border border-border bg-card p-6 mb-8 opacity-0 animate-fade-in" style={{ animationDelay: "100ms" }}>
          <div className="flex items-center gap-2 mb-4">
            <Sparkles className="h-4 w-4 text-accent" />
            <h2 className="text-sm font-semibold">Nouvelle Application</h2>
          </div>
          <div className="space-y-4">
            <div>
              <label className="text-xs text-muted-foreground mb-1 block">Nom du projet</label>
              <Input
                placeholder="Ex: Marketplace de services freelance..."
                value={appName}
                onChange={(e) => setAppName(e.target.value)}
                className="bg-secondary border-border"
              />
            </div>
            <div>
              <label className="text-xs text-muted-foreground mb-1 block">Description & Fonctionnalités</label>
              <Textarea
                placeholder="Décrivez l'application souhaitée, les fonctionnalités principales, le type d'utilisateurs..."
                value={appDesc}
                onChange={(e) => setAppDesc(e.target.value)}
                className="bg-secondary border-border min-h-[100px]"
              />
            </div>
            <Button className="glow-accent bg-accent text-accent-foreground hover:bg-accent/90">
              <Sparkles className="h-4 w-4 mr-2" />
              Générer l'Application
            </Button>
          </div>
        </div>

        {/* Existing Apps */}
        <h2 className="text-sm font-semibold text-foreground mb-4 opacity-0 animate-fade-in" style={{ animationDelay: "200ms" }}>
          Applications Récentes
        </h2>
        <div className="space-y-3">
          {sampleApps.map((app, i) => (
            <div
              key={app.title}
              className="rounded-lg border border-border bg-card p-4 flex items-center justify-between opacity-0 animate-fade-in hover:border-accent/30 transition-colors"
              style={{ animationDelay: `${250 + i * 50}ms` }}
            >
              <div className="flex items-center gap-4">
                <div className="flex h-10 w-10 items-center justify-center rounded-md bg-secondary">
                  <AppWindow className="h-5 w-5 text-accent" />
                </div>
                <div>
                  <h3 className="text-sm font-medium text-foreground">{app.title}</h3>
                  <div className="flex items-center gap-4 mt-1">
                    <span className="text-[10px] text-muted-foreground flex items-center gap-1">
                      <Globe className="h-3 w-3" /> {app.type}
                    </span>
                    <span className="text-[10px] text-muted-foreground flex items-center gap-1">
                      <Code2 className="h-3 w-3" /> {app.tech}
                    </span>
                    <span className="text-[10px] text-muted-foreground flex items-center gap-1">
                      <Database className="h-3 w-3" /> Base de données
                    </span>
                  </div>
                </div>
              </div>
              <span className={`text-xs font-mono px-2 py-1 rounded ${app.status === "Déployé" ? "bg-success/10 text-success" : "bg-warning/10 text-warning"}`}>
                {app.status}
              </span>
            </div>
          ))}
        </div>
      </div>
    </DashboardLayout>
  );
};

export default Applications;
