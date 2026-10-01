// Générations en cours DANS CE PROCESSUS (ids de formations/applications).
// La récupération des générations bloquées les exclut : seules les lignes dont le
// travail a été perdu (crash/redémarrage) passent en 'Erreur'.
export const activeGenerations = new Set<string>();
