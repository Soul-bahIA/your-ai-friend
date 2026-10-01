// Configuration centrale de Soulbah (V3 LOT 1) — équivalent TypeScript de
// shared/config/soulbah_settings.py (référence). Mêmes règles, mêmes cas de test
// (shared/config/resolution_cases.json, test/soulbahSettings.test.ts).
//
// Résolution : valeurs par défaut < fichier JSON (SOULBAH_CONFIG, sinon
// <racine du dépôt>/soulbah.config.json s'il existe) < variables SOULBAH_*. Toute valeur
// invalide est une erreur : le service refuse de démarrer (checkStartupEnv).
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const MODES = ["OFFLINE", "LOCAL_INTERNET", "HYBRID"] as const;
export type SoulbahMode = (typeof MODES)[number];
export const RESOURCE_PROFILES = ["ECO", "BALANCED", "MAX"] as const;
export type ResourceProfile = (typeof RESOURCE_PROFILES)[number];
export const MODE_LABELS: Record<SoulbahMode, string> = { OFFLINE: "OFFLINE — 100% LOCAL", LOCAL_INTERNET: "LOCAL + INTERNET", HYBRID: "HYBRID" };
export const ECO_MAX_AGENTS = 2;
const MAX_ALLOW_HOSTS = 32;
export const CONFIG_FILE_NAME = "soulbah.config.json";

export interface SoulbahSettings {
  mode: SoulbahMode;
  max_agents: number;
  resource_profile: ResourceProfile;
  model_policy: string;
  network: { allow_hosts: string[] };
  computer_control: boolean;
  recording: boolean;
  self_improvement: boolean;
}

export const DEFAULTS: SoulbahSettings = {
  mode: "HYBRID",
  max_agents: 6,
  resource_profile: "BALANCED",
  model_policy: "auto",
  network: { allow_hosts: [] },
  computer_control: true,
  recording: true,
  self_improvement: false,
};

export const ENV_KEYS: Record<string, string> = {
  SOULBAH_MODE: "mode",
  SOULBAH_MAX_PARALLEL_AGENTS: "max_agents",
  SOULBAH_RESOURCE_PROFILE: "resource_profile",
  SOULBAH_MODEL_POLICY: "model_policy",
  SOULBAH_NETWORK_ALLOW_HOSTS: "network.allow_hosts",
  SOULBAH_COMPUTER_CONTROL: "computer_control",
  SOULBAH_RECORDING: "recording",
  SOULBAH_SELF_IMPROVEMENT: "self_improvement",
};

const TRUE = ["1", "true", "yes", "on", "oui"];
const FALSE = ["0", "false", "no", "off", "non"];
const MODEL_POLICY_RE = /^[A-Za-z0-9_.:/-]{1,100}$/;
const HOST_RE = /^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$|^[0-9a-f:.]{2,45}$/;
const TOP_KEYS = Object.keys(DEFAULTS);

type Parsed<T> = [T, null] | [null, string];

function parseMode(v: unknown): Parsed<SoulbahMode> {
  if (typeof v !== "string") return [null, "mode : texte attendu (OFFLINE | LOCAL_INTERNET | HYBRID)"];
  const norm = v.trim().toUpperCase().replace(/[\s+-]+/g, "_");
  return (MODES as readonly string[]).includes(norm) ? [norm as SoulbahMode, null] : [null, `mode inconnu « ${v.trim().slice(0, 40)} » (OFFLINE | LOCAL_INTERNET | HYBRID)`];
}

function parseProfile(v: unknown): Parsed<ResourceProfile> {
  const up = typeof v === "string" ? v.trim().toUpperCase() : "";
  return (RESOURCE_PROFILES as readonly string[]).includes(up) ? [up as ResourceProfile, null] : [null, `resource_profile inconnu « ${String(v).slice(0, 40)} » (ECO | BALANCED | MAX)`];
}

function parseMaxAgents(v: unknown): Parsed<number> {
  let n: unknown = v;
  if (typeof v === "string" && /^\s*\d+\s*$/.test(v)) n = Number(v);
  return typeof n === "number" && Number.isInteger(n) && n >= 1 && n <= 32 ? [n, null] : [null, `max_agents : entier de 1 à 32 attendu (reçu « ${String(v).slice(0, 20)} »)`];
}

