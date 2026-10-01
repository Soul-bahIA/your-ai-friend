// V3 LOT 1 — mode de fonctionnement et registre des capacités (GET /api/v2/capabilities).
// L'utilisateur voit toujours le mode actif : 🟢 OFFLINE — 100% LOCAL · 🔵 LOCAL + INTERNET · 🟣 HYBRID.
import { ApiError, apiFetch } from "@/lib/api";

export type SoulbahMode = "OFFLINE" | "LOCAL_INTERNET" | "HYBRID";
export type CapabilityStatus = "available" | "unavailable" | "disabled";

export interface Capability {
  status: CapabilityStatus;
  via?: string;
  reason?: string;
}

export interface CapabilitiesReport {
  settings: {
    mode: SoulbahMode;
    label: string;
    cloud_models_allowed: boolean;
    internet_allowed: boolean;
    effective_max_agents: number;
    resource_profile: string;
  };
  models: { reachable: boolean; reasoning_available?: boolean | null; blocked_by_mode?: Record<string, string> };
  services: Record<string, Capability>;
  runtimes: { id: string; hostname: string | null; status: string; capabilities: Record<string, Capability> | null; mode: string | null }[];
  generated_at: string;
}

export async function fetchCapabilities(signal?: AbortSignal): Promise<CapabilitiesReport> {
  return apiFetch<CapabilitiesReport>("/api/v2/capabilities", { signal });
}

/** Route absente (serveur antérieur au LOT 1 V3) : l'indicateur reste masqué. */
export const isCapabilitiesUnavailable = (err: unknown): boolean => err instanceof ApiError && err.status === 404;

export interface ModeView {
  icon: string;
  label: string;
  /** Classes de couleur (texte + bordure) du badge. */
  tone: string;
  description: string;
}

export function modeView(mode: SoulbahMode | string | null | undefined): ModeView {
  switch (mode) {
    case "OFFLINE":
      return { icon: "🟢", label: "OFFLINE — 100% LOCAL", tone: "text-emerald-500 border-emerald-500/40", description: "Aucune connexion externe : modèles, données et outils locaux uniquement." };
    case "LOCAL_INTERNET":
      return { icon: "🔵", label: "LOCAL + INTERNET", tone: "text-sky-500 border-sky-500/40", description: "Modèles locaux ; Internet pour la recherche, la documentation et git." };
    case "HYBRID":
      return { icon: "🟣", label: "HYBRID", tone: "text-violet-500 border-violet-500/40", description: "Local prioritaire ; fournisseurs cloud configurés autorisés." };
    default:
      return { icon: "⚪", label: "Mode inconnu", tone: "text-muted-foreground border-border", description: "Mode non communiqué par le serveur." };
  }
}

/** Capacités non disponibles (plan de contrôle + PC), avec leur raison, pour l'infobulle. */
export function limitations(report: Pick<CapabilitiesReport, "services" | "runtimes">): string[] {
  const out: string[] = [];
  for (const [name, c] of Object.entries(report.services)) {
    if (c.status !== "available") out.push(`${name} : ${c.reason ?? c.status}`);
  }
  for (const rt of report.runtimes) {
    for (const [name, c] of Object.entries(rt.capabilities ?? {})) {
      if (c.status !== "available") out.push(`${rt.hostname ?? "PC"} · ${name} : ${c.reason ?? c.status}`);
    }
  }
  return out;
}
