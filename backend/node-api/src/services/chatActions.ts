import { pool } from "../db";
import { logEvent } from "../services/logs";
import { generateFormation, generateApplication } from "../clients/iaClient";

// Exécution des tool-calls du chat (create_formation / create_application / save_knowledge).
// Porté de l'`executeAction` de l'edge function `chat`.

export interface ChatAction {
  name: string;
  arguments: Record<string, any>;
}

export async function executeChatAction(userId: string, action: ChatAction): Promise<Record<string, unknown>> {
  const args = action.arguments ?? {};

  switch (action.name) {
    case "create_formation": {
      const ins = await pool.query(
        `INSERT INTO formations (user_id, title, description, status)
         VALUES ($1, $2, $3, 'En cours') RETURNING id`,
        [userId, args.topic, args.details || `Formation sur ${args.topic}`],
      );
      const id = ins.rows[0].id;
      try {
        const formation = await generateFormation({ topic: args.topic, details: args.details });
        const n = Array.isArray(formation.lessons) ? formation.lessons.length : 0;
        await pool.query(
          `UPDATE formations SET title=$1, description=$2, duration=$3,
             lessons_count=$4, content=$5::jsonb, status='Terminé' WHERE id=$6`,
          [formation.title ?? args.topic, formation.description ?? null, formation.duration ?? null, n, JSON.stringify(formation.lessons ?? []), id],
        );
        await logEvent(userId, "Formations", `Formation « ${formation.title} » créée via Chat IA`, "success");
        return { success: true, type: "formation", title: formation.title, id, lessonsCount: n };
      } catch {
        return { success: true, type: "formation", title: args.topic, id, status: "pending" };
      }
    }

    case "create_application": {
      const ins = await pool.query(
        `INSERT INTO applications (user_id, title, description, status)
         VALUES ($1, $2, $3, 'En cours') RETURNING id`,
        [userId, args.appName, args.appDesc || `Application ${args.appName}`],
      );
      const id = ins.rows[0].id;
      try {
        const appContent = await generateApplication({ appName: args.appName, appDesc: args.appDesc });
        await pool.query(
          `UPDATE applications SET title=$1, description=$2, app_type=$3,
             tech_stack=$4, source_code=$5::jsonb, status='Généré' WHERE id=$6`,
          [
            appContent.title ?? args.appName,
            appContent.description ?? null,
            appContent.app_type ?? "Web App",
            appContent.tech_stack ?? "React + TypeScript",
            JSON.stringify(appContent.architecture ?? {}),
            id,
          ],
        );
        await logEvent(userId, "Applications", `Application « ${appContent.title} » créée via Chat IA`, "success");
        return { success: true, type: "application", title: appContent.title, id };
      } catch {
        return { success: true, type: "application", title: args.appName, id, status: "pending" };
      }
    }

    case "save_knowledge": {
      await pool.query(
        `INSERT INTO knowledge_base (user_id, title, content, category, tags)
         VALUES ($1, $2, $3, $4, $5)`,
        [userId, args.title, args.content, args.category || "general", args.tags || []],
      );
      await logEvent(userId, "Connaissances", `Connaissance « ${args.title} » sauvegardée via Chat IA`, "success");
      return { success: true, type: "knowledge", title: args.title };
    }

    default:
      return { success: false, error: `Action inconnue: ${action.name}` };
  }
}
