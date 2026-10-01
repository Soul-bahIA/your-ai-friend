// Contexte de la requête HTTP courante, propagé à travers les await (AsyncLocalStorage) :
// permet aux services appelés en profondeur (client python-ia, métrage) d'attribuer leur
// travail à l'utilisateur authentifié (JWT ou clé agent) sans passer la requête partout.
// Installé par app.ts (hook onRequest). Hors requête (démarrage, reaper), le store est vide.
import { AsyncLocalStorage } from "node:async_hooks";
import type { FastifyRequest } from "fastify";

export const requestStore = new AsyncLocalStorage<FastifyRequest>();

/** Requête en cours de traitement, ou undefined hors requête. */
export function currentRequest(): FastifyRequest | undefined {
  return requestStore.getStore();
}

/** Utilisateur de la requête courante : JWT (request.user) ou propriétaire de la clé agent. */
export function currentUserId(): string | undefined {
  const req = currentRequest();
  return req?.user?.id ?? req?.agentUserId;
}
