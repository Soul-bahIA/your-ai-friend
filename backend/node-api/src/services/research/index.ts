// Moteur de recherche KB-first de SoulBah AI.
//
// Règle : TOUJOURS interroger la base de connaissances avant une recherche externe.
// Si une connaissance pertinente, récente et fiable existe → on la privilégie.
// Sinon → recherche web (si un fournisseur est configuré) → synthèse ORIGINALE via
// l'orchestrateur → mise en cache dans la KB (avec déduplication).
import { knowledgeService } from "../knowledge";
import type { KnowledgeEntry } from "../knowledge";
import { synthesizeKnowledge } from "../../clients/iaClient";
import { getWebSearchProvider } from "./webSearch";

export interface ResearchOptions {
  domain?: string;
  forceRefresh?: boolean; // ignore la KB, force une recherche fraîche
  maxAgeDays?: number; // fraîcheur maximale acceptée depuis la KB
  minConfidence?: number; // confiance minimale pour se fier à la KB
  provider?: string; // imposer un fournisseur d'IA pour la synthèse
}

export interface ResearchResult {
  query: string;
  source: "kb" | "web+synthesis" | "model-synthesis";
  fromCache: boolean;
  webUsed: boolean;
  webProvider: string;
  entry: KnowledgeEntry; // la connaissance retenue (issue de la KB ou nouvellement synthétisée)
  related: KnowledgeEntry[];
  deduped?: boolean;
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

    // 2) Si une connaissance récente et fiable existe → on la privilégie (pas de web).
    if (!opts.forceRefresh && kbHits.length > 0 && kbHits[0].confidence >= minConfidence) {
      return {
        query,
        source: "kb",
        fromCache: true,
        webUsed: false,
        webProvider: "none",
        entry: kbHits[0],
        related: kbHits.slice(1),
      };
    }

    // 3) Recherche externe (si un fournisseur est configuré).
    const web = getWebSearchProvider();
    const webResults = web.available ? await web.search(query, 6) : [];

    // 4) Synthèse originale (compare sources + connaissances déjà acquises).
    const known = kbHits.slice(0, 3).map((e) => ({
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

    // 5) Mise en cache dans la KB (déduplication automatique).
    const { entry, deduped } = await knowledgeService.remember(userId, {
      title: synthesis.title || query,
      content: synthesis.content,
      summary: synthesis.summary,
      domain: synthesis.domain || opts.domain || "general",
      keywords: synthesis.keywords ?? [],
      sources: synthesis.sources ?? [],
      confidence: synthesis.confidence,
      category: "recherche",
    });

    return {
      query,
      source: webResults.length > 0 ? "web+synthesis" : "model-synthesis",
      fromCache: false,
      webUsed: web.available && webResults.length > 0,
      webProvider: web.id,
      entry,
      related: kbHits,
      deduped,
    };
  }
}

export const researchService = new ResearchService();
