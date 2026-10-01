// V3 — NetworkGuard du plan de contrôle : en OFFLINE, fetch / net / tls vers Internet refusés
// avant la résolution DNS (code ENETGUARD) ; local permis ; règle commune avec Python.
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import path from "node:path";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { installNetworkGuard, ipPublic, networkGuardStatus, networkRefusal, uninstallNetworkGuard } from "../src/lib/networkGuard";
import { resolveSettings } from "../src/lib/soulbahSettings";

const CASES = JSON.parse(fs.readFileSync(path.resolve(__dirname, "../../../shared/config/network_guard_cases.json"), "utf8"));
const offline = resolveSettings({ SOULBAH_MODE: "OFFLINE", SOULBAH_NETWORK_ALLOW_HOSTS: CASES.offline.allow_hosts.join(",") }).settings;

let server: http.Server;
let port = 0;
beforeAll(async () => {
  server = http.createServer((_q, r) => r.end("ok"));
  await new Promise<void>((res) => server.listen(0, "127.0.0.1", res));
  port = (server.address() as net.AddressInfo).port;
});
afterAll(() => new Promise<void>((res) => server.close(() => res())));
afterEach(() => uninstallNetworkGuard());

describe("règle commune (shared/config/network_guard_cases.json)", () => {
  it("OFFLINE", () => {
    const got = Object.fromEntries(Object.keys(CASES.offline.expect).map((h) => [h, networkRefusal(offline, h) === null]));
    expect(got).toEqual(CASES.offline.expect);
  });
  it("HYBRID et LOCAL_INTERNET : rien n'est bloqué", () => {
    for (const [key, mode] of [["hybrid", "HYBRID"], ["local_internet", "LOCAL_INTERNET"]] as const) {
      const s = resolveSettings({ SOULBAH_MODE: mode }).settings;
      for (const [h, ok] of Object.entries(CASES[key].expect)) expect(networkRefusal(s, h) === null, `${mode} ${h}`).toBe(ok);
    }
  });
  it("adresses publiques / non publiques", () => {
    expect(ipPublic("8.8.8.8")).toBe(true);
    expect(ipPublic("10.1.2.3")).toBe(false);
    expect(ipPublic("2606:4700::1")).toBe(true);
    expect(ipPublic("fd12::1")).toBe(false);
    expect(ipPublic("example.com")).toBeNull();
  });
});

describe("garde installée en OFFLINE", () => {
  it("fetch vers Internet refusé (ENETGUARD), fetch local permis, refus comptés", async () => {
    installNetworkGuard(offline);
    const err = await fetch("http://example.com/").then(
      () => null,
      (e: Error & { cause?: { code?: string; message?: string } }) => e,
    );
    expect(err?.cause?.code).toBe("ENETGUARD");
    expect(err?.cause?.message).toContain("example.com");
    expect(await (await fetch(`http://127.0.0.1:${port}/`)).text()).toBe("ok");
    expect(networkGuardStatus()).toMatchObject({ installed: true, active: true, mode: "OFFLINE", blocked: 1 });
  });

  it("net.connect vers une adresse publique refusé", async () => {
    installNetworkGuard(offline);
    const code = await new Promise<string>((res) => {
      const s = net.connect({ host: "1.1.1.1", port: 80 });
      s.on("error", (e: NodeJS.ErrnoException) => res(String(e.code)));
      s.on("connect", () => {
        s.destroy();
        res("connecté");
      });
    });
    expect(code).toBe("ENETGUARD");
  });

  it("HYBRID : la garde laisse passer (vérifié sur le serveur local et par la règle)", async () => {
    installNetworkGuard(resolveSettings({}).settings);
    expect(await (await fetch(`http://127.0.0.1:${port}/`)).text()).toBe("ok");
    expect(networkGuardStatus()).toMatchObject({ installed: true, active: false, blocked: 0 });
  });
});
