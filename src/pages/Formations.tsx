import { useState } from "react";
import DashboardLayout from "@/components/DashboardLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { GraduationCap, Sparkles, Clock, BookOpen, Video } from "lucide-react";

const sampleCourses = [
  { title: "React Avancé : Patterns & Performance", lessons: 24, duration: "8h 30m", status: "Terminé" },
  { title: "Python pour l'IA et le Machine Learning", lessons: 36, duration: "14h", status: "En cours" },
  { title: "Architecture Microservices avec Go", lessons: 18, duration: "6h 15m", status: "En cours" },
];

const Formations = () => {
  const [topic, setTopic] = useState("");
  const [details, setDetails] = useState("");

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
        <div className="rounded-lg border border-border bg-card p-6 mb-8 opacity-0 animate-fade-in" style={{ animationDelay: "100ms" }}>
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
            <Button className="glow-primary">
              <Sparkles className="h-4 w-4 mr-2" />
              Générer la Formation
            </Button>
          </div>
        </div>

        {/* Existing Courses */}
        <h2 className="text-sm font-semibold text-foreground mb-4 opacity-0 animate-fade-in" style={{ animationDelay: "200ms" }}>
          Formations Récentes
        </h2>
        <div className="space-y-3">
          {sampleCourses.map((course, i) => (
            <div
              key={course.title}
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
                      <BookOpen className="h-3 w-3" /> {course.lessons} leçons
                    </span>
                    <span className="text-[10px] text-muted-foreground flex items-center gap-1">
                      <Clock className="h-3 w-3" /> {course.duration}
                    </span>
                    <span className="text-[10px] text-muted-foreground flex items-center gap-1">
                      <Video className="h-3 w-3" /> Vidéo incluse
                    </span>
                  </div>
                </div>
              </div>
              <span className={`text-xs font-mono px-2 py-1 rounded ${course.status === "Terminé" ? "bg-success/10 text-success" : "bg-warning/10 text-warning"}`}>
                {course.status}
              </span>
            </div>
          ))}
        </div>
      </div>
    </DashboardLayout>
  );
};

export default Formations;
