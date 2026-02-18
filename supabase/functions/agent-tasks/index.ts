import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-agent-key",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabaseAdmin = createClient(supabaseUrl, serviceKey);

  const url = new URL(req.url);
  const action = url.searchParams.get("action");

  // Agent polling endpoint (uses agent key for auth)
  const agentKey = req.headers.get("x-agent-key");

  try {
    if (action === "poll" && agentKey) {
      // Agent polls for pending tasks
      // Validate agent key against user's stored key
      const userId = url.searchParams.get("user_id");
      if (!userId) {
        return new Response(JSON.stringify({ error: "user_id required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Fetch pending tasks for this user
      const { data: tasks, error } = await supabaseAdmin
        .from("agent_tasks")
        .select("*")
        .eq("user_id", userId)
        .eq("status", "pending")
        .order("priority", { ascending: true })
        .order("created_at", { ascending: true })
        .limit(5);

      if (error) throw error;

      return new Response(JSON.stringify({ tasks: tasks || [] }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (action === "update" && agentKey) {
      // Agent updates task status/result
      const body = await req.json();
      const { task_id, status, result, error_message } = body;

      const updateData: any = { status, updated_at: new Date().toISOString() };
      if (result) updateData.result = result;
      if (error_message) updateData.error_message = error_message;
      if (status === "in_progress") updateData.started_at = new Date().toISOString();
      if (status === "completed" || status === "failed") updateData.completed_at = new Date().toISOString();

      const { error } = await supabaseAdmin
        .from("agent_tasks")
        .update(updateData)
        .eq("id", task_id);

      if (error) throw error;

      return new Response(JSON.stringify({ success: true }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Web app creates tasks (authenticated via JWT)
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Non authentifié" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabaseUser = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user }, error: authError } = await supabaseUser.auth.getUser();
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Non authentifié" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (req.method === "POST") {
      const body = await req.json();
      const { task_type, payload, priority } = body;

      const { data, error } = await supabaseAdmin
        .from("agent_tasks")
        .insert({
          user_id: user.id,
          task_type,
          payload,
          priority: priority || 5,
        })
        .select()
        .single();

      if (error) throw error;

      return new Response(JSON.stringify({ success: true, task: data }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (req.method === "GET") {
      const status = url.searchParams.get("status");
      let query = supabaseAdmin
        .from("agent_tasks")
        .select("*")
        .eq("user_id", user.id)
        .order("created_at", { ascending: false })
        .limit(50);

      if (status) query = query.eq("status", status);

      const { data, error } = await query;
      if (error) throw error;

      return new Response(JSON.stringify({ tasks: data }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ error: "Méthode non supportée" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("Agent tasks error:", err);
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
