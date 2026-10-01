import type { FastifyInstance, FastifyReply } from "fastify";
import { pool } from "../db.js";
import { requireUser } from "../auth.js";
import { logEvent } from "../services/logs.js";
import { clampInt, isUuid } from "../lib/sanitize.js";

// Port de l'edge function `manage-database`. Toutes les requêtes sont scopées par
// user_id (le pool tourne en direct sur Postgres, donc RLS non appliqué : on filtre
// explicitement, comme le faisait déjà l'edge function).

type Params = Record<string, unknown>;

export async function databaseRoutes(app: FastifyInstance): Promise<void> {
  app.post("/api/database", { preHandler: requireUser }, async (request, reply) => {
    const userId = request.user!.id;
    const body = (request.body ?? {}) as Params & { action?: string };
    const action = body.action;

    // Pas de try/catch ici : les erreurs inattendues remontent au gestionnaire global
    // (détail journalisé, message générique au client).
    {
      switch (action) {
        case "list_schemas":
          return await listSchemas(userId);
        case "create_schema":
          return await createSchema(userId, body, reply);
        case "update_schema":
          return await updateSchema(userId, body, reply);
        case "delete_schema":
          return await deleteSchema(userId, body, reply);
        case "list_data":
          return await listData(userId, body, reply);
        case "insert_data":
          return await insertData(userId, body, reply);
        case "update_data":
          return await updateData(userId, body, reply);
        case "delete_data":
          return await deleteData(userId, body, reply);
        case "get_migrations":
          return await getMigrations(userId, body);
        default:
          return reply.status(400).send({ error: `Action inconnue: ${String(action).slice(0, 50)}` });
      }
    }
  });
}

async function listSchemas(userId: string) {
  const { rows } = await pool.query(
    "SELECT * FROM user_schemas WHERE user_id = $1 ORDER BY created_at DESC",
    [userId],
  );
  return { schemas: rows };
}

async function createSchema(userId: string, p: Params, reply: FastifyReply) {
  const { table_name, columns, description } = p as {
    table_name?: string;
    columns?: unknown[];
    description?: string;
  };
  if (typeof table_name !== "string" || !table_name.trim() || !Array.isArray(columns) || columns.length === 0) {
    return reply.status(400).send({ error: "table_name et columns requis" });
  }
  if (table_name.length > 100 || columns.length > 200) {
    return reply.status(400).send({ error: "table_name (100 car.) ou columns (200) trop long" });
  }

  const { rows } = await pool.query(
    `INSERT INTO user_schemas (user_id, table_name, columns, description)
     VALUES ($1, $2, $3::jsonb, $4) RETURNING *`,
    [userId, table_name, JSON.stringify(columns), description ?? null],
  );
  const schema = rows[0];

  await pool.query(
    `INSERT INTO user_migrations (user_id, schema_id, migration_type, migration_details)
     VALUES ($1, $2, 'CREATE_TABLE', $3::jsonb)`,
    [userId, schema.id, JSON.stringify({ table_name, columns })],
  );
  await logEvent(userId, "Database", `Table « ${table_name} » créée`, "success");

  return { schema };
}

async function updateSchema(userId: string, p: Params, reply: FastifyReply) {
  const { schema_id, columns, table_name, description } = p as {
    schema_id?: string;
    columns?: unknown[];
    table_name?: string;
    description?: string;
  };
  if (!isUuid(schema_id)) return reply.status(400).send({ error: "schema_id requis" });
  if (columns !== undefined && (!Array.isArray(columns) || columns.length > 200)) {
    return reply.status(400).send({ error: "columns invalide" });
  }

  const sets: string[] = [];
  const values: unknown[] = [];
  let i = 1;
  if (columns !== undefined) { sets.push(`columns = $${i++}::jsonb`); values.push(JSON.stringify(columns)); }
  if (table_name !== undefined) { sets.push(`table_name = $${i++}`); values.push(table_name); }
  if (description !== undefined) { sets.push(`description = $${i++}`); values.push(description); }
  if (sets.length === 0) return reply.status(400).send({ error: "aucune modification fournie" });

  values.push(schema_id, userId);
  const { rows } = await pool.query(
    `UPDATE user_schemas SET ${sets.join(", ")} WHERE id = $${i++} AND user_id = $${i} RETURNING *`,
    values,
  );
  if (rows.length === 0) return reply.status(404).send({ error: "Schéma introuvable" });
  const schema = rows[0];

  await pool.query(
    `INSERT INTO user_migrations (user_id, schema_id, migration_type, migration_details)
     VALUES ($1, $2, 'ALTER_TABLE', $3::jsonb)`,
    [userId, schema_id, JSON.stringify({ changes: { columns, table_name, description } })],
  );

  return { schema };
}

