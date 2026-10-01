// Service métier de la base de connaissances — indépendant du fournisseur de stockage.
//
// Fabrique le store selon KNOWLEDGE_STORE_PROVIDER (défaut : "supabase"). Pour migrer
// vers Google Cloud plus tard : ajouter une GoogleCloudKnowledgeStore implémentant
// KnowledgeStore et l'enregistrer ici — aucune autre ligne de code métier ne change.
import { createHash } from "node:crypto";
import { SupabaseKnowledgeStore } from "./supabaseStore";
import type { KnowledgeStore, KnowledgeInput, KnowledgeEntry, SearchQuery } from "./types";

export * from "./types";

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

/** Empreinte stable d'une connaissance (déduplication exacte). */
export function knowledgeHash(title: string, content: string): string {
  const norm = `${title.trim().toLowerCase()}\n${content.trim().toLowerCase()}`.replace(/\s+/g, " ");
  return createHash("sha256").update(norm, "utf8").digest("hex");
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
    const hash = input.content_hash ?? knowledgeHash(input.title, input.content);
    const existing = await this.store.findByHash(userId, hash);
    if (existing) {
      const updated = await this.store.update(
        userId,
        existing.id,
        {
          ...input,
          content_hash: hash,
          // La confiance ne peut que se renforcer lors d'une reconfirmation.
          confidence: Math.max(existing.confidence, input.confidence ?? existing.confidence),
        },
        "Reconfirmation (déduplication)",
      );
      return { entry: updated ?? existing, deduped: true };
    }
    const entry = await this.store.create(userId, { ...input, content_hash: hash });
    return { entry, deduped: false };
  }

  create(userId: string, input: KnowledgeInput) {
    return this.store.create(userId, {
      ...input,
      content_hash: input.content_hash ?? knowledgeHash(input.title, input.content),
    });
  }
  get(userId: string, id: string) {
    return this.store.getById(userId, id);
  }
  update(userId: string, id: string, patch: Partial<KnowledgeInput>, note?: string) {
    return this.store.update(userId, id, patch, note);
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
