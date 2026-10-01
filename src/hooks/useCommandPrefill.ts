import { useEffect, useRef } from "react";
import { useLocation, useNavigate } from "react-router-dom";

/**
 * Récupère la demande passée par la barre de commande universelle
 * (navigate(target, { state: { commandPrompt } })) et l'applique au champ de la page.
 * Nettoie ensuite l'état d'historique (via le routeur, pour rester synchronisé)
 * afin qu'un rafraîchissement ne re-préremplisse pas.
 */
export function useCommandPrefill(apply: (prompt: string) => void) {
  const location = useLocation();
  const navigate = useNavigate();
  const applyRef = useRef(apply);
  applyRef.current = apply;

  useEffect(() => {
    const prompt = (location.state as { commandPrompt?: string } | null)?.commandPrompt;
    if (prompt) {
      applyRef.current(prompt);
      navigate(location.pathname + location.search, { replace: true, state: null });
    }
  }, [location.state, location.pathname, location.search, navigate]);
}
