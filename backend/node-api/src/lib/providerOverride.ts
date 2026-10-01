// Surcharge du fournisseur LLM par un client (champ `provider`) — S32.
// Seuls les fournisseurs listés dans LLM_ALLOWED_OVERRIDES sont acceptés ; vide = aucun.
import type { Result } from "./agentSteps.js";

/** undefined/null/"" → pas de surcharge ; sinon le fournisseur doit être dans l'allowlist (→ 400). */
export function checkProviderOverride(v: unknown, allowed: readonly string[]): Result<string | undefined> {
  if (v === undefined || v === null || v === "") return { ok: true, value: undefined };
  if (typeof v !== "string" || v.length > 40) return { ok: false, error: "provider invalide" };
  const p = v.trim().toLowerCase();
  if (!allowed.includes(p)) {
    return {
      ok: false,
      error: allowed.length
        ? `provider non autorisé (autorisés : ${allowed.join(", ")})`
        : "le choix du fournisseur IA n'est pas autorisé sur ce serveur",
    };
  }
  return { ok: true, value: p };
}
