"""Hardware Profiler (V3 LOT 1, mission V3 §3) : ce que la machine peut faire tourner localement.

`profile()` lit, sans droits administrateur et sans lancer de processus (registre, API Windows
via ctypes, bibliothèque standard), en moins d'une seconde :
  OS · CPU (modèle, cœurs physiques, threads, fréquence, AVX/AVX2/FMA/AVX-512) · RAM totale et
  disponible · GPU (nom, fabricant, VRAM dédiée, pilote, CUDA) · accélérations (Vulkan, DirectML)
  · disques · moteurs et outils locaux présents · paquets Python utiles · voix de synthèse
  installées · recommandations ESTIMÉES (budget de modèle, inférences simultanées, profil).

`profile(bench=True)` ajoute deux mesures courtes (≈ 2 s, numpy) : GFLOPS fp32 et bande
passante mémoire — la vitesse de génération d'un modèle sur CPU en dépend directement.

Aucune donnée ne quitte la machine ici : le résumé est envoyé au plan de contrôle de
l'utilisateur à l'enregistrement du runtime (capabilities.hardware).
"""
from __future__ import annotations

import datetime as _dt
import importlib.metadata
import importlib.util
import os
import platform
import shutil
import sys
import time
from typing import Any

IS_WIN = sys.platform == "win32"
GB = 1024 ** 3
PROFILE_SCHEMA = 1
# Hypothèse prudente si la bande passante n'a pas été mesurée (DDR4 portable, Go/s).
DEFAULT_BANDWIDTH_GBPS = 10.0

ENGINES = ("ollama", "llama-server", "llama-cli", "whisper-cli", "piper", "tesseract")
TOOLS = ("git", "node", "npm", "psql", "adb", "docker", "nvidia-smi", "ffmpeg", "ffprobe")
PY_PACKAGES = ("numpy", "cv2", "mss", "moviepy", "imageio_ffmpeg", "pyautogui", "onnxruntime", "llama_cpp",
               "faster_whisper", "whisper", "vosk", "piper", "pyttsx3", "comtypes", "playwright",
               "sentence_transformers", "torch", "transformers")
_DIST_NAMES = {"cv2": "opencv-python-headless", "imageio_ffmpeg": "imageio-ffmpeg", "llama_cpp": "llama-cpp-python",
               "faster_whisper": "faster-whisper", "piper": "piper-tts", "sentence_transformers": "sentence-transformers",
               "pyautogui": "PyAutoGUI"}


def _round(x: float | None, nd: int = 1) -> float | None:
    return None if x is None else round(float(x), nd)


# --- Windows : registre et ctypes ------------------------------------------------------
def _reg(path: str, name: str) -> Any:
    if not IS_WIN:
        return None
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, path) as k:
            return winreg.QueryValueEx(k, name)[0]
    except OSError:
        return None


def _reg_subkeys(path: str) -> list[str]:
    if not IS_WIN:
        return []
    import winreg

    out: list[str] = []
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, path) as k:
            i = 0
            while True:
                try:
                    out.append(winreg.EnumKey(k, i))
                except OSError:
                    break
                i += 1
    except OSError:
        pass
    return out


def _memory() -> dict[str, Any]:
    if IS_WIN:
        import ctypes
        from ctypes import wintypes

        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [("dwLength", wintypes.DWORD), ("dwMemoryLoad", wintypes.DWORD),
                        ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                        ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                        ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                        ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]

        st = MEMORYSTATUSEX()
        st.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
            return {"total_gb": _round(st.ullTotalPhys / GB), "available_gb": _round(st.ullAvailPhys / GB, 2),
                    "load_percent": int(st.dwMemoryLoad),
                    "commit_limit_gb": _round(st.ullTotalPageFile / GB)}
        return {"total_gb": None, "available_gb": None}
    info: dict[str, float] = {}
    try:
        with open("/proc/meminfo", encoding="ascii") as f:
            for line in f:
                k, v = line.split(":", 1)
                info[k] = float(v.strip().split()[0]) * 1024
    except OSError:
        return {"total_gb": None, "available_gb": None}
    return {"total_gb": _round(info.get("MemTotal", 0) / GB), "available_gb": _round(info.get("MemAvailable", 0) / GB, 2)}


