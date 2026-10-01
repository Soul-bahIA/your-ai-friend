// Implémentation Supabase (PostgreSQL) de KnowledgeStore.
// Toutes les requêtes sont scopées par user_id (le backend se connecte en direct au
// pooler, hors RLS — le scoping est donc appliqué explicitement, comme ailleurs).
import { pool, withTransaction, type Queryable } from "../../db";
import { sanitizeLimit } from "../../lib/sanitize";
import { embed, toVectorLiteral } from "./embeddings";
import type {
  KnowledgeStore,
  KnowledgeEntry,
  KnowledgeInput,
  KnowledgeVersion,
  KnowledgeDomain,
  SearchQuery,
} from "./types";

const ENTRY_COLS = `id, user_id, title, description, content, summary, domain, category,
  keywords, tags, sources, source, confidence, version, links, content_hash,
  last_verified_at, created_at, updated_at`;

function mapRow(r: Record<string, unknown>): KnowledgeEntry {
  return {
    id: r.id as string,
    user_id: r.user_id as string,
    title: r.title as string,
    description: (r.description as string) ?? null,
    content: r.content as string,
    summary: (r.summary as string) ?? null,
    domain: (r.domain as string) ?? "general",
    category: (r.category as string) ?? "general",
    keywords: (r.keywords as string[]) ?? [],
    tags: (r.tags as string[]) ?? [],
    sources: (r.sources as KnowledgeEntry["sources"]) ?? [],
    source: (r.source as string) ?? null,
    confidence: typeof r.confidence === "number" ? r.confidence : Number(r.confidence ?? 0.5),
    version: typeof r.version === "number" ? r.version : Number(r.version ?? 1),
    links: (r.links as KnowledgeEntry["links"]) ?? [],
    content_hash: (r.content_hash as string) ?? null,
    last_verified_at: (r.last_verified_at as string) ?? null,
    created_at: r.created_at as string,
    updated_at: r.updated_at as string,
  };
}

/** Texte indexé pour l'embedding d'une entrée. */
function embedText(m: { title: string; summary?: string | null; content: string }): string {
  return `${m.title}\n${m.summary ?? ""}\n${m.content}`;
}

/** Embedding pré-calculé (hors transaction) réutilisé si le texte n'a pas changé. */
interface PreEmbedding {
  text: string;
  emb: number[] | null;
}
async function embedFor(text: string, pre?: PreEmbedding): Promise<number[] | null> {
  return pre && pre.text === text ? pre.emb : embed(text);
}

function mergeEntry(current: KnowledgeEntry, patch: Partial<KnowledgeInput>): KnowledgeInput {
  return {
    title: patch.title ?? current.title,
    content: patch.content ?? current.content,
    description: patch.description ?? current.description,
    summary: patch.summary ?? current.summary,
    domain: patch.domain ?? current.domain,
    category: patch.category ?? current.category,
    keywords: patch.keywords ?? current.keywords,
    tags: patch.tags ?? current.tags,
    sources: patch.sources ?? current.sources,
    source: patch.source ?? current.source,
    confidence: patch.confidence ?? current.confidence,
    links: patch.links ?? current.links,
    content_hash: patch.content_hash ?? current.content_hash,
  };
}

export class SupabaseKnowledgeStore implements KnowledgeStore {
  async create(
    userId: string,
    input: KnowledgeInput,
    db: Queryable = pool,
    pre?: PreEmbedding,
  ): Promise<KnowledgeEntry> {
    const emb = await embedFor(embedText(input), pre);
    const { rows } = await db.query(
      `INSERT INTO knowledge_base
         (user_id, title, content, description, summary, domain, category, keywords, tags,
          sources, source, confidence, links, content_hash, last_verified_at, embedding)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,$11,$12,$13::jsonb,$14, now(), $15::vector)
       RETURNING ${ENTRY_COLS}`,
      [
        userId,
        input.title,
        input.content,
        input.description ?? null,
        input.summary ?? null,
        input.domain ?? "general",
        input.category ?? "general",
        input.keywords ?? [],
        input.tags ?? [],
        JSON.stringify(input.sources ?? []),
        input.source ?? null,
        input.confidence ?? 0.5,
        JSON.stringify(input.links ?? []),
        input.content_hash ?? null,
        emb ? toVectorLiteral(emb) : null,
      ],
    );
    return mapRow(rows[0]);
  }

  async getById(userId: string, id: string): Promise<KnowledgeEntry | null> {
    const { rows } = await pool.query(
      `SELECT ${ENTRY_COLS} FROM knowledge_base WHERE id = $1 AND user_id = $2`,
      [id, userId],
    );
    return rows[0] ? mapRow(rows[0]) : null;
  }

