// Garde-fous de démarrage selon SOULBAH_ENV (contrat LOT 1 §1). Fonction pure : testable.
import fs from "node:fs";

export const SOULBAH_ENVS = ["dev", "test", "staging", "production"] as const;
export type SoulbahEnv = (typeof SOULBAH_ENVS)[number];

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

  if (strict && !(env.SUPABASE_URL ?? "").trim()) {
    warnings.push("SUPABASE_URL vide : toutes les routes JWT répondront 503");
  }
  if (strict && (env.HOST ?? "").trim() === "0.0.0.0" && !(env.TRUST_PROXY ?? "").trim()) {
    warnings.push("HOST=0.0.0.0 sans TRUST_PROXY : derrière un proxy, la limitation de débit verra l'IP du proxy");
  }
  return { soulbahEnv: raw, strict, errors, warnings };
}

function defaultFileReadable(p: string): boolean {
  try {
    fs.accessSync(p, fs.constants.R_OK);
    return true;
  } catch {
    return false;
  }
}