def _physical_cores() -> int | None:
    if IS_WIN:
        import ctypes

        k32 = ctypes.windll.kernel32
        needed = ctypes.c_ulong(0)
        k32.GetLogicalProcessorInformation(None, ctypes.byref(needed))
        if not needed.value:
            return None
        buf = ctypes.create_string_buffer(needed.value)
        if not k32.GetLogicalProcessorInformation(buf, ctypes.byref(needed)):
            return None
        # SYSTEM_LOGICAL_PROCESSOR_INFORMATION : ULONG_PTR masque, DWORD relation, union 16 o.
        size = ctypes.sizeof(ctypes.c_void_p) + 4 + (4 if ctypes.sizeof(ctypes.c_void_p) == 8 else 0) + 16
        rel_off = ctypes.sizeof(ctypes.c_void_p)
        count = 0
        for off in range(0, needed.value - size + 1, size):
            if int.from_bytes(buf.raw[off + rel_off:off + rel_off + 4], "little") == 0:  # RelationProcessorCore
                count += 1
        return count or None
    try:
        with open("/proc/cpuinfo", encoding="ascii", errors="ignore") as f:
            cores = {line.split(":")[1].strip() for line in f if line.startswith("core id")}
        return len(cores) or None
    except OSError:
        return None


def _cpu_features() -> dict[str, bool | None]:
    """AVX / AVX2 / AVX-512 : API Windows (instantané) ou /proc/cpuinfo ; numpy en dernier recours
    seulement (son import coûte plusieurs secondes sur une machine chargée). FMA3 n'est pas exposé
    par l'API Windows : None = inconnu."""
    feats: dict[str, bool | None] = {"avx": None, "avx2": None, "fma3": None, "avx512f": None}
    if IS_WIN:
        import ctypes

        present = ctypes.windll.kernel32.IsProcessorFeaturePresent
        # PF_AVX_INSTRUCTIONS_AVAILABLE = 39, PF_AVX2 = 40, PF_AVX512F = 41 (Windows 10+).
        feats.update(avx=bool(present(39)), avx2=bool(present(40)), avx512f=bool(present(41)))
        return feats
    try:
        with open("/proc/cpuinfo", encoding="ascii", errors="ignore") as fh:
            flags = next((line.split(":")[1].split() for line in fh if line.startswith("flags")), [])
        if flags:
            return {"avx": "avx" in flags, "avx2": "avx2" in flags, "fma3": "fma" in flags, "avx512f": "avx512f" in flags}
    except OSError:
        pass
    try:
        from numpy._core._multiarray_umath import __cpu_features__ as f  # type: ignore[attr-defined]

        return {"avx": bool(f.get("AVX")), "avx2": bool(f.get("AVX2")), "fma3": bool(f.get("FMA3")),
                "avx512f": bool(f.get("AVX512F"))}
    except Exception:  # noqa: BLE001 - numpy absent ou interne différent
        return feats


def _cpu() -> dict[str, Any]:
    key = r"HARDWARE\DESCRIPTION\System\CentralProcessor\0"
    name = _reg(key, "ProcessorNameString") if IS_WIN else None
    if not name and not IS_WIN:
        try:
            with open("/proc/cpuinfo", encoding="ascii", errors="ignore") as f:
                name = next((line.split(":", 1)[1].strip() for line in f if line.startswith("model name")), None)
        except OSError:
            name = None
    return {
        "name": (str(name).strip() if name else platform.processor()) or None,
        "architecture": platform.machine(),
        "physical_cores": _physical_cores(),
        "logical_threads": os.cpu_count(),
        "max_mhz": _reg(key, "~MHz") if IS_WIN else None,
        "features": _cpu_features(),
    }


_GPU_CLASS = r"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"


def _gpus() -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for sub in _reg_subkeys(_GPU_CLASS):
        if not sub.isdigit():
            continue
        path = f"{_GPU_CLASS}\\{sub}"
        desc = _reg(path, "DriverDesc")
        if not desc:
            continue
        vram = _reg(path, "HardwareInformation.qwMemorySize")
        if vram is None:
            raw = _reg(path, "HardwareInformation.MemorySize")
            if isinstance(raw, (bytes, bytearray)):
                vram = int.from_bytes(bytes(raw)[:8], "little")
            elif isinstance(raw, int):
                vram = raw
        vendor = str(_reg(path, "ProviderName") or "")
        lname = f"{desc} {vendor}".lower()
        kind = "nvidia" if "nvidia" in lname else "amd" if ("amd" in lname or "radeon" in lname) else \
            "intel" if "intel" in lname else "autre"
        virtual = any(w in lname for w in ("hyper-v", "basic display", "basic render", "remote display", "virtual"))
        out.append({"name": str(desc), "vendor": kind, "vram_gb": _round(vram / GB, 2) if vram else None,
                    "driver_version": _reg(path, "DriverVersion"), "driver_date": _reg(path, "DriverDate"),
                    "integrated": kind == "intel" and not ("arc" in lname), "virtual": virtual})
    return out


