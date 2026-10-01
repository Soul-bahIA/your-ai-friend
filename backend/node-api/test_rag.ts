// Vérification manuelle (live) de la recherche sémantique RAG — PAS un test automatisé.
// Nécessite une DB joignable, OPENAI_API_KEY (embeddings) et un utilisateur EXISTANT
// (knowledge_base.user_id référence auth.users) :
//   RAG_TEST_USER_ID=<uuid d'un compte de test> npx tsx test_rag.ts
// Les entrées créées sont supprimées à la fin (uniquement celles créées par ce script).
import { knowledgeService } from "./src/services/knowledge";
import { pool } from "./src/db";
import { isUuid } from "./src/lib/sanitize";

const U = process.env.RAG_TEST_USER_ID ?? "";

async function main() {
  if (!isUuid(U)) {
    console.error("RAG_TEST_USER_ID (uuid d'un utilisateur existant) requis");
    process.exitCode = 2;
    return;
  }
  // Crée une connaissance sur la sécurité des mots de passe
  const e = await knowledgeService.create(U, {
    title: "Sécuriser un mot de passe (test RAG)",
    content:
      "Un bon mot de passe est long, unique, mêle lettres, chiffres et symboles. Utilisez un gestionnaire de mots de passe et activez la double authentification.",
    domain: "cybersecurite",
    confidence: 0.8,
  });
  try {
    const { rows } = await pool.query("SELECT embedding IS NOT NULL AS has_emb FROM knowledge_base WHERE id=$1", [e.id]);
    console.log("Embedding stocké :", rows[0].has_emb);

    // Recherche SÉMANTIQUE : aucune expression « mot de passe » — sens proche seulement
    const sem = await knowledgeService.search(U, { text: "comment protéger mes identifiants de connexion en ligne", limit: 3 });
    console.log("Recherche sémantique « protéger mes identifiants » :", sem.length, "résultat(s)");
    if (sem[0]) console.log("  → trouvé :", sem[0].title);

    // Recherche sans rapport → ne doit rien retourner (seuil de pertinence)
    const none = await knowledgeService.search(U, { text: "recette de cuisine tarte aux pommes", limit: 3 });
    console.log("Recherche hors sujet « tarte aux pommes » :", none.length, "résultat(s) (attendu 0)");
  } finally {
    await pool.query("DELETE FROM knowledge_base WHERE id = $1 AND user_id = $2", [e.id, U]);
    console.log("nettoyé : OK");
  }
}
main()
  .catch((err) => {
    console.error("ÉCHEC:", err.message);
    process.exitCode = 1;
  })
  .finally(() => pool.end());
