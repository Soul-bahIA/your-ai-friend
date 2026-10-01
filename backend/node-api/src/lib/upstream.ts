// Traduction des statuts HTTP du service python-ia vers des statuts côté API publique.
// Un 401/403 amont ne doit JAMAIS être relayé tel quel : le frontend croirait que la
// session de l'utilisateur a expiré.

export interface MappedUpstream {
  status: number;
  message: string;
  /**
   * Vrai si le détail amont peut être montré au client. Toujours faux depuis le LOT 1
   * (S23) : un 400/422 de python-ia peut relayer le texte d'erreur d'un fournisseur LLM
   * ou d'une exception interne. Le détail n'est que journalisé.
   */
  exposeDetail: boolean;
}

export function mapUpstreamStatus(upstream: number): MappedUpstream {
  if (upstream === 429) return { status: 429, message: "Service IA saturé, réessayez dans quelques instants", exposeDetail: false };
  if (upstream === 402) return { status: 402, message: "Crédits du fournisseur IA épuisés", exposeDetail: false };
  if (upstream === 400 || upstream === 422) return { status: 422, message: "Requête refusée par le service IA", exposeDetail: false };
  // 503 : aucun modèle capable (ex. vision), disjoncteurs ouverts, rust-compute absent.
  if (upstream === 503) return { status: 503, message: "Service IA temporairement indisponible", exposeDetail: false };
  if (upstream === 504) return { status: 504, message: "Le service IA n'a pas répondu à temps", exposeDetail: false };
  // 499 : traitement annulé côté python-ia (client parti / échéance) — jamais propagé tel quel.
  if (upstream === 499) return { status: 504, message: "Traitement IA interrompu (délai dépassé ou annulation)", exposeDetail: false };
  if (upstream === 413) return { status: 413, message: "Requête trop volumineuse pour le service IA", exposeDetail: false };
  // 502 amont : réponse du modèle tronquée ou invalide.
  if (upstream === 502) return { status: 502, message: "Réponse du service IA invalide ou tronquée", exposeDetail: false };
  // 401/403 (jeton inter-services), 404, 5xx… → passerelle défaillante.
  return { status: 502, message: "Erreur du service IA", exposeDetail: false };
}
