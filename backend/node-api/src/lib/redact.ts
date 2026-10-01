// Masquage du texte saisi avant tout envoi au LLM évaluateur / à la mémoire (contrat LOT 1 §12).
// Les champs `text` (type_text, phone_type…) et `content` (write_file, read_file…) sont
// remplacés par « [texte masqué : N car.] » — le LLM n'a jamais besoin du contenu exact.

import { MAX_SANITIZE_DEPTH, TOO_DEEP_PLACEHOLDER } from "./sanitize.js";

export const MASKED_KEYS: readonly string[] = ["text", "content"];
export const ALREADY_MASKED = /^\[texte masqué : \d+ car\.\]$/;
/** Le libellé de masquage figure QUELQUE PART dans la chaîne (recopie par le LLM). */
export const CONTAINS_MASKED = /\[texte masqué : \d+ car\.\]/;

export function maskLabel(s: string): string {
  return `[texte masqué : ${s.length} car.]`;
}

/**
 * Copie profonde de `value` où chaque `text`/`content` textuel est masqué. Au-delà de
 * MAX_SANITIZE_DEPTH, le sous-arbre (non inspecté) est remplacé par un libellé : jamais
 * transmis non masqué au LLM.
 */
export function maskTypedText<T>(value: T, depth = 0): T {
  if (depth > MAX_SANITIZE_DEPTH) return (value !== null && typeof value === "object" ? TOO_DEEP_PLACEHOLDER : value) as T;
  if (Array.isArray(value)) return value.map((v) => maskTypedText(v, depth + 1)) as unknown as T;
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (MASKED_KEYS.includes(k) && typeof v === "string") {
        out[k] = ALREADY_MASKED.test(v) ? v : maskLabel(v);
      } else if (MASKED_KEYS.includes(k) && v !== null && v !== undefined) {
        out[k] = maskLabel(JSON.stringify(v) ?? String(v));
      } else {
        out[k] = maskTypedText(v, depth + 1);
      }
    }
    return out as T;
  }
  return value;
}

/**
 * Étapes planifiées / correctives (C§12) : le LLM n'a jamais vu que des libellés
 * « [texte masqué : N car.] ». S'il en recopie un dans un paramètre `text`/`content`,
 * l'agent saisirait/écrirait littéralement ce libellé. On tente de RESTAURER le texte
 * d'origine depuis `originals` (étapes de la tâche évaluée) : même index puis toute
 * étape de même type, même champ, même longueur N — un seul texte candidat. Sinon : erreur.
 * Renvoie les étapes restaurées, ou un message d'erreur.
 */
const DESCRIPTIVE_KEYS: readonly string[] = ["note", "description"];

export function restoreMaskedParams(
  steps: Record<string, unknown>[],
  originals: unknown[] = [],
): { ok: true; value: Record<string, unknown>[] } | { ok: false; error: string } {
  const out: Record<string, unknown>[] = [];
  for (const [i, step] of steps.entries()) {
    const copy: Record<string, unknown> = { ...step };
    for (const [k, v] of Object.entries(step)) {
      if (DESCRIPTIVE_KEYS.includes(k)) continue; // affichage seulement, jamais exécuté
      if (typeof v === "string" && CONTAINS_MASKED.test(v)) {
        const restored = MASKED_KEYS.includes(k) && ALREADY_MASKED.test(v) ? findOriginal(originals, i, step.type, k, v) : null;
        if (restored === null) {
          return {
            ok: false,
            error: `étape ${i + 1} (${String(step.type)}) : le champ « ${k} » contient un texte masqué recopié, texte d'origine inconnu`,
          };
        }
        copy[k] = restored;
      } else if (Array.isArray(v) && v.some((x) => typeof x === "string" && CONTAINS_MASKED.test(x))) {
        return { ok: false, error: `étape ${i + 1} (${String(step.type)}) : le champ « ${k} » contient un texte masqué recopié` };
      }
    }
    out.push(copy);
  }
  return { ok: true, value: out };
}

function findOriginal(originals: unknown[], index: number, type: unknown, key: string, label: string): string | null {
  const n = Number(/(\d+)/.exec(label)?.[1]);
  const fits = (s: unknown): s is Record<string, unknown> =>
    !!s && typeof s === "object" && !Array.isArray(s) &&
    (s as Record<string, unknown>).type === type &&
    typeof (s as Record<string, unknown>)[key] === "string" &&
    ((s as Record<string, unknown>)[key] as string).length === n &&
    !CONTAINS_MASKED.test((s as Record<string, unknown>)[key] as string);
  const same = originals[index];
  if (fits(same)) return same[key] as string;
  const candidates = new Set(originals.filter(fits).map((s) => s[key] as string));
  return candidates.size === 1 ? [...candidates][0] : null;
}

/**
 * Copie profonde SANS les champs `text`/`content` textuels (mémoire « solution » relue par
 * le planificateur) : ni le texte, ni un libellé de masquage qu'il pourrait recopier.
 */
export function omitTypedText<T>(value: T, depth = 0): T {
  if (depth > MAX_SANITIZE_DEPTH) return (value !== null && typeof value === "object" ? TOO_DEEP_PLACEHOLDER : value) as T;
  if (Array.isArray(value)) return value.map((v) => omitTypedText(v, depth + 1)) as unknown as T;
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (MASKED_KEYS.includes(k) && v !== null && v !== undefined) continue;
      out[k] = omitTypedText(v, depth + 1);
    }
    return out as T;
  }
  return value;
}

/** Message d'erreur si une étape planifiée contient un libellé de masquage recopié, sinon null. */
export function findMaskedPlaceholder(steps: Record<string, unknown>[]): string | null {
  const r = restoreMaskedParams(steps, []);
  return r.ok ? null : r.error;
}