  /**
   * Mise à jour versionnée, atomique : la ligne est verrouillée (SELECT … FOR UPDATE)
   * pendant l'archivage de la version courante + l'application du patch, pour que deux
   * mises à jour concurrentes ne produisent ni version perdue ni numéro dupliqué.
   * L'embedding (appel réseau) est calculé AVANT la transaction pour ne pas tenir le verrou.
   */
  async update(
    userId: string,
    id: string,
    patch: Partial<KnowledgeInput>,
    changeNote?: string,
  ): Promise<KnowledgeEntry | null> {
    const before = await this.getById(userId, id);
    if (!before) return null;
    const text = embedText(mergeEntry(before, patch));
    const pre: PreEmbedding = { text, emb: await embed(text) };
    return withTransaction((client) => this.updateLocked(client, userId, id, patch, changeNote, pre));
  }

  /** Corps de update() — à appeler DANS une transaction (db = client transactionnel). */
  private async updateLocked(
    db: Queryable,
    userId: string,
    id: string,
    patch: Partial<KnowledgeInput>,
    changeNote: string | undefined,
    pre?: PreEmbedding,
  ): Promise<KnowledgeEntry | null> {
    const locked = await db.query(
      `SELECT ${ENTRY_COLS} FROM knowledge_base WHERE id = $1 AND user_id = $2 FOR UPDATE`,
      [id, userId],
    );
    if (!locked.rows[0]) return null;
    const current = mapRow(locked.rows[0]);

    // 1) Archive la version courante (historique / restauration)
    await db.query(
      `INSERT INTO knowledge_versions (entry_id, user_id, version, snapshot, change_note)
       VALUES ($1,$2,$3,$4::jsonb,$5)`,
      [id, userId, current.version, JSON.stringify(current), changeNote ?? null],
    );

    // 2) Applique le patch (champs fournis uniquement), incrémente la version
    const merged = mergeEntry(current, patch);
    const emb = await embedFor(embedText(merged), pre);
    const { rows } = await db.query(
      `UPDATE knowledge_base SET
         title=$1, content=$2, description=$3, summary=$4, domain=$5, category=$6,
         keywords=$7, tags=$8, sources=$9::jsonb, source=$10, confidence=$11,
         links=$12::jsonb, content_hash=$13, embedding=$14::vector,
         version = version + 1, last_verified_at = now()
       WHERE id=$15 AND user_id=$16
       RETURNING ${ENTRY_COLS}`,
      [
        merged.title,
        merged.content,
        merged.description ?? null,
        merged.summary ?? null,
        merged.domain ?? "general",
        merged.category ?? "general",
        merged.keywords ?? [],
        merged.tags ?? [],
        JSON.stringify(merged.sources ?? []),
        merged.source ?? null,
        merged.confidence ?? 0.5,
        JSON.stringify(merged.links ?? []),
        merged.content_hash ?? null,
        emb ? toVectorLiteral(emb) : null,
        id,
        userId,
      ],
    );
    return rows[0] ? mapRow(rows[0]) : null;
  }