function parseModelPolicy(v: unknown): Parsed<string> {
  return typeof v === "string" && MODEL_POLICY_RE.test(v.trim()) ? [v.trim(), null] : [null, "model_policy : « auto » ou identifiant de modèle (lettres, chiffres, _ . : / -)"];
}

function parseBool(name: string, v: unknown): Parsed<boolean> {
  if (typeof v === "boolean") return [v, null];
  if (typeof v === "string") {
    const s = v.trim().toLowerCase();
    if (TRUE.includes(s)) return [true, null];
    if (FALSE.includes(s)) return [false, null];
  }
  return [null, `${name} : booléen attendu (true / false)`];
}

function parseHosts(v: unknown): Parsed<string[]> {
  let list: unknown = v;
  if (typeof v === "string") list = v.split(",").map((p) => p.trim()).filter(Boolean);
  if (!Array.isArray(list) || list.length > MAX_ALLOW_HOSTS) return [null, `network.allow_hosts : liste de ${MAX_ALLOW_HOSTS} hôtes au plus attendue`];
  const out: string[] = [];
  for (const h of list) {
    if (typeof h !== "string") return [null, "network.allow_hosts : chaque hôte est un texte"];
    let host = h.trim().toLowerCase();
    if (host.startsWith("[") && host.endsWith("]")) host = host.slice(1, -1);
    if (!host || !HOST_RE.test(host) || host.includes("/")) return [null, `network.allow_hosts : hôte invalide « ${h.slice(0, 60)} » (nom ou adresse IP, sans schéma ni port)`];
    if (!out.includes(host)) out.push(host);
  }
  return [out, null];
}

const VALIDATORS: Record<string, (v: unknown) => Parsed<unknown>> = {
  mode: parseMode,
  max_agents: parseMaxAgents,
  resource_profile: parseProfile,
  model_policy: parseModelPolicy,
  "network.allow_hosts": parseHosts,
  computer_control: (v) => parseBool("computer_control", v),
  recording: (v) => parseBool("recording", v),
  self_improvement: (v) => parseBool("self_improvement", v),
};

function setKey(s: SoulbahSettings, key: string, value: unknown): void {
  if (key === "network.allow_hosts") s.network = { allow_hosts: value as string[] };
  else (s as unknown as Record<string, unknown>)[key] = value;
}

function applyFile(s: SoulbahSettings, data: unknown, errors: string[]): void {
  if (typeof data !== "object" || data === null || Array.isArray(data)) {
    errors.push("fichier de configuration : objet JSON attendu");
    return;
  }
  for (const [rawKey, rawValue] of Object.entries(data as Record<string, unknown>)) {
    if (rawKey.startsWith("$") || rawKey === "description") continue;
    if (!TOP_KEYS.includes(rawKey)) {
      errors.push(`fichier de configuration : clé inconnue « ${rawKey} »`);
      continue;
    }
    let key = rawKey;
    let value = rawValue;
    if (key === "network") {
      const ok = typeof value === "object" && value !== null && !Array.isArray(value) && Object.keys(value).every((k) => k === "allow_hosts");
      if (!ok) {
        errors.push('fichier de configuration : network = {"allow_hosts": [...]} attendu');
        continue;
      }
      if (!("allow_hosts" in (value as object))) continue;
      key = "network.allow_hosts";
      value = (value as { allow_hosts: unknown }).allow_hosts;
    }
    const [parsed, err] = VALIDATORS[key](value);
    if (err) errors.push(`fichier de configuration : ${err}`);
    else setKey(s, key, parsed);
  }
}

export interface Resolved {
  settings: SoulbahSettings;
  errors: string[];
  source: { file: string | null; env: string[] };
}

