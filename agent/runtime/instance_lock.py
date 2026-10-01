r"""Garde d'instance unique (audit §14) : un seul exécutant local à la fois — soit le
runtime V2 (`runtime.supervisor`), soit l'agent V1 (`soulbah_agent.py`), jamais les deux
(ils réclameraient les mêmes tâches ou se disputeraient le bureau).

Fichier `<SOULBAH_RUNTIME_DIR>\instance.lock` (défaut `%LOCALAPPDATA%\Soulbah\runtime`)
créé en exclusif (O_EXCL) et contenant `{pid, kind, started_at}`. Un verrou dont le PID
n'est plus vivant — ou n'est plus un interpréteur Python (PID réutilisé par un autre
programme) — est considéré périmé et remplacé. Le même processus peut reprendre son
propre verrou (legacy_adapter : la boucle V1 tourne DANS le superviseur).
"""
from __future__ import annotations

import json
import logging
import os
import sys
import time
from typing import Any

from skills.proctree import pid_alive

log = logging.getLogger("soulbah.runtime.lock")

LOCK_FILE = "instance.lock"
KIND_RUNTIME = "runtime"
KIND_AGENT_V1 = "agent_v1"
_LABELS = {KIND_RUNTIME: "runtime V2 (runtime.supervisor)", KIND_AGENT_V1: "agent V1 (soulbah_agent.py)"}


def runtime_dir() -> str:
    r"""Dossier d'état du runtime : SOULBAH_RUNTIME_DIR, sinon %LOCALAPPDATA%\Soulbah\runtime."""
    override = os.environ.get("SOULBAH_RUNTIME_DIR", "").strip()
    if override:
        return override
    base = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Local")
    return os.path.join(base, "Soulbah", "runtime")


def _image_name(pid: int) -> str | None:
    """Nom de l'exécutable du processus (Windows), None si inconnu / hors Windows."""
    if sys.platform != "win32":
        return None
    try:
        import ctypes
        from ctypes import wintypes

        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        handle = k32.OpenProcess(0x1000, False, int(pid))  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return None
        try:
            size = wintypes.DWORD(1024)
            buf = ctypes.create_unicode_buffer(size.value)
            if not k32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                return None
            return os.path.basename(buf.value)
        finally:
            k32.CloseHandle(handle)
    except Exception:  # noqa: BLE001 - diagnostic best-effort
        return None


def holder_alive(info: dict[str, Any]) -> bool:
    """True si le détenteur décrit par le verrou est encore un processus Python vivant."""
    try:
        pid = int(info.get("pid"))
    except (TypeError, ValueError):
        return False
    if pid <= 0 or not pid_alive(pid):
        return False
    image = _image_name(pid)
    if image is not None and "python" not in image.lower():
        return False  # PID réutilisé par un autre programme
    return True


def describe(info: dict[str, Any] | None) -> str:
    if not info:
        return "inconnu"
    return f"{_LABELS.get(str(info.get('kind')), info.get('kind'))} · PID {info.get('pid')}"


class InstanceLock:
    def __init__(self, kind: str, directory: str | None = None):
        self.kind = kind
        self.directory = directory or runtime_dir()
        self.path = os.path.join(self.directory, LOCK_FILE)
        self.held = False

    def _read(self) -> dict[str, Any] | None:
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            return None
        return data if isinstance(data, dict) else None

    def _write_exclusive(self) -> bool:
        fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"pid": os.getpid(), "kind": self.kind, "started_at": time.time()}, f)
        return True

    def acquire(self) -> tuple[bool, dict[str, Any] | None]:
        """(True, None) si le verrou est pris ; (False, détenteur) si un autre exécutant
        tourne. Un dossier inaccessible n'empêche pas le démarrage (avertissement)."""
        try:
            os.makedirs(self.directory, exist_ok=True)
        except OSError as e:
            log.warning("Garde d'instance indisponible (%s) : %s", self.directory, e)
            return True, None
        for _ in range(5):
            try:
                self._write_exclusive()
                self.held = True
                return True, None
            except FileExistsError:
                pass
            except OSError as e:
                log.warning("Garde d'instance : écriture impossible (%s)", e)
                return True, None
            info = self._read()
            if info is not None and int(info.get("pid") or -1) == os.getpid():
                self.held = True  # réentrant : même processus (legacy_adapter)
                return True, None
            if info is not None and holder_alive(info):
                return False, info
            # Verrou périmé (processus mort, fichier illisible) : on le retire et on réessaie.
            try:
                os.remove(self.path)
            except OSError:
                time.sleep(0.05)
        info = self._read()
        return False, info or {"pid": None, "kind": "?"}

    def release(self) -> None:
        if not self.held:
            return
        self.held = False
        info = self._read()
        if info is not None and int(info.get("pid") or -1) != os.getpid():
            return  # le verrou a été repris par un autre : ne pas le supprimer
        try:
            os.remove(self.path)
        except OSError:
            pass

    def __enter__(self) -> "InstanceLock":
        return self

    def __exit__(self, *_exc) -> None:
        self.release()
