// Moteur de recherche KB-first de SoulBah AI.
//
// Règle : TOUJOURS interroger la base de connaissances avant une recherche externe.
// Si une connaissance pertinente, récente, fiable ET non issue d'une simple synthèse de
// modèle existe → on la privilégie. Sinon → recherche web (si un fournisseur est
// configuré) → synthèse via python-ia → mise en cache dans la KB comme *finding*
// (category 'recherche'), jamais comme connaissance vérifiée.
//
// Sans clé web (T13) : la synthèse est une pure production du modèle. Elle est stockée
// avec source 'llm_synthesis', une confiance plafonnée (LLM_ONLY_MAX_CONFIDENCE), des URL
// marquées non vérifiées, et n'est JAMAIS resservie comme « kb ».
import { knowledgeService } from "../knowledge/index.js";
import type { KnowledgeEntry, Source } from "../knowledge/index.js";
import { synthesizeKnowledge } from "../../clients/iaClient.js";
import { getWebSearchProvider } from "./webSearch.js";

export const LLM_ONLY_SOURCE = "llm_synthesis";
export const WEB_SYNTHESIS_SOURCE = "web_synthesis";
/** Confiance maximale d'une synthèse sans aucune source récupérée. */
export const LLM_ONLY_MAX_CONFIDENCE = 0.3;
/** Confiance maximale d'une synthèse appuyée sur des résultats web (toujours un finding). */
export const WEB_SYNTHESIS_MAX_CONFIDENCE = 0.8;

export interface ResearchOptions {
  domain?: string;
  forceRefresh?: boolean; // ignore la KB, force une recherche fraîche
  maxAgeDays?: number; // fraîcheur maximale acceptée depuis la KB
  minConfidence?: number; // confiance minimale pour se fier à la KB
  provider?: string; // imposer un fournisseur d'IA pour la synthèse (allowlist côté route)
}

export interface ResearchResult {
  query: string;
  source: "kb" | "web+synthesis" | "model-synthesis";
  fromCache: boolean;
  webUsed: boolean;
  webProvider: string;
  /** false : synthèse du modèle seule (aucune source récupérée) — à vérifier. */
  verified: boolean;
  entry: KnowledgeEntry; // la connaissance retenue (issue de la KB ou nouvellement synthétisée)
  related: KnowledgeEntry[];
  deduped?: boolean;
}

/** Une entrée peut-elle être resservie comme connaissance (« kb ») ? Jamais une synthèse LLM seule. */
export function isServableKnowledge(e: Pick<KnowledgeEntry, "source">): boolean {
  return e.source !== LLM_ONLY_SOURCE;
}

const normUrl = (u: string) => u.trim().replace(/\/+$/, "").toLowerCase();

/**
 * Sources citées par la synthèse : `verified=true` seulement si l'URL fait partie des
 * résultats web effectivement récupérés ; toute autre URL (inventée ?) est non vérifiée.
 */
export function markSourcesVerified(
  cited: { title?: string; url?: string }[] | undefined,
  fetched: { url: string }[],
): Source[] {
  const known = new Set(fetched.map((r) => normUrl(r.url)));
  return (cited ?? []).slice(0, 50).map((s) => ({
    title: typeof s.title === "string" ? s.title : "",
    url: typeof s.url === "string" ? s.url : "",
    verified: typeof s.url === "string" && s.url !== "" && known.has(normUrl(s.url)),
  }));
}

/** Confiance stockée : auto-déclarée par le modèle, donc plafonnée selon la provenance. */
export function cappedConfidence(raw: unknown, webBacked: boolean): number {
  const c = typeof raw === "number" && Number.isFinite(raw) ? Math.min(1, Math.max(0, raw)) : 0.2;
  return Math.min(c, webBacked ? WEB_SYNTHESIS_MAX_CONFIDENCE : LLM_ONLY_MAX_CONFIDENCE);
}

export class ResearchService {
  async research(userId: string, query: string, opts: ResearchOptions = {}): Promise<ResearchResult> {
    const maxAgeDays = opts.maxAgeDays ?? 90;
    const minConfidence = opts.minConfidence ?? 0.6;

    // 1) KB-first : recherche dans la base de connaissances (bornée en fraîcheur).
    const kbHits = await knowledgeService.search(userId, {
      text: query,
      domain: opts.domain,
      maxAgeDays,
      limit: 5,
    });

    // 2) Connaissance récente, fiable et NON issue d'une synthèse LLM seule → on la sert.
    const servable = kbHits.filter(isServableKnowledge);
    if (!opts.forceRefresh && servable.length > 0 && servable[0].confidence >= minConfidence) {
      return {
        query,
        source: "kb",
        fromCache: true,
        webUsed: false,
        webProvider: "none",
        verified: true,
        entry: servable[0],
        related: kbHits.filter((e) => e.id !== servable[0].id),
      };
    }

    // 3) Recherche externe (si un fournisseur est configuré).
    const web = getWebSearchProvider();
    const webResults = web.available ? await web.search(query, 6) : [];
    const webBacked = webResults.length > 0;

    // 4) Synthèse (compare sources + connaissances déjà acquises ; findings LLM exclus).
    const known = servable.slice(0, 3).map((e) => ({
      title: e.title,
      summary: e.summary ?? e.content.slice(0, 300),
    }));
    const synthesis = await synthesizeKnowledge({
      query,
      sources: webResults,
      known,
      domain: opts.domain ?? null,
      provider: opts.provider ?? null,
    });

    // 5) Mise en cache dans la KB comme FINDING (déduplication automatique).
    const { entry, deduped } = await knowledgeService.remember(userId, {
      title: synthesis.title || query,
      content: synthesis.content,
      summary: synthesis.summary,
      domain: synthesis.domain || opts.domain || "general",
      keywords: synthesis.keywords ?? [],
      sources: markSourcesVerified(synthesis.sources, webResults),
      confidence: cappedConfidence(synthesis.confidence, webBacked),
      category: "recherche",
      source: webBacked ? WEB_SYNTHESIS_SOURCE : LLM_ONLY_SOURCE,
    });

    return {
      query,
      source: webBacked ? "web+synthesis" : "model-synthesis",
      fromCache: false,
      webUsed: web.available && webBacked,
      webProvider: web.id,
      verified: webBacked,
      entry,
      related: kbHits,
      deduped,
    };
  }
}

export const researchService = new ResearchService();