def _accelerators(gpus: list[dict[str, Any]]) -> dict[str, bool]:
    sysdir = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "System32") if IS_WIN else ""
    has = (lambda dll: os.path.isfile(os.path.join(sysdir, dll))) if IS_WIN else (lambda dll: False)
    cuda = bool(shutil.which("nvidia-smi")) or has("nvcuda.dll")
    return {"cuda": cuda and any(g["vendor"] == "nvidia" for g in gpus) if gpus else cuda,
            "vulkan": has("vulkan-1.dll") or bool(shutil.which("vulkaninfo")),
            "directml": has("DirectML.dll")}


def _disks(extra_paths: list[str]) -> list[dict[str, Any]]:
    seen: set[str] = set()
    out: list[dict[str, Any]] = []
    for p in [os.path.abspath(os.sep), *extra_paths]:
        try:
            anchor = os.path.splitdrive(os.path.abspath(p))[0] + os.sep if IS_WIN else os.path.abspath(p)
            if anchor.lower() in seen:
                continue
            seen.add(anchor.lower())
            du = shutil.disk_usage(anchor)
            out.append({"path": anchor, "total_gb": _round(du.total / GB), "free_gb": _round(du.free / GB)})
        except OSError:
            continue
    return out


def _tools() -> dict[str, str | None]:
    found: dict[str, str | None] = {t: shutil.which(t) for t in (*ENGINES, *TOOLS)}
    if not found.get("ffmpeg"):
        try:
            import imageio_ffmpeg  # type: ignore[import-not-found]

            found["ffmpeg"] = imageio_ffmpeg.get_ffmpeg_exe()
        except Exception:  # noqa: BLE001
            pass
    found["vscode"] = _find_vscode()
    return found


def _find_vscode() -> str | None:
    """Mêmes emplacements que skills/vscode.find_vscode, sans importer le paquet skills (qui
    charge pyautogui, OpenCV… : plusieurs secondes)."""
    override = os.environ.get("SOULBAH_VSCODE_EXE", "").strip()
    if override:
        return override if os.path.isfile(override) else None
    candidates = []
    if os.environ.get("LOCALAPPDATA"):
        candidates.append(os.path.join(os.environ["LOCALAPPDATA"], "Programs", "Microsoft VS Code", "Code.exe"))
    for var in ("ProgramFiles", "ProgramFiles(x86)"):
        if os.environ.get(var):
            candidates.append(os.path.join(os.environ[var], "Microsoft VS Code", "Code.exe"))
    cli = shutil.which("code.cmd") if IS_WIN else shutil.which("code")
    if cli:
        candidates.append(os.path.join(os.path.dirname(os.path.dirname(cli)), "Code.exe") if IS_WIN else cli)
    return next((c for c in candidates if os.path.isfile(c)), None)


def _packages() -> dict[str, str | None]:
    out: dict[str, str | None] = {}
    for mod in PY_PACKAGES:
        try:
            if importlib.util.find_spec(mod) is None:
                out[mod] = None
                continue
        except (ImportError, ValueError):
            out[mod] = None
            continue
        try:
            out[mod] = importlib.metadata.version(_DIST_NAMES.get(mod, mod))
        except importlib.metadata.PackageNotFoundError:
            out[mod] = "présent"
    return out


def tts_voices() -> list[str]:
    """Voix de synthèse vocale installées (SAPI 5 et OneCore sous Windows)."""
    names: list[str] = []
    for base in (r"SOFTWARE\Microsoft\Speech\Voices\Tokens", r"SOFTWARE\Microsoft\Speech_OneCore\Voices\Tokens"):
        for sub in _reg_subkeys(base):
            name = _reg(f"{base}\\{sub}", "")
            if name and str(name) not in names:
                names.append(str(name))
    return names


