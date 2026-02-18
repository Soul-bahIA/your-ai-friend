import { useState, useEffect } from "react";
import DashboardLayout from "@/components/DashboardLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { GraduationCap, Sparkles, Clock, BookOpen, Video, Trash2 } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { useToast } from "@/hooks/use-toast";

interface Formation {
  id: string;
  title: string;
  description: string | null;
  lessons_count: number | null;
  duration: string | null;
  status: string;
  created_at: string;
}

const Formations = () => {
  const { user } = useAuth();
  const { toast } = useToast();
  const [topic, setTopic] = useState("");
  const [details, setDetails] = useState("");
  const [formations, setFormations] = useState<Formation[]>([]);
  const [loading, setLoading] = useState(true);
  const [creating, setCreating] = useState(false);

  useEffect(() => {
    if (!user) return;
    const fetchFormations = async () => {
      const { data } = await supabase
        .from("formations")
        .select("*")
        .order("created_at", { ascending: false });
      if (data) setFormations(data);
      setLoading(false);
    };
    fetchFormations();
  }, [user]);

  const handleCreate = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!topic.trim() || !user) return;
    setCreating(true);
    
    const { data, error } = await supabase
      .from("formations")
      .insert({
        user_id: user.id,
        title: topic,
        description: details,
        status: "En cours",
      })
      .select()
      .single();

    if (error) {
      toast({ title: "Erreur", description: error.message, variant: "destructive" });
    } else if (data) {
      setFormations((prev) => [data, ...prev]);
      setTopic("");
      setDetails("");
      // Log the event
      await supabase.from("system_logs").insert({
        user_id: user.id,
        module: "Formations",
        event: `Formation « ${data.title} » créée`,
        level: "success",
      });
      toast({ title: "Formation créée !", description: `« ${data.title} » a été ajoutée.` });
    }
    setCreating(false);
  };

  const handleDelete = async (id: string, title: string) => {
    const { error } = await supabase.from("formations").delete().eq("id", id);
    if (!error) {
      setFormations((prev) => prev.filter((f) => f.id !== id));
      if (user) {
        await supabase.from("system_logs").insert({
          user_id: user.id,
          module: "Formations",
          event: `Formation « ${title} » supprimée`,
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
            Générateur de <span className="text-gradient-primary">Formations</span>
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Créez des formations vidéo complètes automatiquement
          </p>
        </div>

        {/* Generator */}
        <form onSubmit={handleCreate} className="rounded-lg border border-border bg-card p-6 mb-8 opacity-0 animate-fade-in" style={{ animationDelay: "100ms" }}>
          <div className="flex items-center gap-2 mb-4">
            <Sparkles className="h-4 w-4 text-primary" />
            <h2 className="text-sm font-semibold">Nouvelle Formation</h2>
          </div>
          <div className="space-y-4">
            <div>
              <label className="text-xs text-muted-foreground mb-1 block">Sujet</label>
              <Input
                placeholder="Ex: Développement d'applications React avec TypeScript..."
                value={topic}
                onChange={(e) => setTopic(e.target.value)}
                className="bg-secondary border-border"
                required
              />
            </div>
            <div>
              <label className="text-xs text-muted-foreground mb-1 block">Détails & Objectifs</label>
              <Textarea
                placeholder="Décrivez le contenu souhaité, le niveau cible, les objectifs d'apprentissage..."
                value={details}
                onChange={(e) => setDetails(e.target.value)}
                className="bg-secondary border-border min-h-[100px]"
              />
            </div>
            <Button type="submit" className="glow-primary" disabled={creating}>
              <Sparkles className="h-4 w-4 mr-2" />
              {creating ? "Création..." : "Générer la Formation"}
            </Button>
          </div>
        </form>

        {/* Existing Courses */}
        <h2 className="text-sm font-semibold text-foreground mb-4 opacity-0 animate-fade-in" style={{ animationDelay: "200ms" }}>
          Formations Récentes
        </h2>
        {loading ? (
          <p className="text-xs text-muted-foreground">Chargement...</p>
        ) : formations.length === 0 ? (
          <p className="text-xs text-muted-foreground">Aucune formation créée.</p>
        ) : (
          <div className="space-y-3">
            {formations.map((course, i) => (
              <div
                key={course.id}
                className="rounded-lg border border-border bg-card p-4 flex items-center justify-between opacity-0 animate-fade-in hover:border-primary/30 transition-colors"
                style={{ animationDelay: `${250 + i * 50}ms` }}
              >
                <div className="flex items-center gap-4">
                  <div className="flex h-10 w-10 items-center justify-center rounded-md bg-secondary">
                    <GraduationCap className="h-5 w-5 text-primary" />
                  </div>
                  <div>
                    <h3 className="text-sm font-medium text-foreground">{course.title}</h3>
                    <div className="flex items-center gap-4 mt-1">
                      <span className="text-[10px] text-muted-foreground flex items-center gap-1">
                        <BookOpen className="h-3 w-3" /> {course.lessons_count || 0} leçons
                      </span>
                      <span className="text-[10px] text-muted-foreground flex items-center gap-1">
                        <Clock className="h-3 w-3" /> {course.duration || "—"}
                      </span>
                      <span className="text-[10px] text-muted-foreground flex items-center gap-1">
                        <Video className="h-3 w-3" /> Vidéo incluse
                      </span>
                    </div>
                  </div>
                </div>
                <div className="flex items-center gap-2">
                  <span className={`text-xs font-mono px-2 py-1 rounded ${course.status === "Terminé" ? "bg-success/10 text-success" : "bg-warning/10 text-warning"}`}>
                    {course.status}
                  </span>
                  <button onClick={() => handleDelete(course.id, course.title)} className="text-muted-foreground hover:text-destructive transition-colors p-1">
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

export default Formations;
