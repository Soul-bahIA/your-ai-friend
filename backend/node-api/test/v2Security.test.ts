// LOT 6 — sécurité V2 (fonctions pures) : rédaction des secrets et canari, politique L0–L3
// pour CHAQUE outil du catalogue, jetons d'approbation HMAC liés au payload.
import { createHash, createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";

const CANARY = "SOULBAH_CANARY_TEST_7f3a9c";
process.env.SOULBAH_REDACT_VALUES = `${CANARY};court`;
process.env.SOULBAH_ENV = "test";

const { TOOL_CATALOG } = await import("../src/lib/toolCatalog");
const { SECRET_LABEL, redactText, redactSecrets, containsForbiddenValue, forbiddenValues, redactingLogger } = await import(
  "../src/v2/security/redactSecrets"
);
const { decide, denyPathReason, stepPathDenial, levelRank, minLevel } = await import("../src/v2/security/policy");
const { canonicalJson, payloadSha256, createApprovalToken, verifyApprovalToken, tokenHash, TOKEN_PREFIX } = await import(
  "../src/v2/security/approvals"
);

describe("rédaction des secrets", () => {
  it("motifs connus → libellé ; le texte ordinaire est intact", () => {
    expect(redactText("clé sk-abcdefghijklmnopqrstuvwxyz012345 fin")).toBe(`clé ${SECRET_LABEL} fin`);
    expect(redactText("sbk_" + "a".repeat(64))).toBe(SECRET_LABEL);
    expect(redactText("Authorization: Bearer abcdefghijklmnopqrstuvwxyz")).toBe(`Authorization: Bearer ${SECRET_LABEL}`);
    expect(redactText("password=Tr3sSecret!")).toBe(`password=${SECRET_LABEL}`);
    expect(redactText("api_key: 'abcdef123456'")).toBe(`api_key: ${SECRET_LABEL}`);
    expect(redactText("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4eHh4In0.c2lnbmF0dXJlMTIz")).toBe(SECRET_LABEL);
    expect(redactText("-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----")).toBe(SECRET_LABEL);
    expect(redactText("AKIAABCDEFGHIJKLMNOP")).toBe(SECRET_LABEL);
    expect(redactText(`${TOKEN_PREFIX}abc.${"f".repeat(64)}`)).toBe(SECRET_LABEL);
    expect(redactText("Ouvre le bloc-notes et tape bonjour")).toBe("Ouvre le bloc-notes et tape bonjour");
    // une empreinte sha256 (64 hex) n'est PAS un secret : jamais rédigée
    expect(redactText("f".repeat(64))).toBe("f".repeat(64));
  });

  it("valeurs déclarées (SOULBAH_REDACT_VALUES) : canari rédigé partout, valeurs < 4 car. ignorées", () => {
    expect(forbiddenValues()).toEqual([CANARY, "court"]);
    expect(redactText(`résultat : ${CANARY} ok`)).toBe(`résultat : ${SECRET_LABEL} ok`);
    expect(containsForbiddenValue({ a: [{ b: `x${CANARY}` }] })).toBe(true);
    expect(containsForbiddenValue(redactSecrets({ a: [{ b: `x${CANARY}` }] }))).toBe(false);
    expect(forbiddenValues(["abc"])).toEqual([CANARY, "court"]);
  });

  it("clés sensibles masquées entièrement ; libellés LOT 1 intacts ; profondeur bornée", () => {
    const out = redactSecrets({
      password: "n'importe quoi",
      token: "t",
      Authorization: "x",
      note: "visible",
      text: "[texte masqué : 12 car.]",
      nested: { api_key: "k", list: ["sk-abcdefghijklmnopqrstuvwxyz0123", "ok"] },
      empty: "",
    });
    expect(out).toEqual({
      password: SECRET_LABEL,
      token: SECRET_LABEL,
      Authorization: SECRET_LABEL,
      note: "visible",
      text: "[texte masqué : 12 car.]",
      nested: { api_key: SECRET_LABEL, list: [SECRET_LABEL, "ok"] },
      empty: "",
    });
    let deep: Record<string, unknown> = { v: CANARY };
    for (let i = 0; i < 40; i++) deep = { d: deep };
    expect(containsForbiddenValue(redactSecrets(deep))).toBe(false);
  });

  it("redactingLogger rédige objets et messages", () => {
    const seen: unknown[] = [];
    const base = { info: (o: unknown, m?: string) => seen.push([o, m]), warn: () => {}, error: () => {} };
    redactingLogger(base).info({ key: CANARY, token: "abc" }, `msg ${CANARY}`);
    expect(seen[0]).toEqual([{ key: SECRET_LABEL, token: SECRET_LABEL }, `msg ${SECRET_LABEL}`]);
  });
});

describe("deny-list des chemins (miroir de agent/skills/safety.py)", () => {
  it("refuse .env, .git, .ssh/.gnupg, clés privées, variantes Windows", () => {
    expect(denyPathReason("C:\\w\\.env")).toContain(".env");
    expect(denyPathReason("C:\\w\\prod.env")).toContain(".env");
    expect(denyPathReason("C:\\w\\.env.local")).toContain(".env");
    expect(denyPathReason("C:\\w\\.env ")).toContain(".env");
    expect(denyPathReason("C:\\w\\.env::$DATA")).toContain(".env");
    expect(denyPathReason("C:\\repo\\.git\\hooks\\pre-commit")).toBe("dossier .git");
    expect(denyPathReason("C:\\Users\\x\\.ssh\\id_rsa")).toContain(".ssh");
    expect(denyPathReason("\\\\?\\C:\\Users\\x\\.gnupg\\x")).toContain(".gnupg");
    expect(denyPathReason("C:\\w\\server.pem")).toBe("clé privée");
    expect(denyPathReason("C:\\w\\id_ed25519.pub")).toBe("clé privée");
    expect(denyPathReason("")).toBe("chemin invalide");
    expect(denyPathReason("C:\\w\\a\0b")).toBe("chemin invalide");
    expect(denyPathReason("C:\\SoulbahWorkspace\\notes.txt")).toBeNull();
    expect(denyPathReason("C:\\w\\environment.txt")).toBeNull();
  });

  it("stepPathDenial parcourt les champs chemin (texte et listes) du catalogue", () => {
    expect(stepPathDenial({ type: "read_file", path: "C:\\w\\.env" })).toContain("path");
    expect(stepPathDenial({ type: "edit_video", clips: ["C:\\w\\a.mp4", "C:\\w\\.ssh\\b"] })).toContain("clips");
    expect(stepPathDenial({ type: "wait", seconds: 1 })).toBeNull();
    expect(stepPathDenial(undefined)).toBeNull();
  });
});

describe("politique L0–L3 : chaque outil du catalogue", () => {
  const tools = TOOL_CATALOG.tools;
  it("le catalogue est chargé", () => {
    expect(tools.length).toBeGreaterThanOrEqual(30);
  });

  for (const t of tools) {
    it(`${t.name} (${t.security_level}${t.requires_confirmation ? ", confirmation" : ""})`, () => {
      const step = { ...(t.examples[0] as Record<string, unknown>), type: t.name };
      const base = { tool: t.name, step, userMaxLevel: "L3" as const };
      const r = decide(base);
      expect(r.level).toBe(t.security_level);
      expect(r.requiresDesktopInput).toBe(t.requires_desktop_input);
      switch (t.security_level) {
        case "L0":
          expect(r.decision).toBe("allow");
          break;
        case "L1":
          expect(r.decision).toBe("session_grant");
          expect(decide({ ...base, sessionApproved: true }).decision).toBe("allow");
          break;
        case "L2":
          if (t.requires_confirmation) {
            expect(r.decision).toBe("approve_each");
            // même un grant ne dispense pas d'une confirmation exigée par le catalogue
            expect(decide({ ...base, grants: [{ level: "L2", tools: ["*"] }] }).decision).toBe("approve_each");
          } else {
            expect(r.decision).toBe("approve_each");
            expect(decide({ ...base, grants: [{ level: "L2", tools: [t.name] }] }).decision).toBe("allow");
            expect(decide({ ...base, grants: [{ level: "L2", tools: [t.name], expiresAt: new Date(0) }] }).decision).toBe("approve_each");
            expect(decide({ ...base, grants: [{ level: "L1", tools: ["*"] }] }).decision).toBe("approve_each");
          }
          break;
        case "L3":
          expect(r.decision).toBe("approve_each");
          expect(r.requiresPayload).toBe(true);
          break;
      }
      // Plafond : un niveau au-dessus du plafond utilisateur ou mission est refusé.
      if (t.security_level !== "L0") {
        expect(decide({ ...base, userMaxLevel: "L0" }).decision).toBe("deny");
        expect(decide({ ...base, userMaxLevel: "L3", sessionMaxLevel: "L0" }).decision).toBe("deny");
      }
      // Alias : même décision que le nom canonique.
      for (const alias of t.aliases) {
        expect(decide({ ...base, tool: alias, step: { ...step, type: alias } }).decision).toBe(r.decision);
      }
      // Chemin interdit : refus quel que soit le niveau (outils à paramètre chemin).
      const pathParam = t.params.find((p) => p.is_path && p.type === "string");
      if (pathParam) {
        expect(decide({ ...base, step: { ...step, [pathParam.name]: "C:\\w\\.env" } }).decision).toBe("deny");
      }
    });
  }

  it("outil inconnu → deny ; niveaux ordonnés", () => {
    expect(decide({ tool: "format_disk" }).decision).toBe("deny");
    expect(levelRank("L0")).toBeLessThan(levelRank("L3"));
    expect(minLevel("L2", "L1")).toBe("L1");
    expect(minLevel("L2", null)).toBe("L2");
  });
});

describe("jetons d'approbation HMAC liés au payload", () => {
  const secret = "x".repeat(32);
  const payload = { type: "type_text", text: "bonjour", window_title: "Bloc-notes" };
  const sha = payloadSha256(payload);
  const exp = new Date(Date.now() + 60_000);

  it("JSON canonique : clés triées, compact, UTF-8 (identique à l'agent)", () => {
    expect(canonicalJson({ b: 1, a: "é", c: [3, { z: null, y: true }] })).toBe('{"a":"é","b":1,"c":[3,{"y":true,"z":null}]}');
    expect(canonicalJson({ b: 1, a: "é" })).toBe('{"a":"é","b":1}');
    expect(payloadSha256({ b: 1, a: "é" })).toBe(createHash("sha256").update('{"a":"é","b":1}', "utf8").digest("hex"));
    expect(payloadSha256({ a: 1, b: 2 })).toBe(payloadSha256({ b: 2, a: 1 }));
    expect(payloadSha256({ a: 1, u: undefined })).toBe(payloadSha256({ a: 1 }));
  });

  it("aller-retour, puis signature altérée, expiration, payload différent, forme invalide", () => {
    const token = createApprovalToken({ id: "11111111-1111-4111-8111-111111111111", payloadSha256: sha, expiresAt: exp, level: "L2" }, secret);
    expect(token.startsWith(TOKEN_PREFIX)).toBe(true);
    const ok = verifyApprovalToken(token, { payloadSha256: sha, secret });
    expect(ok.ok).toBe(true);
    if (ok.ok) expect(ok.body).toMatchObject({ v: 1, id: "11111111-1111-4111-8111-111111111111", sha, lvl: "L2" });
    expect(verifyApprovalToken(token, { secret: "y".repeat(32) })).toEqual({ ok: false, reason: "signature" });
    const flipped = token.slice(0, -1) + (token.endsWith("0") ? "1" : "0");
    expect(verifyApprovalToken(flipped, { secret })).toEqual({ ok: false, reason: "signature" });
    expect(verifyApprovalToken(token, { secret, now: new Date(exp.getTime() + 1) })).toEqual({ ok: false, reason: "expired" });
    expect(verifyApprovalToken(token, { secret, payloadSha256: payloadSha256({ ...payload, text: "autre" }) })).toEqual({ ok: false, reason: "payload_mismatch" });
    expect(verifyApprovalToken("sbap_", { secret })).toEqual({ ok: false, reason: "malformed" });
    expect(verifyApprovalToken("autre_prefixe.abc", { secret })).toEqual({ ok: false, reason: "malformed" });
    expect(verifyApprovalToken(42, { secret })).toEqual({ ok: false, reason: "malformed" });
    // Corps altéré mais re-signé avec le bon secret : rejeté si le niveau ou l'empreinte sont invalides.
    const body = Buffer.from(canonicalJson({ v: 1, id: "x", sha: "zz", exp: 9999999999, lvl: "L9" })).toString("base64url");
    const forged = `${TOKEN_PREFIX}${body}.${createHmac("sha256", secret).update(body).digest("hex")}`;
    expect(verifyApprovalToken(forged, { secret })).toEqual({ ok: false, reason: "malformed" });
    expect(tokenHash(token)).toMatch(/^[0-9a-f]{64}$/);
    expect(tokenHash(token)).not.toBe(tokenHash(flipped));
  });
});
