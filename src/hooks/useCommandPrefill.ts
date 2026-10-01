import { useEffect } from "react";
import { useLocation } from "react-router-dom";

/**
 * Récupère la demande passée par la barre de commande universelle
 * (navigate(target, { state: { commandPrompt } })) et l'applique au champ de la page.
 * Nettoie ensuite l'état d'historique pour qu'un rafraîchissement ne re-préremplisse pas.
 */
export function useCommandPrefill(apply: (prompt: string) => void) {
  const location = useLocation();
  useEffect(() => {
    const prompt = (location.state as { commandPrompt?: string } | null)?.commandPrompt;
    if (prompt) {
      apply(prompt);
      window.history.replaceState({}, "");
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [location.state]);
}
