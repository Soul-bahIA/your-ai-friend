import { knowledgeService } from "./src/services/knowledge";
import { pool } from "./src/db";

const U = "00000000-0000-4000-8000-00000000ra01";

async function main() {
  // Crée une connaissance sur la sécurité des mots de passe
  const e = await knowledgeService.create(U, {
    title: "Sécuriser un mot de passe",
    content:
      "Un bon mot de passe est long, unique, mêle lettres, chiffres et symboles. Utilisez un gestionnaire de mots de passe et activez la double authentification.",
    domain: "cybersecurite",
    confidence: 0.8,
  });
  const { rows } = await pool.query("SELECT embedding IS NOT NULL AS has_emb FROM knowledge_base WHERE id=$1", [e.id]);
  console.log("Embedding stocké :", rows[0].has_emb);

  // Recherche SÉMANTIQUE : aucune expression « mot de passe » — sens proche seulement
  const sem = await knowledgeService.search(U, { text: "comment protéger mes identifiants de connexion en ligne", limit: 3 });
  console.log("Recherche sémantique « protéger mes identifiants » :", sem.length, "résultat(s)");
  if (sem[0]) console.log("  → trouvé :", sem[0].title);

  // Recherche sans rapport → ne doit rien retourner (seuil de pertinence)
  const none = await knowledgeService.search(U, { text: "recette de cuisine tarte aux pommes", limit: 3 });
  console.log("Recherche hors sujet « tarte aux pommes » :", none.length, "résultat(s) (attendu 0)");

  await pool.query("DELETE FROM knowledge_base WHERE user_id=$1", [U]);
  console.log("nettoyé : OK");
  process.exit(0);
}
main().catch((err) => { console.error("ÉCHEC:", err.message); process.exit(1); });
