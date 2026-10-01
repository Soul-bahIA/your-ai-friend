// Tâches de fond SUIVIES : chaque travail lancé hors requête (évaluation d'objectif,
// génération de formation…) est attendu dans une promesse enregistrée, ses erreurs sont
// journalisées (jamais de rejet non géré) et l'arrêt propre les laisse se terminer.
import { logger } from "../lib/logger.js";

const running = new Set<Promise<void>>();

/** Lance `fn` en arrière-plan ; la promesse renvoyée ne rejette jamais. */
export function runInBackground(name: string, fn: () => Promise<unknown>): Promise<void> {
  const job: Promise<void> = (async () => {
    try {
      await fn();
    } catch (e) {
      logger.error({ job: name, err: (e as Error)?.message ?? String(e) }, "tâche de fond échouée");
    }
  })();
  running.add(job);
  void job.finally(() => running.delete(job));
  return job;
}

export function pendingBackgroundJobs(): number {
  return running.size;
}

/** Attend la fin des tâches de fond (au plus `timeoutMs`) — appelé à l'arrêt. */
export async function drainBackgroundJobs(timeoutMs: number): Promise<boolean> {
  if (running.size === 0) return true;
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<false>((resolve) => {
    timer = setTimeout(() => resolve(false), timeoutMs);
  });
  const done = Promise.allSettled([...running]).then(() => true as const);
  const ok = await Promise.race([done, timeout]);
  clearTimeout(timer);
  return ok;
}
