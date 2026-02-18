import { useState, useEffect } from "react";
import DashboardLayout from "@/components/DashboardLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { GraduationCap, Sparkles, Clock, BookOpen, Play, Video, Trash2, ChevronDown, ChevronUp, Loader2, FileDown } from "lucide-react";
import FormationVideoPlayer from "@/components/FormationVideoPlayer";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { useToast } from "@/hooks/use-toast";

interface Lesson {
  title: string;
  objectives: string[];
  content: string;
  examples: string[];
  exercises: string[];
}

interface Formation {
  id: string;
  title: string;
  description: string | null;
  lessons_count: number | null;
  duration: string | null;
  status: string;
  created_at: string;
  content: unknown;
}

const Formations = () => {
  const { user, session } = useAuth();
  const { toast } = useToast();
  const [topic, setTopic] = useState("");
  const [details, setDetails] = useState("");
  const [formations, setFormations] = useState<Formation[]>([]);
  const [loading, setLoading] = useState(true);
  const [creating, setCreating] = useState(false);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [videoFormation, setVideoFormation] = useState<Formation | null>(null);

  useEffect(() => {
    if (!user) return;
    const fetchFormations = async () => {
      const { data } = await supabase
        .from("formations")
        .select("*")
        .order("created_at", { ascending: false });
      if (data) setFormations(data as unknown as Formation[]);
      setLoading(false);
    };
    fetchFormations();
  }, [user]);

  const handleCreate = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!topic.trim() || !user || !session) return;
    setCreating(true);

    // Step 1: Create placeholder in DB
    const { data, error } = await supabase
      .from("formations")
      .insert({
        user_id: user.id,
        title: topic,
        description: details || "Génération en cours...",
        status: "Génération...",
      })
      .select()
      .single();

    if (error || !data) {
      toast({ title: "Erreur", description: error?.message || "Erreur de création", variant: "destructive" });
      setCreating(false);
      return;
    }

    setFormations((prev) => [data as Formation, ...prev]);
    const formationId = data.id;

    // Step 2: Call AI generation edge function
    try {
      const response = await fetch(
        `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/generate-formation`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${session.access_token}`,
            apikey: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
          },
          body: JSON.stringify({ topic, details, formationId }),
        }
      );

      const result = await response.json();

      if (!response.ok) {
        throw new Error(result.error || "Échec de la génération");
      }

      // Update local state with generated content
      setFormations((prev) =>
        prev.map((f) =>
          f.id === formationId
            ? {
                ...f,
                title: result.formation.title || topic,
                description: result.formation.description,
                duration: result.formation.duration,
                lessons_count: result.formation.lessons?.length || 0,
                content: result.formation.lessons || [],
                status: "Terminé",
              }
            : f
        )
      );

      setTopic("");
      setDetails("");
      toast({
        title: "Formation générée !",
        description: `« ${result.formation.title} » — ${result.formation.lessons?.length} leçons créées par IA.`,
      });
    } catch (err: any) {
      toast({ title: "Erreur IA", description: err.message, variant: "destructive" });
      // Update status to error
      setFormations((prev) =>
        prev.map((f) => (f.id === formationId ? { ...f, status: "Erreur" } : f))
      );
      await supabase.from("formations").update({ status: "Erreur" }).eq("id", formationId);
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

  const handleExportPdf = (course: Formation) => {
    const lessons = (course.content as Lesson[]) || [];
    const lines: string[] = [];
    lines.push(course.title);
    lines.push("=".repeat(course.title.length));
    if (course.description) lines.push("", course.description);
    lines.push("", `Durée : ${course.duration || "—"} | ${lessons.length} leçons`, "");

    lessons.forEach((lesson, li) => {
      lines.push("", `--- Leçon ${li + 1} : ${lesson.title} ---`, "");
      if (lesson.objectives?.length) {
        lines.push("Objectifs :");
        lesson.objectives.forEach((o) => lines.push(`  • ${o}`));
        lines.push("");
      }
      if (lesson.content) lines.push(lesson.content, "");
      if (lesson.examples?.length) {
        lines.push("Exemples :");
        lesson.examples.forEach((ex) => lines.push(ex, ""));
      }
      if (lesson.exercises?.length) {
        lines.push("Exercices :");
        lesson.exercises.forEach((ex, ei) => lines.push(`  ${ei + 1}. ${ex}`));
        lines.push("");
      }
    });

    const blob = new Blob([lines.join("\n")], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `${course.title.replace(/[^a-zA-Z0-9]/g, "_")}.txt`;
    a.click();
    URL.revokeObjectURL(url);
    toast({ title: "Export réussi", description: `Formation « ${course.title} » exportée.` });
  };

  const getStatusColor = (status: string) => {
    if (status === "Terminé") return "bg-success/10 text-success";
    if (status === "Erreur") return "bg-destructive/10 text-destructive";
    return "bg-warning/10 text-warning";
  };

  return (
    <DashboardLayout>
      <div className="px-8 py-8 max-w-5xl">
        <div className="mb-8 opacity-0 animate-fade-in">
          <h1 className="text-3xl font-bold tracking-tight">
            Générateur de <span className="text-gradient-primary">Formations</span>
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Créez des formations complètes automatiquement avec l'IA
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
                placeholder="Ex: Python pour débutant, Marketing digital, React avancé..."
                value={topic}
                onChange={(e) => setTopic(e.target.value)}
                className="bg-secondary border-border"
                required
                disabled={creating}
              />
            </div>
            <div>
              <label className="text-xs text-muted-foreground mb-1 block">Détails & Objectifs</label>
              <Textarea
                placeholder="Décrivez le contenu souhaité, le niveau cible, les objectifs d'apprentissage..."
                value={details}
                onChange={(e) => setDetails(e.target.value)}
                className="bg-secondary border-border min-h-[100px]"
                disabled={creating}
              />
            </div>
            <Button type="submit" className="glow-primary" disabled={creating}>
              {creating ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Génération IA en cours...
                </>
              ) : (
                <>
                  <Sparkles className="h-4 w-4 mr-2" />
                  Générer la Formation
                </>
              )}
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
                className="rounded-lg border border-border bg-card opacity-0 animate-fade-in hover:border-primary/30 transition-colors"
                style={{ animationDelay: `${250 + i * 50}ms` }}
              >
                <div className="p-4 flex items-center justify-between">
                  <div className="flex items-center gap-4 flex-1 cursor-pointer" onClick={() => setExpandedId(expandedId === course.id ? null : course.id)}>
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
                          <Video className="h-3 w-3" /> IA générée
                        </span>
                      </div>
                    </div>
                  </div>
                  <div className="flex items-center gap-2">
                    <span className={`text-xs font-mono px-2 py-1 rounded ${getStatusColor(course.status)}`}>
                      {course.status}
                    </span>
                    {course.content && Array.isArray(course.content) && course.content.length > 0 && (
                      <>
                        <button
                          onClick={() => setVideoFormation(course)}
                          className="text-primary hover:text-primary/80 transition-colors p-1"
                          title="Lire en vidéo"
                        >
                          <Play className="h-4 w-4" />
                        </button>
                        <button
                          onClick={() => handleExportPdf(course)}
                          className="text-muted-foreground hover:text-foreground transition-colors p-1"
                          title="Exporter en fichier texte"
                        >
                          <FileDown className="h-4 w-4" />
                        </button>
                        <button onClick={() => setExpandedId(expandedId === course.id ? null : course.id)} className="text-muted-foreground hover:text-foreground transition-colors p-1">
                          {expandedId === course.id ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
                        </button>
                      </>
                    )}
                    <button onClick={() => handleDelete(course.id, course.title)} className="text-muted-foreground hover:text-destructive transition-colors p-1">
                      <Trash2 className="h-4 w-4" />
                    </button>
                  </div>
                </div>

                {/* Expanded lesson content */}
                {expandedId === course.id && course.content && Array.isArray(course.content) && (
                  <div className="border-t border-border px-4 pb-4 pt-3 space-y-4">
                    {course.description && (
                      <p className="text-xs text-muted-foreground">{course.description}</p>
                    )}
                    {(course.content as Lesson[]).map((lesson, li) => (
                      <div key={li} className="rounded-md bg-secondary/50 p-3 space-y-2">
                        <h4 className="text-xs font-semibold text-foreground">
                          Leçon {li + 1} : {lesson.title}
                        </h4>
                        {lesson.objectives && lesson.objectives.length > 0 && (
                          <div>
                            <span className="text-[10px] font-medium text-primary">Objectifs :</span>
                            <ul className="list-disc list-inside text-[10px] text-muted-foreground ml-2">
                              {lesson.objectives.map((obj, oi) => <li key={oi}>{obj}</li>)}
                            </ul>
                          </div>
                        )}
                        <p className="text-[11px] text-foreground/80 whitespace-pre-wrap">{lesson.content}</p>
                        {lesson.examples && lesson.examples.length > 0 && (
                          <div>
                            <span className="text-[10px] font-medium text-primary">Exemples :</span>
                            {lesson.examples.map((ex, ei) => (
                              <pre key={ei} className="text-[10px] bg-background p-2 rounded mt-1 overflow-x-auto">{ex}</pre>
                            ))}
                          </div>
                        )}
                        {lesson.exercises && lesson.exercises.length > 0 && (
                          <div>
                            <span className="text-[10px] font-medium text-accent">Exercices :</span>
                            <ul className="list-decimal list-inside text-[10px] text-muted-foreground ml-2">
                              {lesson.exercises.map((ex, ei) => <li key={ei}>{ex}</li>)}
                            </ul>
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                )}
              </div>
            ))}
          </div>
        )}

        {/* Video Player */}
        {videoFormation && (
          <FormationVideoPlayer
            open={!!videoFormation}
            onOpenChange={(open) => { if (!open) setVideoFormation(null); }}
            title={videoFormation.title}
            lessons={(videoFormation.content as Lesson[]) || []}
          />
        )}
      </div>
    </DashboardLayout>
  );
};

export default Formations;
