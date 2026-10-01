import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const getSession = vi.fn();
vi.mock("@/integrations/supabase/client", () => ({
  supabase: { auth: { getSession: () => getSession() } },
}));

import { ApiError, apiUrl } from "@/lib/api";
import {
  APPROVALS_UNAVAILABLE_MESSAGE,
  L3_CONFIRM_WORD,
  approveApproval,
  auditEntryText,
  auditVerifyText,
  denyApproval,
  formatPayload,
  formatRemaining,
  historyOf,
  isApprovalsUnavailable,
  isExpired,
  isStaleApproval,
  kindLabel,
  levelLabel,
  levelRank,
  levelTone,
  listApprovals,
  listAudit,
  payloadHasLongValues,
  pendingActionable,
  remainingSeconds,
  requiresTypedConfirmation,
  shortSha,
  sortApprovals,
  statusLabel,
  statusTone,
  summarizeApproval,
  targetOf,
  verifyAuditChain,
  type Approval,
} from "@/lib/approvals";

const NOW = Date.parse("2026-10-01T10:00:00Z");

const approval = (over: Partial<Approval> = {}): Approval => ({
  id: "ap-1",
  status: "pending",
  security_level: "L2",
  kind: "request",
  tool: "write_file",
  summary: "Écrire le rapport",
  task_id: "task-1234-5678",
  attempt: 1,
  step_index: 2,
  payload_presented: { path: "C:\\rapport.md", content: "bonjour" },
  payload_sha256: "a".repeat(64),
  reason: null,
  created_at: "2026-10-01T09:59:00Z",
  expires_at: "2026-10-01T10:05:00Z",
  decided_at: null,
  ...over,
});

describe("niveaux et statuts", () => {
  it("libelle les niveaux L0–L3 en français", () => {
    expect(levelLabel("L0")).toBe("lecture");
    expect(levelLabel("L1")).toBe("réversible");
    expect(levelLabel("L2")).toBe("effet réel");
    expect(levelLabel("L3")).toBe("irréversible");
    expect(levelLabel("L9")).toBe("L9");
  });

  it("gradue la tonalité avec la gravité", () => {
    expect(levelTone("L0")).toBe("muted");
    expect(levelTone("L1")).toBe("primary");
    expect(levelTone("L2")).toBe("warning");
    expect(levelTone("L3")).toBe("destructive");
    expect(levelTone("??")).toBe("muted");
    expect(levelRank("L3")).toBeGreaterThan(levelRank("L2"));
    expect(levelRank("inconnu")).toBe(-1);
  });

  it("n'exige la saisie du mot que pour L3", () => {
    expect(requiresTypedConfirmation("L3")).toBe(true);
    expect(requiresTypedConfirmation("L2")).toBe(false);
    expect(L3_CONFIRM_WORD).toBe("AUTORISER");
  });

  it("libelle statuts et types", () => {
    expect(statusLabel("pending")).toBe("En attente");
    expect(statusLabel("approved")).toBe("Approuvée");
    expect(statusLabel("denied")).toBe("Refusée");
    expect(statusLabel("expired")).toBe("Expirée");
    expect(statusLabel("revoked")).toBe("Révoquée");
    expect(statusLabel("bizarre")).toBe("bizarre");
    expect(statusTone("approved")).toBe("success");
    expect(statusTone("denied")).toBe("destructive");
    expect(statusTone("pending")).toBe("warning");
    expect(statusTone("expired")).toBe("muted");
    expect(kindLabel("request")).toBe("action unique");
    expect(kindLabel("grant")).toBe("autorisation de session");
  });
});

describe("échéances", () => {
  it("isExpired : statut expired, ou expires_at dépassé", () => {
    expect(isExpired(approval(), NOW)).toBe(false);
    expect(isExpired(approval(), NOW + 5 * 60_000)).toBe(true);
    expect(isExpired(approval({ status: "expired", expires_at: null }), NOW)).toBe(true);
    expect(isExpired(approval({ expires_at: null }), NOW)).toBe(false);
    expect(isExpired(approval({ expires_at: "pas une date" }), NOW)).toBe(false);
  });

  it("remainingSeconds : arrondi au supérieur, jamais négatif, null sans échéance", () => {
    expect(remainingSeconds(approval(), NOW)).toBe(300);
    expect(remainingSeconds(approval(), NOW + 299_500)).toBe(1);
    expect(remainingSeconds(approval(), NOW + 10 * 60_000)).toBe(0);
    expect(remainingSeconds(approval({ expires_at: null }), NOW)).toBeNull();
  });

  it("formatRemaining : formats lisibles", () => {
    expect(formatRemaining(null)).toBe("sans échéance");
    expect(formatRemaining(0)).toBe("expirée");
    expect(formatRemaining(45)).toBe("45 s");
    expect(formatRemaining(125)).toBe("2 min 05 s");
    expect(formatRemaining(3720)).toBe("1 h 02 min");
  });
});

