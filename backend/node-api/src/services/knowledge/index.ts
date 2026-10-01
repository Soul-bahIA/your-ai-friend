// Service métier de la base de connaissances — indépendant du fournisseur de stockage.
//
// Fabrique le store selon KNOWLEDGE_STORE_PROVIDER (défaut : "supabase"). Pour migrer
// vers Google Cloud plus tard : ajouter une GoogleCloudKnowledgeStore implémentant
// KnowledgeStore et l'enregistrer ici — aucune autre ligne de code métier ne change.
import { SupabaseKnowledgeStore } from "./supabaseStore.js";
import type { KnowledgeStore, KnowledgeInput, KnowledgeEntry, SearchQuery } from "./types.js";

export * from "./types.js";
export { knowledgeHash, clampConfidence } from "./hash.js";
import { knowledgeHash, clampConfidence } from "./hash.js";

let _store: KnowledgeStore | null = null;

export function getKnowledgeStore(): KnowledgeStore {
  if (_store) return _store;
  const provider = (process.env.KNOWLEDGE_STORE_PROVIDER ?? "supabase").toLowerCase();
  switch (provider) {
    case "supabase":
      _store = new SupabaseKnowledgeStore();
      break;
    // case "gcp": _store = new GoogleCloudKnowledgeStore(); break;  // migration future
    default:
      _store = new SupabaseKnowledgeStore();
  }
  return _store;
}


/**
 * Service : ajoute déduplication + upsert par-dessus le store.
 * C'est ce que consomment les routes et, plus tard, le moteur de recherche.
 */
export class KnowledgeService {
  private store: KnowledgeStore;

  constructor(store: KnowledgeStore = getKnowledgeStore()) {
    this.store = store;
  }

  /**
   * Enregistre une connaissance en évitant les doublons : si une entrée de même
   * empreinte existe déjà, on la met à jour (fusion) au lieu de créer un doublon.
   * Retourne l'entrée et un indicateur `deduped`.
   */
  async remember(
    userId: string,
    input: KnowledgeInput,
  ): Promise<{ entry: KnowledgeEntry; deduped: boolean }> {
    // L'empreinte est TOUJOURS recalculée (jamais fournie par un client).
    const hash = knowledgeHash(input.title, input.content);
    input = { ...input, confidence: input.confidence === undefined ? undefined : clampConfidence(input.confidence) };
    return this.store.upsertByHash(
      userId,
      { ...input, content_hash: hash },
      (existing) =>
        // Une synthèse LLM non vérifiée ne doit jamais écraser (source, confiance) une
        // connaissance existante d'une autre origine : simple reconfirmation datée.
        input.source === "llm_synthesis" && existing.source !== "llm_synthesis"
          ? {}
          : {
              ...input,
              content_hash: hash,
              // La confiance ne peut que se renforcer lors d'une reconfirmation.
              confidence: Math.max(existing.confidence, input.confidence ?? existing.confidence),
            },
      "Reconfirmation (déduplication)",
    );
  }

  create(userId: string, input: KnowledgeInput) {
    return this.store.create(userId, {
      ...input,
      content_hash: knowledgeHash(input.title, input.content),
      confidence: input.confidence === undefined ? undefined : clampConfidence(input.confidence),
    });
  }
  get(userId: string, id: string) {
    return this.store.getById(userId, id);
  }
  /** Mise à jour versionnée ; l'empreinte est recalculée par le store sur le contenu fusionné. */
  update(userId: string, id: string, patch: Partial<KnowledgeInput>, note?: string) {
    const { content_hash: _ignored, ...rest } = patch;
    void _ignored;
    const clean = rest.confidence === undefined ? rest : { ...rest, confidence: clampConfidence(rest.confidence) };
    return this.store.update(userId, id, clean, note);
  }
  remove(userId: string, id: string) {
    return this.store.remove(userId, id);
  }
  search(userId: string, query: SearchQuery) {
    return this.store.search(userId, query);
  }
  listVersions(userId: string, entryId: string) {
    return this.store.listVersions(userId, entryId);
  }
  restoreVersion(userId: string, entryId: string, version: number) {
    return this.store.restoreVersion(userId, entryId, version);
  }
  listDomains() {
    return this.store.listDomains();
  }
  addDomain(slug: string, label: string) {
    return this.store.addDomain(slug, label);
  }
}

export const knowledgeService = new KnowledgeService();
