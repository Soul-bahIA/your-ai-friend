// Garde réseau des processus Node ENFANTS de l'agent en mode OFFLINE (V3) — chargée par
// NODE_OPTIONS="--require .../network_guard_child.cjs" (network_guard.child_env()).
// Même règle que shared/config/network_guard.py et backend/node-api/src/lib/networkGuard.ts
// (cas communs : shared/config/network_guard_cases.json) : bouclage, noms sans point, hôtes
// déclarés (SOULBAH_NETWORK_ALLOW_HOSTS) et adresses non publiques permis ; le reste refusé
// avant toute résolution DNS (erreur ENETGUARD). Source : shared/config/guard_site/.
"use strict";
const net = require("node:net");

function ipv4Public(ip) {
  const p = ip.split(".").map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return false;
  const [a, b] = p;
  if (a === 0 || a === 10 || a === 127 || a >= 240) return false;
  if (a === 100 && b >= 64 && b <= 127) return false; // CGNAT
  if (a === 169 && b === 254) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && b === 168) return false;
  if (a === 192 && b === 0 && p[2] === 0) return false;
  if (a === 198 && (b === 18 || b === 19)) return false;
  if ((a === 192 && b === 0 && p[2] === 2) || (a === 198 && b === 51 && p[2] === 100) || (a === 203 && b === 0 && p[2] === 113)) return false; // documentation
  return true;
}

function ipPublic(host) {
  const h = host.split("%")[0];
  if (net.isIPv4(h)) return ipv4Public(h);
  if (net.isIPv6(h)) {
    const low = h.toLowerCase();
    const mapped = low.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
    if (mapped) return ipv4Public(mapped[1]);
    if (low === "::1" || low === "::") return false;
    const first = parseInt(low.split(":")[0] || "0", 16);
    if ((first & 0xfe00) === 0xfc00) return false; // ULA fc00::/7
    if ((first & 0xffc0) === 0xfe80) return false; // lien local fe80::/10
    if (low.startsWith("2001:db8:") || low.startsWith("2001:0db8:")) return false; // documentation
    return (first & 0xe000) === 0x2000 || (first & 0xff00) === 0xff00; // unicast global ou multicast
  }
  return null; // pas une adresse IP
}

function refusal(host, allow) {
  const h = String(host).trim().toLowerCase().replace(/^\[|\]$/g, "");
  if (!h) return null;
  if (allow.has(h)) return null;
  const pub = ipPublic(h);
  if (pub === false) return null;
  if (pub === true) return `NetworkGuard : connexion vers ${h} refusée en mode OFFLINE (adresse d'Internet)`;
  if (h === "localhost" || h.endsWith(".localhost") || (!h.includes(".") && !h.includes(":"))) return null;
  return `NetworkGuard : connexion vers ${h} refusée en mode OFFLINE (hôte d'Internet non déclaré)`;
}

function hostOf(args) {
  let a = args;
  if (Array.isArray(a[0])) a = a[0]; // forme interne [options, cb] (normalizeArgs)
  const first = a[0];
  if (first && typeof first === "object") {
    if (first.path) return null; // canal local (IPC)
    return first.host || "localhost";
  }
  if (typeof first === "string" && Number.isNaN(Number(first))) return null; // chemin IPC
  return typeof a[1] === "string" ? a[1] : "localhost";
}

if ((process.env.SOULBAH_MODE || "").trim().toUpperCase() === "OFFLINE" && !net.Socket.prototype.__soulbahGuard) {
  const allow = new Set((process.env.SOULBAH_NETWORK_ALLOW_HOSTS || "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean));
  const original = net.Socket.prototype.connect;
  net.Socket.prototype.connect = function guardedConnect(...args) {
    const host = hostOf(args);
    const reason = host ? refusal(host, allow) : null;
    if (reason) {
      const err = Object.assign(new Error(reason), { code: "ENETGUARD" });
      process.nextTick(() => this.destroy(err));
      return this;
    }
    return original.apply(this, args);
  };
  Object.defineProperty(net.Socket.prototype, "__soulbahGuard", { value: true });
}

module.exports = { refusal, ipPublic };
