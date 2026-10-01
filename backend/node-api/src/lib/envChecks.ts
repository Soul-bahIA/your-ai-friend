// Garde-fous de démarrage selon SOULBAH_ENV (contrat LOT 1 §1). Fonction pure : testable.
import fs from "node:fs";

export const SOULBAH_ENVS = ["dev", "test", "staging", "production"] as const;
export type SoulbahEnv = (typeof SOULBAH_ENVS)[number];

/** AUTH_MODE (LOT 3) : vérification Supabase des JWT, ou jeton de dev partagé (hors Docker). */
export const AUTH_MODES = ["supabase", "dev-local"] as const;
export type AuthMode = (typeof AUTH_MODES)[number];
export const DEV_LOCAL_TOKEN_MIN_LENGTH = 32;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Adresse d'un pair en boucle locale : 127.x.y.z, ::1, ou IPv4 locale mappée en IPv6. */
export function isLoopbackAddress(ip: string | undefined | null): boolean {
  const v = (ip ?? "").trim().toLowerCase();
  if (!v) return false;
  if (v === "::1") return true;
  const v4 = v.startsWith("::ffff:") ? v.slice("::ffff:".length) : v;
  return /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(v4);
}

/** Hôte d'écoute en boucle locale (vide = défaut 127.0.0.1 de config.ts). */
export function isLoopbackHost(host: string | undefined | null): boolean {
  const v = (host ?? "").trim().toLowerCase();
  return v === "" || v === "localhost" || isLoopbackAddress(v);
}

export interface EnvCheckResult {
  soulbahEnv: SoulbahEnv | string;
  /** Vrai hors dev/test : les erreurs ci-dessous empêchent le démarrage. */
  strict: boolean;
  errors: string[];
  warnings: string[];
}

/**
 * Vérifie l'environnement avant tout démarrage :
 *  - SOULBAH_ENV doit être dev | test | staging | production (défaut dev) ;
 *  - hors dev/test : IA_SERVICE_TOKEN obligatoire ; PG_SSL_CA obligatoire si DATABASE_SSL=true ;
 *  - partout : un PG_SSL_CA défini doit être lisible (sinon crash opaque à la connexion).
 */
