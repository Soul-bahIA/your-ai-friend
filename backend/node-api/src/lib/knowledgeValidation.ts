// Validation des écritures de la base de connaissances (POST/PATCH /api/knowledge) :
// toute valeur hors bornes → 400 explicite (jamais une 500 de contrainte SQL).
import { isPlainObject, isUuid } from "./sanitize.js";
import type { Result } from "./agentSteps.js";
import type { KnowledgeInput, KnowledgeLink, Source } from "../services/knowledge/types.js";

const LIMITS = { title: 500, content: 100_000, description: 5_000, summary: 10_000, domain: 80, category: 50, source: 100 };

function optText(body: Record<string, unknown>, k: keyof typeof LIMITS, nullable: boolean): Result<string | null | undefined> {
  const v = body[k];
  if (v === undefined) return { ok: true, value: undefined };
  if (v === null && nullable) return { ok: true, value: null };
  if (typeof v !== "string") return { ok: false, error: `${k} doit être un texte` };
  if (v.length > LIMITS[k]) return { ok: false, error: `${k} trop long (max ${LIMITS[k]} car.)` };
  return { ok: true, value: v };
}

function strList(v: unknown, name: string, maxItems: number, maxLen: number): Result<string[] | undefined> {
  if (v === undefined) return { ok: true, value: undefined };
  if (!Array.isArray(v) || v.length > maxItems || !v.every((x) => typeof x === "string" && x.length <= maxLen)) {
    return { ok: false, error: `${name} doit être une liste de textes (max ${maxItems} × ${maxLen} car.)` };
  }
  return { ok: true, value: v as string[] };
}

/**
 * Valide un corps de création (partial=false : title et content requis) ou de mise à jour
 * (partial=true). Les champs inconnus (et content_hash, calculé par le serveur) sont ignorés.
 */
export function validateKnowledgeInput(body: unknown, partial: boolean): Result<Partial<KnowledgeInput>> {
  if (!isPlainObject(body)) return { ok: false, error: "corps JSON objet attendu" };
  const out: Partial<KnowledgeInput> = {};
  for (const k of ["title", "content"] as const) {
    const r = optText(body, k, false);
    if (!r.ok) return r;
    const v = r.value ?? undefined;
    if (v === undefined || !v.trim()) {
      if (!partial || v !== undefined) return { ok: false, error: `${k} requis (texte non vide)` };
      continue;
    }
    out[k] = v;
  }
  for (const k of ["description", "summary", "source"] as const) {
    const r = optText(body, k, true);
    if (!r.ok) return r;
    if (r.value !== undefined) out[k] = r.value;
  }
  for (const k of ["domain", "category"] as const) {
    const r = optText(body, k, false);
    if (!r.ok) return r;
    if (typeof r.value === "string") out[k] = r.value;
  }
  const kw = strList(body.keywords, "keywords", 50, 80);
  if (!kw.ok) return kw;
  if (kw.value) out.keywords = kw.value;
  const tags = strList(body.tags, "tags", 50, 80);
  if (!tags.ok) return tags;
  if (tags.value) out.tags = tags.value;

  if (body.confidence !== undefined) {
    const c = body.confidence;
    if (typeof c !== "number" || !Number.isFinite(c) || c < 0 || c > 1) {
      return { ok: false, error: "confidence doit être un nombre entre 0 et 1" };
    }
    out.confidence = c;
  }
  if (body.sources !== undefined) {
    const s = body.sources;
    if (!Array.isArray(s) || s.length > 50) return { ok: false, error: "sources doit être une liste (max 50)" };
    const list: Source[] = [];
    for (const it of s) {
      if (!isPlainObject(it)) return { ok: false, error: "sources : objets { url?, title? } attendus" };
      const url = it.url, title = it.title;
      if ((url !== undefined && (typeof url !== "string" || url.length > 2000)) ||
          (title !== undefined && (typeof title !== "string" || title.length > 500))) {
        return { ok: false, error: "sources : url (2000 car.) / title (500 car.) invalides" };
      }
      const src: Source = {};
      if (typeof url === "string") src.url = url;
      if (typeof title === "string") src.title = title;
      if (typeof it.verified === "boolean") src.verified = it.verified;
      list.push(src);
    }
    out.sources = list;
  }
  if (body.links !== undefined) {
    const l = body.links;
    if (!Array.isArray(l) || l.length > 100) return { ok: false, error: "links doit être une liste (max 100)" };
    const list: KnowledgeLink[] = [];
    for (const it of l) {
      if (!isPlainObject(it) || !isUuid(it.id)) return { ok: false, error: "links : objets { id (uuid), relation? } attendus" };
      if (it.relation !== undefined && (typeof it.relation !== "string" || it.relation.length > 50)) {
        return { ok: false, error: "links : relation (50 car.) invalide" };
      }
      list.push(typeof it.relation === "string" ? { id: it.id, relation: it.relation } : { id: it.id });
    }
    out.links = list;
  }
  if (partial && Object.keys(out).length === 0) return { ok: false, error: "aucune modification fournie" };
  return { ok: true, value: out };
}
