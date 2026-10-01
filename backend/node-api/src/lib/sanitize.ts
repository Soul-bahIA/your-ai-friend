// Fonctions pures de nettoyage / bornage (sans dépendance à la DB ni à la config).

/** Entier borné : NaN / non-numérique → valeur par défaut ; sinon clampé dans [min, max]. */
export function clampInt(value: unknown, def: number, min: number, max: number): number {
  const n = typeof value === "string" && value.trim() !== "" ? Number(value) : value;
  if (typeof n !== "number" || !Number.isFinite(n)) return def;
  return Math.min(Math.max(Math.trunc(n), min), max);
}

/** Limite de pagination/recherche (alias lisible de clampInt). */
export function sanitizeLimit(value: unknown, def = 10, max = 100): number {
  return clampInt(value, def, 1, max);
}

/** Nombre fini optionnel : NaN / vide → undefined. */
export function optionalFiniteNumber(value: unknown): number | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  const n = typeof value === "number" ? value : Number(value);
  return Number.isFinite(n) ? n : undefined;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value);
}

/** Profondeur max parcourue par les nettoyages récursifs (au-delà : sous-arbre remplacé). */
export const MAX_SANITIZE_DEPTH = 32;
/** Remplace un sous-arbre trop imbriqué : jamais renvoyé tel quel (il n'a pas été nettoyé). */
export const TOO_DEEP_PLACEHOLDER = "[contenu trop imbriqué retiré]";

/**
 * Copie profonde d'une valeur JSON où toute clé `image_b64` est retirée (remplacée
 * par `image_omitted: true`). Sert à ne jamais renvoyer/transmettre des captures
 * base64 (plusieurs centaines de Ko chacune) dans des listes ou du texte de prompt.
 * Au-delà de MAX_SANITIZE_DEPTH, le sous-arbre (non inspecté) est remplacé par
 * TOO_DEEP_PLACEHOLDER au lieu d'être recopié tel quel.
 */
export function stripImageB64<T>(value: T, depth = 0): T {
  if (depth > MAX_SANITIZE_DEPTH) return (value !== null && typeof value === "object" ? TOO_DEEP_PLACEHOLDER : value) as T;
  if (Array.isArray(value)) return value.map((v) => stripImageB64(v, depth + 1)) as unknown as T;
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    let omitted = false;
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (k === "image_b64") {
        omitted = true;
        continue;
      }
      out[k] = stripImageB64(v, depth + 1);
    }
    if (omitted) out.image_omitted = true;
    return out as T;
  }
  return value;
}

/** Vrai si `v` est un objet JSON « simple » (pas un tableau, pas null). */
export function isPlainObject(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === "object" && !Array.isArray(v);
}

/** Clés de `obj` absentes de la liste autorisée. */
export function unknownKeys(obj: Record<string, unknown>, allowed: readonly string[]): string[] {
  return Object.keys(obj).filter((k) => !allowed.includes(k));
}