def bench(seconds_budget: float = 3.0) -> dict[str, Any]:
    """Mesures courtes : GFLOPS fp32 (produit matriciel) et bande passante mémoire (copie)."""
    try:
        import numpy as np
    except ImportError:
        return {"error": "numpy absent : mesures impossibles"}
    t_end = time.monotonic() + seconds_budget
    n = 1024
    a = np.random.rand(n, n).astype(np.float32)
    b = np.random.rand(n, n).astype(np.float32)
    a @ b
    flops = []
    while len(flops) < 5 and time.monotonic() < t_end:
        t = time.perf_counter()
        a @ b
        flops.append(2 * n ** 3 / (time.perf_counter() - t) / 1e9)
    x = np.ones(32 * 1024 * 1024 // 8)
    y = np.zeros_like(x)
    np.copyto(y, x)
    bw = []
    while len(bw) < 7 and time.monotonic() < t_end + 1.0:
        t = time.perf_counter()
        np.copyto(y, x)
        bw.append(2 * x.nbytes / (time.perf_counter() - t) / 1e9)
    med = lambda v: sorted(v)[len(v) // 2] if v else None  # noqa: E731
    return {"matmul_gflops": _round(med(flops)), "mem_bandwidth_gbps": _round(med(bw)), "samples": [len(flops), len(bw)]}


def recommendations(p: dict[str, Any]) -> dict[str, Any]:
    """Estimations (à confirmer par les benchmarks de modèles du LOT 2)."""
    total = (p.get("memory") or {}).get("total_gb") or 0.0
    threads = (p.get("cpu") or {}).get("logical_threads") or 1
    gpus = p.get("gpus") or []
    vram = max([g.get("vram_gb") or 0 for g in gpus if g.get("vendor") in ("nvidia", "amd") and not g.get("integrated")] or [0])
    cuda = bool((p.get("accelerators") or {}).get("cuda"))
    bw = ((p.get("bench") or {}).get("mem_bandwidth_gbps")) or DEFAULT_BANDWIDTH_GBPS
    ram_budget = max(0.0, min(total * 0.45, total - 3.5))
    max_file = round(ram_budget * 0.75, 1)
    gpu_budget = round(vram * 0.8, 1) if (cuda and vram >= 4) else 0.0
    disks = p.get("disks") or []
    free = max([d.get("free_gb") or 0 for d in disks] or [0])
    if total < 12 or threads <= 4:
        prof = "ECO"
    elif total < 32:
        prof = "BALANCED"
    else:
        prof = "MAX"
    est = {f"{size}_go": _round(bw * 0.7 / size) for size in (1.0, 2.0, 4.5)}
    return {
        "estimate": True,
        "accelerator": "cuda" if gpu_budget else "cpu",
        "model_ram_budget_gb": _round(ram_budget),
        "max_model_file_gb": max(gpu_budget, max_file),
        "parallel_inferences": 1 if (threads <= 4 and not gpu_budget) else 2,
        "suggested_resource_profile": prof,
        "models_disk_budget_gb": _round(max(0.0, free - 5.0)),
        "est_tokens_per_s_cpu_by_model_size": est,
        "bandwidth_source": "mesurée" if (p.get("bench") or {}).get("mem_bandwidth_gbps") else "hypothèse",
    }


def profile(with_bench: bool = False, extra_paths: list[str] | None = None) -> dict[str, Any]:
    t0 = time.perf_counter()
    gpus = _gpus()
    p: dict[str, Any] = {
        "schema": PROFILE_SCHEMA,
        "collected_at": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
        "os": {"system": platform.system(), "release": platform.release(), "version": platform.version(),
               "python": platform.python_version()},
        "cpu": _cpu(),
        "memory": _memory(),
        "gpus": gpus,
        "accelerators": _accelerators(gpus),
        "disks": _disks(extra_paths or []),
        "tools": _tools(),
        "python_packages": _packages(),
        "tts_voices": tts_voices(),
    }
    if with_bench:
        p["bench"] = bench()
    p["recommendations"] = recommendations(p)
    p["collect_ms"] = int((time.perf_counter() - t0) * 1000)
    return p


def summary(p: dict[str, Any]) -> dict[str, Any]:
    """Résumé compact envoyé au plan de contrôle (sans chemins complets des outils)."""
    return {
        "schema": p.get("schema"),
        "collected_at": p.get("collected_at"),
        "os": p.get("os"),
        "cpu": p.get("cpu"),
        "memory": p.get("memory"),
        "gpus": p.get("gpus"),
        "accelerators": p.get("accelerators"),
        "disks": p.get("disks"),
        "engines": {k: bool(v) for k, v in (p.get("tools") or {}).items() if k in ENGINES},
        "tools": {k: bool(v) for k, v in (p.get("tools") or {}).items() if k not in ENGINES},
        "python_packages": {k: v for k, v in (p.get("python_packages") or {}).items() if v},
        "tts_voices": p.get("tts_voices"),
        "bench": p.get("bench"),
        "recommendations": p.get("recommendations"),
    }
