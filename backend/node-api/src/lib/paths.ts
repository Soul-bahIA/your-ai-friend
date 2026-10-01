// Contrôle (approximatif, côté serveur) qu'un chemin est dans un dossier autorisé.
// L'agent reste l'autorité (realpath, liens) ; le serveur refuse tôt ce qui serait refusé.
import path from "node:path";

const WIN_ABS = /^[a-zA-Z]:[\\/]/;
const UNC = /^\\\\[^\\]/;

function flavor(p: string): "win" | "posix" | null {
  if (WIN_ABS.test(p) || UNC.test(p)) return "win";
  if (p.startsWith("/")) return "posix";
  return null; // relatif ou sans lecteur : refusé
}

/** Vrai si `p` est un chemin absolu (Windows avec lecteur/UNC, ou POSIX). */
export function isAbsoluteAnyOs(p: string): boolean {
  return flavor(p) !== null;
}

/** Vrai si `p` (absolu) est `dir` ou l'un de ses descendants. Insensible à la casse sous Windows. */
export function isPathInside(p: string, dir: string): boolean {
  if (typeof p !== "string" || typeof dir !== "string" || !p || !dir) return false;
  if (p.includes("\0") || dir.includes("\0")) return false;
  const fp = flavor(p);
  const fd = flavor(dir);
  if (!fp || fp !== fd) return false;
  const mod = fp === "win" ? path.win32 : path.posix;
  let rp = mod.resolve(p);
  let rd = mod.resolve(dir);
  if (fp === "win") {
    rp = rp.toLowerCase();
    rd = rd.toLowerCase();
  }
  const rel = mod.relative(rd, rp);
  if (rel === "") return true;
  return rel !== ".." && !rel.startsWith(`..${mod.sep}`) && !mod.isAbsolute(rel);
}

/** Vrai si `p` est à l'intérieur de l'un des dossiers autorisés. */
export function isPathAllowed(p: string, allowedDirs: readonly string[]): boolean {
  return allowedDirs.some((d) => isPathInside(p, d));
}