/** Résolution pure (fichier déjà lu, ou null). */
export function resolveSettings(env: Record<string, string | undefined>, fileData: unknown = null, filePath: string | null = null): Resolved {
  const settings: SoulbahSettings = JSON.parse(JSON.stringify(DEFAULTS));
  const errors: string[] = [];
  if (fileData !== null && fileData !== undefined) applyFile(settings, fileData, errors);
  const used: string[] = [];
  for (const [name, key] of Object.entries(ENV_KEYS)) {
    const raw = env[name];
    if (raw === undefined || !String(raw).trim()) continue;
    const [parsed, err] = VALIDATORS[key](String(raw));
    if (err) errors.push(`${name} : ${err}`);
    else {
      setKey(settings, key, parsed);
      used.push(name);
    }
  }
  return { settings, errors, source: { file: filePath, env: used } };
}

/** Racine du dépôt : <node-api>/{src,dist}/lib → ../../../.. */
export function repoRoot(): string {
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "..");
}

export function loadSettings(env: Record<string, string | undefined> = process.env, root: string | null = repoRoot()): Resolved {
  const explicit = (env.SOULBAH_CONFIG ?? "").trim();
  let file: string | null = explicit || (root && fs.existsSync(path.join(root, CONFIG_FILE_NAME)) ? path.join(root, CONFIG_FILE_NAME) : null);
  const errors: string[] = [];
  let data: unknown = null;
  if (file) {
    try {
      data = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch (e) {
      const code = (e as NodeJS.ErrnoException).code;
      errors.push(code === "ENOENT" ? `SOULBAH_CONFIG : fichier introuvable « ${file} »` : `fichier de configuration illisible « ${file} » : ${(e as Error).message}`);
      if (code === "ENOENT") file = null;
      data = null;
    }
  }
  const out = resolveSettings(env, data, file);
  return { ...out, errors: [...errors, ...out.errors] };
}

// --- Politique dérivée (mêmes règles que soulbah_settings.py) ---------------------------
export const cloudModelsAllowed = (s: Pick<SoulbahSettings, "mode">): boolean => s.mode === "HYBRID";
export const internetAllowed = (s: Pick<SoulbahSettings, "mode">): boolean => s.mode !== "OFFLINE";

export function isLoopbackHost(host: string): boolean {
  const h = host.trim().toLowerCase().replace(/^\[|\]$/g, "");
  return h === "localhost" || h === "::1" || h === "0:0:0:0:0:0:0:1" || h.startsWith("127.") || h.endsWith(".localhost");
}

/** Nom sans point ni « : » (service Docker « python-ia », machine du réseau local). */
export function isLocalName(host: string): boolean {
  const h = host.trim().toLowerCase().replace(/^\[|\]$/g, "");
  return h !== "" && !h.includes(".") && !h.includes(":");
}

export function hostAllowed(s: Pick<SoulbahSettings, "mode" | "network">, host: string): boolean {
  const h = host.trim().toLowerCase().replace(/^\[|\]$/g, "");
  if (isLoopbackHost(h) || isLocalName(h)) return true;
  if (s.network.allow_hosts.includes(h)) return true;
  return internetAllowed(s);
}

/** Machine de l'utilisateur (bouclage, nom local, hôte déclaré) : exigé pour LOCAL_LLM_URL hors HYBRID. */
export function isLocalEndpoint(s: Pick<SoulbahSettings, "network">, host: string): boolean {
  const h = host.trim().toLowerCase().replace(/^\[|\]$/g, "");
  return isLoopbackHost(h) || isLocalName(h) || s.network.allow_hosts.includes(h);
}

export function effectiveMaxAgents(s: Pick<SoulbahSettings, "max_agents" | "resource_profile">): number {
  return s.resource_profile === "ECO" ? Math.min(s.max_agents, ECO_MAX_AGENTS) : s.max_agents;
}

export function publicView(s: SoulbahSettings) {
  return {
    ...JSON.parse(JSON.stringify(s)),
    label: MODE_LABELS[s.mode],
    cloud_models_allowed: cloudModelsAllowed(s),
    internet_allowed: internetAllowed(s),
    effective_max_agents: effectiveMaxAgents(s),
  };
}

let cached: Resolved | null = null;
/** Configuration du processus (lue une fois ; resetSettingsCache() pour les tests). */
export function currentSettings(): SoulbahSettings {
  if (!cached) cached = loadSettings();
  return cached.settings;
}
export function currentResolution(): Resolved {
  if (!cached) cached = loadSettings();
  return cached;
}
export function resetSettingsCache(): void {
  cached = null;
}
