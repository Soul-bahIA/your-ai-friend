// Point d'entrée : contrôles d'environnement (EN PREMIER), application, écoute, DB,
// maintenance et reaper. `npm start` (tsx, dev) ou `npm run start:prod` (node dist/).
import { startupEnv } from "./startupGuard.js";
import { config } from "./config.js";
import { initDb, pool } from "./db.js";
import { setLogger } from "./lib/logger.js";
import { SECRET_LABEL, redactingLogger } from "./v2/security/redactSecrets.js";
import { buildApp } from "./app.js";
import { runMaintenance } from "./services/maintenance.js";
import { reapStaleTasks } from "./services/reaper.js";
import { auditSchedulerError, tick, tickSummary } from "./v2/scheduler/scheduler.js";
import { runEvaluations } from "./v2/evaluation/engine.js";
import { runReviews } from "./v2/evaluation/reviewer.js";
import { runContentTasks } from "./v2/planner/contentRunner.js";
import { defaultRubricJudge } from "./v2/evaluation/judge.js";
import { drainBackgroundJobs } from "./services/backgroundJobs.js";
import { currentSettings } from "./lib/soulbahSettings.js";

// Journaux : en-têtes d'authentification rédigés par pino ; objets et messages des services
// rédigés par redactingLogger (LOT 6 : aucun secret dans les journaux).
const app = await buildApp({
  logger: {
    redact: {
      paths: ['req.headers.authorization', 'req.headers["x-agent-key"]', 'req.headers["x-ia-token"]', 'req.headers.cookie'],
      censor: SECRET_LABEL,
    },
  },
});
setLogger(redactingLogger(app.log));

// --- Base de données : non bloquante au démarrage ---
// Si Postgres est injoignable, l'API démarre quand même (santé, routes sans DB) et
// réessaie périodiquement ; dès que la DB répond : contrôle du schéma, maintenance, reaper.
const DB_RETRY_MS = 30_000;
const MAINTENANCE_MS = 60 * 60 * 1000;
let dbRetryTimer: NodeJS.Timeout | undefined;
let maintenanceTimer: NodeJS.Timeout | undefined;
let reaperTimer: NodeJS.Timeout | undefined;
let schedulerTimer: NodeJS.Timeout | undefined;

/** Colonnes ajoutées par supabase/migrations/20261001090000_lot1_fixes.sql (ciblage d'un PC). */
const LOT1_COLUMNS = ["target_agent_key_id", "claimed_by_key_id"];

async function checkSchema(): Promise<void> {
  const { rows } = await pool.query(
    `SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'agent_tasks' AND column_name = ANY($1::text[])`,
    [LOT1_COLUMNS],
  );
  const present = new Set(rows.map((r) => r.column_name as string));
  const missing = LOT1_COLUMNS.filter((c) => !present.has(c));
  if (missing.length > 0) {
    app.log.error(
      { missing },
      "schéma agent_tasks incomplet : appliquez supabase/migrations/20261001090000_lot1_fixes.sql (poll/claim/création échoueront)",
    );
  }
}

function runReaper(): void {
  reapStaleTasks().catch((e) => app.log.warn({ err: (e as Error).message }, "reaper : échec (nouvel essai au prochain tick)"));
}

// Scheduler V2 (LOT 7) : promotion READY, backoff, escalade, reaper des baux, clôture des sessions.
// LOT 10 : puis relectures QA exécutées par P1 et évaluations restées en VALIDATING. Après une
// coupure de la base (tick en échec) ou au démarrage, le reaper attend une durée de bail complète
// pour laisser les runtimes prolonger leurs baux (0 doublon).
let schedulerBusy = false;
let schedulerFailing = false;
let reapNotBefore: Date | null = null;
function runScheduler(): void {
  if (schedulerBusy) return;
  schedulerBusy = true;
  tick({ tryLock: true, reapNotBefore })
    .then(async (r) => {
      if (schedulerFailing) {
        schedulerFailing = false;
        reapNotBefore = new Date(Date.now() + config.v2LeaseSeconds * 1000);
        app.log.warn({ reapNotBefore }, "scheduler V2 : base de nouveau joignable — baux non récupérés avant une durée de bail");
      }
      const summary = tickSummary(r);
      if (summary) app.log.info({ scheduler: r }, `scheduler V2 : ${summary}`);
      // LOT 11 : rédaction par P1 (modules de formation en parallèle) — sans attendre le tick suivant.
      void runContentTasks().catch((e) => app.log.warn({ err: (e as Error).message }, "rédaction V2 : échec"));
      const reviews = await runReviews({ judge: defaultRubricJudge });
      const evals = await runEvaluations({ judge: defaultRubricJudge });
      if (reviews.reviewed || evals.evaluated || reviews.errors || evals.errors) app.log.info({ reviews, evals }, "évaluations V2");
    })
    .catch((e) => {
      schedulerFailing = true;
      void auditSchedulerError(e as Error);
    })
    .finally(() => {
      schedulerBusy = false;
    });
}

async function connectDb(): Promise<void> {
  try {
    await initDb();
    app.log.info("PostgreSQL joignable");
    await checkSchema().catch((e) => app.log.warn({ err: (e as Error).message }, "contrôle du schéma impossible"));
    await runMaintenance(); // générations bloquées → 'Erreur', purge des évènements et médias
    maintenanceTimer = setInterval(() => void runMaintenance(), MAINTENANCE_MS);
    maintenanceTimer.unref();
    runReaper();
    reaperTimer = setInterval(runReaper, Math.max(10, config.reaperIntervalSeconds) * 1000);
    reaperTimer.unref();
    // Au démarrage de node, aucun runtime n'a pu prolonger son bail pendant l'arrêt.
    reapNotBefore = new Date(Date.now() + config.v2LeaseSeconds * 1000);
    runScheduler();
    schedulerTimer = setInterval(runScheduler, config.schedulerIntervalSeconds * 1000);
    schedulerTimer.unref();
  } catch (err) {
    app.log.warn(
      { err: (err as Error).message },
      `PostgreSQL injoignable — l'API démarre en mode dégradé, nouvel essai dans ${DB_RETRY_MS / 1000} s`,
    );
    dbRetryTimer = setTimeout(() => void connectDb(), DB_RETRY_MS);
    dbRetryTimer.unref();
  }
}

// --- Arrêt propre : plus de nouvelles requêtes, tâches de fond terminées, pool fermé ---
let shuttingDown = false;
async function shutdown(signal: string): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  app.log.info(`${signal} reçu — arrêt propre`);
  clearTimeout(dbRetryTimer);
  clearInterval(maintenanceTimer);
  clearInterval(reaperTimer);
  clearInterval(schedulerTimer);
  const force = setTimeout(() => process.exit(1), 15_000);
  force.unref();
  try {
    await app.close();
    if (!(await drainBackgroundJobs(10_000))) app.log.warn("tâches de fond encore actives à l'arrêt");
    await pool.end();
  } catch (err) {
    app.log.error(err);
  }
  process.exit(0);
}
process.on("SIGINT", () => void shutdown("SIGINT"));
process.on("SIGTERM", () => void shutdown("SIGTERM"));

try {
  await app.listen({ port: config.port, host: config.host });
  app.log.info(
    { corsOrigins: config.corsOrigins, env: startupEnv.soulbahEnv, trustProxy: config.trustProxy, mode: currentSettings().mode, maxAgents: config.maxParallelAgents },
    `node-api en écoute sur http://${config.host}:${config.port}`,
  );
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
void connectDb();
