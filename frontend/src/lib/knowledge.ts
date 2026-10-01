// Corps des écritures de la base de connaissances via /api/knowledge (contrat §11).
// Le client n'envoie que les champs saisis : hash, version et embedding sont
// calculés par le serveur (jamais par le navigateur).

export interface KnowledgeForm {
  title: string;
  content: string;
  category: string;
  source: string;
  tags: string;
}

export interface KnowledgeBody {
  title: string;
  content: string;
  category: string;
  source: string | null;
  tags: string[];
}

/** Découpe les tags saisis (« a, b ,, c ») en liste propre et sans doublon. */
export function parseTags(raw: string): string[] {
  const out: string[] = [];
  for (const t of raw.split(",")) {
    const tag = t.trim();
    if (tag && !out.includes(tag)) out.push(tag);
  }
  return out;
}

export function buildKnowledgeBody(form: KnowledgeForm): KnowledgeBody {
  return {
    title: form.title.trim(),
    content: form.content,
    category: form.category || "general",
    source: form.source.trim() || null,
    tags: parseTags(form.tags),
  };
}
