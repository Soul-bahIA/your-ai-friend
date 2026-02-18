import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const toolSchema = {
  type: "function",
  function: {
    name: "create_application",
    description: "Create or update a complete application architecture. Return the FULL updated architecture.",
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
};

function repairAndParseJson(raw: string): unknown {
  // Step 1: Strip markdown
  let cleaned = raw
    .replace(/```json\s*/gi, "")
    .replace(/```\s*/g, "")
    .trim();

  // Step 2: Find JSON boundaries
  const jsonStart = cleaned.search(/\{/);
  const jsonEnd = cleaned.lastIndexOf("}");
  if (jsonStart === -1 || jsonEnd === -1 || jsonEnd <= jsonStart) {
    throw new Error("No JSON object found in response");
  }
  cleaned = cleaned.substring(jsonStart, jsonEnd + 1);

  // Step 3: Try direct parse
  try {
    return JSON.parse(cleaned);
  } catch { /* continue to repair */ }

  // Step 4: Fix common issues
  cleaned = cleaned
    .replace(/,\s*}/g, "}")
    .replace(/,\s*]/g, "]")
    .replace(/[\x00-\x1F\x7F]/g, "")
    .replace(/\\'/g, "'");

  try {
    return JSON.parse(cleaned);
  } catch { /* continue to repair brackets */ }

  // Step 5: Repair unbalanced braces/brackets
  let braces = 0, brackets = 0;
  for (const char of cleaned) {
    if (char === '{') braces++;
    if (char === '}') braces--;
    if (char === '[') brackets++;
    if (char === ']') brackets--;
  }
  while (brackets > 0) { cleaned += ']'; brackets--; }
  while (braces > 0) { cleaned += '}'; braces--; }

  return JSON.parse(cleaned);
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { appName, appDesc, applicationId, conversationHistory, existingArchitecture } = await req.json();

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

    const isImprovement = !!conversationHistory?.length && !!existingArchitecture;

    const systemPrompt = isImprovement
      ? `Tu es un architecte logiciel expert. L'utilisateur demande de modifier une application existante.
RÈGLES IMPORTANTES:
- Tu DOIS appliquer exactement la modification demandée (ajout, suppression, renommage, etc.)
- Tu DOIS retourner l'architecture COMPLÈTE mise à jour, pas seulement les parties modifiées
- Si l'utilisateur demande de SUPPRIMER un élément, retire-le complètement de l'architecture
- Si l'utilisateur demande de MODIFIER un élément, change-le dans l'architecture
- Si l'utilisateur demande d'AJOUTER un élément, ajoute-le à l'architecture existante

Voici l'architecture ACTUELLE de l'application que tu dois modifier:
${JSON.stringify(existingArchitecture, null, 2)}`
      : `Tu es un architecte logiciel expert. Tu conçois des applications complètes.`;

    const messages: Array<{role: string; content: string}> = [
      { role: "system", content: systemPrompt }
    ];

    if (isImprovement) {
      for (const msg of conversationHistory) {
        messages.push({ role: msg.role, content: msg.content });
      }
    } else {
      messages.push({
        role: "user",
        content: `Conçois l'architecture complète de l'application : "${appName}".${appDesc ? `\nDescription : ${appDesc}` : ""}\nInclus : composants frontend avec code, API backend, schéma de base de données.`
      });
    }

    console.log("Generating application for:", appName, isImprovement ? "(improvement)" : "(new)");

    const response = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "google/gemini-3-flash-preview",
        messages,
        tools: [toolSchema],
        tool_choice: { type: "function", function: { name: "create_application" } }
      }),
    });

    if (!response.ok) {
      const errText = await response.text();
      console.error("AI error:", response.status, errText);
      if (response.status === 429) {
        return new Response(JSON.stringify({ error: "Trop de requêtes. Réessayez dans quelques secondes." }), {
          status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (response.status === 402) {
        return new Response(JSON.stringify({ error: "Crédits IA épuisés." }), {
          status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      throw new Error("AI generation failed: " + response.status);
    }

    const aiData = await response.json();
    
    let appContent;
    
    // Try tool_calls first
    const toolCall = aiData.choices?.[0]?.message?.tool_calls?.[0];
    if (toolCall?.function?.arguments) {
      console.log("Parsing tool call arguments, length:", toolCall.function.arguments.length);
      try {
        appContent = JSON.parse(toolCall.function.arguments);
      } catch {
        console.log("Direct parse failed, attempting repair...");
        appContent = repairAndParseJson(toolCall.function.arguments);
      }
    } else {
      // Fallback: parse from content
      const content = aiData.choices?.[0]?.message?.content || "";
      console.log("No tool call, parsing from content, length:", content.length);
      if (!content) {
        throw new Error("Empty AI response");
      }
      appContent = repairAndParseJson(content);
    }
    
    // Normalize structure
    if (!appContent.architecture && appContent.frontend) {
      appContent = {
        title: appContent.title || appName,
        description: appContent.description || "",
        app_type: appContent.app_type || "Web App",
        tech_stack: appContent.tech_stack || "React + TypeScript",
        architecture: {
          frontend: appContent.frontend,
          backend: appContent.backend,
          database: appContent.database,
        }
      };
    }
    
    // Ensure required fields
    appContent.title = appContent.title || appName;
    appContent.description = appContent.description || "";
    appContent.app_type = appContent.app_type || "Web App";
    appContent.tech_stack = appContent.tech_stack || "React + TypeScript";
    appContent.architecture = appContent.architecture || {};

    const { error: updateError } = await supabase
      .from("applications")
      .update({
        title: appContent.title,
        description: appContent.description,
        app_type: appContent.app_type,
        tech_stack: appContent.tech_stack,
        source_code: appContent.architecture,
        status: "Généré",
      })
      .eq("id", applicationId)
      .eq("user_id", user.id);

    if (updateError) {
      console.error("DB update error:", updateError);
      throw new Error("Failed to save application");
    }

    const eventLabel = isImprovement ? "améliorée" : "générée";
    await supabase.from("system_logs").insert({
      user_id: user.id,
      module: "Applications",
      event: `Application « ${appContent.title} » ${eventLabel} par IA`,
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
