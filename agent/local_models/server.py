"""Serveur de modèle local PARTAGÉ (V3 LOT 2, mission §11, §13) : agent ≠ instance de modèle.

Un seul `llama-server` charge les poids UNE fois ; `parallel` contextes (slots) servent les
agents ; au-delà, les requêtes attendent dans la file du serveur. API compatible OpenAI sur
http://127.0.0.1:<port>/v1 — à donner à python-ia et node-api via LOCAL_LLM_URL.

Paramètres par défaut tirés du profil matériel (hardware.recommendations) : threads = cœurs
physiques, 1 ou 2 slots, contexte de 4 096 jetons par slot. Bouclage uniquement (jamais exposé
au réseau). État : <models>/server.json (pid, port, modèle, arguments).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Any

from local_models import registry

DEFAULT_PORT = 8091
DEFAULT_CTX_PER_SLOT = 4096
HEALTH_TIMEOUT_S = 180.0


class ServerError(RuntimeError):
    pass


def state_path() -> str:
    return os.path.join(registry.base_dir(), "server.json")


def read_state() -> dict[str, Any] | None:
    try:
        with open(state_path(), encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return None


def _write_state(state: dict[str, Any] | None) -> None:
    path = state_path()
    if state is None:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)


def find_binary() -> str | None:
    """llama-server : moteur installé par `soulbah_models.py install-engine`, sinon PATH."""
    data = registry.load()
    for e in data.get("engines", {}).values():
        if e.get("status") == "installed" and e.get("path") and os.path.isfile(e["path"]):
            return e["path"]
    return shutil.which("llama-server")


def build_args(model_path: str, port: int, threads: int, parallel: int, ctx_per_slot: int,
               embedding: bool = False) -> list[str]:
    args = ["-m", model_path, "--host", "127.0.0.1", "--port", str(port), "-t", str(threads),
            "-np", str(parallel), "-c", str(ctx_per_slot * parallel)]
    if embedding:
        args.append("--embedding")
    return args


def defaults_from_profile(profile: dict[str, Any] | None = None) -> dict[str, int]:
    if profile is None:
        import hardware

        profile = hardware.profile()
    cores = (profile.get("cpu") or {}).get("physical_cores") or max(1, ((profile.get("cpu") or {}).get("logical_threads") or 2) // 2)
    parallel = int((profile.get("recommendations") or {}).get("parallel_inferences") or 1)
    return {"threads": int(cores), "parallel": max(1, parallel), "ctx_per_slot": DEFAULT_CTX_PER_SLOT}


def health(port: int, timeout: float = 2.0) -> str:
    """"ok" | "loading" | "down"."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=timeout) as r:
            body = r.read(2000).decode("utf-8", "replace")
            return "ok" if r.status == 200 and ('"ok"' in body or "ok" in body.lower()) else "loading"
    except urllib.error.HTTPError as e:
        return "loading" if e.code == 503 else "down"
    except (urllib.error.URLError, OSError, TimeoutError):
        return "down"


def _pid_alive(pid: int) -> bool:
    try:
        from skills.proctree import pid_alive

        return pid_alive(pid)
    except Exception:  # noqa: BLE001
        return False


def start(model_id: str, port: int = DEFAULT_PORT, threads: int | None = None, parallel: int | None = None,
          ctx_per_slot: int | None = None, binary_argv: list[str] | None = None,
          wait_s: float = HEALTH_TIMEOUT_S) -> dict[str, Any]:
    """Démarre le serveur partagé pour `model_id` et attend qu'il soit prêt (/health)."""
    current = read_state()
    if current and _pid_alive(int(current.get("pid") or 0)):
        if current.get("model_id") == model_id and health(int(current["port"])) == "ok":
            return current
        raise ServerError(f"un serveur tourne déjà (modèle {current.get('model_id')}, pid {current.get('pid')}) : "
                          "arrêtez-le d'abord (stop)")
    model = registry.load()["models"].get(model_id)
    if not model or not model.get("path") or not os.path.isfile(model["path"]):
        raise ServerError(f"modèle non installé : {model_id}")
    d = defaults_from_profile() if (threads is None or parallel is None) else {}
    threads = threads or d.get("threads", 2)
    parallel = parallel or d.get("parallel", 1)
    ctx_per_slot = ctx_per_slot or DEFAULT_CTX_PER_SLOT
    if binary_argv is None:
        binary = find_binary()
        if not binary:
            raise ServerError("llama-server introuvable : installez le moteur (install-engine) ou ajoutez-le au PATH")
        binary_argv = [binary]
    embedding = "embedding" in (model.get("roles") or [])
    argv = [*binary_argv, *build_args(model["path"], port, threads, parallel, ctx_per_slot, embedding)]
    log_path = os.path.join(registry.base_dir(), "server.log")
    os.makedirs(registry.base_dir(), exist_ok=True)
    log = open(log_path, "ab")  # noqa: SIM115 - conservé par le processus enfant
    flags = 0
    if sys.platform == "win32":
        flags = subprocess.CREATE_NEW_PROCESS_GROUP | getattr(subprocess, "CREATE_NO_WINDOW", 0)
    proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                            creationflags=flags, close_fds=True)
    state = {"pid": proc.pid, "port": port, "model_id": model_id, "argv": argv, "threads": threads,
             "parallel": parallel, "ctx_per_slot": ctx_per_slot, "started_at": registry.now_iso(),
             "url": f"http://127.0.0.1:{port}/v1", "log": log_path}
    _write_state(state)
    deadline = time.monotonic() + wait_s
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            _write_state(None)
            raise ServerError(f"llama-server s'est arrêté au démarrage (code {proc.returncode}) — voir {log_path}")
        if health(port) == "ok":
            return state
        time.sleep(0.5)
    stop()
    raise ServerError(f"llama-server pas prêt en {int(wait_s)} s (modèle trop gros pour la RAM ?) — voir {log_path}")


def stop() -> bool:
    state = read_state()
    if not state:
        return False
    pid = int(state.get("pid") or 0)
    if pid and _pid_alive(pid):
        if sys.platform == "win32":
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True, timeout=30)
        else:
            os.kill(pid, 15)
        for _ in range(50):
            if not _pid_alive(pid):
                break
            time.sleep(0.1)
    _write_state(None)
    return True


def status() -> dict[str, Any]:
    state = read_state()
    if not state:
        return {"running": False}
    alive = _pid_alive(int(state.get("pid") or 0))
    return {"running": alive, "health": health(int(state["port"])) if alive else "down", **state}


def peak_memory_mb(pid: int) -> float | None:
    """Mémoire de pointe (working set) d'un processus — Windows : GetProcessMemoryInfo."""
    if sys.platform != "win32":
        try:
            with open(f"/proc/{pid}/status", encoding="ascii") as f:
                for line in f:
                    if line.startswith("VmHWM:"):
                        return round(int(line.split()[1]) / 1024, 1)
        except OSError:
            return None
        return None
    import ctypes
    from ctypes import wintypes

    class PMC(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                    ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t)]

    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    k32.OpenProcess.restype = wintypes.HANDLE
    h = k32.OpenProcess(0x1000 | 0x0010, False, pid)  # QUERY_LIMITED_INFORMATION | VM_READ
    if not h:
        return None
    try:
        pmc = PMC()
        pmc.cb = ctypes.sizeof(PMC)
        if not psapi.GetProcessMemoryInfo(h, ctypes.byref(pmc), pmc.cb):
            return None
        return round(pmc.PeakWorkingSetSize / 1024 ** 2, 1)
    finally:
        k32.CloseHandle(h)
