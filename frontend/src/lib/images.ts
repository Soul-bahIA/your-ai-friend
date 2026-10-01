// Images reçues de l'agent (captures d'écran) : pur, sans dépendance réseau.

// Types autorisés : jamais de SVG/HTML (exécutables) dans une data URL.
const SAFE_IMAGE_TYPES = new Set(["image/jpeg", "image/png", "image/webp", "image/gif"]);
const BASE64_RE = /^[A-Za-z0-9+/=\r\n]+$/;

/** Construit une data URL d'image sûre (type d'image autorisé, base64 valide), sinon null. */
export function toImageDataUrl(b64: unknown, mime?: unknown): string | null {
  if (typeof b64 !== "string" || !b64 || !BASE64_RE.test(b64)) return null;
  const type = typeof mime === "string" && SAFE_IMAGE_TYPES.has(mime) ? mime : "image/jpeg";
  return `data:${type};base64,${b64}`;
}
