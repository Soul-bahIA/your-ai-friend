// NetworkGuard du plan de contrôle (V3, mission §56) : en mode OFFLINE, toute connexion TCP/TLS
// sortante de node-api vers Internet est refusée AVANT la résolution DNS — fetch (undici), pg,
// tls passent tous par net.Socket.prototype.connect. Même règle que
// shared/config/network_guard.py (cas communs : shared/config/network_guard_cases.json) :
// bouclage, noms sans point (services Docker), hôtes déclarés et adresses non publiques permis.
import net from "node:net";
import { internetAllowed, isLocalEndpoint, type SoulbahSettings } from "./soulbahSettings.js";
import { logger } from "./logger.js";

type GuardSettings = Pick<SoulbahSettings, "mode" | "network">;

function ipv4Public(ip: string): boolean {
  const p = ip.split(".").map(Number);
  const [a, b, c] = p;
  if (a === 0 || a === 10 || a === 127 || a >= 240) return false;
  if (a === 100 && b >= 64 && b <= 127) return false;
  if (a === 169 && b === 254) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && b === 168) return false;
  if (a === 192 && b === 0 && (c === 0 || c === 2)) return false;
  if (a === 198 && (b === 18 || b === 19)) return false;
  if ((a === 198 && b === 51 && c === 100) || (a === 203 && b === 0 && c === 113)) return false;
  return true;
}

/** true = adresse publique, false = adresse non publique, null = pas une adresse IP. */
export function ipPublic(host: string): boolean | null {
  const h = host.split("%")[0];
  if (net.isIPv4(h)) return ipv4Public(h);
  if (net.isIPv6(h)) {
    const low = h.toLowerCase();
    const mapped = low.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
    if (mapped) return ipv4Public(mapped[1]);
    if (low === "::1" || low === "::") return false;
    const first = parseInt(low.split(":")[0] || "0", 16);
    if ((first & 0xfe00) === 0xfc00 || (first & 0xffc0) === 0xfe80) return false;
    if (low.startsWith("2001:db8:") || low.startsWith("2001:0db8:")) return false;
    return (first & 0xe000) === 0x2000 || (first & 0xff00) === 0xff00;
  }
  return null;
}

/** Raison du refus d'une connexion vers `host`, ou null si elle est permise. */
export function networkRefusal(settings: GuardSettings, host: string): string | null {
  if (internetAllowed(settings)) return null;
  const h = String(host).trim().toLowerCase().replace(/^\[|\]$/g, "");
  if (!h || settings.network.allow_hosts.includes(h)) return null;
  const pub = ipPublic(h);
  if (pub === false) return null;
  if (pub === true) return `NetworkGuard : connexion vers ${h} refusée en mode ${settings.mode} (adresse d'Internet)`;
  if (isLocalEndpoint(settings, h)) return null;
  return `NetworkGuard : connexion vers ${h} refusée en mode ${settings.mode} (hôte d'Internet non déclaré)`;
}

function hostOf(args: unknown[]): string | null {
  let a = args;
  if (Array.isArray(a[0])) a = a[0] as unknown[]; // forme interne [options, cb]
  const first = a[0];
  if (first && typeof first === "object") {
    const o = first as { path?: unknown; host?: unknown };
    if (o.path) return null; // canal local (IPC)
    return typeof o.host === "string" && o.host ? o.host : "localhost";
  }
  if (typeof first === "string" && Number.isNaN(Number(first))) return null; // chemin IPC
  return typeof a[1] === "string" ? a[1] : "localhost";
}

interface GuardState {
  settings: GuardSettings | null;
  blocked: number;
  recent: { host: string; at: string }[];
}
const state: GuardState = { settings: null, blocked: 0, recent: [] };
let original: typeof net.Socket.prototype.connect | null = null;

/** Active (ou reconfigure) la garde du processus ; ne bloque qu'en OFFLINE. */
export function installNetworkGuard(settings: GuardSettings): void {
  state.settings = { mode: settings.mode, network: { allow_hosts: [...settings.network.allow_hosts] } };
  if (original) return;
  original = net.Socket.prototype.connect;
  const passThrough = original;
  net.Socket.prototype.connect = function guardedConnect(this: net.Socket, ...args: unknown[]) {
    const s = state.settings;
    const host = s && s.mode === "OFFLINE" ? hostOf(args) : null;
    const reason = host && s ? networkRefusal(s, host) : null;
    if (reason) {
      state.blocked++;
      state.recent.push({ host: String(host).slice(0, 200), at: new Date().toISOString() });
      state.recent.splice(0, Math.max(0, state.recent.length - 50));
      logger.warn({ host }, "NetworkGuard : connexion sortante refusée (mode OFFLINE)");
      const err = Object.assign(new Error(reason), { code: "ENETGUARD" });
      process.nextTick(() => this.destroy(err));
      return this;
    }
    return (passThrough as (...a: unknown[]) => net.Socket).apply(this, args);
  } as typeof net.Socket.prototype.connect;
}

export function networkGuardStatus() {
  return {
    installed: original !== null,
    active: original !== null && state.settings?.mode === "OFFLINE",
    mode: state.settings?.mode ?? null,
    blocked: state.blocked,
    recent: state.recent.slice(-10),
  };
}

/** Tests uniquement : retire la garde et remet les compteurs à zéro. */
export function uninstallNetworkGuard(): void {
  if (original) net.Socket.prototype.connect = original;
  original = null;
  state.settings = null;
  state.blocked = 0;
  state.recent = [];
}
