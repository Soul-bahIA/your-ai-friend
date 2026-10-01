import { useState, useCallback } from "react";
import { apiFetch, errorMessage } from "@/lib/api";
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
  row_data: Record<string, unknown>;
  created_at: string;
  updated_at: string;
}

export interface Migration {
  id: string;
  schema_id: string;
  migration_type: string;
  migration_details: unknown;
  applied_at: string;
}

interface DbResponse {
  error?: string;
  schemas?: UserSchema[];
  schema?: UserSchema;
  rows?: UserRow[];
  row?: UserRow;
  total?: number;
  migrations?: Migration[];
}

async function callDb(action: string, params: Record<string, unknown> = {}): Promise<DbResponse> {
  const data = (await apiFetch<DbResponse>("/api/database", {
    method: "POST",
    json: { action, ...params },
  })) ?? {};
  if (data.error) throw new Error(data.error);
  return data;
}

function required<T>(value: T | undefined, what: string): T {
  if (value === undefined || value === null) throw new Error(`Réponse du serveur incomplète (${what}).`);
  return value;
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
    } catch (e) {
      toast({ title: "Erreur", description: errorMessage(e), variant: "destructive" });
    } finally {
      setLoading(false);
    }
  }, [toast]);

  const createSchema = useCallback(async (table_name: string, columns: Column[], description?: string) => {
    const data = await callDb("create_schema", { table_name, columns, description });
    const schema = required(data.schema, "schema");
    setSchemas((prev) => [schema, ...prev]);
    toast({ title: "Table créée", description: `Table « ${table_name} » créée avec succès` });
    return schema;
  }, [toast]);

  const updateSchema = useCallback(async (schema_id: string, updates: Partial<Pick<UserSchema, "table_name" | "columns" | "description">>) => {
    const data = await callDb("update_schema", { schema_id, ...updates });
    const schema = required(data.schema, "schema");
    setSchemas((prev) => prev.map((s) => (s.id === schema_id ? schema : s)));
    toast({ title: "Table modifiée", description: "Migration appliquée avec succès" });
    return schema;
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
    } catch (e) {
      toast({ title: "Erreur", description: errorMessage(e), variant: "destructive" });
    } finally {
      setLoading(false);
    }
  }, [toast]);

  const insertRow = useCallback(async (schema_id: string, row_data: Record<string, unknown>) => {
    const data = await callDb("insert_data", { schema_id, row_data });
    const row = required(data.row, "row");
    setRows((prev) => [row, ...prev]);
    setTotalRows((prev) => prev + 1);
    return row;
  }, []);

  const updateRow = useCallback(async (row_id: string, row_data: Record<string, unknown>) => {
    const data = await callDb("update_data", { row_id, row_data });
    const row = required(data.row, "row");
    setRows((prev) => prev.map((r) => (r.id === row_id ? row : r)));
    return row;
  }, []);

  const deleteRow = useCallback(async (row_id: string) => {
    await callDb("delete_data", { row_id });
    setRows((prev) => prev.filter((r) => r.id !== row_id));
    setTotalRows((prev) => Math.max(0, prev - 1));
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
