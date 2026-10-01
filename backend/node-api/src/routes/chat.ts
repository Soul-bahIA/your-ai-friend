import type { FastifyInstance } from "fastify";
import { Readable } from "node:stream";
import { pool } from "../db";
import { requireUser } from "../auth";
import { executeChatAction, type ChatAction } from "../services/chatActions";
import { resolveChatProvider } from "../services/chatProvider";

// Port de l'edge function `chat` : chat streaming (SSE) avec tool-calling,
// injection de la base de connaissances, et exécution d'actions (tool results).

const CHAT_TOOLS = [
  {
    type: "function",
    function: {
      name: "create_formation",
      description:
        "Créer une formation complète sur un sujet donné. Utilise cet outil quand l'utilisateur demande de créer, générer ou préparer une formation.",
      parameters: {
        type: "object",
        properties: {
          topic: { type: "string", description: "Le sujet de la formation" },
          details: { type: "string", description: "Détails supplémentaires" },
        },
        required: ["topic"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "create_application",
      description:
        "Créer une application complète. Utilise cet outil quand l'utilisateur demande de créer, développer ou concevoir une application.",
      parameters: {
        type: "object",
        properties: {
          appName: { type: "string", description: "Le nom de l'application" },
          appDesc: { type: "string", description: "Description de l'application souhaitée" },
        },
        required: ["appName"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "save_knowledge",
      description:
        "Sauvegarder une information dans la base de connaissances. Utilise cet outil quand l'utilisateur demande de retenir, sauvegarder ou mémoriser quelque chose.",
      parameters: {
        type: "object",
        properties: {
          title: { type: "string" },
          content: { type: "string" },
          category: {
            type: "string",
            enum: ["general", "formation", "application", "code", "recherche", "note"],
          },
          tags: { type: "array", items: { type: "string" } },
        },
        required: ["title", "content"],
      },
    },
  },
];

function buildSystemPrompt(knowledgeContext: string): string {
  return `Tu es SOULBAH IA, l'assistant personnel intelligent de l'utilisateur. Tu es au service EXCLUSIF de cet utilisateur.

Tes capacités :
- Répondre à toutes les questions (technique, général, planification)
- CRÉER des formations complètes via l'outil create_formation
- CRÉER des applications via l'outil create_application
- SAUVEGARDER des connaissances via l'outil save_knowledge
- CONSULTER ta base de connaissances pour fournir des réponses précises

RÈGLES IMPORTANTES :
- Tu travailles UNIQUEMENT pour cet utilisateur
- Quand l'utilisateur demande de créer quelque chose, utilise les outils disponibles
- Quand il demande de retenir une info, utilise save_knowledge
- Consulte la base de connaissances ci-dessous pour enrichir tes réponses
- Utilise le markdown, communique en français sauf demande contraire${knowledgeContext}`;
}

export async function chatRoutes(app: FastifyInstance): Promise<void> {
  app.post("/api/chat", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const { messages, action } = (request.body ?? {}) as {
      messages?: unknown[];
      action?: ChatAction;
    };

    // 1. Exécution d'une action (résultat de tool-call)
    if (action) {
      const result = await executeChatAction(userId, action);
      return reply.send(result);
    }

    // Fournisseur de chat résolu par configuration (plus lié à OpenAI en dur).
    const chatProvider = resolveChatProvider();
    if (!chatProvider) {
      return reply.status(500).send({
        error: "Aucun fournisseur de chat configuré (OPENAI_API_KEY, GEMINI_API_KEY, DEEPSEEK_API_KEY…).",
      });
    }

    // 2. Injection de la base de connaissances
    let knowledgeContext = "";
    try {
      const { rows } = await pool.query(
        `SELECT title, content, category, tags FROM knowledge_base
         WHERE user_id = $1 ORDER BY updated_at DESC LIMIT 50`,
        [userId],
      );
      if (rows.length > 0) {
        knowledgeContext =
          "\n\n--- BASE DE CONNAISSANCES ---\n" +
          rows
            .map(
              (k, i) =>
                `[${i + 1}] **${k.title}** (${k.category})${
                  k.tags?.length ? ` [tags: ${k.tags.join(", ")}]` : ""
                }\n${k.content}`,
            )
            .join("\n\n---\n\n") +
          "\n--- FIN ---";
      }
    } catch (e) {
      request.log.warn(e, "Lecture knowledge_base échouée");
    }

    // 3. Appel streaming à la passerelle LLM
    let upstream: Response;
    try {
      upstream = await fetch(chatProvider.url, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${chatProvider.apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: chatProvider.model,
          messages: [
            { role: "system", content: buildSystemPrompt(knowledgeContext) },
            ...(messages ?? []),
          ],
          tools: CHAT_TOOLS,
          stream: true,
        }),
      });
    } catch {
      return reply.status(502).send({ error: "Service IA injoignable" });
    }

    if (!upstream.ok || !upstream.body) {
      if (upstream.status === 429) return reply.status(429).send({ error: "Trop de requêtes. Réessayez dans quelques instants." });
      if (upstream.status === 402) return reply.status(402).send({ error: "Crédits IA épuisés." });
      request.log.error("AI gateway error %d", upstream.status);
      return reply.status(500).send({ error: "Erreur du service IA" });
    }

    // 4. Relais du flux SSE tel quel vers le client
    reply.header("Content-Type", "text/event-stream");
    reply.header("Cache-Control", "no-cache");
    // upstream.body est un ReadableStream (web) → conversion en flux Node.
    return reply.send(Readable.fromWeb(upstream.body as Parameters<typeof Readable.fromWeb>[0]));
  });
}
