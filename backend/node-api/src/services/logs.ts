import { pool } from "../db.js";

/** Insère un événement dans system_logs (best-effort, n'échoue jamais l'appelant). */
export async function logEvent(
  userId: string,
  module: string,
  event: string,
  level: "info" | "success" | "warning" | "error" = "info",
): Promise<void> {
  try {
    await pool.query(
      "INSERT INTO system_logs (user_id, module, event, level) VALUES ($1, $2, $3, $4)",
      [userId, module, event, level],
    );
  } catch {
    // journalisation best-effort : on ignore les erreurs de log
  }
}
