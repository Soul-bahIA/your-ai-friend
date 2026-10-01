import { createHash } from "node:crypto";

/** Empreinte stable d'une connaissance (déduplication exacte) — titre + contenu normalisés. */
export function knowledgeHash(title: string, content: string): string {
  const norm = `${title.trim().toLowerCase()}\n${content.trim().toLowerCase()}`.replace(/\s+/g, " ");
  return createHash("sha256").update(norm, "utf8").digest("hex");
}

/** Confiance bornée dans [0, 1] (valeur invalide → défaut). */
export function clampConfidence(v: unknown, def = 0.5): number {
  return typeof v === "number" && Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : def;
}
