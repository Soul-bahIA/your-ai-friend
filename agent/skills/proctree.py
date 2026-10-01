"""Exécution d'un processus avec arrêt garanti de TOUT son arbre (T23).

Sous Windows, `subprocess.run(timeout=…)` ne tue que le processus direct :
`npm.cmd → cmd.exe → node.exe` survivait au délai. Ici :
  1. le processus est créé SUSPENDU, placé dans un Job Object
     « KILL_ON_JOB_CLOSE », puis relancé : tous ses descendants héritent du job ;
  2. au délai dépassé (ou à l'annulation : stop, Ctrl+C), le job est terminé
     (TerminateJobObject), puis `taskkill /T /F /PID` sert de filet de sécurité ;
  3. à la fermeture du job, les descendants encore vivants (serveur lancé en
     arrière-plan par un script…) sont tués.
Sous Unix : nouvelle session + killpg.
"""
from __future__ import annotations

import logging
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass

from skills.base import CancelToken

log = logging.getLogger("soulbah.proctree")

_IS_WIN = sys.platform == "win32"
_POLL_SECONDS = 0.25
_DRAIN_SECONDS = 10.0


@dataclass
class ProcResult:
    returncode: int | None
    stdout: str
    stderr: str
    timed_out: bool = False
    cancelled: bool = False
    tree_killed: bool = False
    used_job: bool = False


