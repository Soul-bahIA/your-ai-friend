// V3 LOT 1 — registre des capacités (mission V3 §84-86) : ce que Soulbah peut RÉELLEMENT faire
// maintenant, selon le mode (OFFLINE / LOCAL_INTERNET / HYBRID), les modèles joignables et les
// PC enregistrés. L'interface affiche le mode ; le planificateur et l'utilisateur savent ce qui
// est indisponible et pourquoi, au lieu de découvrir un échec d'appel cloud.
//
//   GET /api/v2/capabilities (JWT)
//     { settings, models, services, runtimes, generated_at }
//   Statuts : available | unavailable (raison) | disabled (refusé par le mode ou la configuration).
import type { FastifyInstance } from "fastify";
import { pool } from "../../db.js";
import { requireUser } from "../../auth.js";
import { modelsStatus, type ModelsStatus } from "../../clients/iaClient.js";
import { cloudModelsAllowed, currentResolution, internetAllowed, publicView, type SoulbahSettings } from "../../lib/soulbahSettings.js";
import { networkGuardStatus } from "../../lib/networkGuard.js";
import { resolveChatProvider } from "../../services/chatProvider.js";
import { getWebSearchProvider } from "../../services/research/webSearch.js";

export type CapabilityStatus = "available" | "unavailable" | "disabled";
export interface Capability {
  status: CapabilityStatus;
  via?: string;
  reason?: string;
}

const ok = (via: string): Capability => ({ status: "available", via });
const no = (reason: string): Capability => ({ status: "unavailable", reason });
const off = (reason: string): Capability => ({ status: "disabled", reason });

/** Capacités du plan de contrôle et des modèles (fonction pure, testée sans réseau). */
export function serviceCapabilities(settings: SoulbahSettings, models: ModelsStatus | null, env: NodeJS.ProcessEnv = process.env): Record<string, Capability> {
  const caps: Record<string, Capability> = {};
  caps["orchestration.dag"] = ok("local");
  caps["evaluation.rules"] = ok("local");
  caps["knowledge.fulltext"] = ok("local");

  if (!models) {
    caps["reasoning.plan"] = no("service de modèles (python-ia) injoignable");
    caps["vision.judge"] = no("service de modèles (python-ia) injoignable");
  } else {
    const configured = models.configured ?? [];
    const via = configured.includes("local") ? "local" : configured.length ? `cloud:${configured.join(",")}` : "";
    caps["reasoning.plan"] = models.reasoning_available
      ? ok(via)
      : Object.keys(models.blocked_by_mode ?? {}).length
        ? off(`aucun modèle local en mode ${settings.mode} (fournisseurs cloud refusés : ${Object.keys(models.blocked_by_mode ?? {}).join(", ")}) — LOCAL_LLM_URL`)
        : no("aucun fournisseur de modèle configuré");
    caps["vision.judge"] = models.vision_available ? ok(via) : no("aucun modèle à vision disponible (vision locale : LOT 9 V3)");
  }

  const chat = resolveChatProvider(env, settings);
  caps["chat"] = chat ? ok(chat.provider === "local" ? "local" : `cloud:${chat.provider}`) : cloudModelsAllowed(settings) ? no("aucun fournisseur de chat configuré") : off(`aucun modèle local de chat en mode ${settings.mode} (LOCAL_LLM_URL)`);

  const web = getWebSearchProvider() as { id: string; available: boolean; reason?: string };
  caps["web.search"] = !internetAllowed(settings) ? off("recherche web désactivée en mode OFFLINE") : web.available ? ok(`internet:${web.id}`) : no(web.reason ?? "aucune clé de recherche web configurée");

  caps["knowledge.vector"] = !cloudModelsAllowed(settings)
    ? no(`embeddings cloud refusés en mode ${settings.mode} — embeddings locaux : LOT 7 V3 (recherche plein texte active)`)
    : env.OPENAI_API_KEY
      ? ok("cloud:openai")
      : no("aucune clé d'embeddings (recherche plein texte active)");

  caps["voice.tts.server"] = cloudModelsAllowed(settings) && env.OPENAI_API_KEY ? ok("cloud:openai") : no("synthèse vocale locale : LOT 11 V3");
  caps["voice.stt"] = no("reconnaissance vocale locale : LOT 11 V3");
  const guard = networkGuardStatus();
  caps["network.guard"] = !guard.installed
    ? no("NetworkGuard non installé dans ce processus")
    : guard.active
      ? ok(`actif : connexions vers Internet refusées (${guard.blocked} refus)`)
      : ok(`installé, inactif en mode ${settings.mode} (Internet autorisé)`);
  return caps;
}

export async function capabilityRoutes(app: FastifyInstance): Promise<void> {
  app.get("/api/v2/capabilities", { preHandler: requireUser }, async (request) => {
    const resolution = currentResolution();
    const settings = resolution.settings;
    const models = await modelsStatus();
    const { rows } = await pool.query(
      `SELECT id, hostname, version, status, max_slots, capabilities, last_seen_at
         FROM soulbah.runtimes WHERE user_id = $1 ORDER BY last_seen_at DESC NULLS LAST LIMIT 20`,
      [request.user!.id],
    );
    return {
      settings: { ...publicView(settings), source: { file: resolution.source.file ? "fichier de configuration" : null, env: resolution.source.env } },
      models: models
        ? { reachable: true, mode: models.mode ?? null, reasoning_available: models.reasoning_available ?? null, vision_available: models.vision_available ?? null, local_configured: models.local_configured ?? null, blocked_by_mode: models.blocked_by_mode ?? {} }
        : { reachable: false },
      services: serviceCapabilities(settings, models),
      runtimes: rows.map((r) => {
        const caps = (r.capabilities ?? {}) as Record<string, unknown>;
        return {
          id: r.id,
          hostname: r.hostname,
          version: r.version,
          status: r.status,
          max_slots: r.max_slots,
          last_seen_at: r.last_seen_at,
          hardware: caps.hardware ?? null,
          capabilities: caps.local ?? null,
          mode: caps.mode ?? null,
        };
      }),
      generated_at: new Date().toISOString(),
    };
  });
}