describe("résumé et cible", () => {
  it("extrait la cible selon l'ordre des clés et tronque à 120 caractères", () => {
    expect(targetOf(null)).toBeNull();
    expect(targetOf({ content: "x" })).toBeNull();
    expect(targetOf({ url: "https://a", path: "/b" })).toBe("/b");
    expect(targetOf({ command: "  git push  " })).toBe("git push");
    expect(targetOf({ path: "x".repeat(130) })).toBe(`${"x".repeat(120)}…`);
  });

  it("summarizeApproval : outil, résumé et cible", () => {
    expect(summarizeApproval(approval())).toBe("write_file — Écrire le rapport → C:\\rapport.md");
    expect(summarizeApproval(approval({ summary: null }))).toBe("write_file → C:\\rapport.md");
    expect(summarizeApproval(approval({ tool: null, summary: null, payload_presented: null }))).toBe("action inconnue");
    // La cible n'est pas répétée si le résumé la contient déjà.
    expect(summarizeApproval(approval({ summary: "Écrire C:\\rapport.md" }))).toBe("write_file — Écrire C:\\rapport.md");
  });
});

describe("formatPayload (S7 : contenu exact, jamais masqué)", () => {
  it("indente et trie les clés récursivement", () => {
    const out = formatPayload({ b: 1, a: { d: [2, { z: 1, y: 2 }], c: null } });
    expect(out).toBe(JSON.stringify({ a: { c: null, d: [2, { y: 2, z: 1 }] }, b: 1 }, null, 2));
  });

  it("tronque les valeurs > 2000 caractères en indiquant la longueur réelle", () => {
    const long = "é".repeat(2500);
    const out = formatPayload({ text: long });
    expect(out).toContain(`${"é".repeat(2000)}… (2500 car.)`);
    expect(out).not.toContain("é".repeat(2001));
    expect(payloadHasLongValues({ text: long })).toBe(true);
    expect(payloadHasLongValues({ nested: [{ t: long }] })).toBe(true);
    expect(payloadHasLongValues({ text: "court" })).toBe(false);
  });

  it("n'altère ni ne masque les valeurs courtes (mots de passe compris) et tout affiche avec Infinity", () => {
    const secret = "motdepasse-" + "x".repeat(2100);
    expect(formatPayload({ password: "hunter2", token: "abc" })).toContain('"password": "hunter2"');
    expect(formatPayload({ password: secret }, Infinity)).toContain(secret);
  });

  it("gère l'absence de contenu", () => {
    expect(formatPayload(null)).toBe("(aucun contenu présenté)");
    expect(formatPayload(undefined)).toBe("(aucun contenu présenté)");
    expect(formatPayload({})).toBe("{}");
  });
});

describe("empreinte", () => {
  it("abrège le sha256 et gère l'absence", () => {
    expect(shortSha(null)).toBe("—");
    expect(shortSha("")).toBe("—");
    expect(shortSha("abcdef")).toBe("abcdef");
    expect(shortSha("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")).toBe("01234567…cdef");
  });
});

describe("tri et partition", () => {
  const rows: Approval[] = [
    approval({ id: "old-L2-approved", status: "approved", security_level: "L2", created_at: "2026-10-01T08:00:00Z" }),
    approval({ id: "new-L2", security_level: "L2", created_at: "2026-10-01T09:58:00Z" }),
    approval({ id: "L3", security_level: "L3", created_at: "2026-10-01T09:59:00Z" }),
    approval({ id: "old-L2", security_level: "L2", created_at: "2026-10-01T09:50:00Z" }),
    approval({ id: "L0", security_level: "L0", created_at: "2026-10-01T09:00:00Z" }),
  ];

  it("sortApprovals : pending d'abord, L3 avant L2, puis plus ancien d'abord", () => {
    expect(sortApprovals(rows).map((r) => r.id)).toEqual(["L3", "old-L2", "new-L2", "L0", "old-L2-approved"]);
    // Ne mute pas l'entrée.
    expect(rows[0].id).toBe("old-L2-approved");
  });

  it("pendingActionable exclut les expirées ; historyOf les reclasse en « expired »", () => {
    const expired = approval({ id: "dead", expires_at: "2026-10-01T09:30:00Z" });
    const all = [...rows, expired];
    expect(pendingActionable(all, NOW).map((r) => r.id)).toEqual(["L3", "old-L2", "new-L2", "L0"]);
    const hist = historyOf(all, NOW);
    expect(hist.map((r) => r.id).sort()).toEqual(["dead", "old-L2-approved"]);
    expect(hist.find((r) => r.id === "dead")?.status).toBe("expired");
  });
});

