// Résolution du fournisseur de chat (streaming SSE + tool-calling).
//
// Le chat n'est plus lié à OpenAI en dur : tous les fournisseurs de la famille
// « compatible OpenAI » (OpenAI, Gemini, Mistral, DeepSeek, xAI, Qwen, local) exposent
// le même /chat/completions avec streaming et outils. On choisit par configuration
// (CHAT_PROVIDER), avec repli automatique sur le 1er fournisseur dont la clé est présente.
// Anthropic n'est pas ici (format SSE différent) : il faudrait un adaptateur dédié.

interface ChatProviderSpec {
  url: string; // endpoint /chat/completions complet
  keyEnv: string;
  modelEnv: string;
  defaultModel: string;
}

const SPECS: Record<string, ChatProviderSpec> = {
  openai: {
    url: process.env.OPENAI_URL ?? "https://api.openai.com/v1/chat/completions",
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

/** Fournisseur de chat retenu, ou null si aucune clé n'est configurée. */
export function resolveChatProvider(): ChatProvider | null {
  const wanted = (process.env.CHAT_PROVIDER ?? "").toLowerCase();

  // Modèle local (Ollama/LM Studio) : activé si LOCAL_LLM_URL est défini.
  const localUrl = process.env.LOCAL_LLM_URL;
  const buildLocal = (): ChatProvider | null =>
    localUrl
      ? {
          provider: "local",
          url: `${localUrl.replace(/\/+$/, "")}/chat/completions`,
          apiKey: process.env.LOCAL_LLM_KEY ?? "",
          model: process.env.CHAT_MODEL ?? process.env.LOCAL_LLM_MODEL ?? "llama3.1",
        }
      : null;

  const build = (id: string): ChatProvider | null => {
    if (id === "local") return buildLocal();
    const spec = SPECS[id];
    if (!spec) return null;
    const key = process.env[spec.keyEnv];
    if (!key) return null;
    return {
      provider: id,
      url: spec.url,
      apiKey: key,
      // CHAT_MODEL surcharge globale, sinon modèle spécifique, sinon défaut.
      model: process.env.CHAT_MODEL || process.env[spec.modelEnv] || spec.defaultModel,
    };
  };

  // 1. Choix explicite s'il est configuré.
  if (wanted) {
    const chosen = build(wanted);
    if (chosen) return chosen;
  }
  // 2. Sinon, 1er fournisseur disponible (OpenAI prioritaire).
  for (const id of ORDER) {
    const p = build(id);
    if (p) return p;
  }
  return buildLocal();
}
