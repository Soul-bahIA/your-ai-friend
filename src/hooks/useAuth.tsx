import { createContext, useContext, useEffect, useState, useRef, ReactNode } from "react";
import { supabase } from "@/integrations/supabase/client";
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
  const [user, setUser] = useState<User | null>(null);
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const refreshTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const scheduleRefresh = (sess: Session) => {
    if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
    if (!sess.expires_at) return;

    // Refresh 60 seconds before expiry
    const expiresInMs = (sess.expires_at * 1000) - Date.now() - 60_000;
    const delay = Math.max(expiresInMs, 5_000); // min 5s

    console.log("[Auth] Scheduling token refresh in", Math.round(delay / 1000), "s");
    refreshTimerRef.current = setTimeout(async () => {
      console.log("[Auth] Auto-refreshing token...");
      const { data, error } = await supabase.auth.refreshSession();
      if (error || !data.session) {
        console.error("[Auth] Auto-refresh failed:", error);
        await supabase.auth.signOut();
      }
      // onAuthStateChange will handle the state update
    }, delay);
  };

  useEffect(() => {
    // Listen for auth changes FIRST
    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      (event, currentSession) => {
        console.log("[Auth] Event:", event);

        if (event === "SIGNED_OUT") {
          setSession(null);
          setUser(null);
          setLoading(false);
          if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
          return;
        }

        if (currentSession) {
          setSession(currentSession);
          setUser(currentSession.user);
          setLoading(false);
          scheduleRefresh(currentSession);
        }
      }
    );

    // Then initialize: always try refresh first to get a fresh token
    const initSession = async () => {
      try {
        const { data: { session: cached } } = await supabase.auth.getSession();

        if (!cached) {
          // No session at all
          setLoading(false);
          return;
        }

        // Always refresh to get a valid token
        const { data, error } = await supabase.auth.refreshSession();
        if (error || !data.session) {
          console.warn("[Auth] Refresh failed, clearing session:", error?.message);
          await supabase.auth.signOut();
          setLoading(false);
          return;
        }

        // onAuthStateChange will set the state
      } catch (err) {
        console.error("[Auth] Init error:", err);
        setLoading(false);
      }
    };

    initSession();

    return () => {
      subscription.unsubscribe();
      if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
    };
  }, []);

  const signOut = async () => {
    if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
    await supabase.auth.signOut();
  };

  return (
    <AuthContext.Provider value={{ user, session, loading, signOut }}>
      {children}
    </AuthContext.Provider>
  );
};

export const useAuth = () => useContext(AuthContext);
