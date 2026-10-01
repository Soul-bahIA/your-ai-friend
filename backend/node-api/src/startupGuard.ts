// Importé EN PREMIER par server.ts : les imports ESM s'évaluent dans l'ordre, donc ce
// contrôle s'exécute avant la création du pool Postgres (db.ts) et des routes.
// Hors dev/test, une configuration dangereuse empêche le démarrage (exit 1).
import { checkStartupEnv } from "./lib/envChecks.js";

const result = checkStartupEnv(process.env);
for (const w of result.warnings) console.warn(`[démarrage] avertissement (${result.soulbahEnv}) : ${w}`);
if (result.errors.length > 0) {
  for (const e of result.errors) console.error(`[démarrage] ERREUR (${result.soulbahEnv}) : ${e}`);
  console.error("[démarrage] node-api refuse de démarrer : corrigez la configuration (voir backend/.env.example).");
  process.exit(1);
}

export const startupEnv = result;