  /**
   * Pas de contrainte UNIQUE sur (user_id, content_hash) : on sérialise par verrou
   * consultatif transactionnel (pg_advisory_xact_lock) sur la paire utilisateur+empreinte.
   */
  async upsertByHash(
    userId: string,
    input: KnowledgeInput & { content_hash: string },
    onExisting: (existing: KnowledgeEntry) => Partial<KnowledgeInput>,
    changeNote?: string,
  ): Promise<{ entry: KnowledgeEntry; deduped: boolean }> {
    const text = embedText(input);
    const pre: PreEmbedding = { text, emb: await embed(text) };
    return withTransaction(async (client) => {
      await client.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        `knowledge:${userId}:${input.content_hash}`,
      ]);
      const existing = await this.findByHash(userId, input.content_hash, client);
      if (existing) {
        const updated = await this.updateLocked(client, userId, existing.id, onExisting(existing), changeNote, pre);
        return { entry: updated ?? existing, deduped: true };
      }
      return { entry: await this.create(userId, input, client, pre), deduped: false };
    });
  }

  async remove(userId: string, id: string): Promise<boolean> {
    const { rowCount } = await pool.query(
      "DELETE FROM knowledge_base WHERE id = $1 AND user_id = $2",
      [id, userId],
    );
    return (rowCount ?? 0) > 0;
  }

  async findByHash(userId: string, hash: string, db: Queryable = pool): Promise<KnowledgeEntry | null> {
    const { rows } = await db.query(
      `SELECT ${ENTRY_COLS} FROM knowledge_base WHERE user_id = $1 AND content_hash = $2 LIMIT 1`,
      [userId, hash],
    );
    return rows[0] ? mapRow(rows[0]) : null;
  }

  async search(userId: string, query: SearchQuery): Promise<KnowledgeEntry[]> {
    const where: string[] = ["user_id = $1"];
    const params: unknown[] = [userId];
    let i = 2;

    if (query.domain) {
      where.push(`domain = $${i++}`);
      params.push(query.domain);
    }
    if (query.keywords && query.keywords.length > 0) {
      where.push(`keywords && $${i++}`);
      params.push(query.keywords);
    }
    if (typeof query.minConfidence === "number") {
      where.push(`confidence >= $${i++}`);
      params.push(query.minConfidence);
    }
    if (typeof query.maxAgeDays === "number") {
      where.push(`last_verified_at >= now() - ($${i++} || ' days')::interval`);
      params.push(String(query.maxAgeDays));
    }

    let rank = "0";
    let orderBy = "_rank DESC, confidence DESC, updated_at DESC";
    if (query.text && query.text.trim()) {
      const qemb = await embed(query.text.trim());
      if (qemb) {
        // Recherche SÉMANTIQUE (RAG) : distance cosinus + seuil de pertinence.
        // Retrouve par le SENS, pas seulement par les mots-clés.
        const p = `$${i++}`;
        params.push(toVectorLiteral(qemb));
        where.push(`embedding IS NOT NULL AND (embedding <=> ${p}::vector) < 0.6`);
        rank = `(1 - (embedding <=> ${p}::vector))`;
        orderBy = `(embedding <=> ${p}::vector) ASC, confidence DESC`;
      } else {
        // Repli plein-texte (OU) si les embeddings sont indisponibles.
        const tokens = query.text.toLowerCase().match(/[\p{L}\p{N}]{2,}/gu) ?? [];
        if (tokens.length > 0) {
          const tsq = [...new Set(tokens)].join(" | ");
          const p = `$${i++}`;
          params.push(tsq);
          const vec =
            "to_tsvector('french', coalesce(title,'') || ' ' || coalesce(summary,'') || ' ' || coalesce(content,''))";
          where.push(`${vec} @@ to_tsquery('french', ${p})`);
          rank = `ts_rank(${vec}, to_tsquery('french', ${p}))`;
        }
      }
    }

    const limit = sanitizeLimit(query.limit, 10, 100); // NaN / hors bornes → défaut / borné
    const { rows } = await pool.query(
      `SELECT ${ENTRY_COLS}, ${rank} AS _rank FROM knowledge_base
       WHERE ${where.join(" AND ")}
       ORDER BY ${orderBy}
       LIMIT ${limit}`,
      params,
    );
    return rows.map(mapRow);
  }

  async listVersions(userId: string, entryId: string): Promise<KnowledgeVersion[]> {
    const { rows } = await pool.query(
      `SELECT id, entry_id, version, snapshot, change_note, created_at
       FROM knowledge_versions WHERE entry_id = $1 AND user_id = $2
       ORDER BY version DESC`,
      [entryId, userId],
    );
    return rows.map((r) => ({
      id: r.id as string,
      entry_id: r.entry_id as string,
      version: r.version as number,
      snapshot: r.snapshot as KnowledgeEntry,
      change_note: (r.change_note as string) ?? null,
      created_at: r.created_at as string,
    }));
  }

  async restoreVersion(
    userId: string,
    entryId: string,
    version: number,
  ): Promise<KnowledgeEntry | null> {
    const { rows } = await pool.query(
      `SELECT snapshot FROM knowledge_versions
       WHERE entry_id = $1 AND user_id = $2 AND version = $3 LIMIT 1`,
      [entryId, userId, version],
    );
    if (!rows[0]) return null;
    const snap = rows[0].snapshot as KnowledgeEntry;

    // Restaurer = appliquer le snapshot comme une nouvelle mise à jour (versionnée).
    return this.update(
      userId,
      entryId,
      {
        title: snap.title,
        content: snap.content,
        description: snap.description,
        summary: snap.summary,
        domain: snap.domain,
        category: snap.category,
        keywords: snap.keywords,
        tags: snap.tags,
        sources: snap.sources,
        source: snap.source,
        confidence: snap.confidence,
        links: snap.links,
        content_hash: snap.content_hash,
      },
      `Restauration de la version ${version}`,
    );
  }

  async listDomains(): Promise<KnowledgeDomain[]> {
    const { rows } = await pool.query(
      "SELECT slug, label, is_system FROM knowledge_domains ORDER BY label ASC",
    );
    return rows.map((r) => ({
      slug: r.slug as string,
      label: r.label as string,
      is_system: r.is_system as boolean,
    }));
  }

  async addDomain(slug: string, label: string): Promise<KnowledgeDomain> {
    const { rows } = await pool.query(
      `INSERT INTO knowledge_domains (slug, label, is_system) VALUES ($1,$2,false)
       ON CONFLICT (slug) DO UPDATE SET label = EXCLUDED.label
       RETURNING slug, label, is_system`,
      [slug, label],
    );
    return { slug: rows[0].slug, label: rows[0].label, is_system: rows[0].is_system };
  }
}
