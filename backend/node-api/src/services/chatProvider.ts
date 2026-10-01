// Résolution du fournisseur de chat (streaming SSE + tool-calling).
//
// Le chat n'est plus lié à OpenAI en dur : tous les fournisseurs de la famille
// « compatible OpenAI » (OpenAI, Gemini, Mistral, DeepSeek, xAI, Qwen, local) exposent
// le même /chat/completions avec streaming et outils. On choisit par configuration
// (CHAT_PROVIDER), avec repli automatique sur le 1er fournisseur dont la clé est présente.
// Anthropic n'est pas ici (format SSE différent) : il faudrait un adaptateur dédié.
import { cloudModelsAllowed, currentSettings, isLocalEndpoint, type SoulbahSettings } from "../lib/soulbahSettings.js";

interface ChatProviderSpec {
  url: string; // endpoint /chat/completions complet
  keyEnv: string;
  modelEnv: string;
  defaultModel: string;
}

const SPECS: Record<string, ChatProviderSpec> = {
  openai: {
    url: "https://api.openai.com/v1/chat/completions",
    keyEnv: "OPENAI_API_KEY",
    modelEnv: "OPENAI_MODEL",
    defaultModel: "gpt-4o",
  },
  gemini: {
    url: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
    keyEnv: "GEMINI_API_KEY",
    modelEnv: "GEMINI_MODEL",
    defaultModel: "gemini-2.0-flash",
  },
  mistral: {
    url: "https://api.mistral.ai/v1/chat/completions",
    keyEnv: "MISTRAL_API_KEY",
    modelEnv: "MISTRAL_MODEL",
    defaultModel: "mistral-large-latest",
  },
  deepseek: {
    url: "https://api.deepseek.com/v1/chat/completions",
    keyEnv: "DEEPSEEK_API_KEY",
    modelEnv: "DEEPSEEK_MODEL",
    defaultModel: "deepseek-chat",
  },
  xai: {
    url: "https://api.x.ai/v1/chat/completions",
    keyEnv: "XAI_API_KEY",
    modelEnv: "XAI_MODEL",
    defaultModel: "grok-2-latest",
  },
  qwen: {
    url: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions",
    keyEnv: "QWEN_API_KEY",
    modelEnv: "QWEN_MODEL",
    defaultModel: "qwen-max",
  },
};

export interface ChatProvider {
  provider: string;
  url: string;
  apiKey: string;
  model: string;
}

const ORDER = ["openai", "gemini", "mistral", "deepseek", "xai", "qwen"];

/**
 * Fournisseur de chat retenu, ou null si aucune clé n'est configurée.
 * CHAT_MODEL ne s'applique qu'au fournisseur explicitement choisi (CHAT_PROVIDER) :
 * en repli sur un autre fournisseur, on n'envoie jamais le modèle d'un autre éditeur.
 */
export function resolveChatProvider(env: NodeJS.ProcessEnv = process.env, settings: Pick<SoulbahSettings, "mode" | "network"> = currentSettings()): ChatProvider | null {
  // V3 LOT 1 : hors HYBRID, seul le modèle local (LOCAL_LLM_URL) est autorisé.
  const cloud = cloudModelsAllowed(settings);
  const wanted = (env.CHAT_PROVIDER ?? "").toLowerCase();
  const chatModel = env.CHAT_MODEL || undefined;

  const build = (id: string, explicit: boolean): ChatProvider | null => {
    const override = explicit ? chatModel : undefined;
    if (id === "local") {
      // Modèle local (Ollama/LM Studio) : activé si LOCAL_LLM_URL est défini.
      const localUrl = env.LOCAL_LLM_URL;
      if (!localUrl) return null;
      // Hors HYBRID, le « modèle local » doit tourner sur une machine de l'utilisateur.
      if (!cloud && !isLocalEndpoint(settings, hostOf(localUrl))) return null;
      return {
        provider: "local",
        url: `${localUrl.replace(/\/+$/, "")}/chat/completions`,
        apiKey: env.LOCAL_LLM_KEY ?? "",
        model: override || env.LOCAL_LLM_MODEL || "llama3.1",
      };
    }
    const spec = SPECS[id];
    if (!spec || !cloud) return null;
    const key = env[spec.keyEnv];
    if (!key) return null;
    return {
      provider: id,
      url: id === "openai" ? env.OPENAI_URL || spec.url : spec.url,
      apiKey: key,
      model: override || env[spec.modelEnv] || spec.defaultModel,
    };
  };

  // 1. Choix explicite s'il est configuré.
  if (wanted) {
    const chosen = build(wanted, true);
    if (chosen) return chosen;
  }
  // 2. Sinon, 1er fournisseur disponible (OpenAI prioritaire), puis le modèle local.
  for (const id of [...ORDER, "local"]) {
    const p = build(id, false);
    if (p) return p;
  }
  return null;
}

function hostOf(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return "";
  }
}