export function checkStartupEnv(
  env: NodeJS.ProcessEnv,
  fileReadable: (p: string) => boolean = defaultFileReadable,
): EnvCheckResult {
  const raw = (env.SOULBAH_ENV ?? "dev").trim().toLowerCase() || "dev";
  const errors: string[] = [];
  const warnings: string[] = [];
  const known = (SOULBAH_ENVS as readonly string[]).includes(raw);
  if (!known) {
    errors.push(`SOULBAH_ENV invalide « ${raw.slice(0, 40)} » (attendu : ${SOULBAH_ENVS.join(" | ")})`);
  }
  // Une valeur inconnue est traitée comme stricte (on ne relâche jamais par erreur de frappe).
  const strict = !known || (raw !== "dev" && raw !== "test");

  const iaToken = (env.IA_SERVICE_TOKEN ?? "").trim();
  const dbSsl = (env.DATABASE_SSL ?? "").trim().toLowerCase() === "true";
  const ca = (env.PG_SSL_CA ?? "").trim();

  if (!iaToken) {
    if (strict) errors.push("IA_SERVICE_TOKEN est obligatoire hors dev/test (jeton partagé node-api → python-ia)");
    else warnings.push("IA_SERVICE_TOKEN vide : les appels à python-ia ne sont pas authentifiés (toléré en dev/test)");
  }
  if (dbSsl && !ca) {
    if (strict) errors.push("PG_SSL_CA est obligatoire hors dev/test quand DATABASE_SSL=true (vérification TLS)");
    else warnings.push("DATABASE_SSL=true sans PG_SSL_CA : certificat Postgres non vérifié (toléré en dev/test)");
  }
  if (ca && !fileReadable(ca)) errors.push(`PG_SSL_CA illisible : ${ca.slice(0, 200)}`);

  // Jetons d'approbation HMAC (LOT 6) : secret stable obligatoire hors dev/test.
  const approvalSecret = (env.SOULBAH_APPROVAL_SECRET ?? "").trim();
  if (approvalSecret && approvalSecret.length < 32) {
    errors.push("SOULBAH_APPROVAL_SECRET trop court (≥ 32 caractères) : node -e \"console.log(require('crypto').randomBytes(32).toString('hex'))\"");
  } else if (!approvalSecret) {
    if (strict) errors.push("SOULBAH_APPROVAL_SECRET est obligatoire hors dev/test (jetons d'approbation HMAC liés au payload)");
    else warnings.push("SOULBAH_APPROVAL_SECRET vide : secret d'approbation ÉPHÉMÈRE par processus (toléré en dev/test)");
  }

  // AUTH_MODE (LOT 3) : dev-local = jeton de dev partagé à la place de Supabase. Jamais hors
  // dev/test, jamais exposé au-delà de la boucle locale, jamais avec un jeton faible.
  const authMode = (env.AUTH_MODE ?? "supabase").trim().toLowerCase() || "supabase";
  if (!(AUTH_MODES as readonly string[]).includes(authMode)) {
    errors.push(`AUTH_MODE invalide « ${authMode.slice(0, 40)} » (attendu : ${AUTH_MODES.join(" | ")})`);
  } else if (authMode === "dev-local") {
    if (strict) errors.push("AUTH_MODE=dev-local est interdit hors dev/test (jeton de dev partagé, aucune vérification Supabase)");
    const listenHost = (env.HOST ?? "").trim() || "127.0.0.1";
    if (!isLoopbackHost(listenHost)) {
      errors.push(`AUTH_MODE=dev-local exige HOST en boucle locale (127.0.0.1, localhost ou ::1), pas « ${listenHost.slice(0, 60)} »`);
    }
    const devToken = (env.DEV_LOCAL_TOKEN ?? "").trim();
    if (devToken.length < DEV_LOCAL_TOKEN_MIN_LENGTH) {
      errors.push(
        `DEV_LOCAL_TOKEN absent ou trop court (≥ ${DEV_LOCAL_TOKEN_MIN_LENGTH} caractères) : ` +
          "généré par scripts/dev_db/dev_db.sh seed, ou node -e \"console.log(require('crypto').randomBytes(32).toString('hex'))\"",
      );
    }
    if (!UUID_RE.test((env.DEV_LOCAL_USER_ID ?? "").trim())) {
      errors.push("DEV_LOCAL_USER_ID doit être l'uuid de l'utilisateur de dev (créé par scripts/dev_db/dev_db.sh seed)");
    }
    warnings.push("AUTH_MODE=dev-local : vérification Supabase des JWT DÉSACTIVÉE — un seul utilisateur de dev, boucle locale uniquement");
  }

  // TLS Postgres (S13) — jamais de DATABASE_URL dans les messages (mot de passe).
  const dbUrl = (env.DATABASE_URL ?? "").trim() || DEFAULT_DATABASE_URL;
  const sslParams = databaseUrlSslParams(dbUrl);
  if (sslParams.length > 0) {
    // pg laisse ces paramètres ÉCRASER l'option ssl explicite (sslmode=no-verify coupe la
    // vérification malgré PG_SSL_CA ; sslmode=require perd la CA).
    if (strict) {
      errors.push(
        `DATABASE_URL contient des paramètres TLS (${sslParams.join(", ")}) qui écrasent DATABASE_SSL/PG_SSL_CA : ` +
          "retirez-les, le TLS se configure uniquement par DATABASE_SSL=true + PG_SSL_CA",
      );
    } else if (dbSsl && ca && stripDatabaseUrlSslParams(dbUrl) !== dbUrl) {
      warnings.push(`paramètres TLS de DATABASE_URL (${sslParams.join(", ")}) ignorés : DATABASE_SSL/PG_SSL_CA font foi`);
    } else {
      warnings.push(`DATABASE_URL contient des paramètres TLS (${sslParams.join(", ")}) : ils priment sur DATABASE_SSL (toléré en dev/test)`);
    }
  }
  const host = databaseHost(dbUrl);
  if (strict && !dbSsl && !isLocalDbHost(host)) {
    errors.push(
      "DATABASE_SSL=true est obligatoire hors dev/test pour une base distante (connexion Postgres en clair sinon)",
    );
  }

  if (strict && !(env.SUPABASE_URL ?? "").trim()) {
    warnings.push("SUPABASE_URL vide : toutes les routes JWT répondront 503");
  }
  if (strict && (env.HOST ?? "").trim() === "0.0.0.0" && !(env.TRUST_PROXY ?? "").trim()) {
    warnings.push("HOST=0.0.0.0 sans TRUST_PROXY : derrière un proxy, la limitation de débit verra l'IP du proxy");
  }
  return { soulbahEnv: raw, strict, errors, warnings };
}

