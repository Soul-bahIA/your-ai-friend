import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";

const toastMock = vi.fn();
vi.mock("@/hooks/use-toast", () => ({ useToast: () => ({ toast: toastMock }) }));
vi.mock("@/hooks/useAuth", () => ({ useAuth: () => ({ user: { id: "u1" }, session: null, loading: false, signOut: async () => {} }) }));
vi.mock("@/lib/approvals", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/approvals")>();
  return {
    ...actual,
    listApprovals: vi.fn(),
    approveApproval: vi.fn(),
    denyApproval: vi.fn(),
    verifyAuditChain: vi.fn(),
    listAudit: vi.fn(),
  };
});

import { ApiError } from "@/lib/api";
import * as approvalsLib from "@/lib/approvals";
import ApprovalsInbox from "@/components/ApprovalsInbox";

const listApprovals = vi.mocked(approvalsLib.listApprovals);
const approveApproval = vi.mocked(approvalsLib.approveApproval);
const verifyAuditChain = vi.mocked(approvalsLib.verifyAuditChain);
const listAudit = vi.mocked(approvalsLib.listAudit);

const approval = (over: Partial<approvalsLib.Approval> = {}): approvalsLib.Approval => ({
  id: "ap-1",
  status: "pending",
  security_level: "L2",
  kind: "request",
  tool: "write_file",
  summary: "Écrire le rapport",
  task_id: "task-1234-5678",
  attempt: 1,
  step_index: 0,
  payload_presented: { path: "C:\\rapport.md", content: "Texte intégral du fichier" },
  payload_sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  reason: null,
  created_at: "2026-10-01T09:59:00Z",
  expires_at: new Date(Date.now() + 5 * 60_000).toISOString(),
  decided_at: null,
  ...over,
});

beforeEach(() => {
  listApprovals.mockResolvedValue([]);
  approveApproval.mockResolvedValue({ id: "ap-1", status: "approved", expires_at: null });
  verifyAuditChain.mockResolvedValue({ ok: false, checked: 12, broken_at: 7 });
  listAudit.mockResolvedValue([
    { seq: 12, action: "approval.approved", actor: "u1", entity: "approval", entity_id: "ap-1", data: {}, created_at: "2026-10-01T10:00:00Z" },
  ]);
});

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

describe("ApprovalsInbox", () => {
  it("affiche l'état vide quand rien n'est en attente", async () => {
    render(<ApprovalsInbox pollMs={0} />);
    expect(await screen.findByText(/Aucune demande en attente/)).toBeInTheDocument();
    expect(listApprovals).toHaveBeenCalledWith("pending", expect.any(AbortSignal), 50);
  });

  it("affiche la demande avec niveau, outil, contenu exact, empreinte abrégée, et approuve avec l'empreinte affichée", async () => {
    listApprovals.mockResolvedValue([approval()]);
    render(<ApprovalsInbox pollMs={0} />);

    expect(await screen.findByText("write_file")).toBeInTheDocument();
    expect(screen.getByText(/L2 · effet réel/)).toBeInTheDocument();
    expect(screen.getByText("Écrire le rapport")).toBeInTheDocument();
    // Payload complet, non masqué (S7), clés triées.
    const pre = screen.getByLabelText("Contenu de la demande ap-1");
    expect(pre.textContent).toContain('"content": "Texte intégral du fichier"');
    expect(pre.textContent).toContain('"path": "C:\\\\rapport.md"');
    expect(pre.textContent!.indexOf('"content"')).toBeLessThan(pre.textContent!.indexOf('"path"'));
    expect(screen.getByText(/sha256 01234567…cdef/)).toBeInTheDocument();
    expect(screen.getByRole("timer")).toHaveTextContent(/min/);

    // L2 : approbation directe, empreinte renvoyée telle quelle.
    fireEvent.click(screen.getByRole("button", { name: /Approuver/ }));
    await waitFor(() => expect(approveApproval).toHaveBeenCalledWith("ap-1", approval().payload_sha256));
    await waitFor(() => expect(toastMock).toHaveBeenCalledWith(expect.objectContaining({ title: "Action approuvée" })));
    // Rafraîchissement après décision.
    await waitFor(() => expect(listApprovals.mock.calls.length).toBeGreaterThanOrEqual(2));
  });

  it("L3 : exige la saisie du mot AUTORISER avant d'approuver", async () => {
    listApprovals.mockResolvedValue([approval({ id: "ap-3", security_level: "L3", tool: "git_push" })]);
    render(<ApprovalsInbox pollMs={0} />);

    fireEvent.click(await screen.findByRole("button", { name: /Approuver/ }));
    expect(approveApproval).not.toHaveBeenCalled();
    const dialog = await screen.findByRole("dialog");
    expect(dialog).toHaveTextContent(/Autoriser une action irréversible/);
    const confirm = screen.getByRole("button", { name: "Autoriser" });
    expect(confirm).toBeDisabled();

    fireEvent.change(screen.getByLabelText("Mot de confirmation"), { target: { value: "autoriser" } });
    expect(confirm).toBeDisabled();
    fireEvent.change(screen.getByLabelText("Mot de confirmation"), { target: { value: "AUTORISER" } });
    expect(confirm).toBeEnabled();
    fireEvent.click(confirm);
    await waitFor(() => expect(approveApproval).toHaveBeenCalledWith("ap-3", approval().payload_sha256));
  });

  it("signale un 409 comme demande périmée", async () => {
    listApprovals.mockResolvedValue([approval()]);
    approveApproval.mockRejectedValue(new ApiError("Empreinte différente", 409));
    render(<ApprovalsInbox pollMs={0} />);
    fireEvent.click(await screen.findByRole("button", { name: /Approuver/ }));
    await waitFor(() =>
      expect(toastMock).toHaveBeenCalledWith(
        expect.objectContaining({ title: "Demande modifiée ou plus en attente", variant: "destructive" }),
      ),
    );
  });

  it("serveur V1 (404) : message explicite et arrêt du polling", async () => {
    listApprovals.mockRejectedValue(new ApiError("Not Found", 404));
    render(<ApprovalsInbox pollMs={20} />);
    expect(await screen.findByText(/indisponibles sur ce serveur/)).toBeInTheDocument();
    await new Promise((r) => setTimeout(r, 120));
    expect(listApprovals).toHaveBeenCalledTimes(1);
  });

  it("journal d'audit : vérifie la chaîne et liste les dernières entrées", async () => {
    render(<ApprovalsInbox pollMs={0} />);
    fireEvent.click(await screen.findByRole("button", { name: /Vérifier la chaîne/ }));
    expect(await screen.findByText("Chaîne ROMPUE à la ligne 7 (12 entrées vérifiées).")).toBeInTheDocument();
    expect(screen.getByText("approval.approved · approval#ap-1")).toBeInTheDocument();
    expect(listAudit).toHaveBeenCalledWith(20);
  });
});
