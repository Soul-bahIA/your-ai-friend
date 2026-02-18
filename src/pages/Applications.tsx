import { useState, useEffect } from "react";
import DashboardLayout from "@/components/DashboardLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { AppWindow, Sparkles, Globe, Database, Code2, Trash2, ChevronDown, ChevronUp, Loader2 } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { useToast } from "@/hooks/use-toast";
import type { Json } from "@/integrations/supabase/types";

interface AppArchitecture {
  frontend?: {
    framework?: string;
    components?: { name: string; description: string; code: string }[];
  };
  backend?: {
    endpoints?: { method: string; path: string; description: string }[];
  };
  database?: {
    tables?: { name: string; columns: string[]; description?: string }[];
  };
}

interface Application {
  id: string;
  title: string;
  description: string | null;
  app_type: string | null;
  tech_stack: string | null;
  status: string;
  created_at: string;
  source_code: Json | null;
}

const Applications = () => {
  const { user, session } = useAuth();
  const { toast } = useToast();
  const [appName, setAppName] = useState("");
  const [appDesc, setAppDesc] = useState("");
  const [apps, setApps] = useState<Application[]>([]);
  const [loading, setLoading] = useState(true);
  const [creating, setCreating] = useState(false);
  const [expandedId, setExpandedId] = useState<string | null>(null);

  useEffect(() => {
    if (!user) return;
    const fetchApps = async () => {
      const { data } = await supabase
        .from("applications")
        .select("*")
        .order("created_at", { ascending: false });
      if (data) setApps(data);
      setLoading(false);
    };
    fetchApps();
  }, [user]);

  const handleCreate = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!appName.trim() || !user || !session) return;
    setCreating(true);

    // Step 1: Create placeholder
    const { data, error } = await supabase
      .from("applications")
      .insert({
        user_id: user.id,
        title: appName,
        description: appDesc || "Génération en cours...",
        app_type: "Web App",
        tech_stack: "React + TypeScript",
        status: "Génération...",
      })
      .select()
      .single();

    if (error || !data) {
      toast({ title: "Erreur", description: error?.message || "Erreur", variant: "destructive" });
      setCreating(false);
      return;
    }

    setApps((prev) => [data, ...prev]);
    const applicationId = data.id;

    // Step 2: Call AI
    try {
      const response = await fetch(
        `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/generate-application`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${session.access_token}`,
            apikey: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
          },
          body: JSON.stringify({ appName, appDesc, applicationId }),
        }
      );

      const result = await response.json();
      if (!response.ok) throw new Error(result.error || "Échec de la génération");

      setApps((prev) =>
        prev.map((a) =>
          a.id === applicationId
            ? {
                ...a,
                title: result.application.title || appName,
                description: result.application.description,
                app_type: result.application.app_type || "Web App",
                tech_stack: result.application.tech_stack || "React + TypeScript",
                source_code: result.application.architecture || {},
                status: "Généré",
              }
            : a
        )
      );

      setAppName("");
      setAppDesc("");
      toast({
        title: "Application générée !",
        description: `« ${result.application.title} » — Architecture complète créée par IA.`,
      });
    } catch (err: any) {
      toast({ title: "Erreur IA", description: err.message, variant: "destructive" });
      setApps((prev) =>
        prev.map((a) => (a.id === applicationId ? { ...a, status: "Erreur" } : a))
      );
      await supabase.from("applications").update({ status: "Erreur" }).eq("id", applicationId);
    }

    setCreating(false);
  };

  const handleDelete = async (id: string, title: string) => {
    const { error } = await supabase.from("applications").delete().eq("id", id);
    if (!error) {
      setApps((prev) => prev.filter((a) => a.id !== id));
      if (user) {
        await supabase.from("system_logs").insert({
          user_id: user.id,
          module: "Applications",
          event: `Application « ${title} » supprimée`,
          level: "warning",
        });
      }
    }
  };

  const getStatusColor = (status: string) => {
    if (status === "Généré" || status === "Déployé") return "bg-success/10 text-success";
    if (status === "Erreur") return "bg-destructive/10 text-destructive";
    return "bg-warning/10 text-warning";
  };

  const getArchitecture = (app: Application): AppArchitecture | null => {
    if (!app.source_code || typeof app.source_code !== "object") return null;
    return app.source_code as unknown as AppArchitecture;
  };

  return (
    <DashboardLayout>
      <div className="px-8 py-8 max-w-5xl">
        <div className="mb-8 opacity-0 animate-fade-in">
          <h1 className="text-3xl font-bold tracking-tight">
            Générateur d'<span className="text-gradient-accent">Applications</span>
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Créez des architectures d'applications complètes avec l'IA
          </p>
        </div>

        {/* Generator */}
        <form onSubmit={handleCreate} className="rounded-lg border border-border bg-card p-6 mb-8 opacity-0 animate-fade-in" style={{ animationDelay: "100ms" }}>
          <div className="flex items-center gap-2 mb-4">
            <Sparkles className="h-4 w-4 text-accent" />
            <h2 className="text-sm font-semibold">Nouvelle Application</h2>
          </div>
          <div className="space-y-4">
            <div>
              <label className="text-xs text-muted-foreground mb-1 block">Nom du projet</label>
              <Input
                placeholder="Ex: Marketplace de services, Gestion de boutique, Réseau social..."
                value={appName}
                onChange={(e) => setAppName(e.target.value)}
                className="bg-secondary border-border"
                required
                disabled={creating}
              />
            </div>
            <div>
              <label className="text-xs text-muted-foreground mb-1 block">Description & Fonctionnalités</label>
              <Textarea
                placeholder="Décrivez l'application souhaitée, les fonctionnalités principales, le type d'utilisateurs..."
                value={appDesc}
                onChange={(e) => setAppDesc(e.target.value)}
                className="bg-secondary border-border min-h-[100px]"
                disabled={creating}
              />
            </div>
            <Button type="submit" className="glow-accent bg-accent text-accent-foreground hover:bg-accent/90" disabled={creating}>
              {creating ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Génération IA en cours...
                </>
              ) : (
                <>
                  <Sparkles className="h-4 w-4 mr-2" />
                  Générer l'Application
                </>
              )}
            </Button>
          </div>
        </form>

        {/* Existing Apps */}
        <h2 className="text-sm font-semibold text-foreground mb-4 opacity-0 animate-fade-in" style={{ animationDelay: "200ms" }}>
          Applications Récentes
        </h2>
        {loading ? (
          <p className="text-xs text-muted-foreground">Chargement...</p>
        ) : apps.length === 0 ? (
          <p className="text-xs text-muted-foreground">Aucune application créée.</p>
        ) : (
          <div className="space-y-3">
            {apps.map((app, i) => {
              const arch = getArchitecture(app);
              const hasContent = arch && (arch.frontend?.components?.length || arch.backend?.endpoints?.length || arch.database?.tables?.length);
              return (
                <div
                  key={app.id}
                  className="rounded-lg border border-border bg-card opacity-0 animate-fade-in hover:border-accent/30 transition-colors"
                  style={{ animationDelay: `${250 + i * 50}ms` }}
                >
                  <div className="p-4 flex items-center justify-between">
                    <div className="flex items-center gap-4 flex-1 cursor-pointer" onClick={() => setExpandedId(expandedId === app.id ? null : app.id)}>
                      <div className="flex h-10 w-10 items-center justify-center rounded-md bg-secondary">
                        <AppWindow className="h-5 w-5 text-accent" />
                      </div>
                      <div>
                        <h3 className="text-sm font-medium text-foreground">{app.title}</h3>
                        <div className="flex items-center gap-4 mt-1">
                          <span className="text-[10px] text-muted-foreground flex items-center gap-1">
                            <Globe className="h-3 w-3" /> {app.app_type}
                          </span>
                          <span className="text-[10px] text-muted-foreground flex items-center gap-1">
                            <Code2 className="h-3 w-3" /> {app.tech_stack || "—"}
                          </span>
                          <span className="text-[10px] text-muted-foreground flex items-center gap-1">
                            <Database className="h-3 w-3" /> IA générée
                          </span>
                        </div>
                      </div>
                    </div>
                    <div className="flex items-center gap-2">
                      <span className={`text-xs font-mono px-2 py-1 rounded ${getStatusColor(app.status)}`}>
                        {app.status}
                      </span>
                      {hasContent && (
                        <button onClick={() => setExpandedId(expandedId === app.id ? null : app.id)} className="text-muted-foreground hover:text-foreground transition-colors p-1">
                          {expandedId === app.id ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
                        </button>
                      )}
                      <button onClick={() => handleDelete(app.id, app.title)} className="text-muted-foreground hover:text-destructive transition-colors p-1">
                        <Trash2 className="h-4 w-4" />
                      </button>
                    </div>
                  </div>

                  {/* Expanded architecture */}
                  {expandedId === app.id && arch && hasContent && (
                    <div className="border-t border-border px-4 pb-4 pt-3 space-y-4">
                      {app.description && <p className="text-xs text-muted-foreground">{app.description}</p>}

                      {/* Database schema */}
                      {arch.database?.tables && arch.database.tables.length > 0 && (
                        <div>
                          <h4 className="text-xs font-semibold text-primary mb-2">📦 Base de données</h4>
                          <div className="space-y-2">
                            {arch.database.tables.map((t, ti) => (
                              <div key={ti} className="rounded-md bg-secondary/50 p-2">
                                <span className="text-[11px] font-mono font-bold text-foreground">{t.name}</span>
                                {t.description && <p className="text-[10px] text-muted-foreground">{t.description}</p>}
                                <div className="flex flex-wrap gap-1 mt-1">
                                  {t.columns.map((c, ci) => (
                                    <span key={ci} className="text-[9px] bg-background px-1.5 py-0.5 rounded font-mono">{c}</span>
                                  ))}
                                </div>
                              </div>
                            ))}
                          </div>
                        </div>
                      )}

                      {/* Backend endpoints */}
                      {arch.backend?.endpoints && arch.backend.endpoints.length > 0 && (
                        <div>
                          <h4 className="text-xs font-semibold text-accent mb-2">⚡ API Backend</h4>
                          <div className="space-y-1">
                            {arch.backend.endpoints.map((ep, ei) => (
                              <div key={ei} className="flex items-center gap-2 text-[10px]">
                                <span className="font-mono font-bold text-accent bg-accent/10 px-1.5 py-0.5 rounded">{ep.method}</span>
                                <span className="font-mono text-foreground">{ep.path}</span>
                                <span className="text-muted-foreground">— {ep.description}</span>
                              </div>
                            ))}
                          </div>
                        </div>
                      )}

                      {/* Frontend components */}
                      {arch.frontend?.components && arch.frontend.components.length > 0 && (
                        <div>
                          <h4 className="text-xs font-semibold text-primary mb-2">🖥️ Composants Frontend</h4>
                          <div className="space-y-2">
                            {arch.frontend.components.map((comp, ci) => (
                              <div key={ci} className="rounded-md bg-secondary/50 p-2">
                                <span className="text-[11px] font-semibold text-foreground">{comp.name}</span>
                                <p className="text-[10px] text-muted-foreground">{comp.description}</p>
                                {comp.code && (
                                  <pre className="text-[9px] bg-background p-2 rounded mt-1 overflow-x-auto max-h-40">{comp.code}</pre>
                                )}
                              </div>
                            ))}
                          </div>
                        </div>
                      )}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>
    </DashboardLayout>
  );
};

export default Applications;
