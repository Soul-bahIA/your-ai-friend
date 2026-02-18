import { createContext, useContext, useEffect, useState, ReactNode } from "react";
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

  useEffect(() => {
    // Set up auth state listener FIRST
    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      async (event, currentSession) => {
        console.log("[Auth] Event:", event);
        
        if (event === "TOKEN_REFRESHED") {
          console.log("[Auth] Token refreshed successfully");
        }
        
        if (event === "SIGNED_OUT") {
          setSession(null);
          setUser(null);
          setLoading(false);
          return;
        }

        setSession(currentSession);
        setUser(currentSession?.user ?? null);
        setLoading(false);
      }
    );

    // THEN check for existing session
    supabase.auth.getSession().then(({ data: { session: existingSession }, error }) => {
      if (error) {
        console.error("[Auth] Error getting session:", error);
        // Clear corrupted session
        supabase.auth.signOut();
        setLoading(false);
        return;
      }
      
      if (existingSession) {
        // Check if token is expired
        const expiresAt = existingSession.expires_at;
        const now = Math.floor(Date.now() / 1000);
        
        if (expiresAt && expiresAt < now) {
          console.log("[Auth] Session expired, attempting refresh...");
          supabase.auth.refreshSession().then(({ data, error: refreshError }) => {
            if (refreshError || !data.session) {
              console.error("[Auth] Refresh failed, signing out:", refreshError);
              supabase.auth.signOut();
            } else {
              console.log("[Auth] Session refreshed");
              setSession(data.session);
              setUser(data.session.user);
            }
            setLoading(false);
          });
          return;
        }
        
        setSession(existingSession);
        setUser(existingSession.user);
      }
      setLoading(false);
    });

    return () => subscription.unsubscribe();
  }, []);

  const signOut = async () => {
    await supabase.auth.signOut();
  };

  return (
    <AuthContext.Provider value={{ user, session, loading, signOut }}>
      {children}
    </AuthContext.Provider>
  );
};

export const useAuth = () => useContext(AuthContext);
