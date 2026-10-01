import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, ReactNode } from "react";
import { supabase } from "@/integrations/supabase/client";
import { sessionChanged } from "@/lib/authState";
import { notifyServerLogout } from "@/lib/agentApi";
import type { User, Session } from "@supabase/supabase-js";

interface AuthContextType {
  user: User | null;
  session: Session | null;
  loading: boolean;
  signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthContextType>({
  user: null,
  session: null,
  loading: true,
  signOut: async () => {},
});

export const AuthProvider = ({ children }: { children: ReactNode }) => {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const sessionRef = useRef<Session | null>(null);

  useEffect(() => {
    let active = true;

    // Ne remplace l'état que si la session a réellement changé (utilisateur ou jeton) :
    // Supabase réémet SIGNED_IN à chaque retour sur l'onglet avec de nouveaux objets.
    const apply = (next: Session | null) => {
      if (!active) return;
      if (sessionChanged(sessionRef.current, next)) {
        sessionRef.current = next;
        setSession(next);
      }
      setLoading(false);
    };

    // Le client Supabase (voir integrations/supabase/client.ts, autoRefreshToken: true)
    // rafraîchit déjà le token tout seul en tâche de fond. Ne PAS dupliquer cette
    // logique ici : le refresh token est à usage unique (rotatif) — deux
    // rafraîchissements concurrents font échouer le second, qui provoquait ici une
    // déconnexion globale immédiate (bug corrigé : voir historique).
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, currentSession) => {
      apply(currentSession);
    });

    supabase.auth
      .getSession()
      .then(({ data: { session: cached } }) => apply(cached))
      .catch((err) => {
        console.error("[Auth] Impossible de lire la session :", err);
        apply(null);
      });

    return () => {
      active = false;
      subscription.unsubscribe();
    };
  }, []);

  const signOut = useCallback(async () => {
    // Invalide d'abord le cache JWT du backend (S26) ; les erreurs sont ignorées.
    await notifyServerLogout();
    await supabase.auth.signOut();
  }, []);

  const user = session?.user ?? null;
  const value = useMemo(() => ({ user, session, loading, signOut }), [user, session, loading, signOut]);

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
};

// eslint-disable-next-line react-refresh/only-export-components
export const useAuth = () => useContext(AuthContext);
