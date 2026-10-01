import fs from "node:fs";
import pg from "pg";
import { config } from "./config";
import { logger } from "./lib/logger";

const { Pool } = pg;

export type Queryable = Pick<pg.PoolClient, "query">;

/**
 * TLS vers Postgres :
 *  - DATABASE_SSL=true + PG_SSL_CA=/chemin/ca.pem → vérification stricte du certificat.
 *  - DATABASE_SSL=true sans CA → chiffré mais SANS vérification (avertissement unique).
 *  - sinon : pas de TLS (Postgres local / docker).
 */
function buildSsl(): pg.PoolConfig["ssl"] {
  if (!config.databaseSsl) return undefined;
  if (config.pgSslCa) {
    return { rejectUnauthorized: true, ca: fs.readFileSync(config.pgSslCa, "utf8") };
  }
  console.warn(
    "[pg] DATABASE_SSL=true sans PG_SSL_CA : connexion chiffrée mais certificat serveur NON vérifié " +
      "(définissez PG_SSL_CA avec le certificat CA de Supabase pour activer la vérification).",
  );
  return { rejectUnauthorized: false };
}

// Pool de connexions PostgreSQL partagé par toute l'application.
export const pool = new Pool({
  connectionString: config.databaseUrl,
  ssl: buildSsl(),
  max: 10,
  connectionTimeoutMillis: 5_000, // DB injoignable → échec rapide (pas de requête pendue)
  idleTimeoutMillis: 30_000,
  statement_timeout: config.pgStatementTimeoutMs, // côté serveur
  query_timeout: config.pgStatementTimeoutMs + 5_000, // côté client (filet de sécurité)
});

// Le pooler Supabase ferme les connexions inactives. Sans ce gestionnaire, l'erreur
// émise sur un client au repos remonte comme exception non gérée et tue le process.
pool.on("error", (err) => {
  logger.warn({ err: err.message }, "[pg] erreur sur une connexion inactive (ignorée)");
});

let dbReady = false;
export function isDbReady(): boolean {
  return dbReady;
}

/** Vérifie la connectivité. */
export async function initDb(): Promise<void> {
  await pool.query("SELECT 1");
  dbReady = true;
}

/** Exécute `fn` dans une transaction (BEGIN/COMMIT, ROLLBACK en cas d'erreur). */
export async function withTransaction<T>(fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (e) {
    await client.query("ROLLBACK").catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}