async function deleteSchema(userId: string, p: Params, reply: FastifyReply) {
  const { schema_id } = p as { schema_id?: string };
  if (!isUuid(schema_id)) return reply.status(400).send({ error: "schema_id requis" });
  const { rowCount } = await pool.query("DELETE FROM user_schemas WHERE id = $1 AND user_id = $2", [schema_id, userId]);
  if (rowCount === 0) return reply.status(404).send({ error: "Schéma introuvable" });
  return { success: true };
}

async function listData(userId: string, p: Params, reply: FastifyReply) {
  const { schema_id } = p as { schema_id?: string };
  if (!isUuid(schema_id)) return reply.status(400).send({ error: "schema_id requis" });
  const page = clampInt(p.page, 1, 1, 100_000);
  const per_page = clampInt(p.per_page, 50, 1, 200);

  const from = (page - 1) * per_page;

  const countRes = await pool.query(
    "SELECT COUNT(*)::int AS total FROM user_table_data WHERE schema_id = $1 AND user_id = $2",
    [schema_id, userId],
  );
  const { rows } = await pool.query(
    `SELECT * FROM user_table_data WHERE schema_id = $1 AND user_id = $2
     ORDER BY created_at DESC LIMIT $3 OFFSET $4`,
    [schema_id, userId, per_page, from],
  );
  return { rows, total: countRes.rows[0].total, page, per_page };
}

async function insertData(userId: string, p: Params, reply: FastifyReply) {
  const { schema_id, row_data } = p as { schema_id?: string; row_data?: unknown };
  if (!isUuid(schema_id) || !row_data || typeof row_data !== "object") {
    return reply.status(400).send({ error: "schema_id et row_data requis" });
  }

  // Le schéma cible doit appartenir à l'utilisateur (sinon on pourrait rattacher des
  // lignes au schéma d'un autre compte).
  const { rows } = await pool.query(
    `INSERT INTO user_table_data (user_id, schema_id, row_data)
     SELECT $1::uuid, $2::uuid, $3::jsonb
      WHERE EXISTS (SELECT 1 FROM user_schemas WHERE id = $2::uuid AND user_id = $1::uuid)
     RETURNING *`,
    [userId, schema_id, JSON.stringify(row_data)],
  );
  if (rows.length === 0) return reply.status(404).send({ error: "Schéma introuvable" });
  return { row: rows[0] };
}

async function updateData(userId: string, p: Params, reply: FastifyReply) {
  const { row_id, row_data } = p as { row_id?: string; row_data?: unknown };
  if (!isUuid(row_id) || !row_data || typeof row_data !== "object") {
    return reply.status(400).send({ error: "row_id et row_data requis" });
  }

  const { rows } = await pool.query(
    `UPDATE user_table_data SET row_data = $1::jsonb
     WHERE id = $2 AND user_id = $3 RETURNING *`,
    [JSON.stringify(row_data), row_id, userId],
  );
  if (rows.length === 0) return reply.status(404).send({ error: "Ligne introuvable" });
  return { row: rows[0] };
}

async function deleteData(userId: string, p: Params, reply: FastifyReply) {
  const { row_id } = p as { row_id?: string };
  if (!isUuid(row_id)) return reply.status(400).send({ error: "row_id requis" });
  const { rowCount } = await pool.query("DELETE FROM user_table_data WHERE id = $1 AND user_id = $2", [row_id, userId]);
  if (rowCount === 0) return reply.status(404).send({ error: "Ligne introuvable" });
  return { success: true };
}

async function getMigrations(userId: string, p: Params) {
  const { schema_id } = p as { schema_id?: string };
  if (schema_id !== undefined && schema_id !== null && !isUuid(schema_id)) {
    return { migrations: [] };
  }
  if (schema_id) {
    const { rows } = await pool.query(
      `SELECT * FROM user_migrations WHERE user_id = $1 AND schema_id = $2
       ORDER BY applied_at DESC LIMIT 50`,
      [userId, schema_id],
    );
    return { migrations: rows };
  }
  const { rows } = await pool.query(
    "SELECT * FROM user_migrations WHERE user_id = $1 ORDER BY applied_at DESC LIMIT 50",
    [userId],
  );
  return { migrations: rows };
}
