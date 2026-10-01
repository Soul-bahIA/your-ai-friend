// Embeddings pour la recherche sémantique (RAG) de la base de connaissances.
// OpenAI text-embedding-3-small (1536 dim). Best-effort : si indisponible, on renvoie
// null et la recherche retombe sur le plein-texte — la KB reste fonctionnelle.

const EMBED_MODEL = process.env.EMBEDDING_MODEL ?? "text-embedding-3-small";
const EMBED_URL = process.env.EMBEDDING_URL ?? "https://api.openai.com/v1/embeddings";
const EMBED_TIMEOUT_MS = 30_000;

export async function embed(text: string): Promise<number[] | null> {
  const key = process.env.OPENAI_API_KEY;
  if (!key || !text.trim()) return null;
  try {
    const res = await fetch(EMBED_URL, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ model: EMBED_MODEL, input: text.slice(0, 8000) }),
      signal: AbortSignal.timeout(EMBED_TIMEOUT_MS),
    });
    if (!res.ok) return null;
    const data = (await res.json()) as { data?: { embedding?: number[] }[] };
    return data.data?.[0]?.embedding ?? null;
  } catch {
    return null;
  }
}

/** Formate un vecteur pour pgvector (littéral « [0.1,0.2,…] »). */
export function toVectorLiteral(vec: number[]): string {
  return `[${vec.join(",")}]`;
}
