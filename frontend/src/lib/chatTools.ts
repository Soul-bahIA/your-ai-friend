// Appels d'outils proposés par le modèle de chat (S12, contrat §10) :
// le navigateur ne les exécute JAMAIS automatiquement. Chaque appel devient une
// action « proposée » affichée dans une carte de confirmation ; seule une
// confirmation explicite produit la requête d'exécution (avec confirmed:true).
import type { PendingToolCall } from "@/lib/sse";

export const KNOWN_CHAT_TOOLS = ["create_formation", "create_application", "save_knowledge"] as const;
export type KnownChatTool = (typeof KNOWN_CHAT_TOOLS)[number];

export type ProposedActionStatus = "proposed" | "executing" | "done" | "failed" | "cancelled";

export interface ProposedAction {
  /** Identifiant local unique (carte de confirmation). */
  key: string;
  conversationId: string | null;
  name: string;
  args: Record<string, unknown>;
  /** Raison pour laquelle l'action ne peut pas être exécutée (outil inconnu, arguments invalides). */
  invalid: string | null;
  status: ProposedActionStatus;
  resultText?: string;
}

export interface ActionField {
  label: string;
  value: string;
}

export interface ActionDescription {
  title: string;
  fields: ActionField[];
}

const isRecord = (v: unknown): v is Record<string, unknown> =>
  !!v && typeof v === "object" && !Array.isArray(v);

export const isKnownChatTool = (name: string): name is KnownChatTool =>
  (KNOWN_CHAT_TOOLS as readonly string[]).includes(name);

const REQUIRED_ARGS: Record<KnownChatTool, string[]> = {
  create_formation: ["topic"],
  create_application: ["appName"],
  save_knowledge: ["title", "content"],
};

let seq = 0;

/**
 * Transforme les appels d'outils reçus en flux en actions PROPOSÉES (jamais exécutées).
 * Les arguments JSON invalides ou un outil inconnu rendent l'action non exécutable.
 */
export function proposeToolCalls(
  calls: readonly (PendingToolCall | undefined)[],
  conversationId: string | null,
): ProposedAction[] {
  const out: ProposedAction[] = [];
  for (const tc of calls) {
    if (!tc || !tc.name) continue;
    let args: Record<string, unknown> = {};
    let invalid: string | null = null;
    try {
      const parsed: unknown = JSON.parse(tc.arguments || "{}");
      if (isRecord(parsed)) args = parsed;
      else invalid = "Arguments invalides";
    } catch {
      invalid = "Arguments illisibles (JSON invalide)";
    }
    if (!invalid && !isKnownChatTool(tc.name)) invalid = "Action inconnue";
    if (!invalid && isKnownChatTool(tc.name)) {
      const missing = REQUIRED_ARGS[tc.name].find((f) => typeof args[f] !== "string" || !(args[f] as string).trim());
      if (missing) invalid = `Argument « ${missing} » manquant`;
    }
    seq += 1;
    out.push({
      key: `${tc.id || tc.name}-${Date.now().toString(36)}-${seq}`,
      conversationId,
      name: tc.name,
      args,
      invalid,
      status: "proposed",
    });
  }
  return out;
}

const text = (v: unknown, max = 400) => {
  const s = typeof v === "string" ? v.trim() : "";
  return s.length > max ? `${s.slice(0, max - 1)}…` : s;
};

/** Détails affichés dans la carte de confirmation. */
export function describeAction(name: string, args: Record<string, unknown>): ActionDescription {
  const fields: ActionField[] = [];
  const push = (label: string, v: unknown, max?: number) => {
    const value = text(v, max);
    if (value) fields.push({ label, value });
  };
  switch (name) {
    case "create_formation":
      push("Sujet", args.topic);
      push("Détails", args.details);
      return { title: "Créer une formation", fields };
    case "create_application":
      push("Nom", args.appName);
      push("Description", args.appDesc);
      return { title: "Créer une application", fields };
    case "save_knowledge":
      push("Titre", args.title);
      push("Contenu", args.content, 600);
      push("Catégorie", args.category);
      if (Array.isArray(args.tags)) push("Tags", args.tags.filter((t) => typeof t === "string").join(", "));
      return { title: "Enregistrer dans la base de connaissances", fields };
    default:
      push("Arguments", JSON.stringify(args), 600);
      return { title: `Action « ${name} »`, fields };
  }
}

export type ActionEvent =
  | { type: "confirm" }
  | { type: "cancel" }
  | { type: "succeeded"; text: string }
  | { type: "failed"; text: string };

/**
 * Machine à états d'une action proposée. Seule une action `proposed` et valide peut
 * être confirmée (→ executing) ; une action annulée ou terminée ne peut plus l'être.
 */
export function transitionAction(action: ProposedAction, event: ActionEvent): ProposedAction {
  switch (event.type) {
    case "confirm":
      return action.status === "proposed" && !action.invalid ? { ...action, status: "executing" } : action;
    case "cancel":
      return action.status === "proposed" ? { ...action, status: "cancelled" } : action;
    case "succeeded":
      return action.status === "executing" ? { ...action, status: "done", resultText: event.text } : action;
    case "failed":
      return action.status === "executing" ? { ...action, status: "failed", resultText: event.text } : action;
    default:
      return action;
  }
}

/**
 * Corps de POST /api/chat pour exécuter une action CONFIRMÉE par l'utilisateur.
 * Lève une erreur si l'action n'a pas été confirmée (statut `executing`).
 */
export function buildConfirmedActionBody(action: ProposedAction) {
  if (action.status !== "executing" || action.invalid) {
    throw new Error("Action non confirmée : exécution refusée.");
  }
  return {
    messages: [],
    action: { name: action.name, arguments: action.args, confirmed: true },
    confirmed: true,
  };
}

/** Mention ajoutée à la réponse de l'assistant (enregistrée) quand une action est proposée. */
export function proposalNotice(actions: readonly ProposedAction[]): string {
  if (actions.length === 0) return "";
  const titles = actions.map((a) => describeAction(a.name, a.args).title);
  return `\n\n🛠️ Action proposée : ${titles.join(", ")} — en attente de votre confirmation.`;
}
