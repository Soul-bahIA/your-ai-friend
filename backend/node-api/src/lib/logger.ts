// Logger partagé hors contexte de requête (services, tâches de fond).
// Par défaut la console ; server.ts branche le logger pino de Fastify au démarrage.

type LogFn = (obj: unknown, msg?: string) => void;
export interface SimpleLogger {
  info: LogFn;
  warn: LogFn;
  error: LogFn;
}

const consoleLogger: SimpleLogger = {
  info: (o, m) => console.log(m ?? "", o),
  warn: (o, m) => console.warn(m ?? "", o),
  error: (o, m) => console.error(m ?? "", o),
};

export let logger: SimpleLogger = consoleLogger;

export function setLogger(l: SimpleLogger): void {
  logger = l;
}
