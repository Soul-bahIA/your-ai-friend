// Traduction des statuts HTTP du service python-ia vers des statuts côté API publique.
// Un 401/403 amont ne doit JAMAIS être relayé tel quel : le frontend croirait que la
// session de l'utilisateur a expiré.

export interface MappedUpstream {
  status: number;
  message: string;
  /** vrai si le détail amont peut être montré au client (erreur de validation). */
  exposeDetail: boolean;
}

export function mapUpstreamStatus(upstream: number): MappedUpstream {
  if (upstream === 429) return { status: 429, message: "Service IA saturé, réessayez dans quelques instants", exposeDetail: false };
  if (upstream === 402) return { status: 402, message: "Crédits du fournisseur IA épuisés", exposeDetail: false };
  if (upstream === 400 || upstream === 422) return { status: 422, message: "Requête refusée par le service IA", exposeDetail: true };
  if (upstream === 503) return { status: 503, message: "Service IA temporairement indisponible", exposeDetail: false };
  if (upstream === 504) return { status: 504, message: "Le service IA n'a pas répondu à temps", exposeDetail: false };
  // 401/403 (jeton inter-services), 404, 5xx… → passerelle défaillante.
  return { status: 502, message: "Erreur du service IA", exposeDetail: false };
}
