import { useState, useCallback } from "react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { useToast } from "@/hooks/use-toast";

export interface Column {
  name: string;
  type: "text" | "number" | "boolean" | "date" | "json";
  required: boolean;
  default_value?: string;
}

export interface UserSchema {
  id: string;
  user_id: string;
  table_name: string;
  columns: Column[];
  description: string | null;
  created_at: string;
  updated_at: string;
}

export interface UserRow {
  id: string;
  schema_id: string;
  row_data: Record<string, any>;
  created_at: string;
  updated_at: string;
}

export interface Migration {
  id: string;
  schema_id: string;
  migration_type: string;
  migration_details: any;
  applied_at: string;
}

async function callDb(action: string, params: Record<string, any> = {}) {
  const { data, error } = await supabase.functions.invoke("manage-database", {
    body: { action, ...params },
  });
  if (error) throw new Error(error.message);
  if (data?.error) throw new Error(data.error);
  return data;
}

export function useDatabase() {
  const [schemas, setSchemas] = useState<UserSchema[]>([]);
  const [rows, setRows] = useState<UserRow[]>([]);
  const [migrations, setMigrations] = useState<Migration[]>([]);
  const [loading, setLoading] = useState(false);
  const [totalRows, setTotalRows] = useState(0);
  const { toast } = useToast();

  const loadSchemas = useCallback(async () => {
    setLoading(true);
    try {
      const data = await callDb("list_schemas");
      setSchemas(data.schemas || []);
    } catch (e: any) {
      toast({ title: "Erreur", description: e.message, variant: "destructive" });
    } finally {
      setLoading(false);
    }
  }, [toast]);

  const createSchema = useCallback(async (table_name: string, columns: Column[], description?: string) => {
    const data = await callDb("create_schema", { table_name, columns, description });
    setSchemas((prev) => [data.schema, ...prev]);
    toast({ title: "Table créée", description: `Table « ${table_name} » créée avec succès` });
    return data.schema;
  }, [toast]);

  const updateSchema = useCallback(async (schema_id: string, updates: Partial<Pick<UserSchema, "table_name" | "columns" | "description">>) => {
    const data = await callDb("update_schema", { schema_id, ...updates });
    setSchemas((prev) => prev.map((s) => (s.id === schema_id ? data.schema : s)));
    toast({ title: "Table modifiée", description: "Migration appliquée avec succès" });
    return data.schema;
  }, [toast]);

  const deleteSchema = useCallback(async (schema_id: string) => {
    await callDb("delete_schema", { schema_id });
    setSchemas((prev) => prev.filter((s) => s.id !== schema_id));
    toast({ title: "Table supprimée" });
  }, [toast]);

  const loadData = useCallback(async (schema_id: string, page = 1) => {
    setLoading(true);
    try {
      const data = await callDb("list_data", { schema_id, page });
      setRows(data.rows || []);
      setTotalRows(data.total || 0);
    } catch (e: any) {
      toast({ title: "Erreur", description: e.message, variant: "destructive" });
    } finally {
      setLoading(false);
    }
  }, [toast]);

  const insertRow = useCallback(async (schema_id: string, row_data: Record<string, any>) => {
    const data = await callDb("insert_data", { schema_id, row_data });
    setRows((prev) => [data.row, ...prev]);
    setTotalRows((prev) => prev + 1);
    return data.row;
  }, []);

  const updateRow = useCallback(async (row_id: string, row_data: Record<string, any>) => {
    const data = await callDb("update_data", { row_id, row_data });
    setRows((prev) => prev.map((r) => (r.id === row_id ? data.row : r)));
    return data.row;
  }, []);

  const deleteRow = useCallback(async (row_id: string) => {
    await callDb("delete_data", { row_id });
    setRows((prev) => prev.filter((r) => r.id !== row_id));
    setTotalRows((prev) => prev - 1);
  }, []);

  const loadMigrations = useCallback(async (schema_id?: string) => {
    const data = await callDb("get_migrations", { schema_id });
    setMigrations(data.migrations || []);
  }, []);

  return {
    schemas, rows, migrations, loading, totalRows,
    loadSchemas, createSchema, updateSchema, deleteSchema,
    loadData, insertRow, updateRow, deleteRow, loadMigrations,
  };
}
