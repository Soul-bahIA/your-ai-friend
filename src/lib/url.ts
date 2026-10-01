/**
 * Assainit une URL de média contrôlée par l'utilisateur/le backend avant de
 * l'utiliser dans un href/src. N'autorise que :
 *  - les chemins relatifs du backend commençant par /media/ (préfixés par l'URL de l'API)
 *  - les URL absolues https://
 * Tout le reste (javascript:, data:, http:, //hote, chemins arbitraires...) renvoie null.
 */
export function sanitizeMediaUrl(url: unknown, apiBase: string): string | null {
  if (typeof url !== "string") return null;
  const value = url.trim();
  if (!value) return null;

  if (value.startsWith("/media/")) {
    // Refuse la remontée de répertoire et les caractères de contrôle.
    if (value.includes("..") || /[\s\\]/.test(value)) return null;
    return `${apiBase.replace(/\/+$/, "")}${value}`;
  }

  if (/^https:\/\//i.test(value)) {
    try {
      const parsed = new URL(value);
      return parsed.protocol === "https:" ? parsed.href : null;
    } catch {
      return null;
    }
  }

  return null;
}
