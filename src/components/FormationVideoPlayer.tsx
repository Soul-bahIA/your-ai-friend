import { useState, useEffect, useRef, useCallback } from "react";
import { Dialog, DialogContent } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Progress } from "@/components/ui/progress";
import {
  Play, Pause, SkipForward, SkipBack, X, Volume2, VolumeX,
  Maximize2, BookOpen, Target, Code, Dumbbell
} from "lucide-react";

interface Lesson {
  title: string;
  objectives: string[];
  content: string;
  examples: string[];
  exercises: string[];
}

interface FormationVideoPlayerProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  lessons: Lesson[];
}

type SlideType = "title" | "objectives" | "content" | "example" | "exercise" | "end";

interface Slide {
  type: SlideType;
  lessonIndex: number;
  title: string;
  body: string;
  items?: string[];
  lessonTitle: string;
}

const SLIDE_DURATION = 8000; // 8s per slide

const buildSlides = (title: string, lessons: Lesson[]): Slide[] => {
  const slides: Slide[] = [];

  // Intro slide
  slides.push({
    type: "title",
    lessonIndex: -1,
    title,
    body: `${lessons.length} leçons`,
    lessonTitle: "Introduction",
  });

  lessons.forEach((lesson, li) => {
    // Lesson title
    slides.push({
      type: "title",
      lessonIndex: li,
      title: `Leçon ${li + 1}`,
      body: lesson.title,
      lessonTitle: lesson.title,
    });

    // Objectives
    if (lesson.objectives?.length) {
      slides.push({
        type: "objectives",
        lessonIndex: li,
        title: "Objectifs",
        body: "",
        items: lesson.objectives,
        lessonTitle: lesson.title,
      });
    }

    // Content - split into chunks of ~300 chars
    if (lesson.content) {
      const chunks = splitText(lesson.content, 400);
      chunks.forEach((chunk, ci) => {
        slides.push({
          type: "content",
          lessonIndex: li,
          title: chunks.length > 1 ? `Contenu (${ci + 1}/${chunks.length})` : "Contenu",
          body: chunk,
          lessonTitle: lesson.title,
        });
      });
    }

    // Examples
    lesson.examples?.forEach((ex, ei) => {
      slides.push({
        type: "example",
        lessonIndex: li,
        title: `Exemple ${ei + 1}`,
        body: ex,
        lessonTitle: lesson.title,
      });
    });

    // Exercises
    if (lesson.exercises?.length) {
      slides.push({
        type: "exercise",
        lessonIndex: li,
        title: "Exercices",
        body: "",
        items: lesson.exercises,
        lessonTitle: lesson.title,
      });
    }
  });

  // End slide
  slides.push({
    type: "end",
    lessonIndex: -1,
    title: "Formation terminée !",
    body: "Félicitations, vous avez terminé toutes les leçons.",
    lessonTitle: "Fin",
  });

  return slides;
};

const splitText = (text: string, maxLen: number): string[] => {
  if (text.length <= maxLen) return [text];
  const chunks: string[] = [];
  let remaining = text;
  while (remaining.length > 0) {
    if (remaining.length <= maxLen) {
      chunks.push(remaining);
      break;
    }
    let cut = remaining.lastIndexOf(". ", maxLen);
    if (cut === -1 || cut < maxLen * 0.3) cut = remaining.lastIndexOf(" ", maxLen);
    if (cut === -1) cut = maxLen;
    else cut += 1;
    chunks.push(remaining.slice(0, cut).trim());
    remaining = remaining.slice(cut).trim();
  }
  return chunks;
};

const slideIcon = (type: SlideType) => {
  switch (type) {
    case "objectives": return <Target className="h-5 w-5" />;
    case "content": return <BookOpen className="h-5 w-5" />;
    case "example": return <Code className="h-5 w-5" />;
    case "exercise": return <Dumbbell className="h-5 w-5" />;
    default: return null;
  }
};

