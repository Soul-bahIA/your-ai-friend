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
    const { appName, appDesc, applicationId } = await req.json();

    const authHeader = req.headers.get("Authorization")!;
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const token = authHeader.replace("Bearer ", "");
    const supabaseUser = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!
    );
    const { data: { user }, error: authError } = await supabaseUser.auth.getUser(token);
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Non autorisé" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    if (!LOVABLE_API_KEY) throw new Error("LOVABLE_API_KEY not configured");

    console.log("Generating application for:", appName);

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
            content: `Tu es un architecte logiciel expert. Tu conçois des applications complètes. Retourne un JSON structuré décrivant l'architecture complète de l'application demandée.`
          },
          {
            role: "user",
            content: `Conçois l'architecture complète de l'application : "${appName}".${appDesc ? `\nDescription : ${appDesc}` : ""}\nInclus : architecture, composants frontend, API backend, schéma de base de données, et le code principal des composants clés.`
          }
        ],
        tools: [
          {
            type: "function",
            function: {
              name: "create_application",
              description: "Create a complete application architecture",
              parameters: {
                type: "object",
                properties: {
                  title: { type: "string" },
                  description: { type: "string" },
                  app_type: { type: "string" },
                  tech_stack: { type: "string" },
                  architecture: {
                    type: "object",
                    properties: {
                      frontend: {
                        type: "object",
                        properties: {
                          framework: { type: "string" },
                          components: { type: "array", items: { type: "object", properties: { name: { type: "string" }, description: { type: "string" }, code: { type: "string" } }, required: ["name", "description", "code"] } }
                        },
                        required: ["framework", "components"]
                      },
                      backend: {
                        type: "object",
                        properties: {
                          endpoints: { type: "array", items: { type: "object", properties: { method: { type: "string" }, path: { type: "string" }, description: { type: "string" } }, required: ["method", "path", "description"] } }
                        },
                        required: ["endpoints"]
                      },
                      database: {
                        type: "object",
                        properties: {
                          tables: { type: "array", items: { type: "object", properties: { name: { type: "string" }, columns: { type: "array", items: { type: "string" } }, description: { type: "string" } }, required: ["name", "columns"] } }
                        },
                        required: ["tables"]
                      }
                    },
                    required: ["frontend", "backend", "database"]
                  }
                },
                required: ["title", "description", "app_type", "tech_stack", "architecture"]
              }
            }
          }
        ],
        tool_choice: { type: "function", function: { name: "create_application" } }
      }),
    });

    if (!response.ok) {
      const errText = await response.text();
      console.error("AI error:", response.status, errText);
      if (response.status === 429) {
        return new Response(JSON.stringify({ error: "Trop de requêtes. Réessayez." }), {
          status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (response.status === 402) {
        return new Response(JSON.stringify({ error: "Crédits IA épuisés." }), {
          status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      throw new Error("AI generation failed");
    }

    const aiData = await response.json();
    let appContent;
    const toolCall = aiData.choices?.[0]?.message?.tool_calls?.[0];
    if (toolCall?.function?.arguments) {
      appContent = JSON.parse(toolCall.function.arguments);
    } else {
      const content = aiData.choices?.[0]?.message?.content || "";
      const jsonMatch = content.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        appContent = JSON.parse(jsonMatch[0]);
      } else {
        throw new Error("Could not parse AI response");
      }
    }

    const { error: updateError } = await supabase
      .from("applications")
      .update({
        title: appContent.title || appName,
        description: appContent.description,
        app_type: appContent.app_type || "Web App",
        tech_stack: appContent.tech_stack || "React + TypeScript",
        source_code: appContent.architecture || {},
        status: "Généré",
      })
      .eq("id", applicationId)
      .eq("user_id", user.id);

    if (updateError) {
      console.error("DB update error:", updateError);
      throw new Error("Failed to save application");
    }

    await supabase.from("system_logs").insert({
      user_id: user.id,
      module: "Applications",
      event: `Application « ${appContent.title} » générée par IA`,
      level: "success",
    });

    console.log("Application generated successfully:", appContent.title);

    return new Response(JSON.stringify({ success: true, application: appContent }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("generate-application error:", e);
    return new Response(JSON.stringify({ error: e instanceof Error ? e.message : "Erreur inconnue" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
