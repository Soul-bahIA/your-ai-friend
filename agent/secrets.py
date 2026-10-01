r"""Stockage de la clé agent chiffré par DPAPI (LOT 6 — S1/S8 : la clé ne traîne plus en
clair dans agent/.env).

Windows uniquement : `CryptProtectData` / `CryptUnprotectData` (ctypes, portée
UTILISATEUR, aucune dépendance). Le fichier `%LOCALAPPDATA%\Soulbah\agent_key.dpapi`
(`SOULBAH_SECRETS_DIR` pour changer le dossier) ne peut être déchiffré que par le
même compte Windows sur la même machine. Hors Windows, `NotImplementedError` : on ne
retombe JAMAIS sur un stockage en clair.

Procédure : `python soulbah_agent.py --store-key` (clé lue dans SOULBAH_AGENT_KEY ou sur
l'entrée standard), puis retirer SOULBAH_AGENT_KEY de agent/.env. `--forget-key` efface
le fichier. config.load_config charge la clé DPAPI quand SOULBAH_AGENT_KEY est vide.

NB : ce module porte le nom du module standard `secrets` (choix du lot). Comme agent/ est
en tête de sys.path, il le masque : l'API publique du module standard est donc réexportée
ci-dessous pour qu'aucune bibliothèque qui en dépendrait ne casse.
"""
from __future__ import annotations

import importlib.util
import logging
import os
import sys
import sysconfig
from typing import Any

log = logging.getLogger("soulbah.secrets")

KEY_FILE_NAME = "agent_key.dpapi"
# Entropie supplémentaire : lie le blob à l'agent (un autre programme du même compte
# ne le déchiffre pas « par hasard »). Ce n'est pas un secret.
_ENTROPY = b"SoulbahAgent/agent_key/v1"
_CRYPTPROTECT_UI_FORBIDDEN = 0x01
_MIN_KEY_LEN = 8


# --- Réexport du module standard `secrets` (masqué par ce fichier) --------------------
def _load_stdlib_secrets() -> Any | None:
    try:
        path = os.path.join(sysconfig.get_paths()["stdlib"], "secrets.py")
        spec = importlib.util.spec_from_file_location("_stdlib_secrets", path)
        if spec is None or spec.loader is None:
            return None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except Exception:  # noqa: BLE001 - réexport best-effort
        return None


_stdlib = _load_stdlib_secrets()
if _stdlib is not None:
    SystemRandom = _stdlib.SystemRandom
    DEFAULT_ENTROPY = _stdlib.DEFAULT_ENTROPY
    choice = _stdlib.choice
    randbelow = _stdlib.randbelow
    randbits = _stdlib.randbits
    token_bytes = _stdlib.token_bytes
    token_hex = _stdlib.token_hex
    token_urlsafe = _stdlib.token_urlsafe
    compare_digest = _stdlib.compare_digest


# --- Emplacement -----------------------------------------------------------------------
def secrets_dir() -> str:
    override = os.environ.get("SOULBAH_SECRETS_DIR", "").strip()
    if override:
        return override
    base = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Local")
    return os.path.join(base, "Soulbah")


def key_file() -> str:
    return os.path.join(secrets_dir(), KEY_FILE_NAME)


def has_agent_key() -> bool:
    """True si un fichier DPAPI existe (sans tenter de le déchiffrer)."""
    return os.path.isfile(key_file())


# --- DPAPI (ctypes) --------------------------------------------------------------------
def _dpapi():
    if sys.platform != "win32":
        raise NotImplementedError(
            "stockage chiffré de la clé agent disponible sous Windows uniquement (DPAPI) ; "
            "aucun repli en clair n'est prévu : fournissez SOULBAH_AGENT_KEY par l'environnement."
        )
    import ctypes
    from ctypes import wintypes

    class DATA_BLOB(ctypes.Structure):  # noqa: N801 - nom Win32
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    blob_p = ctypes.POINTER(DATA_BLOB)
    crypt32.CryptProtectData.argtypes = [blob_p, wintypes.LPCWSTR, blob_p, ctypes.c_void_p, ctypes.c_void_p,
                                         wintypes.DWORD, blob_p]
    crypt32.CryptProtectData.restype = wintypes.BOOL
    crypt32.CryptUnprotectData.argtypes = [blob_p, ctypes.POINTER(wintypes.LPWSTR), blob_p, ctypes.c_void_p,
                                           ctypes.c_void_p, wintypes.DWORD, blob_p]
    crypt32.CryptUnprotectData.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p

    def to_blob(data: bytes) -> DATA_BLOB:
        buf = ctypes.create_string_buffer(data, len(data))
        return DATA_BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))

    def from_blob(blob: DATA_BLOB) -> bytes:
        try:
            return ctypes.string_at(blob.pbData, blob.cbData)
        finally:
            kernel32.LocalFree(blob.pbData)

    def protect(data: bytes) -> bytes:
        out = DATA_BLOB()
        entropy = to_blob(_ENTROPY)
        if not crypt32.CryptProtectData(ctypes.byref(to_blob(data)), "SoulBah agent key", ctypes.byref(entropy),
                                        None, None, _CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(out)):
            raise OSError(ctypes.get_last_error(), "CryptProtectData a échoué")
        return from_blob(out)

    def unprotect(data: bytes) -> bytes:
        out = DATA_BLOB()
        entropy = to_blob(_ENTROPY)
        if not crypt32.CryptUnprotectData(ctypes.byref(to_blob(data)), None, ctypes.byref(entropy), None, None,
                                          _CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(out)):
            raise OSError(ctypes.get_last_error(), "CryptUnprotectData a échoué")
        return from_blob(out)

    return protect, unprotect


# --- API ---------------------------------------------------------------------------------
def store_agent_key(key: str) -> str:
    """Chiffre `key` (DPAPI, utilisateur courant) et l'écrit atomiquement. Retourne le
    chemin du fichier. ValueError si la clé est vide ou trop courte."""
    if not isinstance(key, str) or len(key.strip()) < _MIN_KEY_LEN:
        raise ValueError(f"clé agent invalide (au moins {_MIN_KEY_LEN} caractères attendus)")
    protect, _ = _dpapi()
    blob = protect(key.strip().encode("utf-8"))
    path = key_file()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(blob)
    os.replace(tmp, path)
    return path


def load_agent_key() -> str | None:
    """Clé déchiffrée, ou None si aucun fichier n'existe ou s'il est illisible /
    indéchiffrable (autre compte, autre machine, fichier altéré) — avec avertissement.
    Lève NotImplementedError hors Windows quand un fichier existe."""
    path = key_file()
    if not os.path.isfile(path):
        return None
    _, unprotect = _dpapi()
    try:
        with open(path, "rb") as f:
            blob = f.read()
        key = unprotect(blob).decode("utf-8").strip()
    except (OSError, UnicodeDecodeError) as e:
        log.warning("Clé agent DPAPI illisible (%s) : %s — relancez `--store-key`", path, e)
        return None
    if len(key) < _MIN_KEY_LEN:
        log.warning("Clé agent DPAPI vide ou trop courte (%s) — relancez `--store-key`", path)
        return None
    return key


def delete_agent_key() -> bool:
    """Supprime le fichier DPAPI. True s'il existait."""
    path = key_file()
    try:
        os.remove(path)
        return True
    except FileNotFoundError:
        return False
