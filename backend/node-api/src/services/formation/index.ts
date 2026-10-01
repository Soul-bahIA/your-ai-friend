// Moteur de contenu de formation — orchestre le pipeline pédagogique complet.
//
// analyse de la demande → recherche KB-first (documente + enrichit la base de
// connaissances) → programme → détail de chaque module. Le tout s'appuie sur les
// trois fondations : orchestrateur multi-IA, base de connaissances, recherche KB-first.
import { analyzeFormation, buildProgram, buildModule } from "../../clients/iaClient.js";
import type { FormationAnalysis } from "../../clients/iaClient.js";
import { researchService } from "../research/index.js";

export interface FormationCurriculum {
  title: string;
  description: string;
  level: string;
  duration: string;
  audience: string;
  objectives: string[];
  modules: Record<string, unknown>[];
  glossary: { term: string; definition: string }[];
  faq: { question: string; answer: string }[];
  analysis: FormationAnalysis;
  sources: { title: string; url: string }[];
}

export interface BuildOptions {
  provider?: string;
  maxResearch?: number; // nb de requêtes de recherche à exécuter
  onProgress?: (step: string, detail?: string) => void;
}

export class FormationEngine {
  async build(
    userId: string,
    topic: string,
    details: string | null,
    opts: BuildOptions = {},
  ): Promise<FormationCurriculum> {
    const provider = opts.provider ?? null;
    const maxResearch = opts.maxResearch ?? 3;
    const progress = opts.onProgress ?? (() => {});

    // 1) Analyse de la demande
    progress("analyse", "identification du sujet, niveau, objectifs");
    const analysis = await analyzeFormation({ topic, details, provider });

    // 2) Recherche KB-first sur chaque requête (documente + met en cache la KB)
    const queries = (analysis.research_queries ?? []).slice(0, maxResearch);
    const researchNotes: { title: string; summary: string; content: string; sources: unknown[] }[] = [];
    const allSources: { title: string; url: string }[] = [];
    for (const q of queries) {
      progress("recherche", q);
      try {
        const r = await researchService.research(userId, q, {
          domain: undefined,
          provider: opts.provider,
        });
        researchNotes.push({
          title: r.entry.title,
          summary: r.entry.summary ?? "",
          content: r.entry.content.slice(0, 2000),
          sources: r.entry.sources ?? [],
        });
        for (const s of r.entry.sources ?? []) allSources.push({ title: s.title ?? "", url: s.url ?? "" });
      } catch {
        // La recherche ne doit pas bloquer la formation ; on continue avec ce qu'on a.
      }
    }

    // 3) Programme (squelette + glossaire + FAQ)
    progress("programme", "construction du plan et de la progression");
    const program = await buildProgram({ analysis, research_notes: researchNotes, provider });
    const programTitle = String(program.title ?? analysis.subject);
    const modules = Array.isArray(program.modules) ? (program.modules as Record<string, unknown>[]) : [];

    // 4) Détail de chaque module (chapitres, exercices, quiz, cas, projet, plan de démo)
    const detailedModules: Record<string, unknown>[] = [];
    for (let i = 0; i < modules.length; i++) {
      progress("module", `détail ${i + 1}/${modules.length} : ${modules[i].title ?? ""}`);
      // Une nouvelle tentative avant de se rabattre sur le squelette : les erreurs de
      // détail de module sont le plus souvent transitoires (réseau/troncature).
      let detail: Record<string, unknown> | null = null;
      for (let attempt = 0; attempt < 2 && !detail; attempt++) {
        try {
          detail = await buildModule({
            program_title: programTitle,
            module: modules[i],
            research_notes: researchNotes,
            provider,
          });
        } catch {
          if (attempt === 1) progress("module", `échec détail ${i + 1} — squelette conservé`);
        }
      }
      detailedModules.push(detail ? { ...modules[i], ...detail } : modules[i]);
    }

    return {
      title: programTitle,
      description: String(program.description ?? ""),
      level: String(program.level ?? analysis.level),
      duration: String(program.duration ?? ""),
      audience: String(program.audience ?? analysis.audience),
      objectives: (program.objectives as string[]) ?? analysis.objectives ?? [],
      modules: detailedModules,
      glossary: (program.glossary as FormationCurriculum["glossary"]) ?? [],
      faq: (program.faq as FormationCurriculum["faq"]) ?? [],
      analysis,
      sources: allSources,
    };
  }
}

/**
 * Vue "leçons" à plat, pour compat avec la vidéo/PDF/UI existants qui attendent
 * lessons[{title, objectives, content, examples, exercises}].
 */
export function curriculumToLessons(cur: FormationCurriculum): Record<string, unknown>[] {
  const lessons: Record<string, unknown>[] = [];
  for (const m of cur.modules) {
    const chapters = Array.isArray(m.chapters) ? (m.chapters as Record<string, unknown>[]) : [];
    const content = chapters.map((c) => `${c.title}\n${c.content}`).join("\n\n") || String(m.summary ?? "");
    const examples = chapters.flatMap((c) => (Array.isArray(c.examples) ? (c.examples as string[]) : []));
    const exercises = Array.isArray(m.exercises)
      ? (m.exercises as { question: string }[]).map((e) => e.question)
      : [];
    lessons.push({
      title: String(m.title ?? ""),
      objectives: (m.objectives as string[]) ?? [],
      content,
      examples,
      exercises,
    });
  }
  return lessons;
}

export const formationEngine = new FormationEngine();