const slideColor = (type: SlideType) => {
  switch (type) {
    case "title": return "from-primary/20 to-primary/5";
    case "objectives": return "from-accent/20 to-accent/5";
    case "content": return "from-secondary to-secondary/50";
    case "example": return "from-primary/10 to-secondary";
    case "exercise": return "from-accent/10 to-secondary";
    case "end": return "from-primary/30 to-accent/10";
    default: return "from-secondary to-secondary/50";
  }
};

const FormationVideoPlayer = ({ open, onOpenChange, title, lessons }: FormationVideoPlayerProps) => {
  const slides = useRef(buildSlides(title, lessons));
  const [currentSlide, setCurrentSlide] = useState(0);
  const [playing, setPlaying] = useState(true);
  const [progress, setProgress] = useState(0);
  const [animKey, setAnimKey] = useState(0);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const startTimeRef = useRef(Date.now());

  const totalSlides = slides.current.length;
  const slide = slides.current[currentSlide];

  const goTo = useCallback((idx: number) => {
    const clamped = Math.max(0, Math.min(totalSlides - 1, idx));
    setCurrentSlide(clamped);
    setProgress(0);
    startTimeRef.current = Date.now();
    setAnimKey((k) => k + 1);
  }, [totalSlides]);

  // Auto-play timer
  useEffect(() => {
    if (!open) return;
    if (timerRef.current) clearInterval(timerRef.current);

    if (playing && currentSlide < totalSlides - 1) {
      startTimeRef.current = Date.now();
      timerRef.current = setInterval(() => {
        const elapsed = Date.now() - startTimeRef.current;
        const pct = Math.min(100, (elapsed / SLIDE_DURATION) * 100);
        setProgress(pct);
        if (elapsed >= SLIDE_DURATION) {
          goTo(currentSlide + 1);
        }
      }, 50);
    }

    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, [playing, currentSlide, open, totalSlides, goTo]);

  // Reset on open
  useEffect(() => {
    if (open) {
      slides.current = buildSlides(title, lessons);
      setCurrentSlide(0);
      setPlaying(true);
      setProgress(0);
      setAnimKey(0);
    }
  }, [open, title, lessons]);

  const globalProgress = ((currentSlide + progress / 100) / totalSlides) * 100;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-4xl w-full p-0 overflow-hidden bg-background border-border gap-0 [&>button]:hidden">
        {/* Top bar */}
        <div className="flex items-center justify-between px-4 py-2 bg-card border-b border-border">
          <div className="flex items-center gap-2 min-w-0">
            <div className="h-2 w-2 rounded-full bg-destructive animate-pulse" />
            <span className="text-xs font-medium text-foreground truncate">{title}</span>
          </div>
          <div className="flex items-center gap-2">
            <span className="text-[10px] text-muted-foreground font-mono">
              {currentSlide + 1}/{totalSlides}
            </span>
            <button onClick={() => onOpenChange(false)} className="text-muted-foreground hover:text-foreground p-1">
              <X className="h-4 w-4" />
            </button>
          </div>
        </div>

        {/* Video area */}
        <div className="relative aspect-video bg-background overflow-hidden">
          {/* Animated gradient bg */}
          <div className={`absolute inset-0 bg-gradient-to-br ${slideColor(slide.type)} transition-all duration-700`} />

          {/* Slide content */}
          <div
            key={animKey}
            className="absolute inset-0 flex flex-col items-center justify-center p-8 md:p-16 animate-fade-in"
          >
            {/* Lesson badge */}
            {slide.lessonIndex >= 0 && (
              <div className="absolute top-4 left-4 flex items-center gap-1.5 bg-card/80 backdrop-blur-sm rounded-full px-3 py-1 border border-border">
                <BookOpen className="h-3 w-3 text-primary" />
                <span className="text-[10px] font-medium text-foreground">
                  Leçon {slide.lessonIndex + 1} — {slide.lessonTitle}
                </span>
              </div>
            )}

            {/* Type icon */}
            {slideIcon(slide.type) && (
              <div className="flex items-center gap-2 mb-4 text-primary">
                {slideIcon(slide.type)}
                <span className="text-xs font-semibold uppercase tracking-wider">{slide.title}</span>
              </div>
            )}

            {/* Title slides */}
            {slide.type === "title" && (
              <div className="text-center space-y-4">
                <h2 className="text-2xl md:text-4xl font-bold text-foreground leading-tight">
                  {slide.title === title ? slide.title : slide.body}
                </h2>
                {slide.title === title && (
                  <p className="text-lg text-muted-foreground">{slide.body}</p>
                )}
                {slide.lessonIndex === -1 && slide.title === title && (
                  <div className="flex items-center justify-center gap-2 mt-6">
                    <div className="h-8 w-8 rounded-full bg-primary/20 flex items-center justify-center">
                      <Play className="h-4 w-4 text-primary ml-0.5" />
                    </div>
                    <span className="text-xs text-muted-foreground">La lecture commence automatiquement...</span>
                  </div>
                )}
              </div>
            )}

            {/* End slide */}
            {slide.type === "end" && (
              <div className="text-center space-y-4">
                <div className="text-5xl mb-4">🎓</div>
                <h2 className="text-2xl md:text-3xl font-bold text-foreground">{slide.title}</h2>
                <p className="text-muted-foreground">{slide.body}</p>
              </div>
            )}

            {/* Content slide */}
            {slide.type === "content" && (
              <div className="max-w-2xl w-full space-y-3">
                <p className="text-sm md:text-base text-foreground/90 leading-relaxed whitespace-pre-wrap">
                  {slide.body}
                </p>
              </div>
            )}

            {/* Example slide */}
            {slide.type === "example" && (
              <div className="max-w-2xl w-full">
                <pre className="text-xs md:text-sm bg-card/80 backdrop-blur-sm p-4 rounded-lg border border-border text-foreground/90 overflow-x-auto whitespace-pre-wrap font-mono">
                  {slide.body}
                </pre>
              </div>
            )}

            {/* List slides (objectives, exercises) */}
            {(slide.type === "objectives" || slide.type === "exercise") && slide.items && (
              <div className="max-w-2xl w-full space-y-2">
                {slide.items.map((item, i) => (
                  <div
                    key={i}
                    className="flex items-start gap-3 bg-card/60 backdrop-blur-sm rounded-lg p-3 border border-border animate-fade-in"
                    style={{ animationDelay: `${i * 150}ms` }}
                  >
                    <span className="flex-shrink-0 h-6 w-6 rounded-full bg-primary/20 flex items-center justify-center text-xs font-bold text-primary">
                      {i + 1}
                    </span>
                    <span className="text-sm text-foreground/90">{item}</span>
                  </div>
                ))}
              </div>
            )}
          </div>

          {/* Slide progress bar */}
          <div className="absolute bottom-0 left-0 right-0 h-1 bg-muted">
            <div
              className="h-full bg-primary transition-all duration-100"
              style={{ width: `${progress}%` }}
            />
          </div>
        </div>

        {/* Controls */}
        <div className="flex items-center justify-between px-4 py-3 bg-card border-t border-border">
          <div className="flex items-center gap-1">
            <Button
              variant="ghost"
              size="icon"
              className="h-8 w-8"
              onClick={() => goTo(currentSlide - 1)}
              disabled={currentSlide === 0}
            >
              <SkipBack className="h-4 w-4" />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              className="h-8 w-8"
              onClick={() => setPlaying(!playing)}
            >
              {playing ? <Pause className="h-4 w-4" /> : <Play className="h-4 w-4" />}
            </Button>
            <Button
              variant="ghost"
              size="icon"
              className="h-8 w-8"
              onClick={() => goTo(currentSlide + 1)}
              disabled={currentSlide >= totalSlides - 1}
            >
              <SkipForward className="h-4 w-4" />
            </Button>
          </div>

          {/* Global progress */}
          <div className="flex-1 mx-4">
            <Progress value={globalProgress} className="h-1.5" />
          </div>

          <span className="text-[10px] text-muted-foreground font-mono min-w-[60px] text-right">
            {Math.round(globalProgress)}%
          </span>
        </div>
      </DialogContent>
    </Dialog>
  );
};

export default FormationVideoPlayer;
