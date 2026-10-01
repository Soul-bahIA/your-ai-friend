// URL de base du backend Node (remplace les appels aux edge functions Supabase).
// Configurable via VITE_API_URL ; par défaut le backend local.
export const API_URL = (import.meta.env.VITE_API_URL ?? "http://localhost:3000").replace(/\/+$/, "");

export const apiUrl = (path: string) => `${API_URL}${path}`;

// En-têtes authentifiés (JWT Supabase) pour appeler le backend.
import { supabase } from "@/integrations/supabase/client";

export async function apiAuthHeaders(): Promise<Record<string, string>> {
  const { data: { session } } = await supabase.auth.getSession();
  const token = session?.access_token;
  if (!token) throw new Error("Session expirée. Veuillez vous reconnecter.");
  return { "Content-Type": "application/json", Authorization: `Bearer ${token}` };
}
