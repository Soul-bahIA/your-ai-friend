"""NetworkGuard (V3, mission §56) : en mode OFFLINE, les connexions vers Internet sont REFUSÉES
techniquement dans les processus Soulbah — pas seulement « déconseillées » dans un prompt.

SOURCE UNIQUE : shared/config/network_guard.py, copiée à l'identique (scripts/sync_shared.py)
dans agent/, agent/guard_site/ et backend/python-ia/app/.

Trois couches :
  1. processus Python de Soulbah (agent, superviseur, workers, python-ia) : crochet d'audit
     `sys.addaudithook` sur socket.getaddrinfo / socket.connect / socket.sendto. Une résolution
     DNS ou une connexion vers un hôte d'Internet lève NetworkGuardError AVANT tout paquet
     émis ; toutes les bibliothèques sont couvertes (httpx, requests, urllib, asyncio…) ;
  2. processus enfants lancés par l'agent (run_command, git, tests d'un projet) : `child_env()`
     injecte `guard_site/` dans PYTHONPATH (sitecustomize installe la même garde dans tout
     Python enfant), `--require guard_site/network_guard_child.cjs` dans NODE_OPTIONS (garde
     équivalente pour Node, npm, npx) et des mandataires HTTP(S) inaccessibles (127.0.0.1:9)
     pour les autres outils (git en https, curl…) ;
  3. plan de contrôle Node : backend/node-api/src/lib/networkGuard.ts (même règle).

Règle (identique partout, cas communs : shared/config/network_guard_cases.json) — hors OFFLINE
rien n'est bloqué ; en OFFLINE une destination est permise si c'est :
  - le bouclage, un nom sans point (service Docker, machine du réseau local) ou un hôte déclaré
    dans network.allow_hosts ;
  - une adresse IP NON publique (réseau local, lien local, bouclage) ;
tout le reste (noms d'Internet, adresses publiques) est refusé et compté (status()).

Limites assumées : une application de bureau ouverte par l'utilisateur via l'agent (navigateur,
VS Code) n'hérite pas de ces gardes ; un programme natif qui ignore les mandataires et ouvre ses
propres sockets n'est arrêté que par le pare-feu du système (documenté, facultatif).
"""
from __future__ import annotations

import ipaddress
import os
import sys
import threading
import time
from typing import Any, Mapping

try:  # paquet (python-ia : app.network_guard)
    from . import soulbah_settings as S
except ImportError:  # module de premier niveau (agent, guard_site)
    import soulbah_settings as S  # type: ignore[no-redef]

BLACKHOLE_PROXY = "http://127.0.0.1:9"
GUARD_SITE_ENV = "SOULBAH_GUARD_SITE"
NODE_GUARD_FILE = "network_guard_child.cjs"
_EVENTS = frozenset({"socket.getaddrinfo", "socket.connect", "socket.sendto"})
_RECENT_MAX = 50

_lock = threading.Lock()
_local = threading.local()
_state: dict[str, Any] = {"settings": None, "installed": False, "blocked": 0, "recent": []}


class NetworkGuardError(PermissionError):
    """Connexion refusée par NetworkGuard (mode OFFLINE)."""


def _ip(host: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    try:
        ip = ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        return None
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        return ip.ipv4_mapped
    return ip


def refusal(settings: Mapping[str, Any] | None, host: Any) -> str | None:
    """Raison du refus d'une connexion vers `host` (None = permise)."""
    if settings is None or S.internet_allowed(settings):
        return None
    if isinstance(host, bytes):
        host = host.decode("ascii", "replace")
    if not isinstance(host, str):
        return None
    h = host.strip().lower().strip("[]")
    if not h:
        return None
    allow = (settings.get("network") or {}).get("allow_hosts", [])
    ip = _ip(h)
    mode = settings.get("mode")
    if ip is not None:
        if not ip.is_global or h in allow or str(ip) in allow:
            return None
        return f"NetworkGuard : connexion vers {h} refusée en mode {mode} (adresse d'Internet)"
    if S.is_local_endpoint(settings, h):
        return None
    return f"NetworkGuard : connexion vers {h} refusée en mode {mode} (hôte d'Internet non déclaré)"


def _record(host: str, event: str) -> None:
    with _lock:
        _state["blocked"] += 1
        recent = _state["recent"]
        recent.append({"host": host[:200], "event": event, "at": time.strftime("%Y-%m-%dT%H:%M:%S")})
        del recent[:-_RECENT_MAX]


def _hook(event: str, args: tuple) -> None:
    if event not in _EVENTS:
        return
    settings = _state["settings"]
    if settings is None or settings.get("mode") != "OFFLINE":
        return
    if getattr(_local, "busy", False):
        return
    host: Any = None
    if event == "socket.getaddrinfo":
        host = args[0] if args else None
    elif len(args) >= 2 and isinstance(args[1], tuple) and args[1]:
        host = args[1][0]
    reason = refusal(settings, host)
    if reason:
        _local.busy = True
        try:
            _record(str(host), event)
        finally:
            _local.busy = False
        raise NetworkGuardError(reason)


def install(settings: Mapping[str, Any]) -> dict[str, Any]:
    """Active (ou reconfigure) la garde du processus. Le crochet d'audit est permanent ; il ne
    bloque qu'en OFFLINE, selon la DERNIÈRE configuration reçue."""
    with _lock:
        _state["settings"] = dict(settings)
        if not _state["installed"]:
            sys.addaudithook(_hook)
            _state["installed"] = True
    return status()


def status() -> dict[str, Any]:
    s = _state["settings"] or {}
    with _lock:
        return {"installed": _state["installed"], "active": bool(_state["installed"] and s.get("mode") == "OFFLINE"),
                "mode": s.get("mode"), "blocked": _state["blocked"], "recent": list(_state["recent"][-10:])}


def guard_site_dir() -> str:
    """Dossier injecté dans les processus enfants (sitecustomize.py + garde Node)."""
    explicit = os.environ.get(GUARD_SITE_ENV, "").strip()
    if explicit:
        return explicit
    here = os.path.dirname(os.path.abspath(__file__))
    return here if os.path.basename(here) == "guard_site" else os.path.join(here, "guard_site")


def child_env(base: Mapping[str, str] | None = None) -> dict[str, str] | None:
    """Environnement d'un processus enfant : None (hérité tel quel) hors OFFLINE ; en OFFLINE,
    garde Python et Node injectées, mandataires HTTP(S) inaccessibles, mode transmis."""
    settings = _state["settings"]
    if settings is None or settings.get("mode") != "OFFLINE":
        return None
    env = dict(os.environ if base is None else base)
    allow = list((settings.get("network") or {}).get("allow_hosts", []))
    env["SOULBAH_MODE"] = "OFFLINE"
    env["SOULBAH_NETWORK_ALLOW_HOSTS"] = ",".join(allow)
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
        env[k] = BLACKHOLE_PROXY
    no_proxy = ",".join(["localhost", "127.0.0.1", "::1", *allow])
    env["NO_PROXY"] = env["no_proxy"] = no_proxy
    site = guard_site_dir()
    env["PYTHONPATH"] = site + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    node_guard = os.path.join(site, NODE_GUARD_FILE).replace("\\", "/")
    require = f'--require "{node_guard}"'
    if require not in env.get("NODE_OPTIONS", ""):
        env["NODE_OPTIONS"] = (env.get("NODE_OPTIONS", "") + " " + require).strip()
    return env


def _reset_for_tests() -> None:
    with _lock:
        _state["settings"] = None
        _state["blocked"] = 0
        _state["recent"] = []
