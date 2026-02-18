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
    const { topic, details, formationId } = await req.json();

    const authHeader = req.headers.get("Authorization")!;
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Verify user
    const token = authHeader.replace("Bearer ", "");
    const supabaseUser = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_PUBLISHABLE_KEY")!
    );
    const { data: { user }, error: authError } = await supabaseUser.auth.getUser(token);
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Non autorisé" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    if (!LOVABLE_API_KEY) {
      throw new Error("LOVABLE_API_KEY not configured");
    }

    console.log("Generating formation for:", topic);

    // Call AI to generate structured formation content
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
            content: `Tu es un expert en création de formations pédagogiques. Tu génères des formations structurées et complètes en français.
Tu dois retourner un JSON valide avec cette structure exacte, sans markdown ni backticks :
{
  "title": "Titre de la formation",
  "description": "Description complète",
  "duration": "Durée estimée (ex: 8h)",
  "lessons": [
    {
      "title": "Titre de la leçon",
      "objectives": ["Objectif 1", "Objectif 2"],
      "content": "Contenu détaillé de la leçon avec explications",
      "examples": ["Exemple pratique 1"],
      "exercises": ["Exercice 1"]
    }
  ]
}`
          },
          {
            role: "user",
            content: `Crée une formation complète sur : "${topic}".${details ? `\nDétails supplémentaires : ${details}` : ""}\nGénère entre 5 et 8 leçons structurées avec des exemples concrets et des exercices pratiques.`
          }
        ],
        tools: [
          {
            type: "function",
            function: {
              name: "create_formation",
              description: "Create a structured training course",
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
          }
        ],
        tool_choice: { type: "function", function: { name: "create_formation" } }
      }),
    });

    if (!response.ok) {
      const errText = await response.text();
      console.error("AI error:", response.status, errText);
      
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
      throw new Error("AI generation failed");
    }

    const aiData = await response.json();
    console.log("AI response received");

    // Extract structured data from tool call
    let formationContent;
    const toolCall = aiData.choices?.[0]?.message?.tool_calls?.[0];
    if (toolCall?.function?.arguments) {
      formationContent = JSON.parse(toolCall.function.arguments);
    } else {
      // Fallback: try parsing from content
      const content = aiData.choices?.[0]?.message?.content || "";
      const jsonMatch = content.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        formationContent = JSON.parse(jsonMatch[0]);
      } else {
        throw new Error("Could not parse AI response");
      }
    }

    // Update the formation in database with generated content
    const { error: updateError } = await supabase
      .from("formations")
      .update({
        title: formationContent.title || topic,
        description: formationContent.description,
        duration: formationContent.duration,
        lessons_count: formationContent.lessons?.length || 0,
        content: formationContent.lessons || [],
        status: "Terminé",
      })
      .eq("id", formationId)
      .eq("user_id", user.id);

    if (updateError) {
      console.error("DB update error:", updateError);
      throw new Error("Failed to save formation");
    }

    // Log success
    await supabase.from("system_logs").insert({
      user_id: user.id,
      module: "Formations",
      event: `Formation « ${formationContent.title} » générée par IA (${formationContent.lessons?.length} leçons)`,
      level: "success",
    });

    console.log("Formation generated successfully:", formationContent.title);

    return new Response(JSON.stringify({ success: true, formation: formationContent }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("generate-formation error:", e);
    return new Response(JSON.stringify({ error: e instanceof Error ? e.message : "Erreur inconnue" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