if _IS_WIN:
    import ctypes
    from ctypes import wintypes

    _k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _ntdll = ctypes.WinDLL("ntdll")

    _JobObjectExtendedLimitInformation = 9
    _JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
    _CREATE_SUSPENDED = 0x00000004
    _PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    _STILL_ACTIVE = 259

    class _IO_COUNTERS(ctypes.Structure):
        _fields_ = [(n, ctypes.c_ulonglong) for n in (
            "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
            "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

    class _BASIC_LIMIT(ctypes.Structure):
        _fields_ = [
            ("PerProcessUserTimeLimit", ctypes.c_longlong),
            ("PerJobUserTimeLimit", ctypes.c_longlong),
            ("LimitFlags", wintypes.DWORD),
            ("MinimumWorkingSetSize", ctypes.c_size_t),
            ("MaximumWorkingSetSize", ctypes.c_size_t),
            ("ActiveProcessLimit", wintypes.DWORD),
            ("Affinity", ctypes.c_size_t),
            ("PriorityClass", wintypes.DWORD),
            ("SchedulingClass", wintypes.DWORD),
        ]

    class _EXTENDED_LIMIT(ctypes.Structure):
        _fields_ = [
            ("BasicLimitInformation", _BASIC_LIMIT),
            ("IoInfo", _IO_COUNTERS),
            ("ProcessMemoryLimit", ctypes.c_size_t),
            ("JobMemoryLimit", ctypes.c_size_t),
            ("PeakProcessMemoryUsed", ctypes.c_size_t),
            ("PeakJobMemoryUsed", ctypes.c_size_t),
        ]

    _k32.CreateJobObjectW.restype = wintypes.HANDLE
    _k32.CreateJobObjectW.argtypes = [wintypes.LPVOID, wintypes.LPCWSTR]
    _k32.SetInformationJobObject.restype = wintypes.BOOL
    _k32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD]
    _k32.AssignProcessToJobObject.restype = wintypes.BOOL
    _k32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    _k32.TerminateJobObject.restype = wintypes.BOOL
    _k32.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
    _k32.CloseHandle.restype = wintypes.BOOL
    _k32.CloseHandle.argtypes = [wintypes.HANDLE]
    _k32.OpenProcess.restype = wintypes.HANDLE
    _k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    _k32.GetExitCodeProcess.restype = wintypes.BOOL
    _k32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    _ntdll.NtResumeProcess.restype = ctypes.c_long
    _ntdll.NtResumeProcess.argtypes = [wintypes.HANDLE]


class _Job:
    """Job Object Windows « tuer à la fermeture » (None ailleurs ou en cas d'échec)."""

    def __init__(self, handle: int):
        self.handle = handle

    @classmethod
    def create(cls) -> "_Job | None":
        if not _IS_WIN:
            return None
        handle = _k32.CreateJobObjectW(None, None)
        if not handle:
            return None
        info = _EXTENDED_LIMIT()
        info.BasicLimitInformation.LimitFlags = _JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not _k32.SetInformationJobObject(handle, _JobObjectExtendedLimitInformation,
                                            ctypes.byref(info), ctypes.sizeof(info)):
            _k32.CloseHandle(handle)
            return None
        return cls(handle)

    def assign(self, proc: subprocess.Popen) -> bool:
        return bool(_k32.AssignProcessToJobObject(self.handle, int(proc._handle)))  # type: ignore[attr-defined]

    def terminate(self) -> None:
        if self.handle:
            _k32.TerminateJobObject(self.handle, 1)

    def close(self) -> None:
        if self.handle:
            _k32.CloseHandle(self.handle)  # KILL_ON_JOB_CLOSE : tue les survivants
            self.handle = 0


def pid_alive(pid: int) -> bool:
    """True si le processus `pid` est encore en vie."""
    if _IS_WIN:
        handle = _k32.OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
        if not handle:
            return False
        try:
            code = wintypes.DWORD()
            if not _k32.GetExitCodeProcess(handle, ctypes.byref(code)):
                return False
            return code.value == _STILL_ACTIVE
        finally:
            _k32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _taskkill_tree(pid: int) -> bool:
    """Filet de sécurité : `taskkill /T /F` parcourt l'arbre par PID parent."""
    if not _IS_WIN:
        return False
    windir = os.environ.get("SystemRoot", r"C:\Windows")
    exe = os.path.join(windir, "System32", "taskkill.exe")
    if not os.path.isfile(exe):
        return False
    try:
        proc = subprocess.run([exe, "/T", "/F", "/PID", str(pid)], capture_output=True, timeout=15,
                              stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return False
    return proc.returncode == 0


def kill_tree(proc: subprocess.Popen, job: _Job | None) -> None:
    """Tue le processus et tous ses descendants."""
    if job is not None:
        job.terminate()
    if _IS_WIN:
        if job is None or proc.poll() is None:
            _taskkill_tree(proc.pid)
    else:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (OSError, AttributeError):
            pass
    try:
        proc.kill()
    except OSError:
        pass


def run_tree(
    argv: list[str],
    cwd: str,
    timeout: float,
    cancel: CancelToken | None = None,
    use_job: bool = True,
    env: dict[str, str] | None = None,
) -> ProcResult:
    """Lance `argv` (sans shell), attend la fin, le délai ou l'annulation, et
    garantit qu'aucun descendant ne survit à un délai dépassé ou une annulation."""
    job = _Job.create() if use_job else None
    kwargs: dict = dict(
        cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
        text=True, encoding="utf-8", errors="replace", shell=False, env=env,
    )
    if _IS_WIN:
        if job is not None:
            kwargs["creationflags"] = _CREATE_SUSPENDED
    else:
        kwargs["start_new_session"] = True

    try:
        proc = subprocess.Popen(argv, **kwargs)
    except Exception:
        if job is not None:
            job.close()
        raise

    used_job = False
    if job is not None:
        used_job = job.assign(proc)
        if not used_job:
            log.warning("Job Object indisponible pour PID %d — repli sur taskkill /T", proc.pid)
        status = _ntdll.NtResumeProcess(int(proc._handle))  # type: ignore[attr-defined]
        if status != 0:  # NTSTATUS en échec : le processus resterait suspendu
            kill_tree(proc, job)
            job.close()
            proc.communicate()
            raise OSError(f"impossible de relancer le processus suspendu (NTSTATUS {status:#x})")
        if not used_job:
            job.close()
            job = None

    deadline = time.monotonic() + max(0.0, timeout)
    timed_out = cancelled = tree_killed = False
    out = err = ""
    try:
        while True:
            try:
                out, err = proc.communicate(timeout=_POLL_SECONDS)
                break
            except subprocess.TimeoutExpired:
                if cancel is not None and cancel.is_cancelled():
                    cancelled = True
                elif time.monotonic() >= deadline:
                    timed_out = True
                if timed_out or cancelled:
                    kill_tree(proc, job)
                    tree_killed = True
                    try:
                        out, err = proc.communicate(timeout=_DRAIN_SECONDS)
                    except subprocess.TimeoutExpired:
                        out, err = "", ""
                    break
    finally:
        if job is not None:
            job.close()
    return ProcResult(proc.returncode, out or "", err or "", timed_out=timed_out, cancelled=cancelled,
                      tree_killed=tree_killed, used_job=used_job)
