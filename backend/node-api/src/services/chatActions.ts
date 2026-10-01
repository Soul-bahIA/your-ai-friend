import { pool } from "../db";
import { logEvent } from "../services/logs";
import { generateFormation, generateApplication, ServiceError } from "../clients/iaClient";
import { activeGenerations } from "./activeJobs";
import { logger } from "../lib/logger";

// Exécution des tool-calls du chat (create_formation / create_application / save_knowledge).
// Porté de l'`executeAction` de l'edge function `chat`. Les arguments sont validés en amont
// (lib/chatValidation.ts). En cas d'échec de génération, la ligne passe en 'Erreur' et
// l'échec est RAPPORTÉ (success:false) — plus de faux succès « pending ».

export interface ChatAction {
  name: string;
  arguments: Record<string, any>;
}

const str = (v: unknown, max: number): string | null =>
  typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null;

function publicMessage(e: unknown): string {
  return e instanceof ServiceError ? e.message : "Erreur interne lors de la génération";
}

export async function executeChatAction(userId: string, action: ChatAction): Promise<Record<string, unknown>> {
  const args = action.arguments ?? {};

  switch (action.name) {
    case "create_formation": {
      const topic = str(args.topic, 500)!;
      const details = str(args.details, 5000);
      const ins = await pool.query(
        `INSERT INTO formations (user_id, title, description, status)
         VALUES ($1, $2, $3, 'En cours') RETURNING id`,
        [userId, topic, details || `Formation sur ${topic}`],
      );
      const id = ins.rows[0].id as string;
      activeGenerations.add(id);
      try {
        const formation = await generateFormation({ topic, details });
        const n = Array.isArray(formation.lessons) ? formation.lessons.length : 0;
        await pool.query(
          `UPDATE formations SET title=$1, description=$2, duration=$3,
             lessons_count=$4, content=$5::jsonb, status='Terminé' WHERE id=$6 AND user_id=$7`,
          [formation.title ?? topic, formation.description ?? null, formation.duration ?? null, n, JSON.stringify(formation.lessons ?? []), id, userId],
        );
        await logEvent(userId, "Formations", `Formation « ${formation.title ?? topic} » créée via Chat IA`, "success");
        return { success: true, type: "formation", title: formation.title ?? topic, id, lessonsCount: n };
      } catch (e) {
        logger.error({ err: (e as Error).message, formationId: id }, "génération de formation (chat) échouée");
        await pool
          .query("UPDATE formations SET status = 'Erreur' WHERE id = $1 AND user_id = $2", [id, userId])
          .catch(() => {});
        await logEvent(userId, "Formations", `Échec de la génération de « ${topic} » via Chat IA`, "error");
        return { success: false, type: "formation", title: topic, id, status: "error", error: publicMessage(e) };
      } finally {
        activeGenerations.delete(id);
      }
    }

    case "create_application": {
      const appName = str(args.appName, 200)!;
      const appDesc = str(args.appDesc, 5000);
      const ins = await pool.query(
        `INSERT INTO applications (user_id, title, description, status)
         VALUES ($1, $2, $3, 'En cours') RETURNING id`,
        [userId, appName, appDesc || `Application ${appName}`],
      );
      const id = ins.rows[0].id as string;
      activeGenerations.add(id);
      try {
        const appContent = await generateApplication({ appName, appDesc });
        await pool.query(
          `UPDATE applications SET title=$1, description=$2, app_type=$3,
             tech_stack=$4, source_code=$5::jsonb, status='Généré' WHERE id=$6 AND user_id=$7`,
          [
            appContent.title ?? appName,
            appContent.description ?? null,
            appContent.app_type ?? "Web App",
            appContent.tech_stack ?? "React + TypeScript",
            JSON.stringify(appContent.architecture ?? {}),
            id,
            userId,
          ],
        );
        await logEvent(userId, "Applications", `Application « ${appContent.title ?? appName} » créée via Chat IA`, "success");
        return { success: true, type: "application", title: appContent.title ?? appName, id };
      } catch (e) {
        logger.error({ err: (e as Error).message, applicationId: id }, "génération d'application (chat) échouée");
        await pool
          .query("UPDATE applications SET status = 'Erreur' WHERE id = $1 AND user_id = $2", [id, userId])
          .catch(() => {});
        await logEvent(userId, "Applications", `Échec de la génération de « ${appName} » via Chat IA`, "error");
        return { success: false, type: "application", title: appName, id, status: "error", error: publicMessage(e) };
      } finally {
        activeGenerations.delete(id);
      }
    }

    case "save_knowledge": {
      const title = str(args.title, 500)!;
      const content = str(args.content, 50_000)!;
      const tags = Array.isArray(args.tags)
        ? args.tags.filter((t: unknown): t is string => typeof t === "string").map((t: string) => t.slice(0, 50)).slice(0, 20)
        : [];
      await pool.query(
        `INSERT INTO knowledge_base (user_id, title, content, category, tags)
         VALUES ($1, $2, $3, $4, $5)`,
        [userId, title, content, str(args.category, 50) || "general", tags],
      );
      await logEvent(userId, "Connaissances", `Connaissance « ${title} » sauvegardée via Chat IA`, "success");
      return { success: true, type: "knowledge", title };
    }

    default:
      return { success: false, error: `Action inconnue: ${action.name}` };
  }
}
