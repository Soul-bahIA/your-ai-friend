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
    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.replace("Bearer ", "");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) {
      return json({ error: "Non autorisé" }, 401);
    }

    const { action, ...params } = await req.json();

    switch (action) {
      case "list_schemas":
        return await listSchemas(supabase, user.id);
      case "create_schema":
        return await createSchema(supabase, user.id, params);
      case "update_schema":
        return await updateSchema(supabase, user.id, params);
      case "delete_schema":
        return await deleteSchema(supabase, user.id, params);
      case "list_data":
        return await listData(supabase, user.id, params);
      case "insert_data":
        return await insertData(supabase, user.id, params);
      case "update_data":
        return await updateData(supabase, user.id, params);
      case "delete_data":
        return await deleteData(supabase, user.id, params);
      case "get_migrations":
        return await getMigrations(supabase, user.id, params);
      default:
        return json({ error: `Action inconnue: ${action}` }, 400);
    }
  } catch (e) {
    console.error("manage-database error:", e);
    return json({ error: e instanceof Error ? e.message : "Erreur inconnue" }, 500);
  }
});

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function listSchemas(supabase: any, userId: string) {
  const { data, error } = await supabase
    .from("user_schemas")
    .select("*")
    .eq("user_id", userId)
    .order("created_at", { ascending: false });
  if (error) return json({ error: error.message }, 500);
  return json({ schemas: data });
}

async function createSchema(supabase: any, userId: string, params: any) {
  const { table_name, columns, description } = params;
  if (!table_name || !columns?.length) {
    return json({ error: "table_name et columns requis" }, 400);
  }

  const { data, error } = await supabase.from("user_schemas").insert({
    user_id: userId,
    table_name,
    columns,
    description: description || null,
  }).select().single();

  if (error) return json({ error: error.message }, 500);

  // Log migration
  await supabase.from("user_migrations").insert({
    user_id: userId,
    schema_id: data.id,
    migration_type: "CREATE_TABLE",
    migration_details: { table_name, columns },
  });

  await supabase.from("system_logs").insert({
    user_id: userId,
    module: "Database",
    event: `Table « ${table_name} » créée`,
    level: "success",
  });

  return json({ schema: data });
}

async function updateSchema(supabase: any, userId: string, params: any) {
  const { schema_id, columns, table_name, description } = params;
  if (!schema_id) return json({ error: "schema_id requis" }, 400);

  const updates: any = {};
  if (columns) updates.columns = columns;
  if (table_name) updates.table_name = table_name;
  if (description !== undefined) updates.description = description;

  const { data, error } = await supabase
    .from("user_schemas")
    .update(updates)
    .eq("id", schema_id)
    .eq("user_id", userId)
    .select()
    .single();

  if (error) return json({ error: error.message }, 500);

  await supabase.from("user_migrations").insert({
    user_id: userId,
    schema_id,
    migration_type: "ALTER_TABLE",
    migration_details: { changes: updates },
  });

  return json({ schema: data });
}

async function deleteSchema(supabase: any, userId: string, params: any) {
  const { schema_id } = params;
  if (!schema_id) return json({ error: "schema_id requis" }, 400);

  const { error } = await supabase
    .from("user_schemas")
    .delete()
    .eq("id", schema_id)
    .eq("user_id", userId);

  if (error) return json({ error: error.message }, 500);
  return json({ success: true });
}

async function listData(supabase: any, userId: string, params: any) {
  const { schema_id, page = 1, per_page = 50 } = params;
  if (!schema_id) return json({ error: "schema_id requis" }, 400);

  const from = (page - 1) * per_page;
  const to = from + per_page - 1;

  const { data, error, count } = await supabase
    .from("user_table_data")
    .select("*", { count: "exact" })
    .eq("schema_id", schema_id)
    .eq("user_id", userId)
    .order("created_at", { ascending: false })
    .range(from, to);

  if (error) return json({ error: error.message }, 500);
  return json({ rows: data, total: count, page, per_page });
}

async function insertData(supabase: any, userId: string, params: any) {
  const { schema_id, row_data } = params;
  if (!schema_id || !row_data) return json({ error: "schema_id et row_data requis" }, 400);

  const { data, error } = await supabase.from("user_table_data").insert({
    user_id: userId,
    schema_id,
    row_data,
  }).select().single();

  if (error) return json({ error: error.message }, 500);
  return json({ row: data });
}

async function updateData(supabase: any, userId: string, params: any) {
  const { row_id, row_data } = params;
  if (!row_id || !row_data) return json({ error: "row_id et row_data requis" }, 400);

  const { data, error } = await supabase
    .from("user_table_data")
    .update({ row_data })
    .eq("id", row_id)
    .eq("user_id", userId)
    .select()
    .single();

  if (error) return json({ error: error.message }, 500);
  return json({ row: data });
}

async function deleteData(supabase: any, userId: string, params: any) {
  const { row_id } = params;
  if (!row_id) return json({ error: "row_id requis" }, 400);

  const { error } = await supabase
    .from("user_table_data")
    .delete()
    .eq("id", row_id)
    .eq("user_id", userId);

  if (error) return json({ error: error.message }, 500);
  return json({ success: true });
}

async function getMigrations(supabase: any, userId: string, params: any) {
  const { schema_id } = params;
  const query = supabase
    .from("user_migrations")
    .select("*")
    .eq("user_id", userId)
    .order("applied_at", { ascending: false })
    .limit(50);

  if (schema_id) query.eq("schema_id", schema_id);

  const { data, error } = await query;
  if (error) return json({ error: error.message }, 500);
  return json({ migrations: data });
}
