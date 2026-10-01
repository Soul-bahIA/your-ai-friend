import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";

vi.mock("@/hooks/useAuth", () => ({ useAuth: () => ({ user: { id: "u1" }, session: null, loading: false, signOut: async () => {} }) }));
vi.mock("@/lib/capabilities", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/capabilities")>()),
  fetchCapabilities: vi.fn(),
}));

import { ApiError } from "@/lib/api";
import * as caps from "@/lib/capabilities";
import ModeBadge from "@/components/ModeBadge";

const fetchCapabilities = vi.mocked(caps.fetchCapabilities);

const report = (mode: caps.SoulbahMode, over: Partial<caps.CapabilitiesReport> = {}): caps.CapabilitiesReport => ({
  settings: { mode, label: caps.modeView(mode).label, cloud_models_allowed: mode === "HYBRID", internet_allowed: mode !== "OFFLINE", effective_max_agents: 2, resource_profile: "ECO" },
  models: { reachable: true },
  services: { "knowledge.fulltext": { status: "available", via: "local" }, "reasoning.plan": { status: "disabled", reason: "aucun modèle local en mode OFFLINE" } },
  runtimes: [{ id: "r1", hostname: "pc", status: "online", mode, capabilities: { "voice.stt": { status: "unavailable", reason: "LOT 11 V3" } } }],
  generated_at: new Date().toISOString(),
  ...over,
});

afterEach(() => {
  cleanup();
  fetchCapabilities.mockReset();
});

describe("modeView / limitations", () => {
  it("libellés et icônes des trois modes", () => {
    expect(caps.modeView("OFFLINE")).toMatchObject({ icon: "🟢", label: "OFFLINE — 100% LOCAL" });
    expect(caps.modeView("LOCAL_INTERNET")).toMatchObject({ icon: "🔵", label: "LOCAL + INTERNET" });
    expect(caps.modeView("HYBRID")).toMatchObject({ icon: "🟣", label: "HYBRID" });
    expect(caps.modeView("??").label).toBe("Mode inconnu");
  });

  it("liste les capacités indisponibles du serveur et des PC, avec leur raison", () => {
    expect(caps.limitations(report("OFFLINE"))).toEqual(["reasoning.plan : aucun modèle local en mode OFFLINE", "pc · voice.stt : LOT 11 V3"]);
  });
});

describe("<ModeBadge />", () => {
  it("affiche le mode et le nombre de limites, détail dans l'infobulle", async () => {
    fetchCapabilities.mockResolvedValue(report("OFFLINE"));
    render(<ModeBadge />);
    const badge = await screen.findByTestId("mode-badge");
    expect(badge.textContent).toContain("OFFLINE — 100% LOCAL");
    expect(badge.textContent).toContain("2 limite(s)");
    expect(badge.getAttribute("title")).toContain("aucun modèle local en mode OFFLINE");
    expect(badge.getAttribute("aria-label")).toBe("Mode OFFLINE — 100% LOCAL");
  });

  it("serveur antérieur (404) : rien n'est affiché", async () => {
    fetchCapabilities.mockRejectedValue(new ApiError("introuvable", 404));
    const { container } = render(<ModeBadge />);
    await waitFor(() => expect(fetchCapabilities).toHaveBeenCalled());
    expect(container.textContent).toBe("");
  });

  it("erreur réseau : « Mode : indisponible » plutôt qu'un mode inventé", async () => {
    fetchCapabilities.mockRejectedValue(new ApiError("Service indisponible", 503));
    render(<ModeBadge />);
    expect(await screen.findByText("Mode : indisponible")).toBeTruthy();
  });
});
