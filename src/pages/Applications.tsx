import { useState, useEffect } from "react";
import DashboardLayout from "@/components/DashboardLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { AppWindow, Sparkles, Globe, Database, Code2, Trash2 } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { useToast } from "@/hooks/use-toast";

interface Application {
  id: string;
  title: string;
  description: string | null;
  app_type: string | null;
  tech_stack: string | null;
  status: string;
  created_at: string;
}

const Applications = () => {
  const { user } = useAuth();
  const { toast } = useToast();
  const [appName, setAppName] = useState("");
  const [appDesc, setAppDesc] = useState("");
  const [apps, setApps] = useState<Application[]>([]);
  const [loading, setLoading] = useState(true);
  const [creating, setCreating] = useState(false);

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
    if (!appName.trim() || !user) return;
    setCreating(true);

    const { data, error } = await supabase
      .from("applications")
      .insert({
        user_id: user.id,
        title: appName,
        description: appDesc,
        app_type: "Web App",
        tech_stack: "React + TypeScript",
        status: "En test",
      })
      .select()
      .single();

    if (error) {
      toast({ title: "Erreur", description: error.message, variant: "destructive" });
    } else if (data) {
      setApps((prev) => [data, ...prev]);
      setAppName("");
      setAppDesc("");
      await supabase.from("system_logs").insert({
        user_id: user.id,
        module: "Applications",
        event: `Application « ${data.title} » créée`,
        level: "success",
      });
      toast({ title: "Application créée !", description: `« ${data.title} » a été ajoutée.` });
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
        <form onSubmit={handleCreate} className="rounded-lg border border-border bg-card p-6 mb-8 opacity-0 animate-fade-in" style={{ animationDelay: "100ms" }}>
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
                required
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
            <Button type="submit" className="glow-accent bg-accent text-accent-foreground hover:bg-accent/90" disabled={creating}>
              <Sparkles className="h-4 w-4 mr-2" />
              {creating ? "Création..." : "Générer l'Application"}
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
            {apps.map((app, i) => (
              <div
                key={app.id}
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
                        <Globe className="h-3 w-3" /> {app.app_type}
                      </span>
                      <span className="text-[10px] text-muted-foreground flex items-center gap-1">
                        <Code2 className="h-3 w-3" /> {app.tech_stack || "—"}
                      </span>
                      <span className="text-[10px] text-muted-foreground flex items-center gap-1">
                        <Database className="h-3 w-3" /> Base de données
                      </span>
                    </div>
                  </div>
                </div>
                <div className="flex items-center gap-2">
                  <span className={`text-xs font-mono px-2 py-1 rounded ${app.status === "Déployé" ? "bg-success/10 text-success" : "bg-warning/10 text-warning"}`}>
                    {app.status}
                  </span>
                  <button onClick={() => handleDelete(app.id, app.title)} className="text-muted-foreground hover:text-destructive transition-colors p-1">
                    <Trash2 className="h-4 w-4" />
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </DashboardLayout>
  );
};

export default Applications;