/** Valeur par défaut de config.databaseUrl (Postgres du docker-compose). */
export const DEFAULT_DATABASE_URL = "postgres://soulbah:soulbah@postgres:5432/soulbah";

/** Paramètres de la chaîne de connexion que pg interprète comme configuration TLS. */
function isSslParam(name: string): boolean {
  const n = name.toLowerCase();
  return n.startsWith("ssl") || n === "uselibpqcompat";
}

interface ParsedDbUrl {
  /** Hôte effectif (paramètre `host` prioritaire, comme pg) ; "" = socket local. */
  host: string;
  params: URLSearchParams;
  /** Chaîne telle que pg la lit (espaces / % invalides encodés). */
  normalized: string;
  /** Partie « ?query#hash » de `normalized` si elle a pu être délimitée. */
  tail?: string;
}

/**
 * Analyse DATABASE_URL EXACTEMENT comme pg-connection-string (paramètres de la query
 * string, `host` en paramètre prioritaire, socket Unix). null si illisible.
 */
export function parseDatabaseUrl(url: string): ParsedDbUrl | null {
  if (url.charAt(0) === "/") return { host: url.split(" ")[0], params: new URLSearchParams(), normalized: url };
  let str = url;
  if (/ |%[^a-f0-9]|%[a-f0-9][^a-f0-9]/i.test(str)) str = encodeURI(str).replace(/%25(\d\d)/g, "%$1");
  let u: URL;
  let dummyHost = false;
  try {
    try {
      u = new URL(str, "postgres://base");
    } catch {
      u = new URL(str.replace("@/", "@___DUMMY___/"), "postgres://base");
      dummyHost = true;
    }
  } catch {
    return null;
  }
  const params = u.searchParams;
  let host: string;
  if (u.protocol === "socket:") host = "/";
  else {
    const fromUrl = (dummyHost ? "" : u.hostname).replace(/^\[(.+)\]$/, "$1");
    try {
      host = params.get("host") ?? decodeURIComponent(fromUrl);
    } catch {
      host = params.get("host") ?? fromUrl;
    }
  }
  const tailStr = `${u.search}${u.hash}`;
  const tail = tailStr && str.endsWith(tailStr) ? tailStr : undefined;
  return { host: host.toLowerCase(), params, normalized: str, tail };
}

/** Noms des paramètres TLS présents dans DATABASE_URL (sslmode, ssl, sslrootcert…). */
export function databaseUrlSslParams(url: string): string[] {
  const p = parseDatabaseUrl(url);
  if (!p) return [];
  return [...new Set([...p.params.keys()].filter(isSslParam).map((k) => k.toLowerCase()))];
}

/**
 * DATABASE_URL sans ses paramètres TLS (quand PG_SSL_CA fait foi). Si la query string ne
 * peut pas être délimitée sans ambiguïté, la chaîne est renvoyée intacte (le garde-fou
 * de démarrage refuse alors ces paramètres hors dev/test).
 */
export function stripDatabaseUrlSslParams(url: string): string {
  const p = parseDatabaseUrl(url);
  if (!p || p.tail === undefined) return url;
  const keys = [...p.params.keys()];
  if (!keys.some(isSslParam)) return url;
  const kept = new URLSearchParams();
  for (const [k, v] of p.params) if (!isSslParam(k)) kept.append(k, v);
  const q = kept.toString();
  const hashIdx = p.tail.indexOf("#");
  const hash = hashIdx === -1 ? "" : p.tail.slice(hashIdx);
  return `${p.normalized.slice(0, p.normalized.length - p.tail.length)}${q ? `?${q}` : ""}${hash}`;
}

/** Hôte effectif de DATABASE_URL ; null si illisible. */
export function databaseHost(url: string): string | null {
  return parseDatabaseUrl(url)?.host ?? null;
}

/**
 * Hôte « local » (pas de TLS exigé) : boucle locale, socket Unix, ou nom de service sans
 * point (réseau docker-compose : « postgres », « db »). Tout autre hôte (domaine, IP non
 * locale, pooler Supabase) est distant ; un hôte illisible est traité comme distant.
 */
export function isLocalDbHost(host: string | null): boolean {
  if (host === null) return false;
  if (host === "" || host.startsWith("/")) return true;
  if (host === "localhost" || host === "::1" || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host)) return true;
  return /^[a-z0-9_-]+$/i.test(host) && !/^\d+$/.test(host);
}

function defaultFileReadable(p: string): boolean {
  try {
    fs.accessSync(p, fs.constants.R_OK);
    return true;
  } catch {
    return false;
  }
}
