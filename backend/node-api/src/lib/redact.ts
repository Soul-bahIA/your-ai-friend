// Masquage du texte saisi avant tout envoi au LLM évaluateur / à la mémoire (contrat LOT 1 §12).
// Les champs `text` (type_text, phone_type…) et `content` (write_file, read_file…) sont
// remplacés par « [texte masqué : N car.] » — le LLM n'a jamais besoin du contenu exact.

export const MASKED_KEYS: readonly string[] = ["text", "content"];
const ALREADY_MASKED = /^\[texte masqué : \d+ car\.\]$/;

export function maskLabel(s: string): string {
  return `[texte masqué : ${s.length} car.]`;
}

/** Copie profonde de `value` où chaque `text`/`content` textuel est masqué. */
export function maskTypedText<T>(value: T, depth = 0): T {
  if (depth > 32) return value;
  if (Array.isArray(value)) return value.map((v) => maskTypedText(v, depth + 1)) as unknown as T;
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (MASKED_KEYS.includes(k) && typeof v === "string") {
        out[k] = ALREADY_MASKED.test(v) ? v : maskLabel(v);
      } else {
        out[k] = maskTypedText(v, depth + 1);
      }
    }
    return out as T;
  }
  return value;
}