describe("audit (textes)", () => {
  it("décrit le résultat de la vérification", () => {
    expect(auditVerifyText({ ok: true, checked: 0, broken_at: null })).toBe("Chaîne intègre (journal vide).");
    expect(auditVerifyText({ ok: true, checked: 1, broken_at: null })).toBe("Chaîne intègre : 1 entrée vérifiée.");
    expect(auditVerifyText({ ok: true, checked: 42, broken_at: null })).toBe("Chaîne intègre : 42 entrées vérifiées.");
    expect(auditVerifyText({ ok: false, checked: 42, broken_at: 17 })).toBe("Chaîne ROMPUE à la ligne 17 (42 entrées vérifiées).");
    expect(auditVerifyText({ ok: false, checked: 3, broken_at: null })).toBe("Chaîne ROMPUE (3 entrées vérifiées).");
  });

  it("résume une entrée", () => {
    expect(auditEntryText({ action: "approval.approved", entity: "approval", entity_id: "0123456789" })).toBe(
      "approval.approved · approval#01234567",
    );
    expect(auditEntryText({ action: "login", entity: "user", entity_id: null })).toBe("login · user");
    expect(auditEntryText({ action: "boot", entity: null, entity_id: null })).toBe("boot");
  });
});

describe("appels API", () => {
  const jsonResponse = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
  const fetchMock = vi.fn();

  beforeEach(() => {
    vi.stubGlobal("fetch", fetchMock);
    getSession.mockResolvedValue({ data: { session: { access_token: "tok-1" } } });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    fetchMock.mockReset();
    getSession.mockReset();
  });

  it("listApprovals interroge /api/v2/approvals avec statut, limite et jeton", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ approvals: [approval()] }));
    const controller = new AbortController();
    const rows = await listApprovals("pending", controller.signal);
    expect(rows).toHaveLength(1);
    expect(rows[0].id).toBe("ap-1");
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(apiUrl("/api/v2/approvals?status=pending&limit=50"));
    expect(init.headers.get("Authorization")).toBe("Bearer tok-1");
    expect(init.signal).toBe(controller.signal);
  });

  it("listApprovals renvoie [] sur un corps inattendu et propage le 404 (serveur V1)", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ nope: true }));
    await expect(listApprovals("all", undefined, 10)).resolves.toEqual([]);
    expect(fetchMock.mock.calls[0][0]).toBe(apiUrl("/api/v2/approvals?status=all&limit=10"));

    fetchMock.mockResolvedValueOnce(new Response("Not Found", { status: 404 }));
    const err = await listApprovals("pending").catch((e) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect(isApprovalsUnavailable(err)).toBe(true);
    expect(isStaleApproval(err)).toBe(false);
    expect(APPROVALS_UNAVAILABLE_MESSAGE).toMatch(/indisponibles sur ce serveur/);
  });

  it("approveApproval renvoie l'empreinte affichée telle quelle et refuse sans empreinte", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ id: "a/b", status: "approved", expires_at: null }));
    const res = await approveApproval("a/b", "f".repeat(64));
    expect(res.status).toBe("approved");
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(apiUrl("/api/v2/approvals/a%2Fb/approve"));
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body)).toEqual({ payload_sha256: "f".repeat(64) });

    await expect(approveApproval("x", "")).rejects.toBeInstanceOf(ApiError);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("approveApproval : un 409 est reconnu comme demande périmée", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ error: "Empreinte différente" }, 409));
    const err = await approveApproval("ap-1", "abc").catch((e) => e);
    expect(isStaleApproval(err)).toBe(true);
    expect(err.message).toBe("Empreinte différente");
  });

  it("denyApproval envoie le motif épuré, ou {} sans motif", async () => {
    fetchMock.mockImplementation(() => Promise.resolve(jsonResponse({ id: "ap-1", status: "denied" })));
    await denyApproval("ap-1", "  mauvais fichier ");
    expect(fetchMock.mock.calls[0][0]).toBe(apiUrl("/api/v2/approvals/ap-1/deny"));
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({ reason: "mauvais fichier" });
    await denyApproval("ap-1", "   ");
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({});
  });

  it("verifyAuditChain et listAudit normalisent les réponses", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ ok: false, checked: 10, broken_at: 4 }));
    await expect(verifyAuditChain()).resolves.toEqual({ ok: false, checked: 10, broken_at: 4 });
    expect(fetchMock.mock.calls[0][0]).toBe(apiUrl("/api/v2/audit/verify"));

    fetchMock.mockResolvedValueOnce(jsonResponse({}));
    await expect(verifyAuditChain()).resolves.toEqual({ ok: false, checked: 0, broken_at: null });

    fetchMock.mockResolvedValueOnce(jsonResponse({ entries: [{ seq: 1, action: "x", actor: "u", entity: null, entity_id: null, data: {}, created_at: "2026-10-01T00:00:00Z" }] }));
    const entries = await listAudit(20);
    expect(entries).toHaveLength(1);
    expect(fetchMock.mock.calls[2][0]).toBe(apiUrl("/api/v2/audit?limit=20"));

    fetchMock.mockResolvedValueOnce(jsonResponse({ entries: "non" }));
    await expect(listAudit()).resolves.toEqual([]);
  });
});
