// Poignée de main de version runtime ↔ plan de contrôle (LOT 8). Le runtime annonce sa
// version semver et le numéro de protocole des routes /api/v2/runtime ; un runtime trop ancien
// ou d'un autre protocole est refusé (426 Upgrade Required) AVANT tout bail.
export const RUNTIME_PROTOCOL = 1;

export interface Semver {
  major: number;
  minor: number;
  patch: number;
}

export function parseSemver(v: unknown): Semver | null {
  if (typeof v !== "string") return null;
  const m = /^v?(\d{1,6})\.(\d{1,6})\.(\d{1,6})(?:[-+][0-9A-Za-z.+-]{0,100})?$/.exec(v.trim());
  if (!m) return null;
  return { major: Number(m[1]), minor: Number(m[2]), patch: Number(m[3]) };
}

export function compareSemver(a: Semver, b: Semver): number {
  return a.major - b.major || a.minor - b.minor || a.patch - b.patch;
}

export type Compatibility = { ok: true } | { ok: false; reason: string };

/** Compatibilité d'un runtime : protocole identique et version ≥ minimum configuré. */
export function checkRuntimeCompatibility(input: { version: unknown; protocol: unknown; minVersion: string }): Compatibility {
  if (input.protocol !== RUNTIME_PROTOCOL) {
    return { ok: false, reason: `protocole ${String(input.protocol ?? "absent")} non pris en charge (attendu : ${RUNTIME_PROTOCOL})` };
  }
  const v = parseSemver(input.version);
  if (!v) return { ok: false, reason: "version du runtime absente ou invalide (semver attendu)" };
  const min = parseSemver(input.minVersion) ?? { major: 0, minor: 0, patch: 0 };
  if (compareSemver(v, min) < 0) return { ok: false, reason: `runtime ${String(input.version)} trop ancien (minimum ${input.minVersion})` };
  return { ok: true };
}
