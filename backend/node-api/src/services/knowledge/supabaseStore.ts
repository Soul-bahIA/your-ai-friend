// Implémentation Supabase (PostgreSQL) de KnowledgeStore.
// Toutes les requêtes sont scopées par user_id (le backend se connecte en direct au
// pooler, hors RLS — le scoping est donc appliqué explicitement, comme ailleurs).
import { pool } from "../../db";
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

export class SupabaseKnowledgeStore implements KnowledgeStore {
  async create(userId: string, input: KnowledgeInput): Promise<KnowledgeEntry> {
    const emb = await embed(`${input.title}\n${input.summary ?? ""}\n${input.content}`);
    const { rows } = await pool.query(
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

  async update(
    userId: string,
    id: string,
    patch: Partial<KnowledgeInput>,
    changeNote?: string,
  ): Promise<KnowledgeEntry | null> {
    const current = await this.getById(userId, id);
    if (!current) return null;

    // 1) Archive la version courante (historique / restauration)
    await pool.query(
      `INSERT INTO knowledge_versions (entry_id, user_id, version, snapshot, change_note)
       VALUES ($1,$2,$3,$4::jsonb,$5)`,
      [id, userId, current.version, JSON.stringify(current), changeNote ?? null],
    );

    // 2) Applique le patch (champs fournis uniquement), incrémente la version
    const merged: KnowledgeInput = {
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

    const emb = await embed(`${merged.title}\n${merged.summary ?? ""}\n${merged.content}`);
    const { rows } = await pool.query(
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

  async remove(userId: string, id: string): Promise<boolean> {
    const { rowCount } = await pool.query(
      "DELETE FROM knowledge_base WHERE id = $1 AND user_id = $2",
      [id, userId],
    );
    return (rowCount ?? 0) > 0;
  }

  async findByHash(userId: string, hash: string): Promise<KnowledgeEntry | null> {
    const { rows } = await pool.query(
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

    const limit = Math.min(Math.max(query.limit ?? 10, 1), 100);
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
