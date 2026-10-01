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
  /** Valeur INTÉGRALE (jamais tronquée) : c'est exactement ce qui sera exécuté (S12). */
  value: string;
  /** Texte long ou multiligne : affiché dans une zone défilante plutôt qu'en ligne. */
  long: boolean;
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

/**
 * Arguments réellement lus par le serveur pour chaque outil (node-api services/chatActions.ts).
 * Seuls ceux-ci sont envoyés à l'exécution, et chacun est affiché EN ENTIER dans la carte :
 * l'utilisateur confirme exactement ce qui sera exécuté (S12).
 */
export const EXECUTED_ARGS: Record<KnownChatTool, readonly string[]> = {
  create_formation: ["topic", "details"],
  create_application: ["appName", "appDesc"],
  save_knowledge: ["title", "content", "category", "tags"],
};

/** Au-delà, un champ est affiché dans une zone défilante (jamais tronqué). */
export const LONG_FIELD_CHARS = 160;

/** Arguments transmis à l'exécution : uniquement ceux affichés dans la carte de confirmation. */
export function executedArguments(name: string, args: Record<string, unknown>): Record<string, unknown> {
  if (!isKnownChatTool(name)) return {};
  const out: Record<string, unknown> = {};
  for (const key of EXECUTED_ARGS[name]) {
    if (Object.prototype.hasOwnProperty.call(args, key)) out[key] = args[key];
  }
  return out;
}

const ARG_LABELS: Record<string, string> = {
  topic: "Sujet",
  details: "Détails",
  appName: "Nom",
  appDesc: "Description",
  title: "Titre",
  content: "Contenu",
  category: "Catégorie",
  tags: "Tags",
};

const TITLES: Record<KnownChatTool, string> = {
  create_formation: "Créer une formation",
  create_application: "Créer une application",
  save_knowledge: "Enregistrer dans la base de connaissances",
};

/**
 * Texte affiché pour un argument : la valeur complète, rien d'omis. Le serveur ne garde que les
 * textes (rognés de leurs espaces de bord, puis bornés en longueur) : la carte en montre au moins autant.
 */
function displayValue(key: string, v: unknown): string {
  if (typeof v === "string") return v.trim();
  // Le serveur ne garde que les tags textuels : on les liste tous, sans troncature.
  if (key === "tags" && Array.isArray(v)) return v.filter((t): t is string => typeof t === "string").join(", ");
  return "";
}

/** Détails affichés dans la carte de confirmation : chaque argument exécuté, en entier (S12). */
export function describeAction(name: string, args: Record<string, unknown>): ActionDescription {
  const fields: ActionField[] = [];
  const push = (label: string, value: string) => {
    if (!value.trim()) return;
    fields.push({ label, value, long: value.length > LONG_FIELD_CHARS || value.includes("\n") });
  };
  if (!isKnownChatTool(name)) {
    // Action inconnue (jamais exécutable) : arguments bruts, en entier.
    push("Arguments", JSON.stringify(args, null, 2) ?? "");
    return { title: `Action « ${name} »`, fields };
  }
  const executed = executedArguments(name, args);
  for (const key of EXECUTED_ARGS[name]) push(ARG_LABELS[key] ?? key, displayValue(key, executed[key]));
  return { title: TITLES[name], fields };
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
 * N'envoie que les arguments affichés en entier dans la carte (executedArguments, S12).
 */
export function buildConfirmedActionBody(action: ProposedAction) {
  if (action.status !== "executing" || action.invalid) {
    throw new Error("Action non confirmée : exécution refusée.");
  }
  return {
    messages: [],
    action: { name: action.name, arguments: executedArguments(action.name, action.args), confirmed: true },
    confirmed: true,
  };
}

/** Mention ajoutée à la réponse de l'assistant (enregistrée) quand une action est proposée. */
export function proposalNotice(actions: readonly ProposedAction[]): string {
  if (actions.length === 0) return "";
  const titles = actions.map((a) => describeAction(a.name, a.args).title);
  return `\n\n🛠️ Action proposée : ${titles.join(", ")} — en attente de votre confirmation.`;
}
