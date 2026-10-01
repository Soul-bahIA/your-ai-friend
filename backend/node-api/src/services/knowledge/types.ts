// Contrat de stockage de la base de connaissances — indépendant du fournisseur.
//
// La logique métier (recherche KB-first, synthèse, déduplication) ne dépend QUE de
// cette interface. Aujourd'hui : SupabaseKnowledgeStore. Demain : une implémentation
// Google Cloud pourra la remplacer sans modifier le service ni les routes.

export interface Source {
  url?: string;
  title?: string;
  /** false = URL citée par un modèle mais jamais récupérée (non vérifiée). */
  verified?: boolean;
}

export interface KnowledgeLink {
  id: string; // id d'une autre entrée de connaissance
  relation?: string; // ex. "prérequis", "approfondit", "contredit"
}

export interface KnowledgeEntry {
  id: string;
  user_id: string;
  title: string;
  description: string | null;
  content: string;
  summary: string | null;
  domain: string; // catégorie/domaine (référentiel extensible)
  category: string; // type coarse existant ('general', 'formation'…) conservé
  keywords: string[];
  tags: string[];
  sources: Source[];
  source: string | null;
  confidence: number; // 0..1
  version: number;
  links: KnowledgeLink[];
  content_hash: string | null;
  last_verified_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface KnowledgeInput {
  title: string;
  content: string;
  description?: string | null;
  summary?: string | null;
  domain?: string;
  category?: string;
  keywords?: string[];
  tags?: string[];
  sources?: Source[];
  source?: string | null;
  confidence?: number;
  links?: KnowledgeLink[];
  content_hash?: string | null;
}

export interface SearchQuery {
  text?: string;
  domain?: string;
  keywords?: string[];
  minConfidence?: number;
  maxAgeDays?: number; // fraîcheur : n'accepte que les entrées re-vérifiées récemment
  limit?: number;
}

export interface KnowledgeVersion {
  id: string;
  entry_id: string;
  version: number;
  snapshot: KnowledgeEntry;
  change_note: string | null;
  created_at: string;
}

export interface KnowledgeDomain {
  slug: string;
  label: string;
  is_system: boolean;
}

/** Couche de persistance abstraite. Toute opération est scopée par utilisateur. */
export interface KnowledgeStore {
  create(userId: string, input: KnowledgeInput): Promise<KnowledgeEntry>;
  getById(userId: string, id: string): Promise<KnowledgeEntry | null>;
  update(
    userId: string,
    id: string,
    patch: Partial<KnowledgeInput>,
    changeNote?: string,
  ): Promise<KnowledgeEntry | null>;
  remove(userId: string, id: string): Promise<boolean>;
  search(userId: string, query: SearchQuery): Promise<KnowledgeEntry[]>;
  findByHash(userId: string, hash: string): Promise<KnowledgeEntry | null>;
  /**
   * Déduplication ATOMIQUE par empreinte : sous verrou (pas de doublon en cas d'appels
   * concurrents), met à jour l'entrée de même empreinte (patch = onExisting(existante))
   * ou en crée une nouvelle.
   */
  upsertByHash(
    userId: string,
    input: KnowledgeInput & { content_hash: string },
    onExisting: (existing: KnowledgeEntry) => Partial<KnowledgeInput>,
    changeNote?: string,
  ): Promise<{ entry: KnowledgeEntry; deduped: boolean }>;
  listVersions(userId: string, entryId: string): Promise<KnowledgeVersion[]>;
  restoreVersion(userId: string, entryId: string, version: number): Promise<KnowledgeEntry | null>;
  listDomains(): Promise<KnowledgeDomain[]>;
  addDomain(slug: string, label: string): Promise<KnowledgeDomain>;
}
