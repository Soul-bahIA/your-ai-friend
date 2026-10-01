// Dossier des médias produits par python-ia (MP4/PDF), servis sous /media/.
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config } from "../config.js";

/** MEDIA_DIR, sinon backend/media (src/lib et dist/lib sont au même niveau). */
export function resolveMediaDir(): string {
  const here = path.dirname(fileURLToPath(import.meta.url)); // <node-api>/{src,dist}/lib
  return path.resolve(config.mediaDir || path.join(here, "..", "..", "..", "media"));
}
