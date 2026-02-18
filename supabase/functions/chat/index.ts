import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { messages, action } = await req.json();

    // Authenticate user
    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.replace("Bearer ", "");
    
    const supabaseUser = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!
    );
    const { data: { user }, error: authError } = await supabaseUser.auth.getUser(token);
    
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Non autorisé. Connectez-vous pour utiliser l'IA." }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    if (!LOVABLE_API_KEY) throw new Error("LOVABLE_API_KEY is not configured");

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // If an action was requested (from tool call result), execute it
    if (action) {
      const result = await executeAction(supabaseAdmin, user.id, action);
      return new Response(JSON.stringify(result), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Normal chat with tool-calling capabilities
    const response = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "google/gemini-3-flash-preview",
        messages: [
          {
            role: "system",
            content: `Tu es SOULBAH IA, l'assistant personnel intelligent de l'utilisateur. Tu es au service EXCLUSIF de cet utilisateur.

Tes capacités :
- Répondre à toutes les questions (technique, général, planification)
- CRÉER des formations complètes via l'outil create_formation
- CRÉER des applications via l'outil create_application  
- SAUVEGARDER des connaissances via l'outil save_knowledge
- Donner des conseils en programmation et architecture

RÈGLES IMPORTANTES :
- Tu travailles UNIQUEMENT pour cet utilisateur, personne d'autre
- Quand l'utilisateur te demande de créer quelque chose, utilise les outils disponibles
- Quand il te demande de retenir ou sauvegarder une info, utilise save_knowledge
- Sois proactif : propose des améliorations et pose des questions de clarification
- Utilise le markdown pour formater tes réponses
- Communique en français sauf si on te demande autrement`
          },
          ...messages,
        ],
        tools: [
          {
            type: "function",
            function: {
              name: "create_formation",
              description: "Créer une formation complète sur un sujet donné. Utilise cet outil quand l'utilisateur demande de créer, générer ou préparer une formation.",
              parameters: {
                type: "object",
                properties: {
                  topic: { type: "string", description: "Le sujet de la formation" },
                  details: { type: "string", description: "Détails supplémentaires sur la formation souhaitée" }
                },
                required: ["topic"]
              }
            }
          },
          {
            type: "function",
            function: {
              name: "create_application",
              description: "Créer une application complète. Utilise cet outil quand l'utilisateur demande de créer, développer ou concevoir une application.",
              parameters: {
                type: "object",
                properties: {
                  appName: { type: "string", description: "Le nom de l'application" },
                  appDesc: { type: "string", description: "Description de l'application souhaitée" }
                },
                required: ["appName"]
              }
            }
          },
          {
            type: "function",
            function: {
              name: "save_knowledge",
              description: "Sauvegarder une information dans la base de connaissances. Utilise cet outil quand l'utilisateur demande de retenir, sauvegarder ou mémoriser quelque chose.",
              parameters: {
                type: "object",
                properties: {
                  title: { type: "string", description: "Titre de la connaissance" },
                  content: { type: "string", description: "Le contenu à sauvegarder" },
                  category: { type: "string", enum: ["general", "formation", "application", "code", "recherche", "note"], description: "Catégorie" },
                  tags: { type: "array", items: { type: "string" }, description: "Tags associés" }
                },
                required: ["title", "content"]
              }
            }
          }
        ],
        stream: true,
      }),
    });

    if (!response.ok) {
      if (response.status === 429) {
        return new Response(JSON.stringify({ error: "Trop de requêtes. Réessayez dans quelques instants." }), {
          status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (response.status === 402) {
        return new Response(JSON.stringify({ error: "Crédits IA épuisés." }), {
          status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const t = await response.text();
      console.error("AI gateway error:", response.status, t);
      return new Response(JSON.stringify({ error: "Erreur du service IA" }), {
        status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(response.body, {
      headers: { ...corsHeaders, "Content-Type": "text/event-stream" },
    });
  } catch (e) {
    console.error("chat error:", e);
    return new Response(JSON.stringify({ error: e instanceof Error ? e.message : "Erreur inconnue" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

async function executeAction(supabase: any, userId: string, action: { name: string; arguments: any }) {
  const args = action.arguments;

  switch (action.name) {
    case "create_formation": {
      const { data, error } = await supabase
        .from("formations")
        .insert({
          user_id: userId,
          title: args.topic,
          description: args.details || `Formation sur ${args.topic}`,
          status: "En cours",
        })
        .select("id")
        .single();

      if (error) return { success: false, error: "Erreur création formation" };

      // Trigger AI generation in background
      const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
      const genResponse = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${LOVABLE_API_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "google/gemini-3-flash-preview",
          messages: [
            {
              role: "system",
              content: `Tu es un expert en création de formations pédagogiques. Retourne un JSON via l'outil create_formation_content.`
            },
            {
              role: "user",
              content: `Crée une formation complète sur : "${args.topic}".${args.details ? `\nDétails : ${args.details}` : ""}\nGénère entre 5 et 8 leçons structurées.`
            }
          ],
          tools: [{
            type: "function",
            function: {
              name: "create_formation_content",
              description: "Create structured formation content",
              parameters: {
                type: "object",
                properties: {
                  title: { type: "string" },
                  description: { type: "string" },
                  duration: { type: "string" },
                  lessons: {
                    type: "array",
                    items: {
                      type: "object",
                      properties: {
                        title: { type: "string" },
                        objectives: { type: "array", items: { type: "string" } },
                        content: { type: "string" },
                        examples: { type: "array", items: { type: "string" } },
                        exercises: { type: "array", items: { type: "string" } }
                      },
                      required: ["title", "objectives", "content", "examples", "exercises"]
                    }
                  }
                },
                required: ["title", "description", "duration", "lessons"]
              }
            }
          }],
          tool_choice: { type: "function", function: { name: "create_formation_content" } }
        }),
      });

      if (genResponse.ok) {
        const aiData = await genResponse.json();
        const toolCall = aiData.choices?.[0]?.message?.tool_calls?.[0];
        if (toolCall?.function?.arguments) {
          const content = JSON.parse(toolCall.function.arguments);
          await supabase.from("formations").update({
            title: content.title || args.topic,
            description: content.description,
            duration: content.duration,
            lessons_count: content.lessons?.length || 0,
            content: content.lessons || [],
            status: "Terminé",
          }).eq("id", data.id);

          await supabase.from("system_logs").insert({
            user_id: userId,
            module: "Formations",
            event: `Formation « ${content.title} » créée via Chat IA`,
            level: "success",
          });

          return { success: true, type: "formation", title: content.title, id: data.id, lessonsCount: content.lessons?.length };
        }
      }

      return { success: true, type: "formation", title: args.topic, id: data.id, status: "pending" };
    }

    case "create_application": {
      const { data, error } = await supabase
        .from("applications")
        .insert({
          user_id: userId,
          title: args.appName,
          description: args.appDesc || `Application ${args.appName}`,
          status: "En cours",
        })
        .select("id")
        .single();

      if (error) return { success: false, error: "Erreur création application" };

      // Generate app architecture
      const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
      const genResponse = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${LOVABLE_API_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "google/gemini-3-flash-preview",
          messages: [
            { role: "system", content: "Tu es un architecte logiciel expert. Conçois une application complète." },
            { role: "user", content: `Conçois l'application : "${args.appName}".${args.appDesc ? `\nDescription : ${args.appDesc}` : ""}` }
          ],
          tools: [{
            type: "function",
            function: {
              name: "create_app_architecture",
              description: "Create application architecture",
              parameters: {
                type: "object",
                properties: {
                  title: { type: "string" },
                  description: { type: "string" },
                  app_type: { type: "string" },
                  tech_stack: { type: "string" },
                  architecture: { type: "object" }
                },
                required: ["title", "description", "app_type", "tech_stack"]
              }
            }
          }],
          tool_choice: { type: "function", function: { name: "create_app_architecture" } }
        }),
      });

      if (genResponse.ok) {
        const aiData = await genResponse.json();
        const toolCall = aiData.choices?.[0]?.message?.tool_calls?.[0];
        if (toolCall?.function?.arguments) {
          const content = JSON.parse(toolCall.function.arguments);
          await supabase.from("applications").update({
            title: content.title || args.appName,
            description: content.description,
            app_type: content.app_type || "Web App",
            tech_stack: content.tech_stack || "React + TypeScript",
            source_code: content.architecture || {},
            status: "Généré",
          }).eq("id", data.id);

          await supabase.from("system_logs").insert({
            user_id: userId,
            module: "Applications",
            event: `Application « ${content.title} » créée via Chat IA`,
            level: "success",
          });

          return { success: true, type: "application", title: content.title, id: data.id };
        }
      }

      return { success: true, type: "application", title: args.appName, id: data.id, status: "pending" };
    }

    case "save_knowledge": {
      const { error } = await supabase.from("knowledge_base").insert({
        user_id: userId,
        title: args.title,
        content: args.content,
        category: args.category || "general",
        tags: args.tags || [],
      });

      if (error) return { success: false, error: "Erreur sauvegarde" };

      await supabase.from("system_logs").insert({
        user_id: userId,
        module: "Connaissances",
        event: `Connaissance « ${args.title} » sauvegardée via Chat IA`,
        level: "success",
      });

      return { success: true, type: "knowledge", title: args.title };
    }

    default:
      return { success: false, error: `Action inconnue: ${action.name}` };
  }
}
