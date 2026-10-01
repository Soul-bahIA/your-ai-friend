import type { FastifyInstance } from "fastify";
import { Readable } from "node:stream";
import { pool } from "../db";
import { requireUser } from "../auth";
import { executeChatAction } from "../services/chatActions";
import { resolveChatProvider } from "../services/chatProvider";
import { validateChatAction, validateChatMessages } from "../lib/chatValidation";
import { config } from "../config";

// Délais du flux de chat : connexion (jusqu'aux en-têtes) puis inactivité entre deux fragments.
const CHAT_CONNECT_TIMEOUT_MS = 30_000;
const CHAT_IDLE_TIMEOUT_MS = 60_000;

/** Relais d'un flux web en flux Node, avec coupure si aucun fragment pendant idleMs. */
async function* relayWithIdleTimeout(
  body: ReadableStream<Uint8Array>,
  controller: AbortController,
  idleMs: number,
  onError: (e: unknown) => void,
): AsyncGenerator<Uint8Array> {
  const reader = body.getReader();
  let timer: NodeJS.Timeout | undefined;
  const arm = () => {
    clearTimeout(timer);
    timer = setTimeout(() => controller.abort(new Error("chat stream idle timeout")), idleMs);
  };
  try {
    arm();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      arm();
      if (value) yield value;
    }
  } catch (e) {
    onError(e); // coupure (inactivité / client parti) : on termine proprement le flux
  } finally {
    clearTimeout(timer);
    reader.cancel().catch(() => {});
  }
}

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
  app.post(
    "/api/chat",
    { preHandler: requireUser, config: { rateLimit: { max: config.rateLimitExpensive * 2, timeWindow: "1 minute" } } },
    async (request, reply) => {
    const userId = request.user!.id;
    const { messages: rawMessages, action } = (request.body ?? {}) as {
      messages?: unknown;
      action?: unknown;
    };

    // 1. Exécution d'une action (résultat de tool-call)
    if (action !== undefined && action !== null) {
      const checkedAction = validateChatAction(action);
      if (!checkedAction.ok) return reply.status(400).send({ success: false, error: checkedAction.error });
      const result = await executeChatAction(userId, checkedAction.value);
      return reply.status(result.success === false ? 502 : 200).send(result);
    }

    const checked = validateChatMessages(rawMessages);
    if (!checked.ok) return reply.status(400).send({ error: checked.error });
    const messages = checked.value;

    // Fournisseur de chat résolu par configuration (plus lié à OpenAI en dur).
    const chatProvider = resolveChatProvider();
    if (!chatProvider) {
      return reply.status(503).send({
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
    // Un seul AbortController : délai de connexion, puis inactivité, puis départ du client.
    const controller = new AbortController();
    const connectTimer = setTimeout(() => controller.abort(new Error("chat connect timeout")), CHAT_CONNECT_TIMEOUT_MS);
    reply.raw.on("close", () => {
      if (!reply.raw.writableFinished) controller.abort(new Error("client disconnected"));
    });

    let upstream: Response;
    try {
      upstream = await fetch(chatProvider.url, {
        signal: controller.signal,
        method: "POST",
        headers: {
          Authorization: `Bearer ${chatProvider.apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: chatProvider.model,
          messages: [
            { role: "system", content: buildSystemPrompt(knowledgeContext) },
            ...messages,
          ],
          tools: CHAT_TOOLS,
          stream: true,
        }),
      });
    } catch (e) {
      clearTimeout(connectTimer);
      request.log.warn({ err: (e as Error).message }, "fournisseur de chat injoignable");
      const timedOut = controller.signal.aborted;
      return reply
        .status(timedOut ? 504 : 502)
        .send({ error: timedOut ? "Le service IA n'a pas répondu à temps" : "Service IA injoignable" });
    }
    clearTimeout(connectTimer);

    if (!upstream.ok || !upstream.body) {
      if (upstream.status === 429) return reply.status(429).send({ error: "Trop de requêtes. Réessayez dans quelques instants." });
      if (upstream.status === 402) return reply.status(402).send({ error: "Crédits IA épuisés." });
      // 401/403 du fournisseur = clé serveur invalide : 502, jamais 401 (le front croirait la session expirée).
      request.log.error({ upstreamStatus: upstream.status, provider: chatProvider.provider }, "erreur du fournisseur de chat");
      upstream.body?.cancel().catch(() => {});
      return reply.status(502).send({ error: "Erreur du service IA" });
    }

    // 4. Relais du flux SSE tel quel vers le client
    reply.header("Content-Type", "text/event-stream");
    reply.header("Cache-Control", "no-cache");
    // upstream.body (ReadableStream web) → flux Node, coupé après CHAT_IDLE_TIMEOUT_MS d'inactivité.
    const stream = Readable.from(
      relayWithIdleTimeout(upstream.body, controller, CHAT_IDLE_TIMEOUT_MS, (e) =>
        request.log.warn({ err: (e as Error)?.message }, "flux de chat interrompu"),
      ),
      { objectMode: false },
    );
    return reply.send(stream);
    },
  );
}
