import pg from "pg";
import { config } from "./config";

const { Pool } = pg;

// Pool de connexions PostgreSQL partagé par toute l'application.
// Après migration, DATABASE_URL pointe vers le Postgres de Supabase (SSL requis).
export const pool = new Pool({
  connectionString: config.databaseUrl,
  ssl: config.databaseSsl ? { rejectUnauthorized: false } : undefined,
});

// Le pooler Supabase ferme les connexions inactives. Sans ce gestionnaire, l'erreur
// émise sur un client au repos remonte comme exception non gérée et tue le process.
// On la journalise : le pool recrée une connexion à la requête suivante.
pool.on("error", (err) => {
  console.error("[pg] erreur sur une connexion inactive (ignorée) :", err.message);
});

// Vérifie la connectivité au démarrage.
export async function initDb(): Promise<void> {
  await pool.query("SELECT 1");
}
