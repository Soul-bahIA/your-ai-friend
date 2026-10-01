import type { Session } from "@supabase/supabase-js";

/**
 * Indique si une nouvelle session Supabase diffère réellement de la précédente.
 * Supabase émet SIGNED_IN / TOKEN_REFRESHED à chaque retour sur l'onglet avec de
 * NOUVEAUX objets : sans cette comparaison, tous les effets dépendant de
 * user/session se relanceraient (refetch, ré-abonnements temps réel...).
 */
export function sessionChanged(prev: Session | null, next: Session | null): boolean {
  if (prev === next) return false;
  if (!prev || !next) return true;
  return (
    prev.access_token !== next.access_token ||
    prev.user?.id !== next.user?.id ||
    prev.user?.updated_at !== next.user?.updated_at
  );
}
