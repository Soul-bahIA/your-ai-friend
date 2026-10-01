// Catalogue d'outils de l'agent (LOT 2 : contrat d'outils unique).
//
// src/generated/tool_catalog.json est une copie GÉNÉRÉE de shared/tools/catalog.json :
// agent/skills/manifests.py → scripts/gen_catalog.py (`--check` en CI échoue à la
// moindre dérive). Ne jamais la modifier à la main : voir docs/CATALOGUE_OUTILS.md.
// La copie vit dans src/ parce que l'image Docker est construite depuis backend/node-api
// (shared/ est hors du contexte de build) ; tsc la recopie dans dist/generated/.
import catalogJson from "../generated/tool_catalog.json" with { type: "json" };
import { isPlainObject } from "./sanitize.js";

export type ParamType = "string" | "integer" | "number" | "boolean" | "array";
export type SecurityLevel = "L0" | "L1" | "L2" | "L3";

export interface ToolParam {
  name: string;
  type: ParamType | ParamType[];
  description: string;
  required: boolean;
  is_path: boolean;
  is_secret_text: boolean;
  deprecated: boolean;
  enum?: string[];
  min?: number;
  max?: number;
  /** Valeur hors [min, max] ramenée dans les bornes par l'agent (sinon refusée). */
  clamped?: boolean;
  max_length?: number;
  items?: { type: ParamType };
  max_items?: number;
  default?: string | number | boolean;
  extensions?: string[];
  pattern?: string;
}

export interface ToolEvidence {
  kind: string;
  confidence: "high" | "medium" | "low" | "none";
  description: string;
  field?: string;
}

export interface ToolManifest {
  name: string;
  aliases: string[];
  version: string;
  description: string;
  category: string;
  security_level: SecurityLevel;
  escalation?: { level: SecurityLevel; when: string };
  requires_desktop_input: boolean;
  /** Action à effet réel : payload.requires_confirmation, confirmée sur le PC. */
  requires_confirmation: boolean;
  idempotent: boolean;
  timeout_s: number | null;
  params: ToolParam[];
  /** Groupes « au moins l'un de » (ex. [["app", "software", "name"]]). */
  required_any: string[][];
  evidence: ToolEvidence[];
  examples: Record<string, unknown>[];
  known_errors: string[];
}

export interface ToolCatalog {
  catalog_version: string;
  generated_from: string;
  common_fields: string[];
  workspace_placeholder: string;
  security_levels: Record<SecurityLevel, string>;
  categories: { id: string; label: string; planner_note: string }[];
  tools: ToolManifest[];
}

function invalid(msg: string): never {
  throw new Error(`catalogue d'outils invalide (src/generated/tool_catalog.json) : ${msg}`);
}

const isStringArray = (v: unknown): v is string[] => Array.isArray(v) && v.every((x) => typeof x === "string");

/**
 * Contrôle de forme à l'import (le schéma complet est vérifié par gen_catalog.py) : une
 * copie corrompue empêche le démarrage au lieu de laisser passer des plans au hasard.
 */
export function parseToolCatalog(raw: unknown): ToolCatalog {
  if (!isPlainObject(raw)) invalid("objet attendu");
  if (!isStringArray(raw.common_fields)) invalid("common_fields");
  if (!Array.isArray(raw.tools) || raw.tools.length === 0) invalid("tools vide");
  const seen = new Set<string>();
  for (const t of raw.tools as unknown[]) {
    if (!isPlainObject(t) || typeof t.name !== "string") invalid("outil sans nom");
    const name = t.name;
    if (!isStringArray(t.aliases) || !Array.isArray(t.params) || !Array.isArray(t.required_any)) {
      invalid(`${name} : aliases, params ou required_any`);
    }
    if (typeof t.requires_confirmation !== "boolean") invalid(`${name} : requires_confirmation`);
    for (const type of [name, ...t.aliases]) {
      if (seen.has(type)) invalid(`type d'étape en double « ${type} »`);
      seen.add(type);
    }
    const params = new Set<string>();
    for (const p of t.params as unknown[]) {
      if (!isPlainObject(p) || typeof p.name !== "string") invalid(`${name} : paramètre sans nom`);
      for (const flag of ["required", "is_path", "is_secret_text", "deprecated"] as const) {
        if (typeof p[flag] !== "boolean") invalid(`${name}.${p.name} : ${flag}`);
      }
      params.add(p.name);
    }
    for (const group of t.required_any as unknown[]) {
      if (!isStringArray(group) || !group.every((g) => params.has(g))) invalid(`${name} : required_any`);
    }
  }
  return raw as unknown as ToolCatalog;
}

export const TOOL_CATALOG: ToolCatalog = parseToolCatalog(catalogJson);
